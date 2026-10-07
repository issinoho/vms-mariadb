$! EXIT_STATUS.COM <tree> - patch 0026: do the clients that return from
$! main() give DCL an error status when they fail?  Each runs once against a
$! port nothing listens on (3399), which must fail, and once in a way that
$! must succeed (--version, or my_print_defaults with no option file).
$ set noon
$ define sys$error sys$output
$ set process/parse_style=extended
$ here = f$environment("DEFAULT")
$ bin = here - "]" + "." + p1 + ".VMSOBJ]"
$ conn = """--no-defaults"" ""--host=127.0.0.1"" ""--port=3399"" ""--user=root"""
$ args == conn + " ""ping"""
$ call try MARIADB-ADMIN 0
$ args == """--version"""
$ call try MARIADB-ADMIN 1
$ args == conn + " ""mysql"""
$ call try MARIADB-DUMP 0
$ args == conn + " ""--all-databases"""
$ call try MARIADB-CHECK 0
$ args == conn + " ""db"" ""NO_SUCH_FILE.TXT"""
$ call try MARIADB-IMPORT 0
$ args == """--no-such-option"""
$ call try MY_PRINT_DEFAULTS 0
$ args == """--no-defaults"" ""client"""
$ call try MY_PRINT_DEFAULTS 1
$ write sys$output "EXIT-PROBE-DONE"
$ exit
$!
$! p1 image, p2 1 if it should succeed; arguments in the global args
$try: subroutine
$ set noon
$ x = "$" + bin + p1 + ".EXE"
$ define/user sys$output nl:
$ define/user sys$error nl:
$ x 'args'
$ st = $status
$ sev = st .and. 7
$ ok = (sev .eq. 1) .eq. (p2 .eq. 1)
$ verdict = "FAIL"
$ if ok then verdict = "PASS"
$ write sys$output "EXIT ", p1, " expect ", f$element(p2, ",", "error,success"), ": status ", st, " severity ", sev, " ", verdict
$ exit 1
$ endsubroutine
