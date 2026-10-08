$! redirect.com - does the C RTL redirect stdout for mariadb-dump given "> file"
$! (with a space) and ">file" (without)?  Uses the installed kit; no server needed.
$ set noon
$ define sys$error sys$output
$ mdump :== $VMSMARIADB$ROOT:[BIN]MARIADB-DUMP.EXE
$ if f$search("rd_*.txt") .nes. "" then delete rd_*.txt;*
$ say = "write sys$output"
$ say "CASE1 space: mdump --version > rd_space.txt"
$ mdump "--version" > rd_space.txt
$ say "CASE1 status ", $status, " file: ", f$search("rd_space.txt")
$ say "CASE2 nospace: mdump --version >rd_nospace.txt"
$ mdump "--version" >rd_nospace.txt
$ say "CASE2 status ", $status, " file: ", f$search("rd_nospace.txt")
$ if f$search("rd_nospace.txt") .nes. "" then type rd_nospace.txt
$ say "CASE3 define/user sys$output"
$ define/user sys$output rd_defuser.txt
$ mdump "--version"
$ say "CASE3 status ", $status, " file: ", f$search("rd_defuser.txt")
$ if f$search("rd_defuser.txt") .nes. "" then type rd_defuser.txt
$ say "exit"
