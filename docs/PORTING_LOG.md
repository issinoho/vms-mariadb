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

## Stage B: first server start (2026-10-05)

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | `Too many arguments (first extra is '')` | `server.com` passed an empty optional argument; the C RTL keeps empty quoted arguments | pass it only when given |
| N | `Bind on unix socket: no logical name match`, abort | AF_UNIX `bind` fails on VMS (D7) | `--socket=` (none): TCP only |
| X | connections accepted, never answered; shutdown hangs | **all POSIX threads ran on one kernel thread**: the main thread's blocking `poll()` stopped every other thread (`--thread-handling=no-threads` answered at once) | `LINK/THREADS_ENABLE` for every image (gen_mms.py) |
| N | shutdown still hung | `poll()` reports a pipe readable before anything is written (`probes/poll_wake.c`); a socketpair wakes correctly | patch 0025 (termination socketpair) |
| T | relink stopped at the first compile warning | MMS stops on warning status | `/IGNORE=WARNING` by default in `build.com` |
| S | `SHOW DATABASES` lists `TMP` | tmpdir inside the datadir | tmpdir is `<datadir>_TMP` |

Result: `@[.VMS]INSTALL_DB` creates the system tables; `tools/server.sh x86 start` starts
`mariadbd` detached, our client queries it over TCP (Aria, MyISAM, MEMORY, CSV, MRG_MyISAM,
SEQUENCE; `lower_case_table_names=2`, chosen by the server for case-insensitive ODS-5), and
`mariadb-admin shutdown` gives "Normal shutdown" and "Shutdown complete".
Not chased (my mistakes): a pipe-in-poll theory disproved by a probe before any change; a wait
loop that read the previous run's output file (CLAUDE.md).

## Stage B: server tests (2026-10-05)

`tools/servertest.sh x86`: **12/12**. (1) The client suite (`vms/test_client.com`, 15/15)
against the VMS server on 127.0.0.1:3307: VMS clients and VMS server end to end. (2) Engines:
Aria and MyISAM (20,000 rows each, BIGINT values to 10^14, UPDATE/DELETE, CHECK, REPAIR,
OPTIMIZE), MEMORY, CSV, MRG_MyISAM, SEQUENCE; a three-way join across engines, GROUP BY ...
HAVING, ORDER BY ... LIMIT, FLUSH TABLES. (3) Clean shutdown and restart: on-disk data
intact and CHECK TABLE OK; MEMORY empty, as it should be.

Still to do for the Stage B exit (plan §3): repeated start/stop cycles, a 100+ MB data load,
a remote client (Linux) over TCP, a 24-hour idle + light-load soak.

## Stage B: remote client (2026-10-05)

