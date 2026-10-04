$! VMS_PROBE.COM - compile, link and run the Phase 0 probes in this directory.
$! P1: compiler for C - CLANG (x86-64) or CC (VSI C, both architectures).
$! P2: sets to run, any of H F G R C (default all).
$! H_*.C  header compiles?         F_*.C  CMake-style link test (no header)
$! G_*.C  declared by a header and links?
$! R_*.C  runtime probes, run twice: CRTL defaults, then with the feature
$!        logicals a MariaDB process would set (process table only).
$! CXX*.CPP C++ probes (x86-64 only).
$ set noon
$ set process/parse_style=extended
$! Without this the CRTL lower-cases clang's argv (-D_LARGEFILE became -d_largefile).
$ define/process decc$argv_parse_style enable
$ say = "write sys$output"
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ mode = f$edit(p1, "UPCASE")
$ clang :== $sys$system:clang.exe
$ if mode .eqs. "CLANG"
$ then
$   ccmd = "clang -std=gnu99 -D_LARGEFILE -D_USE_STD_STAT -c"
$   cout = "-o probe_tmp.obj"
$ else
$   ccmd = "cc/names=(as_is,shortened)/float=ieee/define=(_LARGEFILE,_USE_STD_STAT)/nolist/object=probe_tmp.obj"
$   cout = ""
$ endif
$ say "PROBE compiler ", mode, ": ", ccmd
$ sets = f$edit(p2, "UPCASE")
$ if sets .eqs. "" then sets = "HFGRC"
$ if f$locate("H", sets) .lt. f$length(sets) then gosub compile_set_h
$ if f$locate("F", sets) .lt. f$length(sets) then gosub compile_set_f
$ if f$locate("G", sets) .lt. f$length(sets) then gosub compile_set_g
$ if f$locate("R", sets) .lt. f$length(sets) then gosub runtime
$ if f$locate("C", sets) .lt. f$length(sets) .and. f$getsyi("arch_name") .eqs. "x86_64" then gosub cxx
$ if f$search("probe_tmp.*") .nes. "" then delete/nolog probe_tmp.*;*
$ say "PROBE-DONE"
$ exit
$!
$compile_set_h:
$ pat = "H_*.C"
$ goto compile_set
$compile_set_f:
$ pat = "F_*.C"
$ goto compile_set
$compile_set_g:
$ pat = "G_*.C"
$compile_set:
$ f = f$search(pat, 1)
$ if f .eqs. "" then return
$ n = f$edit(f$parse(f,,,"NAME"), "LOWERCASE")
$ if f$search("probe_tmp.obj") .nes. "" then delete/nolog probe_tmp.obj;*
$ define/user sys$output probe_cc.lis
$ define/user sys$error probe_cc.lis
$ 'ccmd' 'n'.c 'cout'
$ csev = $severity
$ lsev = "-"
$ if csev .ne. 2 .and. csev .ne. 4 .and. f$extract(0,2,n) .nes. "h_"
$ then
$   define/user sys$output probe_ln.lis
$   define/user sys$error probe_ln.lis
$   link/exe=probe_tmp.exe probe_tmp.obj
$   lsev = $severity
$ endif
$ msg = ""
$ open/read/error=nomsg in probe_cc.lis
$msgloop:
$ read/end=msgend in line
$ if f$extract(0,1,line) .nes. "%" .or. f$length(msg) .ge. 200 then goto msgloop
$ if f$extract(0,6,line) .eqs. "%CXX-E" .or. f$extract(0,6,line) .eqs. "%CXX-F"
$ then
$   msg = msg + " " + f$extract(0,160,line)
$ else
$   msg = msg + " " + f$element(0,",",line)
$ endif
$ goto msgloop
$msgend:
$ close in
$nomsg:
$ say "RESULT ", n, " cc=", csev, " link=", lsev, msg
$ if f$search("probe_cc.lis") .nes. "" then delete/nolog probe_cc.lis;*
$ if f$search("probe_ln.lis") .nes. "" then delete/nolog probe_ln.lis;*
$ goto compile_set
$!
$runtime:
$ f = f$search("R_*.C", 2)
$ if f .eqs. "" then return
$ n = f$edit(f$parse(f,,,"NAME"), "LOWERCASE")
$ if f$search("probe_tmp.obj") .nes. "" then delete/nolog probe_tmp.obj;*
$ if f$search("''n'.exe") .nes. "" then delete/nolog 'n'.exe;*
$ define/user sys$error sys$output
$ 'ccmd' 'n'.c 'cout'
$ if f$search("probe_tmp.obj") .eqs. ""
$ then
$   say "--- ", n, " did not compile"
$   goto runtime
$ endif
$ link/exe='n'.exe probe_tmp.obj
$ say "--- ", n, " (CRTL defaults)"
$ gosub clean_io
$ define/user sys$error sys$output
$ run 'n'.exe
$ say "--- ", n, " (feature logicals)"
$ gosub clean_io
$ define/process decc$efs_charset enable
$ define/process decc$efs_case_preserve enable
$ define/process decc$filename_unix_report enable
$ define/process decc$filename_unix_no_version enable
$ define/process decc$readdir_dropdotnotype enable
$ define/process decc$file_sharing enable
$ define/process decc$allow_remove_open_files enable
$ define/process decc$posix_seek_stream_file enable
$ define/process decc$rename_no_inherit enable
$ define/user sys$error sys$output
$ run 'n'.exe
$ deassign/process decc$efs_charset
$ deassign/process decc$efs_case_preserve
$ deassign/process decc$filename_unix_report
$ deassign/process decc$filename_unix_no_version
$ deassign/process decc$readdir_dropdotnotype
$ deassign/process decc$file_sharing
$ deassign/process decc$allow_remove_open_files
$ deassign/process decc$posix_seek_stream_file
$ deassign/process decc$rename_no_inherit
$ gosub clean_io
$ goto runtime
$!
$clean_io:
$ if f$search("[.ioprobe]*.*") .nes. "" then delete/nolog [.ioprobe...]*.*;*
$ if f$search("ioprobe.dir") .nes. "" then set security/protection=(o:rwed) ioprobe.dir;*
$ if f$search("ioprobe.dir") .nes. "" then delete/nolog ioprobe.dir;*
$ if f$search("netprobe.sock") .nes. "" then delete/nolog netprobe.sock;*
$ if f$search("[.ioprobe2]*.*") .nes. "" then delete/nolog [.ioprobe2]*.*;*
$ if f$search("ioprobe2.dir") .nes. "" then set security/protection=(o:rwed) ioprobe2.dir;*
$ if f$search("ioprobe2.dir") .nes. "" then delete/nolog ioprobe2.dir;*
$ create/directory/version_limit=1 [.ioprobe2]
$ return
$!
$cxx:
$ say "--- C++"
$ define sys$error sys$output
$ cxx/standard=gnu11/object=probe_tmp.obj cxx_threads.cpp
$ say "RESULT cxx_threads gnu11 TLS cc=", $severity
$ cxx/standard=gnu11/define=NO_TLS/object=probe_tmp.obj cxx_threads.cpp
$ say "RESULT cxx_threads gnu11 NO_TLS cc=", $severity
$ link/exe=cxx_threads.exe probe_tmp.obj
$ run cxx_threads.exe
$ clang -std=gnu++11 -femulated-tls -c cxx_emutls.cpp -o probe_tmp.obj
$ say "RESULT cxx_emutls cc=", $severity
$ if $severity .eq. 1
$ then
$   link/exe=cxx_emutls.exe probe_tmp.obj
$   run cxx_emutls.exe
$ endif
$ clang -std=c++17 -c cxx17.cpp -o probe_tmp.obj
$ say "RESULT cxx17 cc=", $severity
$ link/exe=cxx17.exe probe_tmp.obj
$ run cxx17.exe
$ deassign sys$error
$ return
