$! VMSMARIADB$SERVER.COM - create a MariaDB data directory, start and stop the
$! server.  Part of the VMSMARIADB kit (vms-mariadb); needs VMSMARIADB$ROOT.
$!
$!   @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER INSTALL_DB datadir
$!       Create datadir (and datadir_TMP beside it, the server's tmpdir) with
$!       /VERSION_LIMIT=1 and the system tables.  datadir must be on an
$!       ODS-5 disk, e.g. DKA100:[MARIADB.DATA].  The root@localhost account
$!       has no password: set one (README.VMS).
$!   @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER BOOTSTRAP datadir sqlfile
$!       Run sqlfile through "mariadbd --bootstrap" on datadir, which must
$!       hold system tables and must not be in use by a running server
$!       (VMSMARIADB$CONFIGURE.COM sets passwords and accounts this way).
$!   @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER START datadir [port] [option]
$!       Start mariadbd as a detached process, MARIADBD_<port> (default port
$!       3306), under this user's UAF quotas (RUN/DETACHED/AUTHORIZE).  Its
$!       output is in datadir VMSMARIADB$SERVER.LOG, its error log in
$!       datadir mariadbd.err.  If datadir MY.CNF exists it is the server's
$!       only option file (--defaults-file); otherwise --no-defaults.
$!       option: one more mariadbd option, e.g. "--bind-address=127.0.0.1".
$!       Unless MY.CNF or option sets table_open_cache, it is sized from the
$!       process's FILLM quota.  Refuses to start a second MARIADBD_<port>.
$!   @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER STOP [port] [option]
$!       Ask the server on 127.0.0.1:<port> to shut down (mariadb-admin
$!       shutdown as root).  Once root has a password, pass it as option:
$!       "--password=...".  An option "--defaults-file=..." or
$!       "--defaults-extra-file=..." (UNIX syntax) supplies the user and
$!       password instead, e.g. the service's VMSMARIADB$SHUTDOWN.CNF.
$!   @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER STATUS [port] [option]
$!       mariadb-admin status, and the server process; option as for STOP.
$!
$! The server listens on TCP only: Unix-domain sockets do not work on VMS.
$! The VMS-specific settings (C RTL features) are built into the images.
$!
$ set noon
$ status = 44
$ say = "write sys$output"
$ if f$trnlnm("VMSMARIADB$ROOT") .eqs. ""
$ then
$   say "VMSMARIADB$SERVER: VMSMARIADB$ROOT is not defined; run SYS$STARTUP:VMSMARIADB$STARTUP.COM"
$   exit 44
$ endif
$ set process/parse_style=extended
$ mariadbd = "$VMSMARIADB$ROOT:[BIN]MARIADBD.EXE"
$ madmin = "$VMSMARIADB$ROOT:[BIN]MARIADB-ADMIN.EXE"
$ call to_unix VMSMARIADB$ROOT:[000000]
$ uroot = unix_path
$ ushare = uroot + "/share"
$ op = f$edit(p1, "UPCASE,TRIM")
$ if op .eqs. "INSTALL_DB" then goto install_db
$ if op .eqs. "BOOTSTRAP" then goto bootstrap
$ if op .eqs. "START" then goto start
$ if op .eqs. "RUN" then goto run
$ if op .eqs. "STOP" then goto stop
$ if op .eqs. "STATUS" then goto status
$ say "VMSMARIADB$SERVER: usage: @VMSMARIADB$SERVER INSTALL_DB|BOOTSTRAP|START|STOP|STATUS ..."
$ exit 44
$!
$! --- datadir checks shared by INSTALL_DB, START and RUN ---
$get_datadir: subroutine
$ set noon
$ d = f$edit(p1, "UPCASE,TRIM")
$ if d .eqs. "" .or. f$locate("]", d) .eq. f$length(d)
$ then
$   write sys$output "VMSMARIADB$SERVER: give the data directory as dev:[dir]"
$   exit 44
$ endif
$ datadir == f$parse(d,,,"DEVICE") + f$parse(d,,,"DIRECTORY")
$ tmpdir == datadir - "]" + "_TMP]"
$ exit 1
$ endsubroutine
$!
$install_db:
$ call get_datadir "''p2'"
$ if .not. $status then exit 44
$ if f$search(datadir - "]" + "...]*.*") .nes. "" .or. -
     f$search(tmpdir - "]" + "...]*.*") .nes. ""
$ then
$   say "VMSMARIADB$SERVER: ''datadir' is not empty"
$   exit 44
$ endif
$ create/directory/version_limit=1 'datadir'
$ if .not. $status then exit $status
$ create/directory/version_limit=1 'tmpdir'
$ call to_unix 'datadir'
$ udata = unix_path
$ call to_unix 'tmpdir'
$ utmp = unix_path
$! The bootstrap SQL, as mariadb-install-db's cat_sql().
$ sql = tmpdir + "BOOTSTRAP.SQL"
$ copy VMSMARIADB$ROOT:[SCRIPTS]BOOTSTRAP_HEADER.SQL 'sql'
$ append VMSMARIADB$ROOT:[SCRIPTS]MARIADB_SYSTEM_TABLES.SQL 'sql'
$ append VMSMARIADB$ROOT:[SCRIPTS]MARIADB_PERFORMANCE_TABLES.SQL 'sql'
$ append VMSMARIADB$ROOT:[SCRIPTS]MARIADB_SYSTEM_TABLES_DATA.SQL 'sql'
$ append VMSMARIADB$ROOT:[SCRIPTS]FILL_HELP_TABLES.SQL 'sql'
$ append VMSMARIADB$ROOT:[SCRIPTS]MARIA_ADD_GIS_SP_BOOTSTRAP.SQL 'sql'
$ append VMSMARIADB$ROOT:[SCRIPTS]MARIADB_SYS_SCHEMA.SQL 'sql'
$ say "VMSMARIADB$SERVER: creating the system tables in ''datadir'"
$ call run_bootstrap 'sql'
$ status = $status
$ if .not. status then exit status
$ open/write o 'datadir'mariadb_upgrade_info.
$ write o "@VERSION@-MariaDB"
$ close o
$ delete/nolog 'sql';*
$ say "VMSMARIADB$SERVER: ''datadir' is ready; start it with"
$ say "  $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER START ''datadir'"
$ exit 1
$!
$bootstrap:
$ call get_datadir "''p2'"
$ if .not. $status then exit 44
$ if f$search(datadir - "]" + ".mysql]db.frm") .eqs. ""
$ then
$   say "VMSMARIADB$SERVER: no system tables in ''datadir' (INSTALL_DB first)"
$   exit 44
$ endif
$ sql = f$search(p3)
$ if sql .eqs. ""
$ then
$   say "VMSMARIADB$SERVER: no SQL file ''p3'"
$   exit 44
$ endif
$ call to_unix 'datadir'
$ udata = unix_path
$ call to_unix 'tmpdir'
$ utmp = unix_path
$ call run_bootstrap 'sql'
$ exit $status
$!
$start:
$ call get_datadir "''p2'"
$ if .not. $status then exit 44
$ if f$search(datadir - "]" + ".mysql]db.frm") .eqs. ""
$ then
$   say "VMSMARIADB$SERVER: no system tables in ''datadir' (INSTALL_DB first)"
$   exit 44
$ endif
$ port = p3
$ if port .eqs. "" then port = "3306"
$ call find_process MARIADBD_'port'
$ if found_pid .nes. ""
$ then
$   say "VMSMARIADB$SERVER: MARIADBD_''port' is already running (''found_pid')"
$   exit 44
$ endif
$ run_com = datadir + "VMSMARIADB$RUN.COM"
$ open/write o 'run_com'
$ write o "$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER.COM RUN ''datadir' ''port' ""''p4'"""
$ close o
$ run/detached/authorize/process_name="MARIADBD_''port'"/input='run_com' -
    /output='datadir'VMSMARIADB$SERVER.LOG/error='datadir'VMSMARIADB$SERVER.LOG -
    SYS$SYSTEM:LOGINOUT.EXE
$ status = $status
$ if status then say "VMSMARIADB$SERVER: MARIADBD_''port' started on ''datadir'; log ''datadir'mariadbd.err"
$ exit status
$!
$! RUN: the detached process's input (START writes VMSMARIADB$RUN.COM).
$run:
$ call get_datadir "''p2'"
$ if .not. $status then exit 44
$ call to_unix 'datadir'
$ udata = unix_path
$ call to_unix 'tmpdir'
$ utmp = unix_path
$ port = p3
$ defaults = "--no-defaults"
$ if f$search(datadir + "MY.CNF") .nes. "" then defaults = "--defaults-file=''udata'/my.cnf"
$ extra = ""
$ if p4 .nes. "" then extra = """" + p4 + """"
$! The server sizes its table cache from open_files_limit, which knows
$! nothing of FILLM: past FILLM, tables fail to open (ERROR 1146).  An
$! open MyISAM or Aria table holds two files and each file two channels
$! (the shared-descriptor layer), so allow four per table and keep 50 for
$! logs and temporary files.  MY.CNF or option overrides it.
$ cache = ""
$ set_by = f$locate("TABLE", f$edit(p4, "UPCASE")) .lt. f$length(p4)
$ if f$search(datadir + "MY.CNF") .nes. ""
$ then
$   search/nooutput 'datadir'MY.CNF "table_open_cache","table-open-cache"
$   if $severity .eq. 1 then set_by = 1
$ endif
$ if .not. set_by
$ then
$   fillm = f$getjpi("", "FILLM")
$   n = (fillm - 50) / 4
$   if n .lt. 10 then n = 10
$   if n .gt. 2000 then n = 2000
$   cache = """--table-open-cache=''n'"""
$   say "VMSMARIADB$SERVER: FILLM ''fillm', table_open_cache ''n'"
$ endif
$! --socket= (empty): no Unix-domain socket (AF_UNIX bind fails on VMS).
$ mariadbd "''defaults'" "--datadir=''udata'" "--basedir=''uroot'" -
    "--lc-messages-dir=''ushare'" "--character-sets-dir=''ushare'/charsets" -
    "--tmpdir=''utmp'" "--port=''port'" "--log-error=''udata'/mariadbd.err" -
    "--pid-file=''udata'/mariadbd.pid" "--socket=" 'cache' 'extra'
$ status = $status
$ say "VMSMARIADB$SERVER: mariadbd exited (''status')"
$ exit status
$!
$stop:
$ port = p2
$ if port .eqs. "" then port = "3306"
$ call admin_options "''p3'"
$ madmin "''admin_defaults'" "--host=127.0.0.1" "--port=''port'" 'admin_extra' "shutdown"
$ status = $status
$ if status then say "VMSMARIADB$SERVER: shutdown requested; MARIADBD_''port' exits when it is done"
$ exit status
$!
$status:
$ port = p2
$ if port .eqs. "" then port = "3306"
$ call admin_options "''p3'"
$ madmin "''admin_defaults'" "--host=127.0.0.1" "--port=''port'" 'admin_extra' "status"
$ status = $status
$ show system/process=MARIADBD_'port'
$ exit status
$!
$! mariadb-admin options for STOP and STATUS from their option parameter
$! p1, in the globals admin_defaults and admin_extra.  An option file
$! replaces both --no-defaults and --user=root (the command line would win
$! over the file's user); any other option follows --user=root.
$admin_options: subroutine
$ set noon
$ admin_defaults == "--no-defaults"
$ admin_extra == """--user=root"""
$ if p1 .nes. "" .and. f$locate("--defaults-", p1) .eq. 0
$ then
$   admin_defaults == p1
$   admin_extra == ""
$ else
$   if p1 .nes. "" then admin_extra == admin_extra + " """ + p1 + """"
$ endif
$ exit 1
$ endsubroutine
$!
$! The PID of the process named p1, if this process can see it, else "",
$! in the global found_pid.
$find_process: subroutine
$ set noon
$ found_pid == ""
$ ctx = ""
$ x = f$context("PROCESS", ctx, "PRCNAM", p1, "EQL")
$ pid = f$pid(ctx)
$ if pid .nes. "" then found_pid == pid
$ if f$type(ctx) .eqs. "PROCESS_CONTEXT" then x = f$context("PROCESS", ctx, "CANCEL")
$ exit 1
$ endsubroutine
$!
$! mariadbd --bootstrap on datadir (udata, utmp) with the SQL file p1 as
$! its input; tmpdir BOOTSTRAP.LOG is typed and kept if it fails.
$run_bootstrap: subroutine
$ set noon
$ log = tmpdir + "BOOTSTRAP.LOG"
$ define/user sys$input 'p1'
$ define/user sys$output 'log'
$ define/user sys$error 'log'
$ mariadbd "--no-defaults" "--bootstrap" "--datadir=''udata'" "--basedir=''uroot'" -
    "--lc-messages-dir=''ushare'" "--character-sets-dir=''ushare'/charsets" -
    "--tmpdir=''utmp'" "--log-warnings=0" "--enforce-storage-engine=" -
    "--max_allowed_packet=8M" "--net_buffer_length=16K"
$ status = $status
$ if .not. status
$ then
$   type 'log'
$   write sys$output "VMSMARIADB$SERVER: mariadbd --bootstrap failed; log in ''log'"
$   exit status
$ endif
$ delete/nolog 'log';*
$ exit 1
$ endsubroutine
$!
$! dev:[a.b.c] -> /dev/a/b/c (physical device, concealed roots expanded), in
$! the global symbol unix_path
$to_unix: subroutine
$ set noon
$ spec = p1
$ u = "/" + (f$parse(spec,,,"DEVICE","NO_CONCEAL") - ":")
$ d = f$parse(spec,,,"DIRECTORY","NO_CONCEAL") - "][" - "[" - "]" - "<" - ">"
$ d = d - ".000000"
$ i = 0
$tu_loop:
$ e = f$element(i, ".", d)
$ if e .eqs. "." .or. e .eqs. "" .or. e .eqs. "000000" then goto tu_done
$ u = u + "/" + e
$ i = i + 1
$ goto tu_loop
$tu_done:
$ unix_path == u
$ exit 1
$ endsubroutine
