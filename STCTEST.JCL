//STCTEST  JOB (ACCT),'TEST STCPOC CLIENT',CLASS=A,MSGCLASS=X,
//             MSGLEVEL=(1,1),NOTIFY=&SYSUID
//*====================================================================*
//*  STCTEST  - Run STCCLNT to send one request to STCMAIN           *
//*                                                                    *
//*  Before running this job:                                         *
//*    1. STCPOC.LOADLIB must be APF-authorized                       *
//*    2. STCMAIN must be running (START STCPOC from the console)     *
//*    3. STCPOC.ANCHOR must have been written by STCMAIN            *
//*                                                                    *
//*  Expected SYSPRINT output:                                         *
//*    RESPONSE: RESP=>  HELLO FROM STCCLNT - PLEASE ECHO THIS  ...  *
//*                                                                    *
//*  Return codes:                                                     *
//*     0  - Success                                                   *
//*     4  - ANCHOR empty (STC not started)                           *
//*     8  - Bad eye-catcher (stale anchor)                           *
//*    12  - Server returned non-zero return code                     *
//*    16  - Unexpected error                                         *
//*====================================================================*
//RNCLIENT EXEC PGM=STCCLNT,REGION=512K
//*
//*  STEPLIB - same APF-authorized load library
//*
//STEPLIB  DD  DSN=STCPOC.LOADLIB,DISP=SHR
//*
//*  ANCHOR - the shared address dataset written by STCMAIN.
//*  Open DISP=SHR so both the running STC and this job can access it.
//*
//ANCHOR   DD  DSN=STCPOC.ANCHOR,DISP=SHR
//*
//*  SYSPRINT - where STCCLNT writes the response text.
//*
//SYSPRINT DD  SYSOUT=*
//
