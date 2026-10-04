$! VMS_REPLAY.COM - replay host CMake checks with clang (tools/replay.sh).
$! Reads MANIFEST.TXT in this directory ("NNNN VAR MODULE KIND LANG RUNVAR
$! CHECKVAR"), compiles CHK_NNNN.C/.CPP, links it, and for KIND R or S runs
$! it.  Prints one line per check:
$!   RESULT NNNN VAR cc=<severity> link=<severity|-> out=<first output line>
$ set noon
$ set process/parse_style=extended
$! Without this the CRTL lower-cases clang's argv.
$ define/process decc$argv_parse_style enable
$! OpenSSL checks: <openssl/x.h> resolves through this logical (VSI SSL3).
$ define/process openssl ssl3$include:
$ say = "write sys$output"
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ clang :== $sys$system:clang.exe
$ open/write o ssl3.opt
$ write o "sys$share:ssl3$libssl_shr/share"
$ write o "sys$share:ssl3$libcrypto_shr/share"
$ close o
$ open/read m manifest.txt
$loop:
$ read/end=done m line
$ tag = f$element(0, " ", line)
$ var = f$element(1, " ", line)
$ kind = f$element(3, " ", line)
$ lang = f$element(4, " ", line)
$ if lang .eqs. "CXX"
$ then
$   src = "chk_''tag'.cpp"
$   std = "-std=gnu++11"
$ else
$   src = "chk_''tag'.c"
$   std = "-std=gnu99"
$ endif
$ if f$search("replay_tmp.*") .nes. "" then delete/nolog replay_tmp.*;*
$ define/user sys$output replay_cc.lis
$ define/user sys$error replay_cc.lis
$ clang 'std' -c 'src' -o replay_tmp.obj
$ csev = $severity
$ lsev = "-"
$ out = ""
$ if f$search("replay_tmp.obj") .nes. ""
$ then
$   opt = ""
$   define/user sys$output nla0:
$   define/user sys$error nla0:
$   search/nooutput 'src' "openssl/"
$   if $severity .eq. 1 then opt = ",ssl3.opt/opt"
$   define/user sys$output replay_ln.lis
$   define/user sys$error replay_ln.lis
$   link/exe=replay_tmp.exe replay_tmp.obj'opt'
$   lsev = $severity
$   if (kind .eqs. "R" .or. kind .eqs. "S") .and. f$search("replay_tmp.exe") .nes. ""
$   then
$     define/user sys$output replay_run.lis
$     define/user sys$error replay_run.lis
$     run replay_tmp.exe
$     open/read r replay_run.lis
$runloop:
$     read/end=runend r rline
$     if kind .eqs. "S" .and. f$locate("INFO:size", rline) .lt. f$length(rline) then out = rline
$     if kind .eqs. "R" .and. f$extract(0, 11, rline) .eqs. "REPLAY-EXIT" then out = rline
$     goto runloop
$runend:
$     close r
$   endif
$ endif
$ msg = ""
$ if csev .ne. 1 .and. f$search("replay_cc.lis") .nes. ""
$ then
$   open/read c replay_cc.lis
$msgloop:
$   read/end=msgend c cline
$   if f$extract(0, 6, cline) .eqs. "%CXX-E" .or. f$extract(0, 6, cline) .eqs. "%CXX-F"
$   then
$     msg = f$extract(0, 200, cline)
$     goto msgend
$   endif
$   goto msgloop
$msgend:
$   close c
$ endif
$ say "RESULT ", tag, " ", var, " cc=", csev, " link=", lsev, " out=", out, " msg=", msg
$ goto loop
$done:
$ close m
$ if f$search("replay_*.lis") .nes. "" then delete/nolog replay_*.lis;*
$ if f$search("replay_tmp.*") .nes. "" then delete/nolog replay_tmp.*;*
$ say "REPLAY-DONE"
