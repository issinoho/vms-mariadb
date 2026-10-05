# Decisions

Each entry: the decision, the evidence, the alternatives. **Status** is *proposed* until the
user approves it. Raw evidence: `docs/env-<node>.txt` (recon) and `docs/probes-<node>-<cc>.txt`
(probes); `docs/PHASE0.md` summarises the probe results.

## D0. Repository method: release tarball + patches + overlay (as the sibling ports)

**Status:** approved by the user (2026-10-04).

The plan (§3) suggests forking `MariaDB/server` and working on a `10.6-vms` branch. The sibling
ports (vms-grep, vms-curl, vms-zlib, ...) instead pin a **signed release tarball** in
`upstream.conf`, keep only our deltas in `patches/` (quilt series, one fix per patch) and
`overlay/` (new files only), and regenerate `staging/` with `tools/prepare.sh`.

- For: same tooling and habits as the other ports; rebasing to a new 11.4.x release is
  "bump `upstream.conf`, see which patches reject"; every change is reviewable and
  upstreamable as a separate patch.
- Against: MariaDB is ~1 GB unpacked (221 MB tarball) and ~430 compile units for the client
  alone, so the patch series will be longer than in the other ports. A fork would give
  `git rebase`, but we would lose the uniform workflow.
- The tarball is signed: `mariadb-11.4.13.tar.gz.asc` verifies against the MariaDB Signing Key
  `177F 4010 FE56 CA33 3630 0305 F165 6F24 C74C D1D8` (`keys/mariadb-signing-key.asc`).
  It ships the generated parser (`sql/yy_mariadb.cc`, `yy_oracle.cc`), so no bison is needed.
- The plan's `PORTING_LOG.md` and `DECISIONS.md` are kept (in `docs/`); its
  `vms/scripts/{sync,build,fetch-log}.sh` become the sibling `tools/` scripts
  (`vms.sh`, `push.sh`, `build.sh`).

## D1. How to run CMake: cross-configure on Linux, build with MMS on VMS (plan option B)

**Status:** approved by the user (2026-10-04).

Evidence:
- **No CMake on either node** (no product, nothing on `DCL$PATH`, nothing under
  `SYS$COMMON:[000000...]`). Only GNV `make` (3.x era) and MMS V4.0-5; MMK on IA64 only.
- **CMake's own probes would give wrong answers here anyway.** `CHECK_FUNCTION_EXISTS` links
  `char f(void); main(){return f();}` without a header. With clang that fails for ordinary
  CRTL functions (`strdup`, `strerror`, `strtoull`, `vsnprintf`, `stpcpy`, ...) because the
  `DECC$` name mapping only happens through the CRTL headers. VSI C also accepts
  `<linux/mman.h>` and `<netinet/in6.h>`, so `CHECK_INCLUDE_FILES` is unreliable too.
- A Linux reference configure works (`cmake 4.2.3`, `-DWITHOUT_SERVER=ON`): 430 compile units
  (mysys 125, libmariadb 82, strings 50, ...), `config.h` with 333 `#define`s.

Approach: run CMake on the host for the target configuration, take the per-target source
lists, include paths and defines from CMake's File API / `compile_commands.json`, generate
`DESCRIP.MMS` files (as `vms-grep/tools/gen_mms.py` does), and generate `config.h` /
`my_config.h` from MariaDB's `config.h.cmake` with answers from header-aware probes run by
clang on the node (the vms-grep "compile server" idea), each override commented.

Alternatives: (A) native CMake — none exists; (C) build CMake on VMS — large detour (C++17,
libuv, curl...), and its probes would still need overriding as shown above.

## D2. MariaDB version: 11.4 LTS instead of 10.6

**Status:** approved by the user (2026-10-04). Changes the plan's §1.

