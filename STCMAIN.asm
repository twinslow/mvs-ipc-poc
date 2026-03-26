         TITLE 'STCMAIN - STCPOC Request/Response Server'
***********************************************************************
*  STCMAIN  - Started Task Server for STCPOC POC                      *
*                                                                     *
*  FUNCTION:                                                          *
*    Allocates a shared control block in CSA (Common Service Area).   *
*    Publishes its address so batch clients can locate it.            *
*    Waits for client requests, processes them, and returns a         *
*    response. Handles the P (STOP) operator command gracefully.      *
*                                                                     *
*  AUTHORIZATION:  APF required  (link with SETCODE AC=1)             *
*                                                                     *
*  OPERATOR INTERFACE:                                                *
*    START STCPOC    - Start the server                               *
*    P STCPOC        - Graceful shutdown                              *
*                                                                     *
*  DD STATEMENTS IN PROC:                                             *
*    ANCHOR   - Sequential PS dataset (RECFM=F,LRECL=4,BLKSIZE=4)     *
*               STCMAIN writes its 4-byte CSA address here at start   *
*               so batch clients can discover the shared block.       *
*               Use DISP=SHR - STC opens/writes/closes immediately.   *
*                                                                     *
*  RETURN CODES:                                                      *
*    0  - Normal termination                                          *
*                                                                     *
*  REGISTER CONVENTIONS:                                              *
*    R10 = Base for STCANCB DSECT (CSA anchor block address)          *
*    R12 = Program base register                                      *
*    R13 = Standard 18-word save area pointer                         *
*                                                                     *
*  HOW IT WORKS:                                                      *
*    1. Switches to supervisor state (key 0)                          *
*    2. Allocates STCANCBL bytes from CSA subpool 228                 *
*    3. Initialises the anchor block (zeros + eye-catcher)            *
*    4. Writes the CSA address (4 bytes) to the ANCHOR dataset        *
*    5. EXTRACT/QEDIT to set up operator cmd handling (CIBs)          *
*    6. Enters WAIT loop on ECBLIST (work ECB + COMM ECB)             *
*    7. On wakeup: if COMM ECB - handle STOP/MODIFY via CIB           *
*    8. If work ECB - calls PROCESSQ, then loops back to WAIT         *
***********************************************************************
STCMAIN  CSECT
         YREGS                        Define R0-R15 register equates
*----------------------------------------------------------------------
* Program Prolog - standard OS linkage convention
*----------------------------------------------------------------------
         STM   R14,R12,12(R13)          Save caller's registers
         BALR  R12,0                    Establish base register
         USING *,R12                    Base = first executable inst
         LA    R1,SAVEAREA              Our save area
         ST    R1,8(R13)               Forward chain: caller -> us
         ST    R13,4(R1)               Backward chain: us -> caller
         LR    R13,R1                   R13 -> our save area
*
*----------------------------------------------------------------------
* Switch to supervisor state, storage key 0, for CSA operations.
* This requires APF authorization (SETCODE AC=1 at link-edit time).
*----------------------------------------------------------------------
         MODESET KEY=ZERO,MODE=SUP
*
*----------------------------------------------------------------------
* Allocate the STC Anchor Control Block from CSA.
* SP=228 = Common Service Area - shared across ALL address spaces.
* This block is used by batch clients in other address spaces to
* communicate with this started task.
*----------------------------------------------------------------------
         GETMAIN R,LV=STCANCBL,SP=228  Allocate from CSA
         LR    R10,R1                   R10 -> anchor block
         USING STCANCB,R10             Map DSECT onto allocated block
*
*----------------------------------------------------------------------
* Initialise the anchor block: zero all fields, set eye-catcher.
*----------------------------------------------------------------------
         XC    0(STCANCBL,R10),0(R10)  Zero the entire block
         MVC   STCEYEC,=CL4'STCA'     Set eye-catcher
