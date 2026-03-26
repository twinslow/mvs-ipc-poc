         TITLE 'STCREQ - STCPOC IPC Request Module'
***********************************************************************
*  STCREQ  - IPC Module for STCPOC                                    *
*                                                                     *
*  FUNCTION:                                                          *
*    Callable subroutine that sends a request to the STCMAIN          *
*    started task via the shared CSA anchor block and returns         *
*    the response.  Self-initializing: on the first call it reads     *
*    the ANCHOR dataset, validates the eye-catcher, and switches      *
*    to supervisor state.  Subsequent calls skip initialisation.      *
*                                                                     *
*  CALLING CONVENTION:                                                *
*    Standard OS linkage.  R1 -> parameter list.                      *
*    The parameter list contains one fullword: the address of the     *
*    STCRQPB parameter block.                                         *
*                                                                     *
*    CALL  STCREQ,(parmblk)                                           *
*                                                                     *
*  PARAMETER BLOCK (STCRQPB DSECT):                                   *
*    SRQREQD  CL80  - Request data  (caller fills before call)        *
*    SRQRSPD  CL80  - Response data (filled on return)                *
*    SRQRTCD  F     - Return code   (filled on return)                *
*                                                                     *
*  RETURN CODES (in R15 and SRQRTCD):                                 *
*    0  - Success                                                     *
*    4  - ANCHOR dataset empty / server not started                   *
*    8  - Bad eye-catcher (stale anchor)                              *
*   12  - Server returned non-zero return code                        *
*   16  - POST to server failed                                       *
*                                                                     *
*  AUTHORIZATION:  APF required (needs MODESET KEY=ZERO)              *
*                                                                     *
*  DD STATEMENTS REQUIRED (in caller's JCL):                          *
*    ANCHOR  - Sequential dataset written by STCMAIN                  *
*              (RECFM=F,LRECL=4,BLKSIZE=4), DISP=SHR                  *
*                                                                     *
*  REGISTER CONVENTIONS:                                              *
*    R10 = STCANCB DSECT base (CSA anchor block)                      *
*    R11 = STCRQPB DSECT base (caller's parameter block)              *
*    R12 = Program base register                                      *
*    R13 = Save area chain                                            *
***********************************************************************
STCREQ   CSECT
         YREGS
*
         COPY  STCRQPB                Parameter block DSECT
         COPY  STCDSECT               CSA anchor block DSECT
STCREQ   CSECT                        Re-establish CSECT after DSECTs
*----------------------------------------------------------------------
* Prolog - standard OS linkage
*----------------------------------------------------------------------
         STM   R14,R12,12(R13)        Save caller registers
         BALR  R12,0
         USING *,R12
         LR    R11,R1                 Save R1 (parm list) before prolog
         LA    R1,SAVEAREA
         ST    R1,8(R13)
         ST    R13,4(R1)
         LR    R13,R1
*
*----------------------------------------------------------------------
* Address the parameter block via R11
*----------------------------------------------------------------------
         L     R11,0(,R11)           Deref parm list -> PB address
*
* Handle high-bit-on in last parm pointer (OS convention)
*
         LA    R11,0(,R11)           Clear high byte
         USING STCRQPB,R11           Map parameter block DSECT
*
*----------------------------------------------------------------------
* Check if already initialised (ANCHOR read + MODESET done)
*----------------------------------------------------------------------
         CLI   INITFLAG,X'FF'
         BE    DOREQ                 Already init'd - go to request
*
***********************************************************************
*  I N I T I A L I S A T I O N  (first call only)
*  Read ANCHOR dataset, validate eye-catcher, switch to key 0.
***********************************************************************
*
         OPEN  (ANCHRDCB,(INPUT))
*
         LA    R1,NODATA
         STCM  R1,B'0111',ANCHRDCB+62  Set EODAD
*
         GET   ANCHRDCB,CSAADDR      Read 4-byte CSA address
*
         CLOSE (ANCHRDCB)
*
         L     R10,CSAADDR
         LTR   R10,R10
         BZ    NODATA                Zero = STC not started
         ST    R10,CSAADDR           Save validated address
*
*  Switch to supervisor state (required for CSA access)
*
         MODESET KEY=ZERO,MODE=SUP
*
*  Validate eye-catcher
*
         USING STCANCB,R10
         CLC   STCEYEC,=CL4'STCA'
         BNE   BADEYEC
*
*  Mark as initialised
*
         MVI   INITFLAG,X'FF'
         B     DOREQ
*
***********************************************************************
*  D O R E Q  - Process one request
*
*  Assumes:  R10 = CSA anchor addr (from CSAADDR)
*            R11 = parameter block addr (STCRQPB)
*            Supervisor state already active
***********************************************************************
DOREQ    EQU   *
         L     R10,CSAADDR           Reload CSA anchor address
         USING STCANCB,R10
*
*----------------------------------------------------------------------
* ENQ to serialise against other clients
*----------------------------------------------------------------------
         ENQ   (ENQQNAME,ENQRNAME,E,L'ENQRNAME,SYSTEM)
*
*----------------------------------------------------------------------
* Clear reply ECB, store our ASCB for cross-AS POST
*----------------------------------------------------------------------
         XC    STCRECB,STCRECB
         L     R2,X'224'(0,0)        PSAAOLD = our ASCB
         ST    R2,STCCASCB
*
*----------------------------------------------------------------------
* Copy request data from parameter block into CSA anchor
*----------------------------------------------------------------------
         MVC   STCREQD,SRQREQD
*
*----------------------------------------------------------------------
* POST STCWECB to wake the server (with STCK timing)
*----------------------------------------------------------------------
         STCK  TIMSTRT                Capture start TOD
         L     R2,STCSASCB           Server's ASCB
         LA    R1,STCWECB            Work ECB in CSA
         POST  (1),0,ASCB=(2),ERRET=POSTERRC
*
*----------------------------------------------------------------------
* WAIT for server response
*----------------------------------------------------------------------
         LA    R1,STCRECB
         WAIT  1,ECB=(1)
*
         STCK  TIMEND                 Capture end TOD
*----------------------------------------------------------------------
* Calculate elapsed milliseconds (POST->WAIT round-trip)
*----------------------------------------------------------------------
         L     R3,TIMEND+4
         SL    R3,TIMSTRT+4
         SRL   R3,12                 TOD units -> microseconds
         SR    R2,R2
         D     R2,=F'1000'          R3 = milliseconds
         ST    R3,SRQELMS            Store in parameter block
*
*----------------------------------------------------------------------
* Copy response and return code from CSA into parameter block
*----------------------------------------------------------------------
         MVC   SRQRSPD,STCRSPD       Response data
         MVC   SRQRTCD,STCRETCD      Server return code
*
*----------------------------------------------------------------------
* DEQ
*----------------------------------------------------------------------
         DEQ   (ENQQNAME,ENQRNAME,L'ENQRNAME,SYSTEM)
*
*----------------------------------------------------------------------
* Check server return code
*----------------------------------------------------------------------
         L     R6,SRQRTCD
         LTR   R6,R6
         BNZ   SRVRERR               Server returned error
*
*  Success - RC=0
*
         SR    R15,R15
         B     RETURN
*
***********************************************************************
*  Error / return paths
***********************************************************************
NODATA   EQU   *
         CLOSE (ANCHRDCB)            Close in case open
         LA    R15,4
         ST    R15,SRQRTCD
         B     RETURN
*
BADEYEC  EQU   *
         MODESET KEY=NZERO,MODE=PROB
         LA    R15,8
         ST    R15,SRQRTCD
         B     RETURN
*
SRVRERR  EQU   *
         LA    R15,12
         B     RETURN
*
POSTERRC EQU   *
         DEQ   (ENQQNAME,ENQRNAME,L'ENQRNAME,SYSTEM)
         LA    R15,16
         ST    R15,SRQRTCD
         B     RETURN
*
***********************************************************************
*  R E T U R N  - Epilog
***********************************************************************
RETURN   EQU   *
         L     R13,4(R13)
         L     R14,12(R13)           Restore return address
         LM    R0,R12,20(R13)        Restore R0-R12, skip R15
         BR    R14
*
***********************************************************************
*  S T A T I C   W O R K I N G   S T O R A G E
***********************************************************************
         DS    0F
SAVEAREA DS    18F                   Standard save area
CSAADDR  DS    A                     CSA anchor address (from ANCHOR)
INITFLAG DC    X'00'                 X'FF' = initialised
         DS    0D                     Doubleword alignment for STCK
TIMSTRT  DS    D                     STCK start time
TIMEND   DS    D                     STCK end time
*
*----------------------------------------------------------------------
* ENQ resource name components
*----------------------------------------------------------------------
ENQQNAME DC    CL8'STCPOC  '        ENQ major name
ENQRNAME DC    CL8'ANCBLK  '        ENQ minor name
*
*----------------------------------------------------------------------
* ANCHOR dataset DCB
*----------------------------------------------------------------------
ANCHRDCB DCB   DDNAME=ANCHOR,                                          *
               DSORG=PS,                                               *
               MACRF=(GM),                                             *
               RECFM=F,                                                *
               LRECL=4,                                                *
               BLKSIZE=4
*
         LTORG
*
         CVT   DSECT=YES
*
         END