- 10.6's community support ended in **July 2026**; porting it now ships an EOL server.
- C++ level by branch (from each branch's top-level `CMakeLists.txt`):
  10.6, 10.11 and **11.4: C++11** (`-std=gnu++11`, C `gnu99`); **11.8 and 12.x/13.x: C++17**.
- 11.4 is the newest LTS that is still C++11 (supported to 2029). Current release
  **11.4.13** (pinned in `upstream.conf`).
- C++17 on VSI C++ 10.1 is not ruled out (`std::optional`, `string_view`, structured
  bindings, `<charconv>` integer conversions compile), but `<variant>` breaks when a STARLET
  header's `#define __union union` has been seen first, and `std::shared_mutex` aborts at run
  time (see D5). Revisit 11.8 once 11.4 works.

Alternative: 10.11 LTS (also C++11, supported to Feb 2028) - no advantage over 11.4.

## D3. Targets: server on x86-64 only; IA64 at most for Connector/C, later

**Status:** approved by the user (2026-10-04). Note the user's other ports all ship IA64 + x86-64.

- IA64 VSI C++ V7.4-006 is the classic EDG compiler: no C++11 (`static_assert` rejected,
  vms-grep `docs/vms-environment.md`). MariaDB 11.4's server, `mariadb` client and mysys
  (C++ parts) cannot be built there.
- `libmariadb` (Connector/C, 82 C files) is C99 and *might* build with VSI C 7.4 on IA64,
  giving IA64 a native client library for C programs. Deferred until Stage A works on x86.

## D4. Compiler: clang (VSI C++ V10.1-3U1, clang 10.0.1) for all C and C++ on x86-64

**Status:** approved by the user (2026-10-04).

- clang on x86-64 is **LP64**: `long` 8, pointers 8, `size_t` 8 (C and C++). There is no
  option for a 32-bit `long` (`-pointer-size=` changes pointers only).
- VSI C V7.7 on x86-64 is **ILP32** by default: `long` 4, pointers 4, `size_t` 4.
- So C and C++ objects from the two compilers don't share a data layout for anything with a
  `long` or a pointer in it. MariaDB's C parts (mysys, strings, libmariadb) share structs with
  its C++ parts, so **everything is compiled with clang**. Bonus: clang has the `__atomic_*`
  and `__sync_*` builtins `my_atomic.h` uses (VSI C has neither), and C11 (`__STDC_VERSION__`
  201112). It has no `<stdatomic.h>`, which MariaDB doesn't need.
- Consequence for dependencies: the vms-zlib and vms-pcre2 trees are VSI C objects and
  `zlib`'s `uLong`/`z_stream` layout differs; use MariaDB's **bundled zlib and PCRE2** compiled
  with clang (`WITH_ZLIB=bundled`, `WITH_PCRE=bundled`), or rebuild the sibling libraries with
  clang into a separate install tree. VSI's SSL3 (OpenSSL 3.0) images are VSI C builds too:
  calls returning `long`/`unsigned long` (`ERR_get_error`, `SSL_CTX_ctrl`, `BIO_ctrl`) need
  checking before TLS is enabled. **[VERIFY]** in Stage A's TLS pass.
- Command-line case: the CRTL lower-cases clang's argv (`-D_LARGEFILE` arrived as
  `-d_largefile`) unless `DECC$ARGV_PARSE_STYLE` is enabled with `/PARSE_STYLE=EXTENDED`.
- Diagnostics go to SYS$ERROR, which `@x.com/OUTPUT=` does not capture:
  `define sys$error sys$output` in build procedures.

## D5. Thread-local storage: shim `thread_local` with pthread keys

**Status:** approved by the user (2026-10-04).

- VSI C++ 10.1 rejects `thread_local`, `__thread` and `_Thread_local`: "OpenVMS does not
  currently support thread_local/__thread/_Thread_local declaration specifiers". The
  `-femulated-tls` option hits the same check.
- Uses in the parts we build (11.4.13): `sql/mysqld.cc` (`THR_THD`, the current THD),
  `sql/mdl.cc` (2), `sql/my_json_writer.{h,cc}`, `sql/threadpool_common.cc`,
  `tpool/tpool_generic.cc`, `tpool/wait_notification.cc`, `storage/innobase/log/log0sync.cc`,
  `libmariadb/plugins/auth/ed25519.c`, `libmariadb/plugins/auth/parsec.c`.
- Plan: a small header in `overlay/` providing `vms_tls<T>` (lazy per-thread object behind a
  `pthread_key_t`, destroyed by the key destructor), and one patch per file switching to it
  under `#ifdef __VMS`. For C (`__thread` in the two auth plugins), use pthread keys directly.
  Hot path: `current_thd` goes through `pthread_getspecific`; measure later.
- Memory: under clang, `malloc` returns 64-bit addresses (16 x 256 MB allocated, highest
  0x1_9200_6010), so large buffers are possible despite libc++'s "32-bit allocator" warning
  about aligned `operator new`.
