# STCPOC - MVS 3.8J Started Task POC

A proof-of-concept showing how a started task (STC) can accept requests
from batch jobs in other address spaces, process them, and return responses,
all through a shared CSA control block.

The original code was written by Claude, but I later switched to using 
Warp (which us also using claude and more). It was partly an excercise 
in creating a started task and a job that could communicate with that
started task -- but also in seeing how the current LLMs could handle
mainframe MVS related development. That answer to the latter is
better than I thought. 

---

## Files in This Package

| File           | Description                                          |
|----------------|------------------------------------------------------|
| STCDSECT.asm   | DSECT copybook - shared CSA anchor block layout      |
| STCRQPB.asm    | DSECT copybook - STCREQ request parameter block      |
| STCMAIN.asm    | Started task server program                          |
| STCCLNT.asm    | Batch client application (loop, timing, reporting)   |
| STCREQ.asm     | IPC module - sends request to server via CSA         |
| STCPOC.PROC    | JCL procedure for the started task                   |
| STCBLD.JCL     | Assemble + link-edit job for all programs             |
| STCTEST.JCL    | Batch job to run the client test                     |
| deploy.sh      | Automated build & deploy script for Hercules         |
| DEPLOY.md      | Documentation for the deploy script                  |

---

## Architecture

The client application (STCCLNT) calls the IPC module (STCREQ) which
handles all communication with the server (STCMAIN) via a shared CSA
anchor block.  STCREQ is self-initialising: on its first call it reads
the ANCHOR dataset, validates the eye-catcher, and switches to
supervisor state.  Subsequent calls skip straight to ENQ/POST/WAIT/DEQ.

```
  STCCLNT (application)     STCREQ (IPC module)       STCMAIN (server)
  ─────────────────────     ───────────────────       ─────────────────
  Fill SRQREQD in PB
  CALL STCREQ ───────────>  (first call only:)
                            Read ANCHOR dataset
                            MODESET KEY=ZERO
                            Validate eye-catcher
                            ─────────────────────
                            ENQ STCPOC.ANCBLK
                            Copy SRQREQD → STCREQD
                            POST STCWECB ─────────>  WAIT ECBLIST
                                                     Process request
                                                     Write STCRSPD
                            WAIT STCRECB <─────────  POST STCRECB
                            Copy STCRSPD → SRQRSPD
                            DEQ STCPOC.ANCBLK
  Read SRQRSPD from PB <──  Return RC in R15
  Report timing + response
  Random delay
  (loop)
```

PB = STCRQPB parameter block passed between STCCLNT and STCREQ.

The shared medium is a **224-byte CSA anchor block** in subpool 228:

```
Offset  Field      Len  Description
──────  ─────      ───  ───────────
+0      STCEYEC    4    Eye-catcher: 'STCA'
+4      STCWECB    4    Work ECB  - server WAITs here for requests
+8      STCRECB    4    Reply ECB - client  WAITs here for responses
+12     STCSFLAG   4    Shutdown flag (reserved - unused after STAX removal)
+16     STCREQD    80   Request data  (client writes)
+96     STCRSPD    80   Response data (server writes)
+176    STCRETCD   4    Server return code
+180    STCSASCB   4    Server ASCB address (for cross-AS POST)
+184    STCCASCB   4    Client ASCB address (for cross-AS POST)
+188    STCRESRV   36   Reserved
```

---

## Prerequisites

1. **MVS 3.8J** running under Hercules (or real iron).
2. **Assembler** - IFOX00 (OS/360 Assembler F) on SYS1.LINKLIB or SYS1.SVCLIB.
3. **IBM macro libraries**:
   - `SYS2.MACLIB`  - WTO, GETMAIN, MODESET, EXTRACT, QEDIT, ENQ, POST, WAIT, etc.
   - `SYS1.AMODGEN` - CVT DSECT and other system mappings.

---

## Step 1 - Pre-allocate Datasets

Upload the source members to MVS (using IND$FILE, XMIT, or your preferred
transfer method), then allocate the required datasets.