*
*  Store our ASCB address so clients can POST to us cross-AS.
*  PSAAOLD (PSA+X'224') = home address space ASCB address.
*
         L     R2,X'224'(0,0)          PSAAOLD from PSA
         ST    R2,STCSASCB             Server ASCB -> anchor block
*
*----------------------------------------------------------------------
* Save the CSA anchor address in module storage.
* Used by PUT to write the address to the ANCHOR dataset.
*----------------------------------------------------------------------
         ST    R10,STCANCAR           Save for ANCHOR dataset write
*
*----------------------------------------------------------------------
* Publish the CSA anchor address to the ANCHOR dataset.
* Batch clients open this dataset (DISP=SHR,INPUT) to discover
* where the shared control block lives in storage.
* We open OUTPUT, write 4 bytes, close immediately.
*----------------------------------------------------------------------
         OPEN  (ANCHRDCB,(OUTPUT))     Open the anchor dataset
         PUT   ANCHRDCB,STCANCAR     Write 4-byte CSA address
         CLOSE (ANCHRDCB)              Close - clients can now read it
*
*----------------------------------------------------------------------
* Get the operator command interface via EXTRACT.
* FIELDS=COMM returns the address of the communications parameter
* list (IEZCOM):  +0 = COMM ECB,  +4 = CIB chain pointer.
*----------------------------------------------------------------------
         EXTRACT COMMADDR,'S',FIELDS=COMM
         L     R9,COMMADDR            R9 -> IEZCOM (comm parm list)
*
*----------------------------------------------------------------------
* Free the initial START CIB if present.
* MVS creates a CIB for the START command; we must free it via
* QEDIT before we can receive subsequent STOP/MODIFY commands.
*----------------------------------------------------------------------
         L     R8,4(,R9)              R8 -> first CIB
         LTR   R8,R8
         BZ    NOCIB                   No CIB present
         CLI   4(R8),CIBSTART         Is it a START CIB?
         BNE   NOCIB
         LA    R7,4(,R9)              R7 -> COMCIBPT field
         QEDIT ORIGIN=(R7),BLOCK=(R8)    Free the START CIB
NOCIB    EQU   *
*
*----------------------------------------------------------------------
* Build the two-entry ECBLIST for the main WAIT.
* Entry 1 = STCWECB (client request)
* Entry 2 = COMM ECB (operator command) - high bit set = last
*----------------------------------------------------------------------
         LA    R1,STCWECB             Work ECB address in CSA
         ST    R1,ECBLST              First entry
         L     R1,COMMADDR            R1 -> IEZCOM
         L     R1,0(,R1)              R1 = COMM ECB addr (deref ptr)
         O     R1,=X'80000000'        Mark as last entry
         ST    R1,ECBLST+4            Second entry
*
*----------------------------------------------------------------------
* Announce that the server is ready.
*----------------------------------------------------------------------
         WTO   'SSRVR001I STCMAIN STARTED - WAITING FOR REQUESTS',     *
               ROUTCDE=11
*
***********************************************************************
*  M A I N   L O O P
*  The server spends its life here:
*    WAIT on ECBLIST -> check which ECB posted -> dispatch -> repeat
***********************************************************************
MAINLOOP EQU   *
*
*  Wait until either:
*   (a) a batch client POSTs STCWECB (a request has arrived), or
*   (b) MVS posts the COMM ECB  (operator STOP/MODIFY command)
*
         WAIT  1,ECBLIST=ECBLST        Suspend until any ECB posted
*
*  Check COMM ECB first - operator commands take priority
*
         L     R9,COMMADDR             R9 -> IEZCOM
         L     R7,0(,R9)               R7 -> COMM ECB (deref ptr)
         TM    0(R7),X'40'             COMM ECB posted? (complete bit)
         BO    CMDRECVD                 Yes - process operator command