- `std::shared_timed_mutex` aborts ("mutex lock failed: invalid argument") with libc++ 10 on
  VMS. The cause (Stage A): a pthread mutex set up by `PTHREAD_MUTEX_INITIALIZER` fails with
  EINVAL when it lives **on the stack**; static and heap ones work, as does
  `pthread_mutex_init()`. libc++'s `std::mutex` (and `std::condition_variable`'s use of it)
  relies on the static initializer, so automatic-storage `std::mutex` objects fail.
  Stage B step 0.2 (`probes/r_mutex.c`): **every** statically-initialised mutex on a thread
  stack fails (main thread or created thread, any alignment, even a `memcpy` of a static
  one), while the same bytes on the heap work. POSIX only promises the initializer for
  statically allocated mutexes, so VMS is within its rights. Exposure in 11.4: `std::mutex`
  appears 46 times in tpool, 24 in InnoDB, 4 in sql/, 3 in mysys, nearly all as members of
  heap or static objects. Failures are loud (libc++ throws `system_error`), not silent.
  Decision: audit stack-allocated objects with `std::mutex`/`std::condition_variable`
  members as Stage B meets them and patch those sites; no global workaround.

## D6. File-system semantics: CRTL feature logicals + datadir with version limit 1

**Status:** approved by the user (2026-10-04); the descriptor-coherence problem below is open.

Findings (identical on IA64 with VSI C and x86-64 with clang; see `docs/PHASE0.md`):
- MariaDB's file names (`#sql-…`, `t@002d1.frm`, `x#P#p0.ibd`, `a.b.c`, names with spaces,
  mixed case) **fail without `DECC$EFS_CHARSET`** and all work with it; `readdir` reports
  them exactly (case and dots preserved, no `;version`) with
  `DECC$EFS_CASE_PRESERVE`, `DECC$FILENAME_UNIX_REPORT`, `DECC$FILENAME_UNIX_NO_VERSION`,
  `DECC$READDIR_DROPDOTNOTYPE`.
- A second `O_RDWR` open of a file fails ("file currently locked by another user") unless
  `DECC$FILE_SHARING` is enabled; `unlink` of an open file needs
  `DECC$ALLOW_REMOVE_OPEN_FILES`.
- **`st_size` is stale on an open file:** after `pwrite`s, `fstat`/`stat` report 0 (the RMS
  end-of-file is only written back by `fsync` or `close`), while `lseek(fd, 0, SEEK_END)` is
  right. Every engine asks for file sizes (`my_fstat`, `os_file_get_size`, Aria/MyISAM
  `mysql_file_seek(..., MY_SEEK_END)`), so mysys must use `lseek(SEEK_END)` on VMS.
  (`r_io2`, every variant, both nodes.)
- **Writes are not coherent across two descriptors of the same file:** with
  `DECC$FILE_SHARING` (or `"shr=get,put,upd"`), a `pwrite` through one descriptor was not seen
  by `pread` through the other, not even after `fsync` of the writer, in either direction.
  The CRTL buffers per descriptor. MyISAM opens its data file once per table instance, so this
  is a correctness problem, not a performance one. No `open()` RMS option tried so far
  (`ctx=stm`, `rfm=udf`, `shr=...`) fixes it. **Must be solved before Stage B**; options: find
  a CRTL/RMS setting that disables the buffering, route mysys I/O through one shared
  descriptor per file, or do mysys file I/O with `SYS$QIO`/RMS block I/O directly.
- **File versions:** `open(O_TRUNC)` and `rename()` onto an existing name create a new
  version and keep the old one, so the next `unlink` "reveals" stale data. In a directory
  created with `/VERSION_LIMIT=1` this does not happen (`r_io2`: name gone after one unlink).
  Plan: datadir and tmpdir created `/VERSION_LIMIT=1`, and `my_mkdir` doing the same for
  database directories.
- `realpath()` is declared and links but returns `ENOSYS` at run time on both nodes; `open()` on a directory fails (so `fsync` of a directory,
  used by InnoDB and the DDL log, needs a no-op path); no `O_DIRECT`; `O_DSYNC`/`O_SYNC` exist.
- The feature logicals will be set inside the images via `LIB$INITIALIZE` (as the sibling
  ports do), not system-wide.

## D7. Networking: TCP only at first

**Status:** approved by the user (2026-10-04).

