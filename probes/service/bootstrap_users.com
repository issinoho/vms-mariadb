$! BOOTSTRAP_USERS.COM <tree> SETUP|CHECK|STOP|CLEAN - PLAN_SERVICE step 2
$! probe: can a second "mariadbd --bootstrap" run on an existing data
$! directory set the root password (ALTER USER, given as hex so any
$! character survives DCL), create a SHUTDOWN-only account with a random
$! password (RANDOM_BYTES) and write that password to an option file
$! (SELECT ... INTO DUMPFILE)?  Then: do mariadb-admin --defaults-file=<it>
$! ping/shutdown and root with the new password work?  Uses the build tree's
$! images, [.SVCPROBE.DATA] under the current directory and port 3310.
$ set noon
$ define sys$error sys$output
$ set process/parse_style=extended
$ say = "write sys$output"
$ here = f$environment("DEFAULT")
$ tree = here - "]" + "." + p1 + "]"
$ datadir = here - "]" + ".SVCPROBE.DATA]"
$ tmpdir = here - "]" + ".SVCPROBE.DATA_TMP]"
$ mariadbd = "$" + tree - "]" + ".VMSOBJ_SERVER]MARIADBD.EXE"
$ madmin = "$" + tree - "]" + ".VMSOBJ]MARIADB-ADMIN.EXE"
$ mariadb = "$" + tree - "]" + ".VMSOBJ]MARIADB.EXE"
$ call to_unix 'datadir'
$ udata = unix_path
$ call to_unix 'tmpdir'
$ utmp = unix_path
$ call to_unix 'tree'
$ uroot = unix_path
$ cnf = datadir + "VMSMARIADB$SHUTDOWN.CNF"
$ ucnf = udata + "/VMSMARIADB$SHUTDOWN.CNF"
$ rootcnf = here - "]" + ".SVCPROBE]ROOT.CNF"
$ call to_unix 'rootcnf'
$ urootcnf = unix_path + "/ROOT.CNF"
$ goto 'f$edit(p2, "UPCASE")'
$!
$SETUP:
$ @'f$string(tree - "]" + ".VMS]INSTALL_DB")' 'datadir'
$ say "PROBE install_db status ", $status
$! A password with characters DCL and SQL both treat specially.
$ pw = "Pr0be'x""y%z\"
$ say "PROBE password length ", f$length(pw)
$ call to_hex
$ sql = tmpdir + "SERVICE.SQL"
$ open/write o 'sql'
$ write o "FLUSH PRIVILEGES;"
$ write o "SET @pw = CONVERT(X'", hex_string, "' USING utf8mb4);"
$ write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE('localhost'), ' IDENTIFIED BY ', QUOTE(@pw));"
$ write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE('127.0.0.1'), ' IDENTIFIED BY ', QUOTE(@pw));"
$ write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE('::1'), ' IDENTIFIED BY ', QUOTE(@pw));"
$ write o "EXECUTE IMMEDIATE CONCAT('ALTER USER IF EXISTS root@', QUOTE(LOWER(@@hostname)), ' IDENTIFIED BY ', QUOTE(@pw));"
$ write o "SET @pw = NULL;"
$ write o "SET @sp = HEX(RANDOM_BYTES(16));"
$ write o "EXECUTE IMMEDIATE CONCAT('CREATE OR REPLACE USER vmsmariadb_shutdown@', QUOTE('localhost'), ' IDENTIFIED BY ', QUOTE(@sp));"
$ write o "EXECUTE IMMEDIATE CONCAT('CREATE OR REPLACE USER vmsmariadb_shutdown@', QUOTE('127.0.0.1'), ' IDENTIFIED BY ', QUOTE(@sp));"
$ write o "GRANT SHUTDOWN ON *.* TO vmsmariadb_shutdown@'localhost';"
$ write o "GRANT SHUTDOWN ON *.* TO vmsmariadb_shutdown@'127.0.0.1';"
$ write o "SELECT CONCAT('[client]', CHAR(10), 'user=vmsmariadb_shutdown', CHAR(10), 'password=', @sp, CHAR(10)) INTO DUMPFILE '", ucnf, "';"
$ write o "SET @sp = NULL;"
$ close o
$ log = tmpdir + "SERVICE.LOG"
$ define/user sys$input 'sql'
$ define/user sys$output 'log'
$ define/user sys$error 'log'
$ mariadbd "--no-defaults" "--bootstrap" "--datadir=''udata'" "--basedir=''uroot'" -
    "--lc-messages-dir=''uroot'/vmsgen/sql/share" "--character-sets-dir=''uroot'/sql/share/charsets" -
    "--tmpdir=''utmp'" "--log-warnings=0"
