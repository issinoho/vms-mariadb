$! VMSMARIADB$STARTUP.COM - system startup for MariaDB (vms-mariadb) on OpenVMS
$!
$! Installed by PCSI into SYS$STARTUP.  Defines the system logical name
$! VMSMARIADB$ROOT, pointing at the installed [VMSMARIADB] directory, where
$! VMSMARIADB$SETUP.COM and VMSMARIADB$SERVER.COM find the images, error
$! messages, character sets and bootstrap SQL.  It does not start a server
$! (see VMSMARIADB$SERVER.COM).  To run it at every boot, add this line to
$! SYS$MANAGER:SYSTARTUP_VMS.COM:
$!
$!     $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM
$!
$! The names differ from VSI's MariaDB kit so that both can be installed.
$!
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
$ if mode .nes. "INSTALL" then exit 1
$ say = "write sys$output"
$ say ""
$ say "    Post-installation tasks for MariaDB (vms-mariadb)"
$ say ""
$ say "    At system startup: to define VMSMARIADB$ROOT at every boot, add this"
$ say "    line to SYS$MANAGER:SYSTARTUP_VMS.COM:"
$ say "    $ @SYS$STARTUP:VMSMARIADB$STARTUP.COM"
$ say "    For each user: to define the mariadb commands, add this line to"
$ say "    LOGIN.COM (or SYLOGIN.COM, for everyone):"
$ say "    $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SETUP.COM"
$ say "    To create a data directory (on an ODS-5 disk) and start a server:"
$ say "    $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER INSTALL_DB dev:[dir.DATA]"
$ say "    $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER START dev:[dir.DATA]"
$ say "    The new root@localhost account has no password: set one."
$ say "    See VMSMARIADB$ROOT:[DOC]README.VMS."
$ say ""
$ say "    PRODUCT REMOVE VMSMARIADB removes the product and deassigns"
$ say "    VMSMARIADB$ROOT; data directories are not touched."
$ say ""
$ exit 1
