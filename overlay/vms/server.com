$! SERVER.COM - run mariadbd on a data directory made by [.VMS]INSTALL_DB.
$!
$! Usage:  @[.VMS]SERVER datadir [port] [config] [extra-option]
$!   Runs mariadbd in this process until it shuts down; tools/server.sh starts
$!   it as a detached process (RUN/DETACHED SYS$SYSTEM:LOGINOUT) with this
$!   procedure as its input.  Errors go to <datadir>MARIADBD.ERR.
$!   port defaults to 3307, config to SERVER.
$ set noon
$ set process/parse_style=extended
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [-]
$ root = f$environment("DEFAULT")
$ datadir = f$edit(p1, "UPCASE,TRIM")
$ port = p2
$ if port .eqs. "" then port = "3307"
$ cfg = f$edit(p3, "UPCASE,TRIM")
$ if cfg .eqs. "" then cfg = "SERVER"
$ exe = f$search("[.VMSOBJ_''cfg']MARIADBD.EXE")
$ mariadbd = "$" + exe
$ call to_unix 'datadir'
$ udata = unix_path
$ call to_unix 'f$string(datadir - "]" + "_TMP]")'
$ utmp = unix_path
$ call to_unix 'root'
$ uroot = unix_path
$! An empty quoted argument reaches mariadbd as '' (the C RTL keeps it).
$! --socket= (empty): no Unix-domain socket; AF_UNIX bind() fails on VMS with
$! "no logical name match" (docs/DECISIONS.md D7), so TCP only.
$ extra = ""
$ if p4 .nes. "" then extra = """" + p4 + """"
$ write sys$output "SERVER: ''exe' on ''datadir', port ''port'"
$ mariadbd "--no-defaults" "--datadir=''udata'" "--basedir=''uroot'" -
    "--lc-messages-dir=''uroot'/vmsgen/sql/share" "--character-sets-dir=''uroot'/sql/share/charsets" -
    "--tmpdir=''utmp'" "--port=''port'" "--log-error=''udata'/mariadbd.err" -
    "--pid-file=''udata'/mariadbd.pid" "--socket=" 'extra'
$ write sys$output "SERVER: mariadbd exited with ", $status
$ exit
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