$ say "PROBE bootstrap status ", $status
$ type 'log'
$ say "PROBE cnf: [", f$search(cnf), "] ", f$file_attributes(cnf, "RFM"), " ", f$file_attributes(cnf, "PRO")
$ say "PROBE cnf user line: "
$ search 'cnf' "user="
$ search/statistics/output=nl: 'cnf' "password="
$ open/write o 'rootcnf'
$ write o "[client]"
$ write o "user=root"
$ write o "password=", pw
$ close o
$ open/write o 'datadir'SVCPROBE_RUN.COM
$ write o "$ @", tree - "]", ".VMS]SERVER.COM ", datadir, " 3310 SERVER"
$ close o
$ run/detached/process_name="MARIADBD_3310"/input='datadir'SVCPROBE_RUN.COM -
    /output='datadir'SERVER.LOG/error='datadir'SERVER.LOG/authorize SYS$SYSTEM:LOGINOUT.EXE
$ say "PROBE start status ", $status
$ say "PROBE-SETUP-DONE"
$ exit
$!
$CHECK:
$ madmin "--defaults-file=''ucnf'" "--host=127.0.0.1" "--port=3310" "ping"
$ say "PROBE ping with the shutdown cnf: ", $status
$ mariadb "--defaults-file=''urootcnf'" "--host=127.0.0.1" "--port=3310" "--batch" "-e" -
    "SELECT CURRENT_USER(); SELECT user, host, JSON_VALUE(priv, '$.plugin') AS plugin, LENGTH(JSON_VALUE(priv, '$.authentication_string')) AS authlen FROM mysql.global_priv ORDER BY 1, 2; SHOW GRANTS FOR vmsmariadb_shutdown@localhost"
$ say "PROBE root with the new password: ", $status
$ mariadb "--no-defaults" "--host=127.0.0.1" "--port=3310" "--user=root" "-e" "SELECT 1"
$ say "PROBE root without a password (expect 1045): ", $status
$ mariadb "--defaults-file=''ucnf'" "--host=127.0.0.1" "--port=3310" "-e" "SELECT COUNT(*) FROM mysql.user"
$ say "PROBE shutdown account selecting mysql.user (expect denied): ", $status
$ say "PROBE-CHECK-DONE"
$ exit
$!
$STOP:
$ madmin "--defaults-file=''ucnf'" "--host=127.0.0.1" "--port=3310" "shutdown"
$ say "PROBE shutdown with the shutdown cnf: ", $status
$ say "PROBE-STOP-DONE"
$ exit
$!
$CLEAN:
$ type 'datadir'MARIADBD.ERR
$ set message/nofacility/noseverity/noidentification/notext
$ top = here - "]" + ".SVCPROBE]"
$ delete/nolog 'f$string(top - "]" + "...]*.*;*")'/exclude=*.DIR
$ n = 0
$cl_loop:
$ set security/protection=(o:rwed) 'f$string(top - "]" + "...]*.DIR;*")'
$ delete/nolog 'f$string(top - "]" + "...]*.DIR;*")'
$ n = n + 1
$ if n .lt. 6 then goto cl_loop
$ set security/protection=(o:rwed) SVCPROBE.DIR;*
$ delete/nolog SVCPROBE.DIR;*
$ set message/facility/severity/identification/text
$ say "PROBE after clean: [", f$search(here + "SVCPROBE.DIR"), "]"
$ say "PROBE-CLEAN-DONE"
$ exit
$!
$! pw (a symbol of the caller) -> its bytes in hex, in the global hex_string
$to_hex: subroutine
$ h = ""
$ i = 0
$th_loop:
$ if i .ge. f$length(pw) then goto th_done
$ h = h + f$fao("!XB", f$cvui(0, 8, f$extract(i, 1, pw)))
$ i = i + 1
$ goto th_loop
$th_done:
$ hex_string == h
$ exit 1
$ endsubroutine
$!
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