Sockets behave as vio needs: non-blocking `connect`/`accept`, `poll()` on listening and
connecting sockets, `MSG_DONTWAIT`, `TCP_NODELAY`, `SO_KEEPALIVE`, `SO_RCVTIMEO`,
`getaddrinfo`, IPv6 dual stack, `socketpair`. `AF_UNIX` sockets can be created but `bind` to
a relative path fails ("no logical name match"); the Unix-socket listener is left off
(`--socket` unused) until that is understood.

## D8. Configure answers: replay CMake's own checks on the node

**Status:** implemented in Phase 1 (follows from D1).

`tools/host_configure.sh` runs CMake on the host with `vms/cmake/toolchain-openvms.cmake`
(`CMAKE_SYSTEM_NAME OpenVMS`: a cross-configure, so no host libraries are found and CMake's
own `Platform/OpenVMS.cmake` applies). MariaDB then loads `cmake/os/OpenVMS.cmake` (overlay),
which includes `cmake/os/OpenVMSCache.cmake`, the same mechanism as upstream's
`cmake/os/WindowsCache.cmake`. The cache is generated:

1. `--debug-trycompile` keeps the source of every check CMake runs;
   `CMakeFiles/CMakeConfigureLog.yaml` names its variable and compile command.
2. `tools/replay_gen.py` turns each check into a self-contained C/C++ file;
   `tools/vms_replay.com` compiles, links and runs it with clang on the node
   (`tools/replay.sh`). Header-less `CheckFunctionExists` checks are replayed as
   "declared by a CRTL header and links" (see D1), type sizes are printed by a wrapper,
   GCC flag checks and `CheckLibraryExists` are answered "no" by policy.
3. `tools/replay_answers.py` merges results into `vms/config/answers.txt` (generated) and
   writes `cmake/os/OpenVMSCache.cmake` from it plus `vms/config/manual.txt` (hand-set,
   each with a reason: `realpath`, headers the CRTL finds by ignoring the directory part).
4. Configure again; new answers can open new code paths, so repeat until no check is left
   (client: 294 checks, then 7 more, then none).

MariaDB's cross-compile support needs its build-time generators from a native build
(`IMPORT_EXECUTABLES`); host_configure.sh builds them once under `cache/native-<version>`.
Their output (`mysqld_error.h`, ...) is platform-independent and goes to `vmsgen/`.

`tools/gen_mms.py` writes `vms/build/<config>/DESCRIP.MMS` from CMake's File API: one rule
per object, compile flags in per-target clang response files (only `-D` and `-std` from
CMake; our flags from `vms/config/clang_common.rsp`), `.OLB` per library, options files for
images. `vms/build.com` runs it with MMS.

## D9. TLS library: VSI SSL3, with an audit of `long`-typed calls

**Status:** approved by the user (2026-10-04): option (a). Link VSI SSL3's 64-bit-pointer
images (`SSL3$LIBSSL_SHR`, `SSL3$LIBCRYPTO_SHR`) and audit every `long`-typed OpenSSL call
MariaDB makes; option (b), our own clang-built OpenSSL, is the fallback if the audit finds
problems that cannot be worked around.

Audit (2026-10-04; Connector/C `secure/openssl*.c`, auth plugins, `vio/`, `mysys_ssl/`):
- `ERR_get_error`/`ERR_peek_error` return `unsigned long`: values come from a 32-bit `long`
  library so they fit in 32 bits; whether the caller sees them zero- or sign-extended, the
  header macros (`ERR_GET_LIB`, `ERR_GET_REASON`, `ERR_SYSTEM_ERROR`) mask the bits they use,
  and passing a code back (`ERR_error_string_n`) only uses the low 32 bits.
- `long` arguments: `SSL_SESSION_set_timeout` (seconds), `X509_gmtime_adj` (0 and 10 years =
  315360000), `X509_verify_cert_error_string`, `X509_set_version`: all far below 2^31.
- Macros expanding to `SSL_CTX_ctrl`/`SSL_ctrl` (`SSL_CTX_sess_set_cache_size`,
  `SSL_CTX_set_tmp_dh`, `SSL_set_tlsext_host_name`): small arguments, boolean results.
- `BN_*` (`vio/viosslfactories.c`: `BN_bin2bn`, `BN_free`): opaque pointers only; nothing
  reads `BN_ULONG`s.
Result: no source changes needed. Revisit with the server (more OpenSSL use in `sql/`) and if
TLS tests misbehave.

