$! VMS_INSTALLCHECK.COM <tree-dir-name> <phase> - install the VMSMARIADB kit,
$! run a server and the clients from it, and remove it.  tools/installcheck.sh
$! runs the phases in order (the host does the waiting: DCL's WAIT hangs in
$! sessions started over ssh):
$!   INSTALL  PRODUCT INSTALL, verify files and VMSMARIADB$ROOT, INSTALL_DB on
$!            [.KITDATA] (beside the tree), START on port 3308
$!   STATUS   VMSMARIADB$SERVER STATUS 3308 (prints INSTALLCHECK_UP when it answers)
$!   QUERY    the installed client: version, engines, a table; then STOP
$!   PROCESS  is MARIADBD_<p3> (default 3308) still there?
$!   SVC_CONFIGURE  VMSMARIADB$CONFIGURE NOCONFIRM: test account MDBSVCT
$!            [361,1], data in [.SVCTEST.DATA], port 3309, site file
$!            []SVCTEST_CONFIG.COM (logical VMSMARIADB$CONFIG), not SYS$MANAGER
$!   SVC_START      VMSMARIADB$STARTUP START (the batch job as MDBSVCT)
$!   SVC_STATUS     the server's username and quotas; ping with the shutdown
$!            option file (prints INSTALLCHECK_SVC_UP when it answers)
$!   SVC_QUERY      root's password, the shutdown account's limits, the table
$!            cache, a second START refused
$!   SVC_SHUTDOWN   VMSMARIADB$SHUTDOWN NOWAIT (then PROCESS 3309)
$!   SVC_CLEANUP    logs; remove the account, [.SVCTEST] and the site file
$!   REMOVE   PRODUCT REMOVE, check nothing is left, delete [.KITDATA] and [.KITDATA_TMP]
$! Changes the system while it runs (PCSI database, SYS$COMMON:[VMSMARIADB],
$! SYS$STARTUP:VMSMARIADB$STARTUP.COM, system logical VMSMARIADB$ROOT, and
$! the SVC_ phases a temporary account); REMOVE and SVC_CLEANUP leave it as
$! it was.
$ set noon
$ define sys$error sys$output
$ set process/privilege=(SYSPRV,CMKRNL,WORLD)
$ set process/parse_style=extended
$ say = "write sys$output"
$ here = f$environment("DEFAULT")
$ tree = here - "]" + "." + p1 + "]"
$ kitdir = tree - "]" + ".KIT_X86_64]"
$ datadir = here - "]" + ".KITDATA]"
$ svcdata = here - "]" + ".SVCTEST.DATA]"
$ svcacct = "MDBSVCT"
$ define/process VMSMARIADB$CONFIG 'here'SVCTEST_CONFIG.COM
$ phase = f$edit(p2, "UPCASE")
$ goto 'phase'
$!
$INSTALL:
$ say "=== INSTALL from ", kitdir
$ product install VMSMARIADB /producer=ISSINOHO /base_system=X86VMS /source='kitdir' -
    /options=noconfirm /log
$ say "=== install status ", $status
$ product show product VMSMARIADB /producer=ISSINOHO
$ say "startup procedure: [", f$search("SYS$STARTUP:VMSMARIADB$STARTUP.COM"), "]"
$ say "VMSMARIADB$ROOT = [", f$trnlnm("VMSMARIADB$ROOT", "LNM$SYSTEM_TABLE"), "]"
$ say "server image: [", f$search("VMSMARIADB$ROOT:[BIN]MARIADBD.EXE"), "]"
$ say "english messages: [", f$search("VMSMARIADB$ROOT:[SHARE.ENGLISH]ERRMSG.SYS"), "]"
$ say "charsets index: [", f$search("VMSMARIADB$ROOT:[SHARE.CHARSETS]INDEX.XML"), "]"
$ directory/total VMSMARIADB$ROOT:[000000...]
$ say "=== INSTALL_DB ", datadir
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER INSTALL_DB 'datadir'
$ say "=== install_db status ", $status
$ say "=== START"
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER START 'datadir' 3308
$ say "=== start status ", $status
$ exit
$!
$STATUS:
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER STATUS 3308
$ if $status then say "INSTALLCHECK_UP"
$ exit
$!
$QUERY:
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SETUP.COM
$ say "=== CLIENT FROM THE INSTALLED KIT"
$ mariadb "--version"
$ if $severity .eq. 1 then say "INSTALLCHECK_CLIENT_VERSION: PASS"
$ mariadb "--no-defaults" "-h" "127.0.0.1" "-P" "3308" "-u" "root" "--batch" "-e" -
    "SELECT VERSION(), @@version_compile_os, @@lc_messages_dir, @@character_sets_dir; CREATE DATABASE kitcheck; CREATE TABLE kitcheck.t (id INT PRIMARY KEY, v VARCHAR(20)) ENGINE=Aria; INSERT INTO kitcheck.t VALUES (1,'installed'),(2,'kit'); SELECT COUNT(*) AS kitrows FROM kitcheck.t; SELECT engine FROM information_schema.engines WHERE support IN ('YES','DEFAULT') ORDER BY 1; SELECT no_such_column FROM kitcheck.t"
