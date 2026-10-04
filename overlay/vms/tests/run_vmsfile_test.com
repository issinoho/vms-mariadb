$! RUN_VMSFILE_TEST.COM - build and run [.VMS.TESTS]VMSFILE_TEST.C against the
$! client configuration's MYSYS, STRINGS and DBUG libraries (build first).
$ set noon
$ set process/parse_style=extended
$ define/process decc$argv_parse_style enable
$ define/process sys$error sys$output
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [--]
$ clang :== $sys$system:clang.exe
$ clang "-std=gnu99" "-D__GNUC__=4" "-D__GNUC_MINOR__=2" "-pointer-size=argv64" -
    "-names2=shortened" "-DHAVE_CONFIG_H" "-Ivmsgen/include" "-Iinclude" -
    -c vms/tests/vmsfile_test.c -o vmsobj/vmsfile_test.obj
$ link/exe=[.vmsobj]vmsfile_test.exe [.vmsobj]vmsfile_test.obj, -
    [.vmsobj]mysys.olb/lib, [.vmsobj]strings.olb/lib, [.vmsobj]dbug.olb/lib, -
    [.vmsobj]mysys.olb/lib, [.vmsobj]strings.olb/lib
$! Two opens of one file need DECC$FILE_SHARING, several threads on one
$! descriptor DECC$FD_LOCKING.  Only for the test run: clang itself cannot
$! write its object file with FILE_SHARING set.
$ define/process decc$file_sharing enable
$ define/process decc$fd_locking enable
$ define/process decc$efs_charset enable
$ run [.vmsobj]vmsfile_test.exe
$ deassign/process decc$file_sharing
$ deassign/process decc$fd_locking
$ deassign/process decc$efs_charset
$ if f$search("vmsfile_test.dat") .nes. "" then delete/nolog vmsfile_test.dat;*
