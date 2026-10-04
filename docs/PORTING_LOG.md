# Porting log

One entry per build failure (plan §3): command, error, triage code (plan §5: T toolchain,
P probe, H header, L libc, F filesystem, N network, X threads/atomics, S shell/process,
D dependency, U upstream bug), root cause, fix, patch. Newest last.

## Phase 0 tooling notes (no MariaDB build yet)

- **T** `clang -D_LARGEFILE` arrived as `-d_largefile`: the CRTL lower-cases argv unless
  `DECC$ARGV_PARSE_STYLE` is enabled with `SET PROCESS/PARSE_STYLE=EXTENDED`. Fixed in
  `tools/vms_probe.com`; the build procedures must do the same.
- **T** Compiler diagnostics were missing from `vms.sh run` logs: VSI C++/clang write them to
  SYS$ERROR, which `@x.com/OUTPUT=` does not redirect. `define sys$error sys$output`.
- **T** `#if !defined(__has_include) || __has_include(<x>)` is a hard error with VSI C (no
  short-circuit in the preprocessor); guard with `#ifdef __has_include` instead.
- **S** Editing `tools/probe.sh` while it ran broke the running copy ("unexpected EOF"), the
  pitfall vms-grep's CLAUDE.md warns about. Replace running scripts atomically.

## Phase 1 (pipeline)

- **T** `cmake/ssl.cmake`: 11.4 has no `WITH_SSL=OFF`; it fell back to bundled wolfSSL,
  which `upstream.conf` PRUNE had removed. Configure against VSI SSL3's headers in the host
  sysroot (`WITH_SSL=system`); decision D9.
- **S** `cmake/readline.cmake`: no curses/readline on VMS. Patch 0001 skips the search as on
  Windows (`VMS` is set in `cmake/os/OpenVMS.cmake`). `client/mysql.cc` still needs a VMS
  line reader (Stage A).
- **T** `IMPORTFILE-NOTFOUND`: cross-configures need `IMPORT_EXECUTABLES` from a native
  build; `host_configure.sh` builds the generators on the host.
- **T** `sql-bench` cannot be pruned: the top-level CMakeLists.txt adds it unconditionally.
- **T** `clang @vms/build/client/x.rsp`: "no such file". clang finds a response file by a
  plain name or an absolute UNIX path, not by a relative path with directories (VMS syntax
  fails too). `build.com` passes the tree's absolute path to MMS as `ROOT`.
- **T** `include/my_byteorder.h`: "provide byteswap intrinsics". VSI's clang does not define
  `__GNUC__` (upstream clang defines 4.2.1; `-fgnuc-version` is ignored). Defined in
  `vms/config/clang_common.rsp`, and replayed checks get the same defines.
