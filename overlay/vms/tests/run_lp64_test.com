$! RUN_LP64_TEST.COM - compile [.VMS.TESTS]LP64_TEST.C as C and as C++ with
$! vms_lp64.h force-included, and run both.
$ set noon
$ set process/parse_style=extended
$ define/process decc$argv_parse_style enable
$ define/process sys$error sys$output
$ proc = f$environment("PROCEDURE")
$ set default 'f$parse(proc,,,"DEVICE")''f$parse(proc,,,"DIRECTORY")'
$ set default [--]
$ clang :== $sys$system:clang.exe
$ clang "-std=gnu99" "-names2=shortened" "-include" "vms/include/vms_lp64.h" -
    -c vms/tests/lp64_test.c -o vmsobj/lp64_test_c.obj
$ link/exe=[.vmsobj]lp64_test_c.exe [.vmsobj]lp64_test_c.obj
$ run [.vmsobj]lp64_test_c.exe
$ clang "-x" "c++" "-std=gnu++11" "-names2=shortened" "-include" "vms/include/vms_lp64.h" -
    -c vms/tests/lp64_test.c -o vmsobj/lp64_test_cxx.obj
$ link/exe=[.vmsobj]lp64_test_cxx.exe [.vmsobj]lp64_test_cxx.obj
$ run [.vmsobj]lp64_test_cxx.exe
