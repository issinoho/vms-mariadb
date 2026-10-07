$! VMSMARIADB$SHUTDOWN.COM - stop the MariaDB service (vms-mariadb) cleanly
$!
$! Installed by PCSI into SYS$STARTUP.  Stops the server configured by
$! VMSMARIADB$CONFIGURE.COM: asks it to shut down through the SHUTDOWN-only
$! account vmsmariadb_shutdown, whose password is in <datadir>
$! VMSMARIADB$SHUTDOWN.CNF, then waits for MARIADBD_<port> to exit.  An
$! unclean stop (STOP/ID, or the system going down under it) costs Aria
$! recovery and possibly MyISAM table repairs at the next start.  Add this
$! line to SYS$MANAGER:SYSHUTDWN.COM:
$!
$!     $ @SYS$STARTUP:VMSMARIADB$SHUTDOWN.COM
$!
$! P1 = "NOWAIT": ask for the shutdown and return without waiting.
$! The site file is SYS$MANAGER:VMSMARIADB$CONFIG.COM, or the file the
$! logical name VMSMARIADB$CONFIG names.  Needs WORLD (to see the process)
$! and read access to the option file (SYSTEM has it).
$!
$ set noon
$ say = "write sys$output"
$ cfg = f$trnlnm("VMSMARIADB$CONFIG")
$ if cfg .eqs. "" then cfg = "SYS$MANAGER:VMSMARIADB$CONFIG.COM"
$ if f$search(cfg) .eqs. ""
$ then
$   say "VMSMARIADB$SHUTDOWN: no ''cfg'; nothing to stop"
$   exit 1
$ endif
$ if f$trnlnm("VMSMARIADB$ROOT") .eqs. ""
$ then
$   say "VMSMARIADB$SHUTDOWN: VMSMARIADB$ROOT is not defined; server not stopped"
$   exit 44
$ endif
$ @'cfg'
$ datadir = vmsmariadb_datadir
$ port = vmsmariadb_port
$ node = vmsmariadb_node
$ timeout = f$integer(vmsmariadb_shutdown_timeout)
$ call forget_config
$ if node .nes. f$getsyi("NODENAME") then exit 1
$ call find_process MARIADBD_'port'
$ if found_pid .eqs. ""
$ then
$   say "VMSMARIADB$SHUTDOWN: MARIADBD_''port' is not running"
$   exit 1
$ endif
$ pid = found_pid
$ cnf = datadir + "VMSMARIADB$SHUTDOWN.CNF"
$ if f$search(cnf) .eqs. ""
$ then
$   say "VMSMARIADB$SHUTDOWN: no ''cnf'; cannot ask MARIADBD_''port' to stop"
$   exit 44
$ endif
$ call to_unix 'datadir'
$ ucnf = unix_path + "/VMSMARIADB$SHUTDOWN.CNF"
$ say "VMSMARIADB$SHUTDOWN: stopping MARIADBD_''port' (''pid')"
$ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER STOP 'port' "--defaults-file=''ucnf'"
$ status = $status
$ if .not. status
$ then
$   say "VMSMARIADB$SHUTDOWN: the shutdown request failed (''status')"
$   exit status
$ endif
$ if f$edit(p1, "UPCASE") .eqs. "NOWAIT" then exit 1
$ waited = 0
$wait_loop:
$ call find_process MARIADBD_'port'
$ if found_pid .eqs. ""
$ then
$   say "VMSMARIADB$SHUTDOWN: MARIADBD_''port' has stopped"
$   exit 1
$ endif
$ if waited .ge. timeout
$ then
$   say "VMSMARIADB$SHUTDOWN: MARIADBD_''port' (''pid') still running after ''timeout' seconds"
$   exit 44
$ endif
$ wait 00:00:02
$ waited = waited + 2
$ goto wait_loop
$!
$forget_config: subroutine
$ set noon
$ delete/symbol/global vmsmariadb_datadir
$ delete/symbol/global vmsmariadb_port
$ delete/symbol/global vmsmariadb_account
$ delete/symbol/global vmsmariadb_node
$ delete/symbol/global vmsmariadb_autostart
$ delete/symbol/global vmsmariadb_queue
$ delete/symbol/global vmsmariadb_option
$ delete/symbol/global vmsmariadb_shutdown_timeout
$ exit 1
$ endsubroutine
$!
$! The PID of the process named p1, or "", in the global found_pid.
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
