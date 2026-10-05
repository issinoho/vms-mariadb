$! VMSMARIADB$SETUP.COM - define the MariaDB client commands for a user
$!
$! Add to LOGIN.COM (or SYS$MANAGER:SYLOGIN.COM for everyone):
$!     $ @VMSMARIADB$ROOT:[000000]VMSMARIADB$SETUP.COM
$!
$! DCL symbols cannot contain "-", so mariadb-admin is MARIADB_ADMIN and so
$! on.  MARIADB_SERVER runs VMSMARIADB$SERVER.COM (INSTALL_DB, START, STOP,
$! STATUS).  Options are case-sensitive (-P is the port, -p the password):
$! use SET PROCESS/PARSE_STYLE=EXTENDED, or quote them ("-P3306"); batch
$! jobs use the traditional style.
$!
$ if f$trnlnm("VMSMARIADB$ROOT") .eqs. ""
$ then
$   write sys$error "VMSMARIADB$SETUP: VMSMARIADB$ROOT is not defined; run VMSMARIADB$STARTUP.COM first"
$   exit 44
$ endif
$ mariadb        :== $VMSMARIADB$ROOT:[BIN]MARIADB.EXE
$ mariadb_admin  :== $VMSMARIADB$ROOT:[BIN]MARIADB-ADMIN.EXE
$ mariadb_check  :== $VMSMARIADB$ROOT:[BIN]MARIADB-CHECK.EXE
$ mariadb_dump   :== $VMSMARIADB$ROOT:[BIN]MARIADB-DUMP.EXE
$ mariadb_import :== $VMSMARIADB$ROOT:[BIN]MARIADB-IMPORT.EXE
$ mariadb_show   :== $VMSMARIADB$ROOT:[BIN]MARIADB-SHOW.EXE
$ mariadb_slap   :== $VMSMARIADB$ROOT:[BIN]MARIADB-SLAP.EXE
$ my_print_defaults :== $VMSMARIADB$ROOT:[BIN]MY_PRINT_DEFAULTS.EXE
$ perror         :== $VMSMARIADB$ROOT:[BIN]PERROR.EXE
$ mariadb_server :== @VMSMARIADB$ROOT:[000000]VMSMARIADB$SERVER.COM
$ exit 1