A native Linux `mariadb` 11.4.13 client (`cache/native-11.4.13`) connected to the VMS server
over TCP from the build host, as a password account `vmsremote@'%'` (its credentials only in the
git-ignored `tools/testdb.conf`): `VERSION()` 11.4.13-MariaDB, `version_compile_os` OpenVMS,
`version_compile_machine` x86_64; TLS negotiated automatically (`Ssl_cipher`
TLS_AES_256_GCM_SHA384, from the server's auto-generated certificate); CREATE TABLE, INSERT
and SELECT in database `vmsremote`.

## Stage B: data load and restart cycles (2026-10-05)

`tools/loadcycle.sh x86`: 1,000,000 rows into an Aria and a MyISAM table, CHECKSUM TABLE,
then stop/start cycles checking row counts, checksums and CHECK TABLE.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | Aria `INSERT ... SELECT` sat in "Repair by sorting" for 22+ minutes; a new client got no greeting for ~10 minutes | `server.sh` ran `RUN/DETACHED LOGINOUT` without `/AUTHORIZE`, so the server got the PQL_D* default quotas (page file 700,000 pagelets, nearly all used by its ~480 MB of virtual memory; FILLM 52, DIOLM 100) instead of the UAF's | `/AUTHORIZE`: the UAF quotas (PGFLQUOTA 10,000,000) |

With the UAF quotas: Aria load 120 s, MyISAM 99 s (150 MB and 138 MB); a fresh connection
every 30 s during the load answered in at most 0.8 s. A first full run was stopped in cycle 3
by memory pressure on the Linux host (not a failure); the rerun passed: **LOADCYCLE: PASS**,
5/5 stop/start cycles with 2,000,000 rows, matching checksums (1377483367 for both tables)
and CHECK TABLE OK after every start (load 143 s + 171 s, slowest probe 2.8 s while a
previous run's CHECKSUM was still finishing).

**Performance (open):** each cycle's `CHECKSUM TABLE` + `CHECK TABLE` over the two tables
takes ~35 minutes and ~3.8M direct I/Os, about 75 bytes per I/O. `probes/io_count.c` (16 MB
file, x86) measures the C RTL: every `pread()` costs one QIO more than its 16 KB chunks
(8 KB: 2 QIOs, 0.76 ms; 512 B: 2 QIOs, 0.74 ms; 128 KB: 9 QIOs), and `pwrite()` 8 KB costs 3.
MyISAM's checksum scan uses no read cache (no `HA_EXTRA_CACHE` in
`handler::calculate_checksum`), so each dynamic row is two small `pread()`s: ~2M calls x 0.75 ms
is the half hour. On Linux these hit the page cache in ~1 us. The fix belongs in
`my_vmsfile.c` (block I/O on the master by `$QIOW IO$_READVBLK/WRITEVBLK`, or a per-file
block cache), not in the engines.

## Stage D (early): PCSI kit (2026-10-05)

`tools/kit.sh` builds `ISSINOHO X86VMS VMSMARIADB V11.4-13E1` (D13) in `[.KIT_X86_64]`:
`ISSINOHO-X86VMS-VMSMARIADB-V1104-13E1-1.PCSI` (409,616 blocks) and a `.PCSI$COMPRESSED`
copy (223,508 blocks), fetched to `out/kits/`.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | the kit build recompiled the whole server (~600 objects) | `push.sh` replaced the node's manifest with the configuration just pushed; after a client push the server push resent ~3,000 server-only files with new dates | merge the manifest |
| T | `%PCSI-E-SEARCHFAIL ... [.KIT_X86_64.MAT]MARIADB.EXE` | PRODUCT PACKAGE looks material up by file name in one flat directory, not by destination path | flat material directory |
| T | 28 `ERRMSG.SYS` (one per language) cannot share a flat directory | as above | copy as `<LANGUAGE>_ERRMSG.SYS`; PDF `file [...SHARE.<LANG>]ERRMSG.SYS source [000000]<LANG>_ERRMSG.SYS` |
| T | `%PCSI-E-PDFIVS, invalid value syntax` | `source NAME.EXT` needs a directory; PCSI then ignores it (tested with a dummy product) | `source [000000]NAME.EXT` |
| T | `%DCL-W-NOLIST` from `SET SECURITY a,b` | SET SECURITY takes one file spec | one command per spec |

Checked without installing: `PRODUCT LIST` shows every file at its destination (the error
messages under their material names, mapped by `source` in the PDF). PRODUCT EXTRACT FILE
writes everything flat, so `tools/installcheck.sh x86` (with the user's approval) installs it:
**INSTALLCHECK: PASS**. PRODUCT INSTALL into `SYS$COMMON:[VMSMARIADB]` (every language
directory and the charsets in place, `VMSMARIADB$ROOT` defined by the postinstall step);
`VMSMARIADB$SERVER INSTALL_DB` and `START` on a scratch data directory, port 3308; the
installed `mariadb` reports 11.4.13-MariaDB/OpenVMS with `lc_messages_dir` and
`character_sets_dir` under `VMSMARIADB$ROOT`, creates and reads an Aria table, and gets the
server's "Unknown column" message text; `mariadb_dump` works; STOP shuts it down; PRODUCT
REMOVE leaves no files, startup procedure or logical name.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | installcheck left the empty scratch directory `KITDATA.DIR` | a repeated `F$SEARCH` of the same spec continues its old search | delete without an `F$SEARCH` loop |

## Field use: a phpBB database on the x86 server (2026-10-05)

A phpBB 3.3 database (71 InnoDB tables, 7 MB, ~21,500 rows) copied from a MariaDB 11.8 server
on Linux to a user-run 11.4.13 server on x86-64 (port 3306): `mariadb-dump
--single-transaction` on the host, `ENGINE=InnoDB` rewritten to `ENGINE=Aria`, loaded over
TCP as the application account, created on the VMS server with the source's password hash
(`IDENTIFIED BY PASSWORD`) and privileges on the one database. Result: 70 tables identical row
for row (the 71st, `phpbb_sessions`, is live on the source), CHECK TABLE OK, the
application account logs in over the network.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | the load stopped after 21 tables; the other 50 were created (`SHOW TABLES` lists them) but `ERROR 1146 ... doesn't exist` on use, engine NULL in `information_schema.tables` | the server process's open file quota ran out: `FILLM` 150, `FILCNT` 0. `table_open_cache` defaults to 2000 and `open_files_limit` is computed as 32182, so the server never closes tables to stay under FILLM; an Aria table holds two files, and our shared-descriptor layer (D10) holds **two VMS channels per file** (the master plus the caller's read-only channel), so ~35 open tables exhaust 150 | at run time, `SET GLOBAL table_open_cache = 20` and `FLUSH TABLES` (FILCNT back to 135); reloaded the dump |
| S | a single `SELECT ... UNION ALL ...` over all 71 tables failed the same way | one statement needs all its tables open at once, whatever the cache size | one table per statement |

Open (the port's fault, not the user's): (1) the server should size `open_files_limit` and
the table cache from the process's `FILLM`/`FILCNT` (`getrlimit(RLIMIT_NOFILE)` does not
reflect it on VMS) - a patch to `mysys/my_file.c`/`sql/mysqld.cc`; (2) `my_vmsfile.c` could
keep one channel per file instead of two, halving the file count; (3) until then README.VMS
should tell administrators to raise FILLM (1000 or more) for the server's account or set
`table_open_cache` in the option file. The user's server keeps `table_open_cache = 20` only
until it restarts.