### Source library (SRCLIB) - PDS for assembler source
```
//ALLOCSRC EXEC PGM=IEFBR14
//SRCLIB   DD DSN=STCPOC.SRCLIB,DISP=(NEW,CATLG),
//            UNIT=SYSDA,SPACE=(TRK,(5,2,10)),
//            DCB=(RECFM=FB,LRECL=80,BLKSIZE=3120)
```
Upload: STCMAIN, STCCLNT, STCREQ, STCDSECT, STCRQPB → STCPOC.SRCLIB

### Macro library (MACLIB) - PDS for the COPY member
```
//ALLOCMAC EXEC PGM=IEFBR14
//MACLIB   DD DSN=STCPOC.MACLIB,DISP=(NEW,CATLG),
//            UNIT=SYSDA,SPACE=(TRK,(2,1,5)),
//            DCB=(RECFM=FB,LRECL=80,BLKSIZE=3120)
```
Upload: STCDSECT, STCRQPB → STCPOC.MACLIB  (assembler COPYs these)

### Load library (LOADLIB) - PDS for linked modules
```
//ALLOCLIB EXEC PGM=IEFBR14
//LOADLIB  DD DSN=STCPOC.LOADLIB,DISP=(NEW,CATLG),
//            UNIT=SYSDA,SPACE=(TRK,(10,5,5)),
//            DCB=(RECFM=U,BLKSIZE=6144)
```

### Anchor dataset - PS for the 4-byte CSA address
```
//ALLOCANC EXEC PGM=IEFBR14
//ANCHOR   DD DSN=STCPOC.ANCHOR,DISP=(NEW,CATLG),
//            UNIT=SYSDA,SPACE=(TRK,(1,1)),
//            DCB=(RECFM=F,LRECL=4,BLKSIZE=4)
```
**Note:** Content does not matter - STCMAIN overwrites it at startup.

---

## Step 2 - APF-Authorize the Load Library

STCMAIN and STCCLNT both use MODESET (to switch to key-0 supervisor state)
which requires the load module to be APF-authorized.

### Option A - IEAAPFxx PARMLIB member (static)
Add this line to `SYS1.PARMLIB(IEAAPF00)` (or whichever suffix is active):
```
STCPOC.LOADLIB   XXXXXX    (replace XXXXXX with the VOLSER of the disk volume)
```
Then IPL, or use SETPROG APF (if your MVS level supports it).

### Option B - PROGxx PARMLIB member (dynamic, MVS/SP 3.1+)
```
APF ADD DSNAME(STCPOC.LOADLIB) VOLUME(XXXXXX)
```

**Verify:** After authorization, `D PROG,APF` should list STCPOC.LOADLIB.

---

## Step 3 - Build the Programs

Submit `STCBLD.JCL` (or use `deploy.sh`).  It runs these steps:

```
ASMSTC  - Assemble STCMAIN  (assembler: IFOX00)
LNKSTC  - Link STCMAIN      (linker: IEWL, SETCODE AC=1)
ASMCLNT - Assemble STCCLNT  (assembler: IFOX00)
ASMREQ  - Assemble STCREQ   (assembler: IFOX00)
LNKCLNT - Link STCCLNT+STCREQ into single module (IEWL, SETCODE AC=1)
```

All steps must complete with return code 0.
The load library `STCPOC.LOADLIB` will contain members STCMAIN and
STCCLNT (the latter includes STCREQ as a linked CSECT).

**Common assembly errors and fixes:**

| Error                       | Cause                          | Fix                              |
|-----------------------------|--------------------------------|----------------------------------|
| IFO153 COPY STCDSECT FAILED | STCDSECT not in SYSLIB         | Add STCPOC.MACLIB to SYSLIB DD  |
| IFO153 MACRO NOT FOUND      | SYS2.MACLIB / SYS1.AMODGEN missing | Check SYSLIB concatenation  |
| IEWL SETCODE AC=1 rejected  | Linker doesn't support SETCODE | Use PARM='AC=1' on EXEC instead  |

---

## Step 4 - Install the JCL Procedure

