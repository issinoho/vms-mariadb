$! SERVICE_PROBE.COM SETUP|CLEANUP - D15 probe: under which username and UAF
$! quotas does a detached LOGINOUT process run when started (a) by a batch job
$! submitted /USER=<account>, (b) by RUN/DETACHED/UIC=<account's UIC>/AUTHORIZE
$! from a privileged process, (c) as (b) without /AUTHORIZE?  Uses a temporary
$! account MDBPROBE [361,1] with distinctive quotas; CLEANUP removes it.
$ set noon
$ define sys$error sys$output
$ set process/privilege=(SYSPRV,CMKRNL,IMPERSONATE,OPER,GRPNAM)
$ here = f$environment("DEFAULT")
$ pdir = here - "]" + ".MDBPROBE]"
$ goto 'p1'
$SETUP:
$ if f$identifier("MDBPROBE","NAME_TO_NUMBER") .ne. 0
$ then
$   write sys$output "PROBE: MDBPROBE already exists; not touching it"
$   exit 44
$ endif
$ create/directory/owner=[361,1] 'pdir'
$ copy/nolog PROBE_RUN.COM,PROBE_A.COM 'pdir'
$ set file/owner=[361,1]/protection=(s:rwed,o:rwed,g,w) 'pdir'*.*;*
$! A random password nobody needs: the account only runs batch jobs.
$ pw = "Pr" + (f$cvtime(,,"TIME") - ":" - ":" - ".") + "x" + f$getjpi("","PID")
$! DCL does not substitute symbols in data lines, so AUTHORIZE reads a file.
$ open/write a 'here'MDBPROBE_UAF.TMP
$ write a "ADD MDBPROBE /UIC=[361,1] /DEVICE=", f$parse(pdir,,,"DEVICE"), " /DIRECTORY=", f$parse(pdir,,,"DIRECTORY"), -
    " /PASSWORD=", pw, " /NOPWDEXPIRED /FLAGS=(RESTRICTED,DISMAIL,DISNEWMAIL)", -
    " /NOINTERACTIVE /NONETWORK /NOLOCAL /NODIALUP /NOREMOTE /BATCH", -
    " /PRIVILEGES=(TMPMBX,NETMBX) /DEFPRIVILEGES=(TMPMBX,NETMBX)", -
    " /PGFLQUOTA=777777 /FILLM=333 /DIOLM=222 /BIOLM=211 /ASTLM=300 /BYTLM=200000 /ENQLM=2000 /TQELM=100", -
    " /WSQUOTA=8192 /WSEXTENT=16384 /PRCLM=5"
$ write a "EXIT"
$ close a
$ saved = f$environment("DEFAULT")
$ set default sys$system
$ define/user sys$input 'here'MDBPROBE_UAF.TMP
$ run sys$system:authorize
$ set default 'saved'
$ delete/nolog 'here'MDBPROBE_UAF.TMP;*
$ write sys$output "PROBE: account ", f$identifier("MDBPROBE","NAME_TO_NUMBER")
$ goto ACL_ADD
$RERUN_A:
$ if f$search(pdir - "]" + "]*.TXT;*") .nes. "" then delete/nolog 'pdir'*.TXT;*
$ copy/nolog PROBE_RUN.COM,PROBE_A.COM 'pdir'
$ set file/owner=[361,1]/protection=(s:rwed,o:rwed,g,w) 'pdir'*.*;*
$ACL_ADD:
$! The account must be able to pass through the directories above its own:
$! execute-only access for its identifier, removed by CLEANUP.
$ set security/acl=(identifier=MDBPROBE,access=execute) DISK$SYSDUMP:[000000]IAIN.DIR
$ set security/acl=(identifier=MDBPROBE,access=execute) DISK$SYSDUMP:[IAIN]VMS_MARIADB.DIR
$! (a) a batch job as the account starts the detached process
$RUN_A:
$ submit/user=MDBPROBE/noprinter/queue=SYS$BATCH/log='pdir'A_JOB.LOG/name=MDBPROBE_JOB 'pdir'PROBE_A.COM
$ write sys$output "PROBE: submit status ", $status
$! (b) RUN/DETACHED/UIC/AUTHORIZE from this privileged process
$ run/detached/uic=[361,1]/authorize/process_name="MDBPROBE_B"/input='pdir'PROBE_RUN.COM -
    /output='pdir'B_DET.TXT/error='pdir'B_DET.TXT SYS$SYSTEM:LOGINOUT.EXE
$ write sys$output "PROBE: run (b) status ", $status
$! (c) the same without /AUTHORIZE
$ run/detached/uic=[361,1]/process_name="MDBPROBE_C"/input='pdir'PROBE_RUN.COM -
    /output='pdir'C_DET.TXT/error='pdir'C_DET.TXT SYS$SYSTEM:LOGINOUT.EXE
$ write sys$output "PROBE: run (c) status ", $status
$ write sys$output "PROBE-SETUP-DONE"
$ exit
$REPORT:
$ type 'pdir'A_JOB.LOG
$ type 'pdir'A_DET.TXT,B_DET.TXT,C_DET.TXT
$ write sys$output "PROBE-REPORT-DONE"
$ exit
$CLEANUP:
$ set security/acl=(identifier=MDBPROBE,access=execute)/delete DISK$SYSDUMP:[000000]IAIN.DIR
$ set security/acl=(identifier=MDBPROBE,access=execute)/delete DISK$SYSDUMP:[IAIN]VMS_MARIADB.DIR
$ if f$search(pdir - "]" + "]*.*;*") .nes. "" then delete/nolog 'pdir'*.*;*
$ if f$search(here + "MDBPROBE.DIR") .nes. ""
$ then
$   set security/protection=(o:rwed) MDBPROBE.DIR;*
$   delete/nolog MDBPROBE.DIR;*
$ endif
$ saved = f$environment("DEFAULT")
$ set default sys$system
$ run sys$system:authorize
REMOVE MDBPROBE
EXIT
$ set default 'saved'
$ write sys$output "PROBE: after cleanup account=", f$identifier("MDBPROBE","NAME_TO_NUMBER"), " dir=[", f$search(here + "MDBPROBE.DIR"), "]"
$ write sys$output "PROBE-CLEANUP-DONE"
$ exit