*
*  Work ECB posted - a client request arrived.
*  Clear the work ECB so the next WAIT will block properly.
*
         XC    STCWECB,STCWECB         Clear work ECB for next cycle
*
         BAL   R14,PROCESSQ            Call request processor
*
         B     MAINLOOP                Loop back to wait
*
***********************************************************************
*  P R O C E S S Q  - Process one client request
*
*  Input:  STCREQD (80 bytes) - request data written by client
*  Output: STCRSPD (80 bytes) - response to return to client
*          STCRETCD (fullword) - 0=success, non-zero=error
*          STCRECB is POSTed  - wakes the waiting client
*
*  >>>  R E P L A C E   T H E   E C H O   L O G I C   B E L O W   <<<
*  >>>  W I T H   Y O U R   A C T U A L   B U S I N E S S   L O G I C
***********************************************************************
PROCESSQ EQU  *
         ST    R14,PRQSAVE             Save return address
*
         WTO   'SSRVR002I REQUEST RECEIVED - PROCESSING',ROUTCDE=11
*
*----------------------------------------------------------------------
*  B U S I N E S S   L O G I C   S T A R T S   H E R E
*
*  At entry:
*    STCREQD  - 80-byte request from the client (read-only)
*  Set before returning:
*    STCRSPD  - 80-byte response to the client
*    STCRETCD - return code (0=success, non-zero=error code)
*
*  For this POC we simply echo the request back with a prefix,
*  demonstrating that the STC received and processed the data.
*  Replace this section with your real server logic.
*----------------------------------------------------------------------
*
         MVC   STCRSPD,=CL80' '        Clear response area
         MVC   STCRSPD(8),=CL8'RESP=>  '  8-char prefix
         MVC   STCRSPD+8(72),STCREQD   Copy 72 chars of request data
*
         XC    STCRETCD,STCRETCD        Return code = 0 (success)
*
*----------------------------------------------------------------------
*  B U S I N E S S   L O G I C   E N D S   H E R E
*----------------------------------------------------------------------
*
         WTO   'SSRVR003I RESPONSE READY - NOTIFYING CLIENT',          *
               ROUTCDE=11
*
*  POST the reply ECB to wake the client that is WAITing on it.
*  Register form used for the same reason as the WAIT above.
*
         L     R2,STCCASCB             R2 = client's ASCB address
         LA    R1,STCRECB              R1 = real CSA addr of reply ECB
         POST  (1),0,ASCB=(2),ERRET=POSTERRS  Wake client cross-AS
*
         L     R14,PRQSAVE             Restore return address
         BR    R14
*
***********************************************************************
*  P O S T E R R S  - POST ERRET for server reply POST
*
*  Entered if the cross-AS POST of STCRECB fails (e.g. client
*  address space has terminated).  Log the error and return to
*  the main loop so the server keeps running.
***********************************************************************
POSTERRS EQU   *
         WTO   'SSRVR006E POST REPLY TO CLIENT FAILED',ROUTCDE=11
         L     R14,PRQSAVE             Restore return address
         BR    R14                     Return to main loop
*
***********************************************************************
*  C M D R E C V D  - Process operator command from CIB
*
*  Reached from MAINLOOP when the COMM ECB is posted.
*  R9 -> IEZCOM (loaded before branching here).
*  Reads the CIB verb to determine action:
*    STOP  (P STCPOC)   -> free CIB, branch to SHUTDOWN
*    MODIFY              -> log, free CIB, clear COMM ECB, loop
*    No CIB              -> clear COMM ECB, loop (spurious wake)
***********************************************************************
CMDRECVD EQU   *
         L     R8,4(,R9)               R8 -> CIB (from COMCIBPT)
         LTR   R8,R8
         BZ    CMDCLR                   No CIB - clear COMM ECB & loop
*
         CLI   4(R8),CIBSTOP           CIBVERB = STOP?
         BE    DOSTOP                   Yes - initiate shutdown