Copy `STCPOC.PROC` to `SYS2.PROCLIB(STCPOC)` (or whichever PROCLIB JES2
uses).  Ensure:

- `STEPLIB DD DSN=STCPOC.LOADLIB` is APF-authorized.
- `ANCHOR  DD DSN=STCPOC.ANCHOR`  exists and is catalogued.

---

## Step 5 - Start the Server

From the MVS operator console (or the TCAS/SDSF command line):

```
START STCPOC
```

Expected SYSLOG messages (ROUTCDE=11, so check the hardcopy log):
```
SSRVR001I STCMAIN STARTED - WAITING FOR REQUESTS
```

The ANCHOR dataset now contains the 4-byte CSA address.
The STC is blocked in WAIT, consuming no CPU.

---

## Step 6 - Run the Client

Submit `STCTEST.JCL` as a batch job (or use `deploy.sh --test`).

The client sends 20 requests (configurable via `LOOPCNT EQU` in
`STCCLNT.asm`) with a random 50-1000ms delay between each.  Each
iteration produces a timing WTO showing start time, end time, and
POST-to-WAIT round-trip in milliseconds.

Expected SYSPRINT output (one line per request):
```
   RESPONSE: RESP=>  HELLO FROM STCCLNT - PLEASE ECHO THIS  SECOND HALF...
```

Expected SYSLOG (per request):
```
SCLNT010I CLIENT SENDING REQUEST 01 TO SERVER
SSRVR002I REQUEST RECEIVED - PROCESSING
SSRVR003I RESPONSE READY - NOTIFYING CLIENT
SCLNT011I CLIENT RECEIVED RESPONSE FROM SERVER
SCLNT012I S=16.56.21.47 E=16.56.21.50 R=00003 MS
```

The batch job return code should be 0.

---

## Step 7 - Stop the Server

From the operator console:
```
P STCPOC
```

Expected SYSLOG:
```
SSRVR008I STOP COMMAND RECEIVED
SSRVR004I SHUTDOWN IN PROGRESS - FREEING CSA
SSRVR005I STCMAIN TERMINATED NORMALLY
```

The server clears the eye-catcher in the CSA block (so late-arriving
clients see a stale block), frees the CSA storage, and terminates
with RC=0.

---

## Replacing the Echo Logic with Real Business Logic

The POC server simply echoes the request back with a `RESP=>  ` prefix.
To implement real server functionality, replace the section between the
two comment banners in `STCMAIN.asm`:

```asm
*  B U S I N E S S   L O G I C   S T A R T S   H E R E
...
*  B U S I N E S S   L O G I C   E N D S   H E R E
```

At entry to PROCESSQ:
- `STCREQD` (80 bytes, via R10/STCANCB) holds the client's request.

Before returning from PROCESSQ:
- Write your response into `STCRSPD` (80 bytes).
- Set `STCRETCD` to 0 for success or a non-zero error code.
- `POST STCRECB` (with `ASCB=` for cross-AS) is already done for you
  after PROCESSQ returns.

To pass more than 80 bytes, extend STCDSECT (STCREQD/STCRSPD fields)
and re-assemble both programs.

---

## Sending a Custom Request from the Client

In `STCCLNT.asm`, find the `REQTEXT` constant and replace it with your
data.  The request is copied into the `SRQREQD` field of the STCRQPB
parameter block before each `CALL STCREQ`:

```asm
REQTEXT  DC    CL40'HELLO FROM STCCLNT - PLEASE ECHO THIS  '
         DC    CL40'SECOND HALF OF REQUEST DATA             '
```

For a production client you would typically read the request from a
dataset or SYSIN, or accept it via the PARM field.

---

## Client / IPC Module Interface (STCRQPB)

STCCLNT calls STCREQ via standard OS linkage:
```asm
         CALL  STCREQ,(PARMBLK)
```

The parameter block layout (STCRQPB DSECT, defined in `STCRQPB.asm`):