## D15 probe: starting a detached process as a service account (2026-10-06)

`probes/service/service_probe.com` (temporary account MDBPROBE `[361,1]` with distinctive
quotas; SETUP, REPORT, CLEANUP). Results in DECISIONS D15: only `SUBMIT/USER=` gives the
detached server the account's identity, UAF quotas and privileges.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | the batch job ran and vanished without a log | `AUTHORIZE ADD` sets DISUSER unless told otherwise (`%LOGIN-F-DISUSER`, seen with `SUBMIT/RETAIN=ALWAYS`) | `/FLAGS=NODISUSER` |
| S | `%DCL-E-NOCMDPROC, error opening captive command procedure - access denied` | the RESTRICTED flag runs `SYLOGIN.COM` captive, and the site's SYLOGIN calls ~20 procedures | no RESTRICTED flag |
| T | ssh to the node stopped answering (banner timeout) overnight | a session of ours stuck since a server stop had used 26 CPU minutes; stopped after access returned | watch for leftover `FTA*_IAIN` sessions (CLAUDE.md) |
| - | (my mistake) blamed directory traversal for the first failure and added ACL entries | `[IAIN]` and `[IAIN.VMS_MARIADB]` already allow world execute | ACLs removed at cleanup |

## PLAN_SERVICE step 2: accounts through a second bootstrap (2026-10-06)

