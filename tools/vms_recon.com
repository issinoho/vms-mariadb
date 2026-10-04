$! VMS_RECON.COM - Phase 0 reconnaissance for the MariaDB port (read-only).
$! Run through tools/recon.sh; the output becomes docs/env-<node>.txt.
$ set noon
$ say = "write sys$output"
$ sect: subroutine
$   say ""
$   say "=== ''p1'"
$ endsubroutine
$ call sect "system"
$ say "version   ", f$getsyi("version")
$ say "arch      ", f$getsyi("arch_name")
$ say "hw_name   ", f$getsyi("hw_name")
$ say "node      <redacted>"
$ say "cpus      ", f$getsyi("activecpu_cnt")
$ say "memsize   ", f$getsyi("memsize"), " pages of ", f$getsyi("page_size"), " bytes"
$ say "pgflquota ", f$getjpi("", "pgflquota"), "  wsextent ", f$getjpi("", "wsextent")
$ say "bytlm     ", f$getjpi("", "bytlm"), "  fillm ", f$getjpi("", "fillm"), -
      "  prclm ", f$getjpi("", "prclm"), "  tqlm ", f$getjpi("", "tqlm")
$ say "maxprocesscnt ", f$getsyi("maxprocesscnt"), "  channelcnt ", f$getsyi("channelcnt")
$ say "workdir disk ", f$getdvi("sys$disk", "acpptype"), "  ods ", f$getdvi("sys$disk", "odstructure")
$ say "free blocks ", f$getdvi("sys$disk", "freeblocks"), " of ", f$getdvi("sys$disk", "maxblock")
$ call sect "products"
$ product show product/full
$ call sect "cc/version"
$ cc/version
$ call sect "cxx/version"
$ cxx/version
$ call sect "clang"
$ if f$search("sys$system:clang.exe") .nes. ""
$ then
$   clang :== $sys$system:clang.exe
$   clang --version
$ else
$   say "no SYS$SYSTEM:CLANG.EXE"
$ endif
$ call sect "cxx setup procedure"
$ say f$search("sys$examples:cxx$setup.com")
$ call sect "librarian / linker"
$ link/version
$ call sect "mms / mmk"
$ mms/ident
$ say "mmk: ", f$search("sys$system:mmk.exe"), f$trnlnm("mmk")
$ call sect "tools on DCL$PATH and elsewhere"
$ show logical dcl$path
$ show symbol cmake
$ show symbol git
$ show symbol perl
$ show symbol python
$ show symbol bash
$ show symbol gmake
$ show symbol make
$ define/user sys$output nla0:
$ x = f$search("sys$system:cmake*.exe")
$ say "sys$system cmake: ", f$search("sys$system:cmake*.exe")
$ say "dcl$path cmake:   ", f$search("dcl$path:cmake*.exe")
$ say "gnv cmake:        ", f$search("gnu:[bin]cmake*.")
$ call sect "perl"
$ perl -v
$ call sect "python"
$ python --version
$ call sect "git"
$ git --version
$ call sect "OpenSSL kits"
$ show logical ssl3$*
$ show logical ssl$include
$ call sect "zlib / pcre2 install trees in the work directory"
$ dir/size/nohead/notrail [...]*ZLIB*.DIR, [...]*PCRE2*.DIR
$ call sect "decc$ logicals"
$ show logical decc$*
$ call sect "process parse style"
$ say f$getjpi("", "parse_style_perm")
$ call sect "batch queues"
$ show queue/batch/all
$ say "RECON-DONE"
