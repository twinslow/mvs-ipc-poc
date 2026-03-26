         TITLE 'STCCLNT - STCPOC Batch Client Application'
***********************************************************************
*  STCCLNT  - Batch Client Application for STCPOC POC                 *
*                                                                     *
*  FUNCTION:                                                          *
*    Sends multiple requests to the STCMAIN started task via the      *
*    STCREQ IPC module.  Each iteration fills a request, calls        *
*    STCREQ, reports the response, and waits a random delay.          *
*                                                                     *
*  MODULES CALLED:                                                    *
*    STCREQ - IPC module (linked into same load module)               *
*             Self-initializes on first call (reads ANCHOR, etc.)     *
*                                                                     *
*  AUTHORIZATION:  APF required (STCREQ uses MODESET)                 *
*                                                                     *
*  DD STATEMENTS REQUIRED:                                            *
*    ANCHOR   - STCMAIN anchor dataset (passed through to STCREQ)     *
*    SYSPRINT - Response output (RECFM=FBA,LRECL=133)                 *
*                                                                     *
*  RETURN CODES:                                                      *
*    0  - All requests completed successfully                         *
*    Other codes (4,8,12,16) passed through from STCREQ.              *
*                                                                     *
*  REGISTER CONVENTIONS:                                              *
*    R9  = Loop counter (current request number)                      *
*    R11 = STCRQPB DSECT base (parameter block)                       *
*    R12 = Program base register                                      *
*    R13 = Save area chain                                            *
***********************************************************************
STCCLNT  CSECT
         YREGS
*
         COPY  STCRQPB                Parameter block DSECT
STCCLNT  CSECT                        Re-establish CSECT after DSECT
*----------------------------------------------------------------------
* Program Prolog
*----------------------------------------------------------------------
         STM   R14,R12,12(R13)        Save caller registers
         BALR  R12,0                  Establish base register
         USING *,R12
         LA    R1,SAVEAREA
         ST    R1,8(R13)
         ST    R13,4(R1)
         LR    R13,R1
*
*----------------------------------------------------------------------
* Initialise return code and parameter block pointer
*----------------------------------------------------------------------
         SR    R15,R15
         ST    R15,RETCODE
         LA    R11,PARMBLK           R11 -> request parameter block
         USING STCRQPB,R11
*
*----------------------------------------------------------------------
* Open SYSPRINT (open once, close after loop)
*----------------------------------------------------------------------
         OPEN  (PRTDCB,(OUTPUT))
*
*----------------------------------------------------------------------
* Initialise request loop - R9 = current request number
* Change LOOPCNT EQU to adjust iteration count.
*----------------------------------------------------------------------
         LA    R9,1                  Start at request 1
*
***********************************************************************
*  R E Q U E S T   L O O P   (LOOPCNT iterations)
***********************************************************************
REQLOOP  EQU   *
*
* Capture start time of day
*
         TIME  BIN
         ST    R0,TIMBSTRT