$ say "=== error message check above: expect ERROR 1054 Unknown column"
$ mariadb "--no-defaults" "-h" "127.0.0.1" "-P" "3308" "-u" "root" "--batch" "--skip-column-names" "-e" -
    "SELECT CONCAT('INSTALLCHECK_ROWS: ', COUNT(*)) FROM kitcheck.t"
$ mariadb_dump "--no-defaults" "-h" "127.0.0.1" "-P" "3308" "-u" "root" "kitcheck" "t"
$ if $severity .eq. 1 then say "INSTALLCHECK_DUMP: PASS"
$ say "=== STOP"
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER STOP 3308
$ say "=== stop status ", $status
$ exit
$!
$PROCESS:
$ port = p3
$ if port .eqs. "" then port = "3308"
$ ctx = ""
$ found = 0
$proc_loop:
$ pid = f$pid(ctx)
$ if pid .eqs. "" then goto proc_done
$ if f$getjpi(pid, "PRCNAM") .eqs. "MARIADBD_''port'" then found = 1
$ goto proc_loop
$proc_done:
$ if found then say "INSTALLCHECK_RUNNING"
$ if .not. found then say "INSTALLCHECK_GONE"
$ exit
$!
$SVC_CONFIGURE:
$ if f$identifier(svcacct, "NAME_TO_NUMBER") .ne. 0
$ then
$   say "INSTALLCHECK_SVC: account ''svcacct' exists already; not touching it"
$   exit
$ endif
$! A root password that needs quoting in DCL and SQL alike.
$ define/process VMSMARIADB$CONFIGURE_ROOTPW "Svc'Chk""pw%1"
$ say "=== CONFIGURE"
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$CONFIGURE 'svcdata' 3309 'svcacct' [361,1] NOCONFIRM
$ say "=== configure status ", $status
$ deassign/process VMSMARIADB$CONFIGURE_ROOTPW
$ type 'here'SVCTEST_CONFIG.COM
$ directory/security 'f$string(here - "]" + ".SVCTEST]")'*.DIR,'svcdata'*.*;
$ say "account: ", f$identifier(svcacct, "NAME_TO_NUMBER")
$ exit
$!
$SVC_START:
$ say "=== STARTUP START"
$ @SYS$STARTUP:VMSMARIADB$STARTUP.COM START
$ say "=== startup status ", $status
$ exit
$!
$SVC_STATUS:
$ ctx = ""
$svc_loop:
$ pid = f$pid(ctx)
$ if pid .eqs. "" then goto svc_done
$ if f$getjpi(pid, "PRCNAM") .nes. "MARIADBD_3309" then goto svc_loop
$ user = f$edit(f$getjpi(pid, "USERNAME"), "TRIM")
$ say "server process ", pid, " username=", user, " uic=", f$getjpi(pid, "UIC"), -
    " fillm=", f$getjpi(pid, "FILLM"), " pgflquota=", f$getjpi(pid, "PGFLQUOTA"), " mode=", f$getjpi(pid, "MODE")
$ say "server privileges: ", f$getjpi(pid, "CURPRIV")
$ if user .eqs. svcacct .and. f$getjpi(pid, "FILLM") .eq. 1000 .and. -
     f$getjpi(pid, "CURPRIV") .eqs. "TMPMBX,NETMBX" then say "INSTALLCHECK_SVC_IDENTITY: PASS"
$svc_done:
$ call to_unix 'svcdata'
$ madmin = "$VMSMARIADB$ROOT:[BIN]MARIADB-ADMIN.EXE"
$ madmin "--defaults-file=''unix_path'/VMSMARIADB$SHUTDOWN.CNF" "--host=127.0.0.1" "--port=3309" "ping"
$ if $severity .eq. 1 then say "INSTALLCHECK_SVC_UP"
$ exit
$!
$SVC_QUERY:
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SETUP.COM
$ call to_unix 'svcdata'
$ ucnf = unix_path + "/VMSMARIADB$SHUTDOWN.CNF"
$ rootcnf = here + "SVCTEST_ROOT.CNF"
$ open/write o 'rootcnf'
$ write o "[client]"
$ write o "user=root"
$ write o "password=Svc'Chk""pw%1"
$ close o
$ call to_unix 'here'
$ urootcnf = unix_path + "/SVCTEST_ROOT.CNF"
$ mariadb "--defaults-file=''urootcnf'" "--host=127.0.0.1" "--port=3309" "--batch" "--skip-column-names" "-e" -
    "SELECT CONCAT('INSTALLCHECK_SVC_ROOTPW: ', IF(CURRENT_USER() = 'root@localhost', 'PASS', CURRENT_USER())); SELECT CONCAT('INSTALLCHECK_SVC_CACHE: ', @@table_open_cache); SELECT CONCAT('shutdown grants: ', COUNT(*)) FROM mysql.global_priv WHERE user = 'vmsmariadb_shutdown'"