*
*  Not STOP (e.g. MODIFY) - log, free the CIB, continue
*
         WTO   'SSRVR007I MODIFY COMMAND RECEIVED - IGNORED',          *
               ROUTCDE=11
         LA    R7,4(,R9)               R7 -> COMCIBPT field in IEZCOM
         QEDIT ORIGIN=(R7),BLOCK=(R8)    Free the CIB
CMDCLR   EQU   *
         L     R7,0(,R9)               R7 -> COMM ECB (deref ptr)
         XC    0(4,R7),0(R7)           Clear COMM ECB for next WAIT
         B     MAINLOOP
*
DOSTOP   EQU   *
         WTO   'SSRVR008I STOP COMMAND RECEIVED',ROUTCDE=11
         LA    R7,4(,R9)               R7 -> COMCIBPT field in IEZCOM
         QEDIT ORIGIN=(R7),BLOCK=(R8)    Free the STOP CIB
         B     SHUTDOWN
*
***********************************************************************
*  S H U T D O W N  - Graceful termination
*
*  Called from DOSTOP when the operator issues P STCPOC.
*  Nulls out the saved anchor address, frees the CSA block,
*  and returns to MVS.
***********************************************************************
SHUTDOWN EQU   *
         WTO   'SSRVR004I SHUTDOWN IN PROGRESS - FREEING CSA',         *
               ROUTCDE=11
*
*  Clear the eye-catcher so late-arriving clients see a stale block.
*
         XC    STCEYEC,STCEYEC       Clear eye-catcher in CSA block
*
*  Null the saved anchor address before freeing CSA.
*
         XC    STCANCAR,STCANCAR     Null saved anchor address
*
*  Free the CSA anchor block back to the system
*
         FREEMAIN R,LV=STCANCBL,A=(R10),SP=228
*
*  Return to problem state before exiting (housekeeping)
*
         MODESET KEY=NZERO,MODE=PROB
*
         WTO   'SSRVR005I STCMAIN TERMINATED NORMALLY',ROUTCDE=11
*
*  Normal return to MVS with return code 0
*
         L     R13,4(R13)              Restore caller save area ptr
         LM    R14,R12,12(R13)         Restore caller registers
         SR    R15,R15                 Return code = 0
         BR    R14
*
***********************************************************************
*  S T A T I C   W O R K I N G   S T O R A G E
***********************************************************************
         DS    0F                       Force fullword alignment
SAVEAREA DS    18F                      Standard 18-word save area
STCANCAR DS    A                       CSA anchor addr (ANCHOR write)
PRQSAVE  DS    F                       PROCESSQ linkage save
COMMADDR DS    A                       IEZCOM addr (from EXTRACT)
ECBLST   DS    2A                      ECBLIST: work ECB, COMM ECB
*
*----------------------------------------------------------------------
* CIB command verb equates (from IEZCIB DSECT)
*----------------------------------------------------------------------
CIBSTART EQU   X'04'                   START command
CIBSTOP  EQU   X'40'                   STOP (P) command
CIBMODFY EQU   X'44'                   MODIFY (F) command
*
*----------------------------------------------------------------------
*  ANCHOR dataset DCB
*  Writes the 4-byte binary CSA anchor address at startup.
*  Clients read this file to locate the shared CSA control block.
*
*  RECFM=F, LRECL=4, BLKSIZE=4:  one fixed 4-byte physical block.
*----------------------------------------------------------------------
ANCHRDCB DCB   DDNAME=ANCHOR,                                          *
               DSORG=PS,                                               *
               MACRF=(PM),                                             *
               RECFM=F,                                                *
               LRECL=4,                                                *
               BLKSIZE=4
*
         LTORG                          Literal pool
*
***********************************************************************
*  D S E C T s
***********************************************************************
         COPY  STCDSECT                 Anchor block layout
         CVT   DSECT=YES                CVT mapping (from SYS1.AMODGEN)
*
         END   STCMAIN