*
* Fill request data in parameter block
*
         MVC   SRQREQD,=CL80' '
         MVC   SRQREQD(L'REQTEXT),REQTEXT
*
* Issue WTO with request number
*
         MVC   WTOSNWRK(WTOSNMLL),WTOSNMPL
         CVD   R9,DWORK
         UNPK  WTOSNWRK+37(2),DWORK+6(2)
         OI    WTOSNWRK+38,X'F0'
         WTO   MF=(E,WTOSNWRK)
*
***********************************************************************
*  Call STCREQ to send request and get response
***********************************************************************
         CALL  STCREQ,(PARMBLK)
         LTR   R15,R15
         BNZ   REQERR                Non-zero = error from STCREQ
*
         WTO   'SCLNT011I CLIENT RECEIVED RESPONSE FROM SERVER',       *
               ROUTCDE=11
*
         MVC   PRNTDATA(80),SRQRSPD
         B     REQRPT
*
*----------------------------------------------------------------------
* Request error - save RC, copy whatever response we got
*----------------------------------------------------------------------
REQERR   EQU   *
         ST    R15,RETCODE
         MVC   PRNTDATA(80),SRQRSPD
*
*----------------------------------------------------------------------
* Reporting: end time, combined timing WTO, print response
*----------------------------------------------------------------------
REQRPT   EQU   *
         TIME  BIN
         ST    R0,TIMBEND
*
* Build combined timing WTO: S=start E=end R=elapsed ms
*
         MVC   WTOCWRK(WTOCMPLL),WTOCMPL
         L     R0,TIMBSTRT
         BAL   R14,FMTTIM
         MVC   WTOCWRK+16(11),TIMFMT
         L     R0,TIMBEND
         BAL   R14,FMTTIM
         MVC   WTOCWRK+30(11),TIMFMT
         L     R3,SRQELMS            Elapsed ms from STCREQ
         CVD   R3,DWORK
         UNPK  WTOCWRK+44(5),DWORK+5(3)
         OI    WTOCWRK+48,X'F0'
         WTO   MF=(E,WTOCWRK)
*
* Print response to SYSPRINT
*
         MVC   PRTLINE(03),=C'   '
         MVC   PRTLINE+3(10),=C'RESPONSE: '
         MVC   PRTLINE+13(80),PRNTDATA
         PUT   PRTDCB,PRTLINE
*
*----------------------------------------------------------------------
* If STCREQ returned error, exit loop
*----------------------------------------------------------------------
         L     R6,RETCODE
         LTR   R6,R6
         BNZ   LOOPEND
*
*----------------------------------------------------------------------
* Check if more iterations remain
*----------------------------------------------------------------------
         C     R9,=A(LOOPCNT)
         BNL   LOOPEND
*
*----------------------------------------------------------------------
* Random delay 50-1000ms before next request
*----------------------------------------------------------------------
         STCK  DWORK
         L     R3,DWORK+4
         SRL   R3,12
         SR    R2,R2
         D     R2,=F'96'
         LA    R2,5(R2)
         ST    R2,DELAYTM
         STIMER WAIT,BINTVL=DELAYTM
*
         LA    R9,1(R9)
         B     REQLOOP
*
***********************************************************************
*  End of request loop
***********************************************************************
LOOPEND  EQU   *
         CLOSE (PRTDCB)
*
         L     R6,RETCODE
         LTR   R6,R6
         BZ    EXITOK
         LR    R15,R6
         B     EXITRC
*
EXITOK   EQU   *
         SR    R15,R15
EXITRC   EQU   *
         L     R13,4(R13)
         L     R14,12(R13)
         LM    R0,R12,20(R13)
         BR    R14
*
***********************************************************************
*  F M T T I M  - Format TIME BIN into TIMFMT buffer
*
*  Input:  R0 = hundredths since midnight
*  Output: TIMFMT = 'HH.MM.SS.hh' (11 chars)
*  Destroys: R0, R1, R2, R3
***********************************************************************
FMTTIM   EQU   *
         ST    R14,FMTSAVE
         LR    R3,R0
*
         SR    R2,R2
         D     R2,=F'360000'
         CVD   R3,DWORK
         UNPK  TIMFMT(2),DWORK+6(2)
         OI    TIMFMT+1,X'F0'
         MVI   TIMFMT+2,C'.'
*
         LR    R3,R2
         SR    R2,R2
         D     R2,=F'6000'
         CVD   R3,DWORK
         UNPK  TIMFMT+3(2),DWORK+6(2)
         OI    TIMFMT+4,X'F0'
         MVI   TIMFMT+5,C'.'
*
         LR    R3,R2
         SR    R2,R2
         D     R2,=F'100'
         CVD   R3,DWORK
         UNPK  TIMFMT+6(2),DWORK+6(2)
         OI    TIMFMT+7,X'F0'
         MVI   TIMFMT+8,C'.'
*
         LR    R3,R2
         CVD   R3,DWORK
         UNPK  TIMFMT+9(2),DWORK+6(2)
         OI    TIMFMT+10,X'F0'
*
         L     R14,FMTSAVE
         BR    R14
*
***********************************************************************
*  S T A T I C   W O R K I N G   S T O R A G E
***********************************************************************
         DS    0F
SAVEAREA DS    18F
RETCODE  DS    F
PRNTDATA DS    CL80
*
*----------------------------------------------------------------------
* Request parameter block (passed to STCREQ)
*----------------------------------------------------------------------
         DS    0F
PARMBLK  DS    CL(SRQPBLN)
*
*----------------------------------------------------------------------
* Timing fields
*----------------------------------------------------------------------
         DS    0D
DWORK    DS    D
TIMBSTRT DS    F
TIMBEND  DS    F
DELAYTM  DS    F
TIMFMT   DS    CL11
FMTSAVE  DS    F
*
*----------------------------------------------------------------------
* Combined timing WTO template
* 'SCLNT012I S=HH.MM.SS.hh E=HH.MM.SS.hh R=00000 MS' (48 chars)
* Start at parm+16(11), End at +30(11), ms at +44(5)
*----------------------------------------------------------------------
WTOCMPL  WTO   'SCLNT012I S=HH.MM.SS.hh E=HH.MM.SS.hh R=00000 MS',     *
               ROUTCDE=11,MF=L
WTOCMPLL EQU   *-WTOCMPL
WTOCWRK  DS    CL(WTOCMPLL)
*
*----------------------------------------------------------------------
* Loop control
*----------------------------------------------------------------------
LOOPCNT  EQU   20                    Number of requests per run
*
*----------------------------------------------------------------------
* WTO template for request number message
* 'SCLNT010I CLIENT SENDING REQUEST nn TO SERVER' (45 chars)
* nn at parm offset 37
*----------------------------------------------------------------------
WTOSNMPL WTO   'SCLNT010I CLIENT SENDING REQUEST nn TO SERVER',        *
               ROUTCDE=11,MF=L
WTOSNMLL EQU   *-WTOSNMPL
WTOSNWRK DS    CL(WTOSNMLL)
*
*----------------------------------------------------------------------
* Sample request text
*----------------------------------------------------------------------
REQTEXT  DC    CL40'HELLO FROM STCCLNT - PLEASE ECHO THIS  '
         DC    CL40'SECOND HALF OF REQUEST DATA             '
*
*----------------------------------------------------------------------
* Print line (1 CC + 132 data = 133)
*----------------------------------------------------------------------
PRTLINE  DS    CL133
*
*----------------------------------------------------------------------
* SYSPRINT DCB
*----------------------------------------------------------------------
PRTDCB   DCB   DDNAME=SYSPRINT,                                        *
               DSORG=PS,                                               *
               MACRF=(PM),                                             *
               RECFM=FBA,                                              *
               LRECL=133,                                              *
               BLKSIZE=133
*
         LTORG
*
*
         END   STCCLNT
