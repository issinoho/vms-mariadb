$! VMS_INSTALLCHECK.COM <tree-dir-name> <phase> - install the VMSMARIADB kit,
$! run a server and the clients from it, and remove it.  tools/installcheck.sh
$! runs the phases in order (the host does the waiting: DCL's WAIT hangs in
$! sessions started over ssh):
$!   INSTALL  PRODUCT INSTALL, verify files and VMSMARIADB$ROOT, INSTALL_DB on
$!            [.KITDATA] (beside the tree), START on port 3308
$!   STATUS   VMSMARIADB$SERVER STATUS 3308 (prints INSTALLCHECK_UP when it answers)
$!   QUERY    the installed client: version, engines, a table; then STOP
$!   PROCESS  is MARIADBD_3308 still there?
$!   REMOVE   PRODUCT REMOVE, check nothing is left, delete [.KITDATA] and [.KITDATA_TMP]
$! Changes the system while it runs (PCSI database, SYS$COMMON:[VMSMARIADB],
$! SYS$STARTUP:VMSMARIADB$STARTUP.COM, system logical VMSMARIADB$ROOT); REMOVE
$! leaves it as it was.
$ set noon
$ define sys$error sys$output
$ set process/parse_style=extended
$ say = "write sys$output"
$ here = f$environment("DEFAULT")
$ tree = here - "]" + "." + p1 + "]"
$ kitdir = tree - "]" + ".KIT_X86_64]"
$ datadir = here - "]" + ".KITDATA]"
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
$ ctx = ""
$ found = 0
$proc_loop:
$ pid = f$pid(ctx)
$ if pid .eqs. "" then goto proc_done
$ if f$getjpi(pid, "PRCNAM") .eqs. "MARIADBD_3308" then found = 1
$ goto proc_loop
$proc_done:
$ if found then say "INSTALLCHECK_RUNNING"
$ if .not. found then say "INSTALLCHECK_GONE"
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
