$! INSTALL_DB.COM - create a MariaDB data directory with its system tables.
$! The DCL counterpart of scripts/mariadb-install-db (a shell script): feeds
$! the same SQL files, in the same order, to "mariadbd --bootstrap".
$!
$! Usage:  @[.VMS]INSTALL_DB datadir [config]
$!   datadir  e.g. DISK$USER:[ME.MARIADB.DATA]; created with /VERSION_LIMIT=1,
$!            and so is its [.TMP] (tmpdir): MariaDB replaces files by
$!            O_TRUNC and rename, which on VMS create new versions
$!            (docs/DECISIONS.md D6).
$!   config   build configuration whose mariadbd to use (default SERVER)
$! Uses the tree this procedure is in: [.VMSOBJ_<config>]MARIADBD.EXE, the
$! error messages in [.VMSGEN.SQL.SHARE] and the SQL in [.VMSGEN.SCRIPTS].
$! The root account gets no unix_socket authentication (VMS has no peer
$! credentials): root@localhost with no password, as --auth-root-
$! authentication-method=normal does.  Prints "INSTALL_DB: done" on success.
$ set noon
$ status = 44
$ say = "write sys$output"
$ saved_default = f$environment("DEFAULT")
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [-]
$ root = f$environment("DEFAULT")
$ datadir = f$edit(p1, "UPCASE,TRIM")
$ cfg = f$edit(p2, "UPCASE,TRIM")
$ if cfg .eqs. "" then cfg = "SERVER"
$ if datadir .eqs. ""
$ then
$   say "INSTALL_DB: usage: @[.VMS]INSTALL_DB datadir [config]"
$   goto done
$ endif
$ exe = f$search("[.VMSOBJ_''cfg']MARIADBD.EXE")
$ if exe .eqs. ""
$ then
$   say "INSTALL_DB: no [.VMSOBJ_''cfg']MARIADBD.EXE (build first)"
$   goto done
$ endif
$ mariadbd = "$" + exe
$ tmpdir = datadir - "]" + ".TMP]"
$ if f$search(datadir - "]" + "...]*.*") .nes. ""
$ then
$   say "INSTALL_DB: ''datadir' is not empty"
$   goto done
$ endif
$ create/directory/version_limit=1 'datadir'
$ create/directory/version_limit=1 'tmpdir'
$!
$! Paths in UNIX form for mariadbd.
$ call to_unix 'datadir'
$ udata = unix_path
$ call to_unix 'tmpdir'
$ utmp = unix_path
$ call to_unix 'root'
$ uroot = unix_path
$!
$! The bootstrap SQL, as mariadb-install-db's cat_sql().
$ sql = tmpdir + "BOOTSTRAP.SQL"
$ missing == 0
$! Start from [.VMS]BOOTSTRAP_HEADER.SQL, a Stream_LF file like the rest:
$! APPEND will not mix it with the variable-length records OPEN/WRITE makes.
$ copy [.vms]bootstrap_header.sql 'sql'
$ call add_sql mariadb_system_tables.sql
$ call add_sql mariadb_performance_tables.sql
$ call add_sql mariadb_system_tables_data.sql
$ call add_sql fill_help_tables.sql
$ call add_sql maria_add_gis_sp_bootstrap.sql
$ call add_sql mariadb_sys_schema.sql
$ if missing
$ then
$   say "INSTALL_DB: bootstrap SQL missing from [.VMSGEN.SCRIPTS] (run tools/prepare.sh)"
$   goto done
$ endif
$!
$ say "INSTALL_DB: system tables in ''datadir' (''udata')"
$ log = tmpdir + "BOOTSTRAP.LOG"
$ define/user sys$input 'sql'
$ define/user sys$output 'log'
$ define/user sys$error 'log'
$ mariadbd "--no-defaults" "--bootstrap" "--datadir=''udata'" "--basedir=''uroot'" -
    "--lc-messages-dir=''uroot'/vmsgen/sql/share" "--character-sets-dir=''uroot'/sql/share/charsets" -
    "--tmpdir=''utmp'" "--log-warnings=0" "--enforce-storage-engine=" -
    "--max_allowed_packet=8M" "--net_buffer_length=16K"
$ status = $status
$ type 'log'
$ if .not. status
$ then
$   say "INSTALL_DB: mariadbd --bootstrap failed (''status'); log in ''log'"
$   goto done
$ endif
$ open/write o 'datadir'mariadb_upgrade_info.
$ write o "11.4.13-MariaDB"
$ close o
$ say "INSTALL_DB: done"
$done:
$ set default 'saved_default'
$ exit status
$!
$! Append [.VMSGEN.SCRIPTS]<p1> to the bootstrap SQL; missing == 1 if absent.
$add_sql: subroutine
$ f = f$search("[.VMSGEN.SCRIPTS]''p1'")
$ if f .eqs. ""
$ then
$   write sys$output "INSTALL_DB: no [.VMSGEN.SCRIPTS]''p1'"
$   missing == 1
$   exit 1
$ endif
$ append 'f' 'sql'
$ exit 1
$ endsubroutine
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
