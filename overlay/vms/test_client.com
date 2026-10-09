$! TEST_CLIENT.COM - Stage A tests: the native clients against a remote server.
$!
$! Usage: @[.VMS]TEST_CLIENT host port user password database
$! (tools/clienttest.sh passes these from tools/testdb.conf).  The SQL for
$! each test is in [.VMS.TESTS]*.SQL, which clienttest.sh writes, so no SQL
$! goes through DCL quoting.  Uses tables VMS_T and VMS_BIG and drops them.
$! Prints "TEST <name>: PASS|FAIL <detail>" per test and a summary line
$! "CLIENTTEST: <n> passed, <m> failed".
$ set noon
$ set process/parse_style=extended
$ say = "write sys$output"
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [-]
$ bin = f$environment("DEFAULT") - "]" + ".VMSOBJ]"
$ mariadb :== $'bin'MARIADB.EXE
$ mdump :== $'bin'MARIADB-DUMP.EXE
$ mshow :== $'bin'MARIADB-SHOW.EXE
$ madmin :== $'bin'MARIADB-ADMIN.EXE
$ mcheck :== $'bin'MARIADB-CHECK.EXE
$ db = p5
$! --no-defaults must come first.
$ conn = """--no-defaults"" ""--host=''p1'"" ""--port=''p2'"" ""--user=''p3'"" ""--password=''p4'"""
$ badconn = """--no-defaults"" ""--host=''p1'"" ""--port=''p2'"" ""--user=''p3'"" ""--password=x''p4'"""
$ passed == 0
$ failed == 0
$! stdout and stderr go to separate files: two redirections to one file name
$! create two versions of it, and only the newer one would be searched.
$ out == "sys$scratch:test_client.out"
$ err == "sys$scratch:test_client.err"
$!
$ call sql VERSION version          ! SELECT VERSION()
$ call expect VERSION "MariaDB"
$ call sql DDL_DML ddl_dml          ! create, insert, update, delete, select
$ call expect DDL_DML "rows=2,s2=TWO"
$ call sql BIG_SETUP big_setup      ! 100000-row table
$ call expect BIG_SETUP "big=100000"
$ call sql BIG_RESULT big_result "--batch" "--skip-column-names"
$ call count_records BIG_RESULT 100000
$ call sql BIG_INSERT big_insert    ! one ~1 MB INSERT statement
$ call expect BIG_INSERT "after=10003"
$!
$! Failed login: must say so and exit with an error status.
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mariadb 'badconn' "-e" "SELECT 1"
$ sts = $status
$ call expect BAD_LOGIN "Access denied"
$ if sts then call fail BAD_LOGIN_STATUS "success status ''sts'"
$ if .not. sts then call pass BAD_LOGIN_STATUS "status ''sts'"
$!
$! A refused connection (nothing listens on the node's port 1) must report
$! ECONNREFUSED (61), not connect()'s EINPROGRESS (36): patch 0028
$! (probes/conn_refused.c: the refusal comes only from SO_ERROR).
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mariadb "--no-defaults" "--host=127.0.0.1" "--port=1" "-e" "SELECT 1"
$ call expect REFUSED "'127.0.0.1' (61)"
$!
$! The server kills our session in the middle of a batch.  Given with -e
$! (not through "source", where upstream also exits 0) the client must fail,
$! as upstream's does on Linux.
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mariadb 'conn' "''db'" "-e" "SELECT CONCAT('before-kill','-result'); KILL CONNECTION_ID(); SELECT CONCAT('after-kill','-result')"
$ sts = $status
$ call expect KILLED "before-kill-result"
$ call expect_not KILLED_NOT_AFTER "after-kill-result"
$ if sts then call fail KILLED_STATUS "success status ''sts'"
$ if .not. sts then call pass KILLED_STATUS "status ''sts'"
$!
$! The other client programs.
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mdump 'conn' "''db'" "vms_t"
$ call expect DUMP "INSERT INTO `vms_t`"
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mshow 'conn' "''db'"
$ call expect SHOW "vms_big"
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ madmin 'conn' "ping"
$ call expect ADMIN_PING "is alive"
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mcheck 'conn' "''db'" "vms_t"
$ call expect CHECK "OK"
$!
$ call sql CLEANUP cleanup
$ call expect CLEANUP "cleaned"
$ if f$search(out) .nes. "" then delete/nolog 'out';*
$ if f$search(err) .nes. "" then delete/nolog 'err';*
$ say "CLIENTTEST: ''passed' passed, ''failed' failed"
$ exit
$!
$sql: subroutine
$! P1 test name, P2 file [.VMS.TESTS]P2.SQL, P3/P4 extra options
$ opts = ""
$ if p3 .nes. "" then opts = opts + " ""''p3'"""
$ if p4 .nes. "" then opts = opts + " ""''p4'"""
$ define/user sys$output 'out'
$ define/user sys$error 'err'
$ mariadb 'conn' 'opts' "''db'" "-e" "source vms/tests/''p2'.sql"
$ sql_sts == $status
$ exit 1
$ endsubroutine
$!
$expect: subroutine
$! P1 test name, P2 text the output must contain (SEARCH ignores case)
$ define/user sys$output nla0:
$ define/user sys$error nla0:
$ search 'out','err' "''p2'"
$ if $severity .eq. 1
$ then
$   call pass 'p1' ""
$ else
$   msg == "missing: " + p2
$   call fail 'p1' "(see below)"
$   say "  ''msg'"
$   type 'out'
$   type 'err'
$ endif
$ exit 1
$ endsubroutine
$!
$expect_not: subroutine
$ define/user sys$output nla0:
$ define/user sys$error nla0:
$ search 'out','err' "''p2'"
$ if $severity .eq. 1
$ then
$   call fail 'p1' "(unexpected text)"
$ else
$   call pass 'p1' ""
$ endif
$ exit 1
$ endsubroutine
$!
$count_records: subroutine
$! P1 test name, P2 expected number of records; the last must start with P2
$ n = 0
$ last = ""
$ open/read cr 'out'
$crloop:
$ read/end=crend cr line
$ n = n + 1
$ last = line
$ goto crloop
$crend:
$ close cr
$ if n .eq. f$integer(p2) .and. f$element(0, "	", last) .eqs. p2 .and. -
     f$length(last) .eq. f$length(p2) + 61
$ then
$   call pass 'p1' "''n' rows"
$ else
$   call fail 'p1' "''n' rows"
$   say "  last: ", f$extract(0, 100, last)
$ endif
$ exit 1
$ endsubroutine
$!
$pass: subroutine
$ say "TEST ''p1': PASS ''p2'"
$ passed == passed + 1
$ exit 1
$ endsubroutine
$!
$fail: subroutine
$ say "TEST ''p1': FAIL ''p2'"
$ failed == failed + 1
$ exit 1
$ endsubroutine
