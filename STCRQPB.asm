***********************************************************************
*  STCRQPB - STCREQ Request Parameter Block DSECT                     *
*                                                                     *
*  COPY this member into STCCLNT and STCREQ at assembly time.         *
*  Place in a PDS on the SYSLIB concatenation (STCPOC.MACLIB).        *
*                                                                     *
*  The caller allocates storage for SRQPBLN bytes, fills SRQREQD      *
*  with the request data, and passes the address via R1 (standard     *
*  OS parameter list).  On return, SRQRSPD contains the server        *
*  response and SRQRTCD has the return code.                          *
*                                                                     *
*  Layout:                                                            *
*    +0   SRQREQD   CL80  Request data  (caller writes)               *
*    +80  SRQRSPD   CL80  Response data (STCREQ writes)               *
*    +160 SRQRTCD   F     Return code   (STCREQ writes)               *
*    +164 SRQELMS   F     Elapsed ms    (STCREQ writes)               *
*                                                                     *
*  Return codes:                                                      *
*    0  - Success                                                     *
*    4  - ANCHOR dataset empty (server not started)                   *
*    8  - Bad eye-catcher (stale anchor)                              *
*   12  - Server returned non-zero STCRETCD                           *
*   16  - POST to server failed                                       *
*                                                                     *
*  Total length: SRQPBLN = 168 bytes                                  *
***********************************************************************
*
STCRQPB  DSECT
SRQREQD  DS    CL80              Request data  (caller writes)
SRQRSPD  DS    CL80              Response data (STCREQ writes)
SRQRTCD  DS    F                 Return code   (STCREQ writes)
SRQELMS  DS    F                 Elapsed ms    (STCREQ writes)
SRQPBLN  EQU   *-STCRQPB        Length of parameter block (=168)
