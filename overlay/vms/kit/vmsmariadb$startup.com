$! VMSMARIADB$STARTUP.COM - system startup for MariaDB (vms-mariadb) on OpenVMS
$!
$! Installed by PCSI into SYS$STARTUP.  Defines the system logical name
$! VMSMARIADB$ROOT, pointing at the installed [VMSMARIADB] directory, where
$! VMSMARIADB$SETUP.COM and VMSMARIADB$SERVER.COM find the images, error
$! messages, character sets and bootstrap SQL.  To run it at every boot, add
$! this line to SYS$MANAGER:SYSTARTUP_VMS.COM:
$!
$!     $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM
$!
$! or, to start the server configured by VMSMARIADB$CONFIGURE.COM as well
$! (after TCP/IP and the batch queues have started):
$!
$!     $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM START
$!
$! The names differ from VSI's MariaDB kit so that both can be installed.
$!
$! P1 = "START":   also start the configured server: read the site file
$!                 (SYS$MANAGER:VMSMARIADB$CONFIG.COM, or the file the logical
$!                 name VMSMARIADB$CONFIG names) and, unless autostart is off,
$!                 the file is for another node or MARIADBD_<port> already
$!                 runs, submit a batch job as the service account that runs
$!                 VMSMARIADB$SERVER START (the server then has the account's
$!                 identity, UAF quotas and privileges).  Needs CMKRNL
$!                 (SUBMIT/USER) and WORLD (to see the process).
$! P1 = "INSTALL": also print the post-installation tasks (PCSI runs it so).
$! P1 = "REMOVE":  deassign VMSMARIADB$ROOT instead (PCSI runs it so at removal).
$!
$ set noon
$ mode = f$edit(p1, "UPCASE")
$ if mode .eqs. "REMOVE"
$ then
$   if f$trnlnm("VMSMARIADB$ROOT", "LNM$SYSTEM_TABLE") .nes. "" then -
        deassign/system/executive_mode VMSMARIADB$ROOT
$   exit 1
$ endif
$!
$! This procedure sits in <destination>[SYS$STARTUP]; the product is in
$! <destination>[VMSMARIADB].  Rooted logicals need the physical form:
$! DKA0:[SYS0.SYSCOMMON.SYS$STARTUP] -> DKA0:[SYS0.SYSCOMMON.VMSMARIADB.]
$ proc = f$environment("PROCEDURE")
$ dev = f$parse(proc,,,"DEVICE","NO_CONCEAL")
$ dir = f$edit(f$parse(proc,,,"DIRECTORY","NO_CONCEAL"), "UPCASE") - "]["
$ root = dir - "SYS$STARTUP]" + "VMSMARIADB.]"
$ if root .eqs. dir + "VMSMARIADB.]"
$ then
$   write sys$error "VMSMARIADB$STARTUP: expected to be in a [SYS$STARTUP] directory, not ''dir'"
$   exit 44
$ endif
$ root = root - ".000000"
$ define/system/executive_mode/translation_attributes=concealed VMSMARIADB$ROOT 'dev''root'
$ if f$search("VMSMARIADB$ROOT:[BIN]MARIADBD.EXE") .eqs. ""
$ then
$   write sys$error "VMSMARIADB$STARTUP: MARIADBD.EXE not found under ''dev'''root'"
$   exit 44
$ endif
$ say = "write sys$output"
$ if mode .eqs. "START" then goto start
$ if mode .nes. "INSTALL" then exit 1
$ say ""
$ say "    Post-installation tasks for MariaDB (vms-mariadb)"
$ say ""
$ say "    To run the server as a service (its own account, started at boot,"
$ say "    stopped cleanly at shutdown), run once, as SYSTEM:"
$ say "    $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$CONFIGURE"
$ say "    and add the two lines it prints to SYSTARTUP_VMS.COM and SYSHUTDWN.COM."
$ say "    Otherwise, to define VMSMARIADB$ROOT at every boot, add this line to"
$ say "    SYS$MANAGER:SYSTARTUP_VMS.COM:"
$ say "    $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM"
$ say "    For each user: to define the mariadb commands, add this line to"
$ say "    LOGIN.COM (or SYLOGIN.COM, for everyone):"
$ say "    $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SETUP.COM"
$ say "    See VMSMARIADB$ROOT:[DOC]README.VMS."
$ say ""
$ say "    PRODUCT REMOVE VMSMARIADB removes the product and deassigns"
$ say "    VMSMARIADB$ROOT; data directories, the service account and"
$ say "    SYS$MANAGER:VMSMARIADB$CONFIG.COM are not touched."
$ say ""
$ exit 1
$!
$start:
$ cfg = f$trnlnm("VMSMARIADB$CONFIG")
$ if cfg .eqs. "" then cfg = "SYS$MANAGER:VMSMARIADB$CONFIG.COM"
$ if f$search(cfg) .eqs. ""
$ then
$   say "VMSMARIADB$STARTUP: no ''cfg' (run VMSMARIADB$CONFIGURE.COM); server not started"
$   exit 1
$ endif
$ @'cfg'
$ datadir = vmsmariadb_datadir
$ port = vmsmariadb_port
$ account = vmsmariadb_account
$ node = vmsmariadb_node
$ autostart = vmsmariadb_autostart
$ queue = vmsmariadb_queue
$ option = vmsmariadb_option
$ call forget_config
$ if .not. autostart
$ then
$   say "VMSMARIADB$STARTUP: autostart is off in ''cfg'; server not started"
$   exit 1
$ endif
$ if node .nes. f$getsyi("NODENAME")
$ then
$   say "VMSMARIADB$STARTUP: ''cfg' is for node ''node'; server not started"
$   exit 1
$ endif
$ ctx = ""
$ x = f$context("PROCESS", ctx, "PRCNAM", "MARIADBD_''port'", "EQL")
$ pid = f$pid(ctx)
$ if f$type(ctx) .eqs. "PROCESS_CONTEXT" then x = f$context("PROCESS", ctx, "CANCEL")
$ if pid .nes. ""
$ then
$   say "VMSMARIADB$STARTUP: MARIADBD_''port' is already running (''pid')"
$   exit 1
$ endif
$! The job cannot read SYS$MANAGER: everything it needs is in parameters.
$ submit/user='account'/noprinter/queue='queue'/name=MARIADBD_'port' -
    /log_file='datadir'VMSMARIADB$START.LOG -
    /parameters=("START","''datadir'","''port'","''option'") -
    VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER.COM
$ status = $status
$ if status then say "VMSMARIADB$STARTUP: starting MARIADBD_''port' as ''account' (log ''datadir'VMSMARIADB$START.LOG)"
$ exit status
$!
$forget_config: subroutine
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