```
Offset  Field      Len  Direction   Description
──────  ─────      ───  ─────────   ───────────
+0      SRQREQD    80   Caller→     Request data
+80     SRQRSPD    80   ←STCREQ     Response data
+160    SRQRTCD    4    ←STCREQ     Return code (also in R15)
+164    SRQELMS    4    ←STCREQ     Elapsed ms (POST→WAIT)
```

STCREQ is self-initialising.  On the first call it reads the ANCHOR
dataset, validates the eye-catcher, and issues MODESET KEY=ZERO.
Subsequent calls go straight to ENQ/POST/WAIT/DEQ.

---

## Known Limitations (POC)

| Limitation                        | Production Remedy                         |
|-----------------------------------|-------------------------------------------|
| Single client at a time (ENQ)     | Request queue with multiple ECBs          |
| 80-byte request/response          | Extend DSECT or use CSA-based buffer pool |
| MODIFY command logged but ignored | Add command parser to CMDRECVD            |
| No client timeout                 | WAIT with ECBLIST or timer ECB            |
| COMM ECB cleared manually         | Let QEDIT manage ECB state in production  |

---

## WTO Message Summary

Server messages use prefix **SSRVR**, client messages use **SCLNT**.

| Msgid        | Text                                           | Source  |
|--------------|------------------------------------------------|---------|
| SSRVR001I    | STCMAIN STARTED - WAITING FOR REQUESTS         | Server  |
| SSRVR002I    | REQUEST RECEIVED - PROCESSING                  | Server  |
| SSRVR003I    | RESPONSE READY - NOTIFYING CLIENT              | Server  |
| SSRVR004I    | SHUTDOWN IN PROGRESS - FREEING CSA             | Server  |
| SSRVR005I    | STCMAIN TERMINATED NORMALLY                    | Server  |
| SSRVR006E    | POST REPLY TO CLIENT FAILED                    | Server  |
| SSRVR007I    | MODIFY COMMAND RECEIVED - IGNORED              | Server  |
| SSRVR008I    | STOP COMMAND RECEIVED                          | Server  |
| SCLNT010I    | CLIENT SENDING REQUEST nn TO SERVER            | Client  |
| SCLNT011I    | CLIENT RECEIVED RESPONSE FROM SERVER           | Client  |
| SCLNT012I    | S=HH.MM.SS.hh E=HH.MM.SS.hh R=nnnnn MS       | Client  |
| SCLNT020E    | ANCHOR DATASET EMPTY - IS STCMAIN RUNNING?     | STCREQ  |
| SCLNT021E    | BAD EYE-CATCHER - STALE ANCHOR DATASET?        | STCREQ  |
| SCLNT022E    | POST REQUEST TO SERVER FAILED                  | STCREQ  |

SCLNT012I is a combined timing line: S=start time, E=end time
(HH.MM.SS.hh), R=POST-to-WAIT round-trip in milliseconds.

All messages use ROUTCDE=11 (hardcopy log only). Change to ROUTCDE=2 to
also display on the operator console.

---

## Technical Notes

### Cross-Address-Space POST
Both STCMAIN and STCREQ use `POST (reg),0,ASCB=(reg),ERRET=label` for
cross-address-space ECB posting.  The standard POST without `ASCB=`
only dispatches tasks in the caller's own address space.  Each program
stores its ASCB address (from PSAAOLD at PSA+X'224') in the shared CSA
block so the other side can use it.

### Client Timing
The client captures wall-clock time (`TIME BIN`) before and after each
request cycle (including ENQ/DEQ overhead), plus STCK-based millisecond
precision around the POST/WAIT round-trip.  All three values are
reported in a single SCLNT012I WTO per request.

### Operator Command Handling
The server uses `EXTRACT FIELDS=COMM` to obtain the IEZCOM communications
parameter list, which contains a pointer to the COMM ECB and the CIB
chain. The initial START CIB is freed via QEDIT at startup. The main
loop WAITs on an ECBLIST containing both the work ECB and the COMM ECB.
When the COMM ECB is posted, the server reads the CIB verb to determine
whether it is a STOP (P) or MODIFY (F) command.
