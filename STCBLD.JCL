//STCBLD  JOB (ACCT),'BUILD STCPOC',CLASS=A,MSGCLASS=X,
//             MSGLEVEL=(1,1),NOTIFY=&SYSUID
//*====================================================================*
//*  STCBLD  - Assemble and Link-Edit STCPOC programs                 *
//*                                                                    *
//*  Steps:                                                            *
//*    ASMSTC  - Assemble STCMAIN.asm   → object in &&STCOBJ          *
//*    LNKSTC  - Link-edit STCMAIN      → STCPOC.LOADLIB(STCMAIN)    *
//*    ASMCLNT - Assemble STCCLNT.asm   → object in &&CLNOBJ          *
//*    LNKCLNT - Link-edit STCCLNT      → STCPOC.LOADLIB(STCCLNT)    *
//*                                                                    *
//*  Prerequisites:                                                    *
//*    STCPOC.SRCLIB  - PDS containing STCMAIN, STCCLNT, STCDSECT    *
//*    STCPOC.MACLIB  - PDS containing STCDSECT (COPY member)        *
//*    STCPOC.LOADLIB - PDS (load library) - must be pre-allocated    *
//*    SYS1.AMODGEN   - IBM macro library (CVT, etc.)                 *
//*    SYS2.MACLIB    - IBM macro library (WTO, GETMAIN, etc.)       *
//*                                                                    *
//*  IMPORTANT: STCPOC.LOADLIB must be APF-authorized in PROGxx or   *
//*  IEAAPFxx BEFORE starting STCPOC.  Both programs use MODESET.    *
//*====================================================================*
//*
//*--------------------------------------------------------------------*
//*  Step 1 - Assemble STCMAIN
//*--------------------------------------------------------------------*
//ASMSTC  EXEC PGM=IFOX00,REGION=512K,
//             PARM='OBJECT,NODECK,NOLIST,NOXREF'
//SYSPRINT DD  SYSOUT=*
//SYSUT1   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSUT2   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSUT3   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//*  Macro libraries - order matters: site maclib first, then system
//SYSLIB   DD  DSN=STCPOC.MACLIB,DISP=SHR       STCDSECT copybook
//         DD  DSN=SYS2.MACLIB,DISP=SHR         WTO, GETMAIN, etc.
//         DD  DSN=SYS1.AMODGEN,DISP=SHR        CVT and system DSECTs
//*  Source input
//SYSIN    DD  DSN=STCPOC.SRCLIB(STCMAIN),DISP=SHR
//*  Object output to temporary dataset
//SYSGO    DD  DSN=&&STCOBJ,UNIT=SYSDA,SPACE=(CYL,(1,1)),
//             DISP=(NEW,PASS)
//*
//*--------------------------------------------------------------------*
//*  Step 2 - Link-edit STCMAIN
//*
//*  SETCODE AC=1  - Mark the load module APF-authorized.
//*                  Required for MODESET and CSA GETMAIN/FREEMAIN.
//*  RENT         - Reentrant (good practice for STC programs)
//*  REFR         - Refreshable
//*--------------------------------------------------------------------*
//LNKSTC  EXEC PGM=IEWL,REGION=512K,COND=(0,LT,ASMSTC),
//             PARM='LIST,XREF,LET,RENT,REFR'
//SYSPRINT DD  SYSOUT=*
//SYSUT1   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSLIN   DD  DSN=&&STCOBJ,DISP=(OLD,DELETE)   Object from assembly
//         DD  *
  SETCODE AC=1
  NAME STCMAIN(R)
/*
//SYSLMOD  DD  DSN=STCPOC.LOADLIB,DISP=SHR     Output load library
//*
//*--------------------------------------------------------------------*
//*  Step 3 - Assemble STCCLNT
//*--------------------------------------------------------------------*
//ASMCLNT EXEC PGM=IFOX00,REGION=512K,
//             PARM='OBJECT,NODECK,NOLIST,NOXREF',
//             COND=(0,LT,LNKSTC)
//SYSPRINT DD  SYSOUT=*
//SYSUT1   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSUT2   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSUT3   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSLIB   DD  DSN=STCPOC.MACLIB,DISP=SHR
//         DD  DSN=SYS2.MACLIB,DISP=SHR
//         DD  DSN=SYS1.AMODGEN,DISP=SHR
//SYSIN    DD  DSN=STCPOC.SRCLIB(STCCLNT),DISP=SHR
//SYSGO    DD  DSN=&&CLNOBJ,UNIT=SYSDA,SPACE=(CYL,(1,1)),
//             DISP=(NEW,PASS)
//*
//*--------------------------------------------------------------------*
//*  Step 4 - Link-edit STCCLNT
//*--------------------------------------------------------------------*
//LNKCLNT EXEC PGM=IEWL,REGION=512K,COND=(0,LT,ASMCLNT),
//             PARM='LIST,XREF,LET,RENT,REFR'
//SYSPRINT DD  SYSOUT=*
//SYSUT1   DD  UNIT=SYSDA,SPACE=(CYL,(1,1))
//SYSLIN   DD  DSN=&&CLNOBJ,DISP=(OLD,DELETE)
//         DD  *
  SETCODE AC=1
  NAME STCCLNT(R)
/*
//SYSLMOD  DD  DSN=STCPOC.LOADLIB,DISP=SHR
//*
//
