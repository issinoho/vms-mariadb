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

## Stage A, round 1 (`tools/build.sh x86 client ALL KEEP_GOING`: libraries, my_print_defaults, perror)

| Code | Error | Root cause | Fix |
|---|---|---|---|
| H | `include/my_time.h`: undeclared `suseconds_t` | not in the VMS CRTL | patch 0002 (`long`, as on Windows) |
| H | `mysys/my_lib.c`: undeclared `_POSIX_PATH_MAX` | not in VMS `<limits.h>` | patch 0003 (256, the POSIX value) |
| L | `mysys/guess_malloc_library.c`: undeclared `RTLD_DEFAULT` | VMS `dlsym` has no pseudo-handles | patch 0004 |
| H | `mysys/mf_qsort.c`: undeclared `intptr_t` | POSIX puts it in `<unistd.h>` too; VMS only in `<stdint.h>` | patch 0005 |
| H | `mariadb_lib.c`: no member `__passwd64` in `struct st_mysql`; `my_setuser.c`: conflicting types for `my_set_user` | VMS `<pwd.h>` does `#define passwd __passwd64` with 64-bit pointers, renaming `MYSQL::passwd` and `struct passwd` only after it is seen | patch 0006 (`<pwd.h>` first, from the global headers) |
| H | `ma_net.c`, `pvio_socket.c`: `netinet/in_systm.h` not found | not in VMS TCP/IP headers | patch 0007 |
| T | `mysys/crc32/*`: `cpuid.h`, `emmintrin.h`, `nmmintrin.h` not found | VSI C++ ships no x86 intrinsic headers | patch 0008 (portable CRC on VMS; SIMD later) |
| T | `extra/my_print_defaults.c`: `char * __ptr32 * __ptr32` to `char **` | `main`'s `argv` is 32-bit pointers by default | `-pointer-size=argv64` in `clang_common.rsp` |
| T | `%ILINK-F-OPENIN ... -LIB-E-NOWILD` | the linker takes no wildcards in an options file | gen_mms.py lists objects |

## Stage A, rounds 2-4 (all client programs added)

| Code | Error | Root cause | Fix |
|---|---|---|---|
| H | `ma_net.c`, `pvio_socket.c`: `netinet/ip.h` not found | not in VMS TCP/IP headers; only `IPTOS_THROUGHPUT` is used, already `#ifdef`ed | folded into patch 0007 |
| H | `include/my_net.h`: `netinet/in_systm.h` not found (then `ip.h`) | same as 0007, MariaDB's own copy | patch 0010 |
| S | `client/mysql.cc` needs readline | no readline/libedit/curses on VMS | patch 0009: `fgets()` line reader, no history or completion |
| L | link: `tcgetattr`, `tcsetattr` undefined (`libmariadb/get_password.c`) | no termios functions in the VMS CRTL | patch 0011: no-echo `$QIOW` on `SYS$COMMAND`, stdin without a terminal |
| T | link: `SSL_CTX_use_certificate_chain_file`, `SSL_CTX_set_default_verify_paths`, `SSL_get_ex_data_X509_STORE_CTX_idx` undefined | names longer than 31 characters are exported shortened by VSI SSL3 | `-names2=shortened` in `clang_common.rsp` (C only; C++/libc++ unaffected, tested) |
| T | `mms/ignore=(error,fatal)`: `%DCL-W-ONEVAL` | `/IGNORE` takes one level | `/IGNORE=FATAL` for KEEP_GOING |

First programs run: `perror` (OS and MariaDB error codes decoded) and `my_print_defaults --help`.

**Found while testing the names option:** a pthread mutex initialised with
`PTHREAD_MUTEX_INITIALIZER` fails to lock (EINVAL) when it is on the stack; static and heap
ones work, and so does any mutex set up with `pthread_mutex_init()`. libc++'s `std::mutex`
uses the static initializer, so a `std::mutex` with automatic storage is unusable (this is
also why `std::shared_mutex` aborted in Phase 0). Connector/C uses `pthread_mutex_init()`.
Must be audited for the server (InnoDB, tpool use `std::mutex`): DECISIONS D5.

## Stage A, rounds 5-8 (links clean; client tests)

| Code | Error | Root cause | Fix |
|---|---|---|---|
| L | link: `tcgetattr`, `tcsetattr` still undefined | `mysys/get_password.c` has its own termios code | patch 0012 (no-echo `$QIOW`, as 0011) |
| U | failed login exits `%X00000001` (success to DCL) | `exit(1)`: an odd VMS status is success | patch 0013: `exit()` in `my_global.h` maps non-zero codes to an error-severity status under DCL (POSIX exit under GNV), as vms-wget/vms-curl; now `%X1035A00A` |
| T | test still saw success after patch 0013 | MMS tracks no header dependencies; objects were stale | CLEAN + ALL; noted in CLAUDE.md |
| T | `push.sh` exited silently when nothing had changed | `grep .` with no input fails under `pipefail` | `|| true` |
| - | test: killed session inside `source` exits 0 | **upstream behaviour**: the Linux 11.4.13 client (native build) also exits 0 there, and 1 when the statements are given with `-e` | test changed to `-e` |
| ? | once: `ERROR 2026: TLS/SSL error: connection reset by peer (54)` during the 1 MB INSERT | not reproduced: 5 TLS and 5 plain runs of the same INSERT all succeeded | watch; suspected network (the server is reached through the public address) |