`probes/service/bootstrap_users.com` (build tree's images, scratch data directory in the work
directory, port 3310; removed afterwards): a second `mariadbd --bootstrap` on an existing data
directory runs `FLUSH PRIVILEGES`, `ALTER USER IF EXISTS root@... IDENTIFIED BY` (the password
`Pr0be'x"y%z\` given as hex), `CREATE OR REPLACE USER vmsmariadb_shutdown` with
`HEX(RANDOM_BYTES(16))`, `GRANT SHUTDOWN`, and writes the option file with
`SELECT ... INTO DUMPFILE` (Stream_LF, created `(S:RWD,O:RWD,G:R,W:R)`, so configure resets the
protection). Root logs in with the new password and not without one; the shutdown account can
ping and shut down but not read `mysql.user`; its shutdown was clean.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | `ERROR: 1064 ... near 'BY ', QUOTE(@pw));'` in the bootstrap | DCL substitutes `''localhost'` inside a quoted string: the SQL `root@''localhost''` lost its host | `QUOTE('localhost')` (no doubled apostrophes in DCL strings) |

## PLAN_SERVICE step 2: first install check with the service phase (2026-10-07, kit V11.4-13E2)

`tools/installcheck.sh x86`, run by the user: the kit part passed (install, INSTALL_DB, START,
queries, removal of the product), the service part did not get past configure. Nothing was left
on the system but my 3308 test server (stopped cleanly afterwards) and its scratch directories
(deleted).

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | `%DCL-W-TKNOVF, command element is too long`, then `%UAF-W-BADSPC, no user matches specification`; configure stopped (`AUTHORIZE did not add MDBSVCT`) | the ADD qualifiers were one ~300-character symbol; DCL allows 255 per token, so the ADD line was never written and the MODIFY found no user | three AUTHORIZE commands (ADD, MODIFY access, MODIFY quotas), each built from parts under 255 |
| S | `MARIADBD_3308` still running 10 minutes after STOP; the check went on to `PRODUCT REMOVE` under it | my `admin_options`: `F$LOCATE("--defaults-", "")` is 0, so no option counted as an option file and STOP sent no `--user=root` (`Access denied for user 'IAIN'`) | require a non-empty option |
| S | STOP reported "shutdown requested" although mariadb-admin failed | mariadb-admin ends with `return error;` from `main()`: the C RTL encodes `exit(n)` (`%X1035A00A`) but passes main's return value to DCL raw, and 1 is success. mariadb-dump, -check, -import and my_print_defaults end the same way; `mariadb` uses `exit()` | patch 0026 (2026-10-07): under `__VMS` a small `main()` runs the renamed original through `exit()` in mariadb-admin, -dump, -check, -import and my_print_defaults (mariadb-show, -slap and perror already call `exit()`). The install check still waits for the process rather than trusting a status, and stops before removing anything while a test server runs |

Patch 0026 checked with `probes/exit_status.com` (x86, rebuilt clients, nothing listening on
port 3399): mariadb-admin ping `%X1035A00A`, mariadb-dump, mariadb-check and my_print_defaults
with a bad option `%X1035A012`, mariadb-import `%X1035A00A`, all severity 2; `--version` and a
plain my_print_defaults stay `%X00000001`. `tools/clienttest.sh x86`: 15 passed, 0 failed.
(Probe pitfalls: a CALLed subroutine starts with `ON ERROR THEN EXIT`, so it needs its own
`SET NOON`; and `st = $STATUS` resets `$SEVERITY`, so take the severity from `st`.)

## PLAN_SERVICE step 2: second install check (2026-10-07, kit V11.4-13E2 with patch 0026)

The kit part passed and the 3308 server stopped cleanly (patch 0026 and the process wait).
The service part did not run: the SVC_CONFIGURE phase came back at once with no output.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | a phase returned empty output within a minute; the check took it as "configure failed" | the node had the phase's `.com` (06:59:24) but no `/OUTPUT` log: the ssh session never started, and `vms.sh` printed nothing and returned 0 | `vms.sh`: no log means no session, so retry once after 15 s; a log without the end marker (timeout, cut off) now returns 1 with a message |
| S | `[.KITDATA]` and `[.KITDATA_TMP]` left behind (empty) after REMOVE, in both runs | `deltree` is a CALLed subroutine, which starts with `ON ERROR THEN EXIT`: the first error (deleting a directory not yet empty) left it before the top `.DIR` was deleted | `SET NOON` in it, and in every subroutine of the kit procedures (e.g. `run_bootstrap` would have exited before typing a failed bootstrap's log) |

## PLAN_SERVICE step 2: third install check (2026-10-07)

Configure ran end to end (account MDBSVCT added, data directory, shutdown option file, site
file), but the check reported "configure failed" and went straight to cleanup.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | "service up: 0 (configure failed)" although configure wrote the site file | `phase SVC_CONFIGURE \| grep -q ...`: grep stops at the first match, `tee` then dies of SIGPIPE, and with `pipefail` the `if` is false (the STATUS loops had the same pattern and passed by timing) | `has <phase> <pattern>`: capture the output, then grep it |
| S | `%DCL-W-NOLIST, list of parameter values not allowed` at "give the data to the account", yet configure printed "belongs to MDBSVCT" | `SET SECURITY` takes one file specification; the files were owned by `[361,1]` only because they inherited the owner of the login directory configure had just created (an adopted data directory would have kept its owner) | one `SET SECURITY` per specification, status checked |
| T | `[.SVCTEST]` left after cleanup | the service's files give the system category no delete access, and the check deletes through SYSPRV | `deltree` sets `(S:RWED,O:RWED)` first |

## Host tools on macOS (2026-10-07, a user's report)

A user building on macOS (BSD userland) reported prepare.sh failing in the PCSI kit inputs,
then `kit: client build failed` with no further detail and no images on the node.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | `sed: 1: "d}": extra characters at the end of d command` | prepare.sh inserted the kit's file list with GNU sed's `{r file` / `d}` across two `-e`s; BSD sed rejects it (removing the `d` leaves the `@FILES@` line in the PCSI description) | awk (`getline` from the file); output identical to the release build's (`cmp`), also with mawk and busybox awk |
| T | (possible) push fails on macOS | push.sh used `xargs -r` (GNU) for the directories to create | the existing awk lists every parent directory itself; same list as before but for a harmless `.` |
| T | `kit: client build failed`, nothing else | kit.sh sent build.sh's output to /dev/null and showed only the build log, which does not exist when push or ssh fails | build.sh's output kept in `out/kit-build-<node>-<config>.txt` and shown on failure |

Not checked on a Mac (none here). Still GNU/bash-4 assumptions, which the user's run got past:
`mapfile` (host_configure.sh, build.sh: bash 4+), `sha256sum` (fetch.sh, push.sh).

## Interactive configure in a terminal (2026-10-07)

`CONFIGURE_TTY=1 tools/installcheck.sh x86` (kit V11.4-13E2 as released; configure driven over
an ssh terminal by `tools/configure_tty.py`): **INSTALLCHECK: PASS**, CONFIGURE_TTY: PASS. All
prompts answered, the next free UIC offered (`[360,1]`), a mismatched confirmation asked again,
the default taken at "Go ahead", the password never echoed. Driving DCL: lines must end with
CR (LF is Ctrl/J, delete word); the site prompt was `X86VMS::`, so the driver sets its own.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | on a terminal, "Empty, or the two differ; again." is overwritten by the next password prompt (transcript: `again.^M^[>Password ...`) | `SET TERMINAL/NOECHO` between the message and the READ: after it, READ writes its prompt at column 0 of the current line (without SET TERMINAL, a prompt after a message starts on a new line). `probes/service/prompt_lf.com` over a terminal: `SECRET1: oecho prompt next` on screen; with a blank line first, both intact. Any warning just before the first password prompt would be lost the same way | a blank line before every password prompt (`pw_again`); in the next kit, not yet run through configure on the node |

## Client output redirection (2026-10-08, a user's report)

`mariadb_dump -h 127.0.0.1 -u vamp -p phpbb3315 > phpbb3315_081026.sql` (installed kit):
the dump header appeared on the terminal, then `Couldn't find table: ">"`.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| S | `Couldn't find table: ">"`; no output file | DCL has no `>` redirection, and the C RTL does not redirect for our images either: `probes/redirect.com` on x86 (installed kit) shows `> file` and `>file` both leave stdout on the terminal and create no file, while `DEFINE/USER SYS$OUTPUT` captures it (Stream_LF). So `>` and the file name reach mariadb-dump as table names. README and README.VMS showed exactly this command | documentation: `--result-file=<file>` (the user's dump worked with it) or `DEFINE/USER SYS$OUTPUT`. No code change; parsing `>` in the clients would be a decision of its own |

## DTrace on a macOS host (2026-10-08, the macOS user's next report)

After the host-tool fixes above, `tools/prepare.sh` then `tools/build.sh <node> client` from
the same macOS 26 host (bash 5.3 from Homebrew, BSD sed/xargs, coreutils sha256sum) pushed and
started the build on the node (VSI C++ V10.1-3U1, C V7.7-3, MMS V4.0-5, ODS-5 work disk, as
here), which stopped at the first file that includes `probes_mysql.h`.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| T | `mysys/mf_keycache.c`: `probes_mysql.h:22:10: fatal error: 'probes_mysql_dtrace.h' file not found` | `cmake/dtrace.cmake` sets `ENABLE_DTRACE` (and so `HAVE_DTRACE` in `my_config.h`) whenever the host has a `dtrace` program; macOS has `/usr/sbin/dtrace`, our Linux hosts have none. The header is generated by running dtrace, which never happens for VMS | `-DENABLE_DTRACE=OFF` in `client.options` and `server.options` (a `-D` value is not overridden by the module's `SET(... CACHE)`). Not yet run here: no CMake on this host; the user's next prepare/build will show it |

The `'format' attribute argument not supported: vms_lp64_printf` warnings in the same log are
expected: `vms_lp64.h` (D12) defines `printf` as an object-like macro, so `format(printf, ...)`
attributes name `vms_lp64_printf` and clang ignores them.

## clang memset/bzero miscompile (2026-10-09, found porting PHP)

Porting PHP with the same VSI clang 10.0.1 (vms-php PORTING_LOG #17), `ecalloc()` returned
blocks that were already in use. VSI clang lowers `memset()` and `bzero()` to `OTS$FILL`, but
its optimiser still assumes the call returns its destination, as `memset` does: the shape
`p = alloc(n); if (p) bzero(p, n); return p;` becomes a tail call to `OTS$FILL`, and the caller
gets whatever `OTS$FILL` left in RAX. MariaDB has this shape in `THD::calloc`
(`sql/sql_class.h`, bzero), `ma_calloc_root` (`libmariadb/mariadb_rpl.c`) and
`new_ma_field_extension` (`libmariadb/mariadb_lib.c`). No failure seen here that could be traced
to it; it is a latent wrong-pointer bug in every clang build so far.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| C | (latent) a calloc-style helper returns a pointer to some other block | as above. vms-php `probes/r_calloc_shape.c` on x86: the bzero shape still returned the wrong block with `-fno-builtin-memset` alone; with both flags it returned its own block | `-fno-builtin-memset -fno-builtin-bzero` in `vms/config/clang_common.rsp`: the calls stay real C RTL calls. x86, from CLEAN: client and server build; `tools/servertest.sh x86` 12/12 (client suite 15/15). `tools/clienttest.sh x86` against the 11.8.6 server: 15/15 (with patch 0027 too). Not yet run: `loadcycle.sh` (the first try was stopped: its CHECKSUM connection was dropped and the host client waited with no timeout) |

Checked at the same time: `vms_crtl_init.c` (D6) does run in our images. vms-php found its
own `LIB$INITIALIZE` entry never called with clang, so a probe on x86 linked
`[.vmsobj]vms_crtl_init.obj` exactly as the client `.opt` files do (with
`PSECT_ATTR=LIB$INITIALIZE,CON,REL,GBL,NOSHR,NOEXE,RD,NOWRT`): all eleven D6 features read 1,
`getcwd()` and `argv[0]` are UNIX-form; the same program without the object reads 0 and VMS
form. So the D6 features have been in effect in every clang build; nothing to change.

## DROP DATABASE left the database behind (2026-10-09)

Found while checking the D6 features on the 3307 test server: `DROP DATABASE vmsefs` deleted
the tables, then failed. `servertest.sh` drops `vmsengines` at the end but did not check it, so
`vmsengines` had been left behind by every run since Stage B.

| Code | Error | Root cause | Fix |
|---|---|---|---|
| R | `ERROR 24 (HY000): Can't read value for symlink './vmsefs' (Errcode: 2 "no such file or directory")`; tables gone, database still listed, directory left | `rm_dir_w_symlink()` (`sql/sql_db.cc`) calls `my_readlink()` on the database directory; `my_readlink()` takes only `EINVAL` as "not a symlink". A probe on x86 with the D6 features: `readlink()` gives `EINVAL` on a file but `ENOENT` on an existing directory (`dir`, `./dir`, `dir/`); symlinks to files and directories read correctly | patch 0027: under `__VMS`, `ENOENT` from `readlink()` on a path that `lstat()` finds and that is not a symlink counts as `EINVAL`. x86: `servertest.sh` 14/14 with two new checks (`drop_database`, `persist_done`); a database named `` `drop-me.x` `` with Aria, MyISAM and CSV tables, the leftover `vmsefs`, and `DROP DATABASE IF EXISTS` of a missing one: all dropped, directories gone |

## Connect errors reported as (36) (2026-10-09)

A clienttest run against an address the node could not reach failed every test with
`Can't connect to server on '192.168.0.155' (36)`. The same `(36)` appears in a user's report
("system error: 36").

| Code | Error | Root cause | Fix |
|---|---|---|---|
| R | `ERROR 2002 (HY000): Can't connect to server on '<host>' (36)` for an unreachable host without `--connect-timeout`; with it, `(60)` | Connector/C (`pvio_socket_internal_connect()`) connects a non-blocking socket: `connect()` sets `errno` to `EINPROGRESS` (36 on OpenVMS), `poll()` waits, `getsockopt(SO_ERROR)` gives the real error, which is returned; but `pvio_socket_connect()` reports `socket_errno`, still 36. With `--connect-timeout` the `poll()` timeout sets `ETIMEDOUT` itself. Upstream bug (Linux would show 115) | patch 0028: `errno` set to the `SO_ERROR` value before it is returned. x86: refused port `(61)`; unreachable `(60)` with and without `--connect-timeout` (75 s, one TCP timeout); `mariadb-dump` likewise, one attempt in 74.6 s (the apparent retry loop was clienttest's separate commands, each waiting out a TCP timeout); normal connections unchanged; `clienttest.sh x86` 15/15 |