MariaDB 11.4 cannot be configured without a TLS library (`WITH_SSL` is bundled wolfSSL or
system OpenSSL; even the client tools hash through it). The configure uses VSI SSL3's
headers for now. `probes/ssl3_abi.c` (clang code calling SSL3's 64-bit-pointer images):
SHA-256 via EVP, error codes, `BIO_ctrl` all work, but **SSL3 was built with a 32-bit
`long`**: `SSL_CTX_set_timeout(3000000000)` reads back as -1294967296, and SSL3's headers tell
clang `BN_ULONG` is 8 bytes while `BN_get_word(2^32)` returns 0. Options:
- (a) use SSL3 and audit every `long`-typed OpenSSL call MariaDB makes (values above 2^31,
  structs with `long` members, `BN_*`);
- (b) build OpenSSL 3 with clang ourselves (a vms-openssl sibling), LP64 throughout;
- (c) bundled wolfSSL (built with clang) for the server and mysys_ssl; but Connector/C
  cannot use wolfSSL on non-Windows (it wants GnuTLS or OpenSSL), so the client side would
  still need (a) or (b).

## D10. Coherent file I/O across descriptors: one shared descriptor per file in mysys

**Status:** approved by the user (2026-10-04): option (b).

`probes/r_coherence.c` (x86-64, clang, `DECC$FILE_SHARING`), two descriptors of one file:
- a descriptor that has only *read* a block sees another's write once the writer flushes
  (`fsync`), or at once if the writer has `O_SYNC`/`O_DSYNC`: the CRTL buffers writes;
- a descriptor that has itself *written* a block keeps serving it from its own buffer and
  never sees later writes through other descriptors, in every variant tried (`O_SYNC`,
  `O_DSYNC`, RMS `shr=...upi`, `ctx=bin/xplct/nocvt`, `mbc`, `mbf`, `rop`, `fop=wck`),
  with `pread`/`pwrite` as with `lseek`+`read`/`write`.

None of the 82 `DECC$` features (`docs/crtl-features-x86.txt`) controls this, except
**`DECC$SSIO`** (shared stream I/O, VSI's answer to exactly this problem). On this node it
does not work: on the system disk `open()` succeeds but every read/write fails with
`%SYSTEM-?-...` "system service or exec routine is not loaded"; on DKA300 (converted to
ODS-5 in place) `open()` fails with "unsupported file structure level".

Options:
- (a) **SSIO**: if it can be enabled on E9.2-4 (system component, parameter, later
  update?) and the work volume supports it, the fix is one feature logical in `mariadbd`.
- (b) **One shared CRTL descriptor per file inside mysys**: `my_open` of a file already open
  returns a handle onto the same descriptor (refcounted, keyed by device + file id), so
  all I/O in the server process goes through one buffer. Coherent within `mariadbd`; offline
  tools (`aria_chk`, `myisamchk`) must not run against a live server (already upstream's
  rule without external locking). Medium effort, contained in mysys.
- (c) **mysys file I/O through RMS block I/O or `$QIO`**, bypassing the CRTL: coherent across
  processes, but mysys must then manage EOF/file size and every `my_*` I/O call. Most work.

Implemented (patch 0014 + `mysys/my_vmsfile.c`, tested by `vms/tests/vmsfile_test.c`, 20/20):
mysys file calls on VMS go through `my_vms_*()` beside the Windows `my_win_*()` hooks. One
master descriptor per file (by `st_dev`/`st_ino`) does all data I/O; caller descriptors keep
their own positions and `O_APPEND`. Building it exposed three more C RTL behaviours, all now
handled in the layer:
- `lseek(SEEK_END)` still reports the old size after `ftruncate()` (and `fstat()` lags
  behind writes): the layer keeps each file's size itself.
- A `pread()` past the end of file returns 0 but moves the end of file to that offset when
  the file is closed: reads are clamped at the kept size.
- `ftruncate()` keeps dirty buffered blocks past the new end, and `close()` writes them
  back: the layer flushes before truncating.
- Closing a *writable* channel writes that channel's stale end of file into the file
  header, even after another channel synced: caller descriptors are made read-only
  channels (`dup2`), the master closes last. `fcntl()` record locks are taken on the master
  (patch 0023): a write lock on a read-only channel fails with EBADF, and Aria always locks
  `aria_log_control`. POSIX record locks belong to the process, so this is the same lock.
- `O_TRUNC` on an existing file would create a new version: truncation goes through the
  master instead.

## D11. PCRE2 for the server: a clang build from vms-pcre2

**Status:** approved by the user (2026-10-04): option (a). vms-pcre2 now has a clang (LP64)
build variant (`BUILD ALL "" CLANG`, install tree `[.INSTALL_X86_64_CLANG]`, commit
"Clang (LP64) build variant"); `PCRE2$ROOT` points there (nodes.conf column 8).

The server needs PCRE2 (REGEXP). MariaDB's `WITH_PCRE=bundled` downloads PCRE2 10.47 from
GitHub at build time (MD5 only) and builds it with PCRE2's own CMake, which the generated MMS
build cannot follow. The configuration therefore takes PCRE2 as a system library
(`server.options`, two hand-set answers in `manual.txt`): headers from vms-pcre2 10.49
(host sysroot; `PCRE2$ROOT:[INCLUDE]` on the node), library from `PCRE2$ROOT:[LIB]` (`server.link`).
vms-pcre2's library is built with VSI C (ILP32), so it cannot be linked into clang (LP64)
code (D4); the headers are fine (`size_t` and fixed-width types). Options:
- (a) add a clang (LP64) build of the library to **vms-pcre2** (install tree
  `[.INSTALL_X86_64_CLANG]` or similar): one PCRE2 port for the family, as for zlib and grep;
- (b) compile vms-pcre2's patched 10.49 sources with clang inside this repository's build
  (pinned and verified like the MariaDB tarball): self-contained, but a second copy of the job.

**Chosen (user): (a).** vms-pcre2 builds a clang variant (`BUILD ALL "" CLANG`, install tree
`[.INSTALL_X86_64_CLANG]`); nodes.conf's 8th column points `PCRE2$ROOT` at it. The library
is linked in, so the server kit has no PCRE2 dependency.

## D12. The C RTL's 32-bit `long` interfaces: a forced-include header

clang's `long` is 64-bit but the C RTL's `long`-typed interfaces (printf's `%ld`, `strtol`,
`ftell`, `LONG_MAX`...) are 32-bit. Options: (a) one header, `vms/include/vms_lp64.h`,
force-included by `clang_common.rsp`, mapping those interfaces onto 64-bit equivalents and
wrappers; (b) patch each call site. **Chosen (user): (a)**: object-like macros (a
function-like `snprintf` macro once clashed with a struct member), positional formats left
alone (the C RTL rejects `ll`/`j` in them).

## D13. Packaging: a PCSI kit VMSMARIADB, x86-64, client and server

Following vms-curl: product `ISSINOHO X86VMS VMSMARIADB`, in `[VMSMARIADB]` with
`VMSMARIADB$ROOT`, so it can sit beside VSI's MariaDB kit; version `V11.4-13E<VMS_PATCH_LEVEL>`
(upstream 11.4.13, our patch level as the ECO). x86-64 only (D3: IA64 has no C++11).
One kit holds the clients and `mariadbd`, the error messages, character sets and bootstrap
SQL. The images keep their compiled-in `/usr/local/mysql` paths; the kit's
`VMSMARIADB$SERVER.COM` (INSTALL_DB, START, STOP, STATUS) passes `--basedir`,
`--lc-messages-dir`, `--character-sets-dir` and `--tmpdir` explicitly, so no rebuild was
needed. Rejected for now: a `CMAKE_INSTALL_PREFIX` of `/VMSMARIADB$ROOT` (needs full
rebuilds; better done with the option-file work), a ZIP (no install/remove, no dependency on
SSL3), separate client and server kits (one product is simpler while the server is a preview).
The server runs detached under the starting account's UAF quotas (`RUN/DETACHED/AUTHORIZE`,
PORTING_LOG); no dedicated account or boot-time server start yet. Requires VSI SSL3.


- Disk space (resolved 2026-10-04): the x86-64 work disk was the system disk with ~2 GB free.
  The port now works in `DISK$SYSDUMP:[IAIN.VMS_MARIADB]` (16 GB volume, 7.85 GB free), which
  the user converted to ODS-5 with high-water marking off; IA64 uses
  `USER$ROOT:[IAIN.VMS_MARIADB]` (ODS-5, 25 GB free). Work directories must be ODS-5.
- `time_t` is 32-bit with both compilers (Y2038); note for TIMESTAMP handling.
- Prior-art 5.5-era VMS patches: not looked for yet.