The client uses TLS by default against the 11.8.6 server: `Ssl_cipher` = `TLS_AES_256_GCM_SHA384`
(TLS 1.3 through VSI SSL3, decision D9).

## Stage A exit (2026-10-04)

Interactive session on the x86-64 node, run by the user from a terminal: the password prompt
does not echo (patch 0011), `\s` reports `SSL: Cipher in use is TLS_AES_256_GCM_SHA384, cert
is OK`, statements round-trip, Ctrl/Z exits with "Bye". With `tools/clienttest.sh` 15/15 in
batch, the plan's Stage A exit criterion is met; tagged `stage-a`.

Follow-ups (cosmetic, not blocking):
- Client character set defaults to `latin1`; on Linux it comes from the locale (usually
  `utf8mb4`). Pick a VMS default.
- `my_progname` is the full VMS file spec (`x86vms$dka300:[...]mariadb.exe;1`) in `--version`,
  `\s` and messages; strip it to `mariadb`.
- Default option files are the Unix ones (`/etc/my.cnf`, `~/.my.cnf`); a VMS layout
  (e.g. `MARIADB$ROOT:[ETC]MY.CNF`, `SYS$LOGIN:`) belongs with packaging.
- No input history or tab completion in the interactive client.
- MMS has no header dependencies (a header change needs CLEAN); clang's `-MMS` depfiles could fix it.

## Stage B step 0 (blockers)

- **F** Cross-descriptor coherence (D10, option b): patch 0014 and `mysys/my_vmsfile.c`; see
  D10 for the C RTL behaviours found on the way (stale `lseek(SEEK_END)` after truncate,
  `pread` past EOF extending the file at close, truncate keeping dirty blocks, a writable
  channel's close rewriting the header EOF). `vms/tests/run_vmsfile_test.com`: 20/20.
  Client tests still 15/15.
- **T** `DECC$FILE_SHARING` defined as a process logical makes clang unable to write its
  object file: feature logicals for MariaDB belong inside the images (`LIB$INITIALIZE`),
  never in the build process.
- **X** Stack mutexes (D5): any statically-initialised pthread mutex on a thread stack fails;
  audit as met.

## Stage B: PCRE2 and 64-bit long (D11, D12)

- **D** vms-pcre2 gains a clang (LP64) build variant (D11), commit "Clang (LP64) build
  variant" in that repo; its patch 0003 replaces VAX C `#include descrip` forms clang rejects.
  Its tests under clang found the next item.
- **L** The C RTL's `long` interfaces are 32-bit even for clang's 64-bit `long` (D12):
  `overlay/vms/include/vms_lp64.h`, force-included. Found on the way: the C RTL rejects
  positional printf arguments combined with `ll` or `j`.
- **F** ODS-5 has no sparse files: the header test's `fseek()` to 5 GB on a new file allocated
  and zero-filled the blocks, twice (a timed-out `vms.sh` run kept going on VMS), and took the
  work disk from 15.9M to 3.2M free blocks before both processes were stopped and the files
  deleted. Test changed to a small offset; CLAUDE.md notes both pitfalls.
- **T** The first server build round (started before the header) was stopped, since every
  object must be rebuilt with it; its log was locked and unreadable while it ran.

## Stage B, server round 2 (stopped; first errors from 374 compiles)

| Code | Error | Root cause | Fix |
|---|---|---|---|
| H | `sql_cache.h:537`: "expected identifier" in `enum {WAIT, TIMEOUT, TRY}`, then cascades in 183 files | VMS `<pthread.h>` includes STARLET's `pthread_exception.h`, which defines `TRY`, `CATCH`, `CATCH_ALL`, `FINALLY`, `ENDTRY`, `RAISE`, `RERAISE`, `THIS_CATCH` | `-D_PTHREAD_EXC_INCL_CLEAN` in `clang_common.rsp` (the header's own switch) |
| T | `myrg_static.c`: unknown type `LIST` | its `#ifndef stdin` guard skips `myrg_def.h` once `<stdio.h>` was seen, and `vms_lp64.h` includes it first | patch 0017 |
| X | `tpool_generic.cc`, `wait_notification.cc`: thread_local | D5 | patch 0018, `include/my_vms_tls.h` (tested: `vms/tests/tls_test.cc`) |
| X | `mysqld.cc` (`THR_THD`), `threadpool_common.cc` | D5 | patch 0019; debug-only sites in `mdl.cc`, `my_json_writer.cc` left for a debug build |
| L | `my_addr_resolve.c`: `fork`; `stacktrace.c`: `pthread_kill` | not on VMS | patches 0015, 0016 |

