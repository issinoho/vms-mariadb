$! RUN_TLS_TEST.COM - build and run [.VMS.TESTS]TLS_TEST.CC (my_vms_tls.h).
$ set noon
$ set process/parse_style=extended
$ define/process decc$argv_parse_style enable
$ define/process sys$error sys$output
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [--]
$ clang :== $sys$system:clang.exe
$ clang "-std=gnu++11" "-names2=shortened" "-include" "vms/include/vms_lp64.h" -
    "-Iinclude" -c vms/tests/tls_test.cc -o vmsobj/tls_test.obj
$ link/exe=[.vmsobj]tls_test.exe [.vmsobj]tls_test.obj
$ run [.vmsobj]tls_test.exe