$ delete/nolog 'rootcnf';*
$ mariadb "--no-defaults" "--host=127.0.0.1" "--port=3309" "--user=root" "-e" "SELECT 1"
$ say "=== above: expect ERROR 1045 for root without a password"
$ mariadb "--defaults-file=''ucnf'" "--host=127.0.0.1" "--port=3309" "-e" "SELECT COUNT(*) FROM mysql.user"
$ say "=== above: expect ERROR 1142 for the shutdown account"
$ say "=== a second STARTUP START (expect: already running)"
$ @SYS$STARTUP:VMSMARIADB$STARTUP.COM START
$ exit
$!
$SVC_SHUTDOWN:
$ say "=== SHUTDOWN"
$ @SYS$STARTUP:VMSMARIADB$SHUTDOWN.COM NOWAIT
$ say "=== shutdown status ", $status
$ exit
$!
$SVC_CLEANUP:
$ say "=== start job log"
$ type 'svcdata'VMSMARIADB$START.LOG
$ say "=== server log"
$ type 'svcdata'VMSMARIADB$SERVER.LOG
$ type 'svcdata'mariadbd.err
$ search/nooutput 'svcdata'mariadbd.err "initiated by: vmsmariadb_shutdown"
$ if $severity .eq. 1 then say "INSTALLCHECK_SVC_CLEAN_STOP: PASS"
$ say "=== remove the account, [.SVCTEST] and the site file"
$ if f$identifier(svcacct, "NAME_TO_NUMBER") .eq. 0 then goto svc_noacct
$ saved = f$environment("DEFAULT")
$ set default SYS$SYSTEM
$ run SYS$SYSTEM:AUTHORIZE
REMOVE MDBSVCT
EXIT
$ set default 'saved'
$svc_noacct:
$ call deltree SVCTEST
$ if f$search(here + "SVCTEST_CONFIG.COM") .nes. "" then delete/nolog 'here'SVCTEST_CONFIG.COM;*
$ say "account after cleanup: [", f$identifier(svcacct, "NAME_TO_NUMBER"), "]"
$ say "svctest after cleanup: [", f$search(here + "SVCTEST*.*"), "]"
$ exit
$!
$REMOVE:
$ say "=== server log"
$ type 'datadir'mariadbd.err
$ say "=== REMOVE"
$ product remove VMSMARIADB /producer=ISSINOHO /options=noconfirm /log
$ say "=== remove status ", $status
$ say "VMSMARIADB$ROOT after removal: [", f$trnlnm("VMSMARIADB$ROOT"), "]"
$ say "files after removal: [", f$search("SYS$COMMON:[VMSMARIADB...]*.*"), "]"
$ say "startup after removal: [", f$search("SYS$STARTUP:VMSMARIADB$STARTUP.COM"), "]"
$ product show product VMSMARIADB /producer=ISSINOHO
$ say "=== delete the scratch data directory"
$ call deltree KITDATA
$ call deltree KITDATA_TMP
$ say "data after cleanup: [", f$search(here + "KITDATA*.DIR"), "]"
$ exit
$!
$! dev:[a.b.c] -> /dev/a/b/c, in the global symbol unix_path
$to_unix: subroutine
$ spec = p1
$ u = "/" + (f$parse(spec,,,"DEVICE","NO_CONCEAL") - ":")
$ d = f$parse(spec,,,"DIRECTORY","NO_CONCEAL") - "][" - "[" - "]" - "<" - ">"
$ i = 0
$tu_loop:
$ e = f$element(i, ".", d)
$ if e .eqs. "." .or. e .eqs. "" then goto tu_done
$ u = u + "/" + e
$ i = i + 1
$ goto tu_loop
$tu_done:
$ unix_path == u
$ exit 1
$ endsubroutine
$!
$! Delete a directory tree of ours, [.<p1>] under the current default: files,
$! then directories deepest first, then <p1>.DIR.
$deltree: subroutine
$! (no F$SEARCH loop: a repeated F$SEARCH continues its old search and
$! returns files already deleted)
$ top = f$environment("DEFAULT") - "]" + "." + p1 + "]"
$ set message/nofacility/noseverity/noidentification/notext
$ delete/nolog 'f$string(top - "]" + "...]*.*;*")'/exclude=*.DIR
$ n = 0
$dt_loop:
$ set security/protection=(o:rwed) 'f$string(top - "]" + "...]*.DIR;*")'
$ delete/nolog 'f$string(top - "]" + "...]*.DIR;*")'
$ n = n + 1
$ if n .lt. 6 then goto dt_loop
$ set security/protection=(o:rwed) 'p1'.DIR;*
$ delete/nolog 'p1'.DIR;*
$ set message/facility/severity/identification/text
$ exit 1
$ endsubroutine