Build speed: MMS is serial; `JOBS=n tools/build.sh` now runs n library groups at once.

## Stage B, server round 3 (399 compiles; serial: the parallel split failed)

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | 191 files: no member `vms_lp64_snprintf` in `my_charset_handler_st` | `vms_lp64.h`'s function-like `snprintf(...)` macro renamed the call `cs->cset->snprintf(...)` but not the member | object-like macros in `vms_lp64.h` |
| T | `sql_select.cc`: `Item_int(thd, ULONGLONG_MAX)` ambiguous | VSI's `ULLONG_MAX` is `18446744073709551615u`, an `unsigned long` under LP64 | `vms_lp64.h` defines `LLONG_*`/`ULLONG_MAX` |
| L | `mysqld.cc`: `pthread_sigmask` undeclared | no `pthread_sigmask`/`sigthreadmask` on VMS | patch 0020 (`sigprocmask`) |
| L | `mysqld.cc`: `chroot` undeclared | no `chroot` on VMS | patch 0021 (`--chroot` is an error) |
| H | `table.cc`, `opt_histogram_json.cc`, `event_queue.cc`: narrowing `my_time_t` to `time_t` | VMS `time_t` is 32-bit unsigned | patch 0022 (casts) |
| S | `sql_prepare.cc`: `../libmysqld/embedded_priv.h` not found | included by relative path; CMake does not list it | `server.pushdirs` |
| D | `item_strfunc.cc`: `fmt/args.h` not found | bundled {fmt} is a build-time download | {fmt} 12.2.0 pinned by SHA-256 in `upstream.conf` (same file as cmake's MD5), unpacked by `prepare.sh` |
| T | parallel groups: `%DCL-W-TKNOVF`, `%MMS-F-BADTARG` | long file-spec target list; case of the targets | `LIB_<name>` pseudo-targets |

## Stage B, server round 4 (parallel; all compiles clean; link)

- Every server source compiles. The link of `mariadbd` reported 8 undefined symbols:
  - `ro_after_init_start`/`_end` (weak): section bounds that GNU ld makes; the VMS linker
    does not. `HAVE_RO_AFTER_INIT` set to no in `manual.txt` (the replayed check links
    because weak references may stay undefined).
  - `Ack_receiver::*`: `SEMISYNC_MASTER_ACK_RECEIVER.OBJ` was **empty** (from a compile killed
    when a round was stopped) and newer than its source, so MMS skipped it and the
    librarian left it out with only `%LIBRAR-I-EMPTYFILE`.
- **T** Cause behind that: `build.com`'s CLEAN deleted `[.VMSOBJ...]` only, never the
  server's `[.VMSOBJ_SERVER]`, so "clean" server rounds kept objects from earlier rounds
  (some compiled before `vms_lp64.h` and the pthread fix). CLEAN now deletes the
  configuration's own tree, and `build.sh` treats `%LIBRAR-I-EMPTYFILE` as an error.
  The client's CLEAN was always right; its results stand.

## Stage B, server round 5: mariadbd links and runs (2026-10-05)

Clean parallel build (`JOBS=2`): 599 compiles, no errors, no undefined symbols, no empty
objects. `mariadbd.exe` (252,331 blocks with debug info) runs:
- `mariadbd --version`: `Ver 11.4.13-MariaDB for OpenVMS on x86_64 (Source distribution)`.
- `mariadbd --no-defaults --help --verbose`: the full option and variable listing (~2,000
  lines), success status. Defaults are the 64-bit ones (`myisam-max-sort-file-size`
  9223372036853727232 as on Linux).
- Warning `failed to retrieve the MAC address` (`my_gethwaddr()` has no VMS implementation;
  used for server UUIDs): follow-up.
- Unix defaults for `basedir`, `datadir`, `socket`, option files: set explicitly for now;
  VMS defaults belong with packaging.

## Stage B: bootstrap attempts

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | `INSTALL_DB.COM`: `%DCL-W-INSFPRM` on each APPEND; bootstrap ran on 3 lines | `'f$search(...)'` in a command line is not evaluated (only symbols are substituted) | `add_sql` subroutine |
| F | Aria: `Can't lock aria control file ... error: 9` | `my_vmsfile.c` gives callers read-only channels; `F_WRLCK` on them is EBADF. Aria always locks `aria_log_control` (not only with `--external-locking`, as D10 assumed) | patch 0023: `my_lock()` locks through the master (`my_vms_lock_fd()`) |
| F | Aria: `File '.../DATA/' not found`, log initialization failed | `translog_init` opens the log directory to fsync it; VMS cannot open a directory | patch 0024 (skip it, as on Windows) |
| S | `%APPEND-W-INCOMPAT` | header lines written by `OPEN/WRITE` (variable records) vs Stream_LF SQL files | `vms/bootstrap_header.sql` (Stream_LF) copied first |
| T | cleanup: second `F$SEARCH` on the same wildcard returned "" | shared wildcard context (vms-grep pitfall) | explicit deletes |
