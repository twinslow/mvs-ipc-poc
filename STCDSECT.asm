***********************************************************************
*  STCDSECT - STC POC Common Control Block Definitions                *
*                                                                     *
*  COPY this member into STCMAIN and STCCLNT at assembly time.        *
*  Place in a PDS on the SYSLIB concatenation (e.g. STCPOC.MACLIB).   *
*                                                                     *
*  Layout of the shared CSA Anchor Control Block:                     *
*                                                                     *
*  +0   STCEYEC   CL4  Eye-catcher ('STCA')                           *
*  +4   STCWECB   F    Work ECB  - STC  WAITs here for requests       *
*  +8   STCRECB   F    Reply ECB - Client WAITs here for responses    *
*  +12  STCSFLAG  F    Shutdown flag  (0=running, 1=stop requested)   *
*  +16  STCREQD   CL80 Request data area  (client writes)             *
*  +96  STCRSPD   CL80 Response data area (STC writes)                *
*  +176 STCRETCD  F    Return code from request  (STC writes)         *
*  +180 STCSASCB  A    Server ASCB addr  (for POST ASCB=)             *
*  +184 STCCASCB  A    Client ASCB addr  (for POST ASCB=)             *
*  +188 STCRESRV  CL36 Reserved / future use                          *
*                                                                     *
*  Total length: STCANCBL = 224 bytes                                 *
***********************************************************************
*
STCANCB  DSECT
STCEYEC  DS    CL4               Eye-catcher: must be 'STCA'
STCWECB  DS    F                 Work ECB  (STC WAITs here)
STCRECB  DS    F                 Reply ECB (Client WAITs here)
STCSFLAG DS    F                 Shutdown flag: 0=run, 1=shutdown
STCREQD  DS    CL80              Request data (written by client)
STCRSPD  DS    CL80              Response data (written by STC)
STCRETCD DS    F                 Return code: 0=success, else error
STCSASCB DS    A                 Server ASCB addr (for POST ASCB=)
STCCASCB DS    A                 Client ASCB addr (for POST ASCB=)
STCRESRV DS    CL36              Reserved - must be zero
STCANCBL EQU   *-STCANCB         Length of anchor block (=224)
