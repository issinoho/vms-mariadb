# Phase 0 results

Summary of the plan's Phase 0 (reconnaissance). Raw output:

| File | What |
|---|---|
| `docs/env-x86.txt`, `docs/env-ia64.txt` | `tools/recon.sh`: OS, products, compilers, tools, quotas |
| `docs/probes-x86-clang.txt` | `tools/probe.sh x86 CLANG`: all sets (its G_ set is invalid, see below) |
| `docs/probes-x86-clang-GR.txt` | G_ and runtime sets again, after fixing the G_ header list and `r_proc.c` |
| `docs/probes-x86-cc.txt`, `docs/probes-ia64-cc.txt` | the same with VSI C (comparison; not the build compiler) |

Decisions drawn from these are in [DECISIONS.md](DECISIONS.md).

## Nodes

| | x86-64 | IA64 |
|---|---|---|
| OS | OpenVMS E9.2-4 (KVM guest, 2 CPUs, 7.6 GB) | OpenVMS V8.4-2L3 (rx2660, 1 CPU, 4.3 GB) |
| C++ | VSI C++ V10.1-3U1 = **clang 10.0.1**, libc++ 10 | VSI C++ V7.4-006 (EDG, pre-C++11) |
| C | VSI C V7.7-003 (GEM) | VSI C V7.4-001 |
| Build tools | MMS V4.0-5; GNV make; **no CMake** | MMS V4.0-5, MMK; **no CMake** |
| Other | Perl 5.42 and 5.34, Python 3.10, Git 2.44 (none on the default command path) | Perl 5.34, Python 3.10, Git 2.44 |
| OpenSSL | SSL3 V3.0-21 (and SSL31) | SSL3 V3.0-22 (and SSL31, SSL111, SSL1) |
| Work dir | `DISK$SYSDUMP:[IAIN.VMS_MARIADB]` (ODS-5, 7.85 GB free) | `USER$ROOT:[IAIN.VMS_MARIADB]` (ODS-5, 25 GB free) |

## Compilers and language (x86-64)

| Question | Answer |
|---|---|
| Type sizes, clang (C and C++) | `void*` 8, `long` 8, `size_t` 8, `off_t` 8, **`time_t` 4** |
| Type sizes, VSI C | `void*` 4, `long` 4, `size_t` 4, `off_t` 8, `time_t` 4 |
| C++11 / C++14 (`CXX/STANDARD=GNU11`, `GNU14`) | yes: `<thread>`, `<atomic>` (64-bit lock-free, CAS), `<mutex>`, `<condition_variable>` `wait_for`, `<chrono>`, lambdas, `unique_ptr`, `unordered_map` |
| `thread_local` / `__thread` / `_Thread_local` | **no**, compile error, also with `-femulated-tls` |
| `std::shared_timed_mutex` / `std::shared_mutex` | compiles, **aborts** at run time ("mutex lock failed: invalid argument") |
| C++17 (`clang -std=c++17`) | `optional`, `string_view`, structured bindings, `if constexpr`, inline variables, `<charconv>` integers: yes. `<variant>` breaks if a STARLET header (`#define __union union`) came first |
| C with clang | C11 (`__STDC_VERSION__` 201112), `__atomic_*` and `__sync_*` builtins (8-byte always lock-free); **no `<stdatomic.h>`** |
| C with VSI C | C99; no `__atomic`/`__sync` builtins |
| libc++ `operator new` | warns "32-bit allocator has no aligned allocation"; `malloc` itself returns 64-bit addresses (below) |

## CRTL: headers (clang, x86-64)

Present: `alloca.h arpa/inet.h dirent.h dlfcn.h fcntl.h float.h grp.h inttypes.h langinfo.h
limits.h locale.h malloc.h memory.h netinet/in.h poll.h pwd.h sched.h stdarg.h stddef.h
stdint.h stdlib.h string.h strings.h sys/file.h sys/ioctl.h sys/mman.h sys/param.h sys/poll.h
sys/resource.h sys/socket.h sys/statvfs.h sys/stat.h sys/time.h sys/times.h sys/types.h
sys/utime.h sys/utsname.h sys/wait.h termios.h time.h unistd.h utime.h wchar.h wctype.h`.

Absent: `execinfo.h fenv.h fnmatch.h link.h paths.h select.h sys/select.h termio.h termcap.h
crypt.h sys/prctl.h sys/syscall.h valgrind/memcheck.h` and the other platform-specific ones.

**Not trustworthy:** `linux/mman.h`, `linux/unistd.h` and `netinet/in6.h` "exist" because the
CRTL header library ignores the directory part. `varargs.h` exists but `#error`s under clang.
`config.h` answers for these must be set by hand.

## CRTL: functions (clang, declared by a header and linking)

Present: `access alarm aligned_alloc clock_gettime crypt cuserid dlerror dlopen dlsym dup2
execv fchmod fcntl fseeko fstatvfs fsync ftime ftruncate getaddrinfo getcwd gethostname
getnameinfo getpagesize getpid getppid getpwnam getpwuid getrusage gettimeofday gmtime_r
index inet_ntop inet_pton kill ldiv localtime_r lstat memcpy memmove mkostemp mkstemp mmap
mprotect nanosleep nl_langinfo pclose perror pipe poll popen posix_memalign pread
pthread_attr_{get,set}guardsize pthread_attr_{get,set}stacksize pthread_attr_setscope
pthread_key_delete pthread_rwlock_rdlock pthread_setname_np pthread_yield_np putenv pwrite
raise readlink readv realpath* recvmsg rename sched_yield sendmsg setenv setitimer setlocale
sigaction sigprocmask sigwait sigwaitinfo sleep socketpair statvfs stpcpy strcasecmp strcoll
strdup strerror strndup strnlen strpbrk strtok_r strtoll strtoul strtoull sysconf time times
uname vasprintf vsnprintf writev _malloc64`.

\* `realpath` links but returns **ENOSYS** at run time: answer "no" in `config.h`.

Absent: `accept4 backtrace* clock_nanosleep dladdr epoll_create fdatasync fesetround flock
fork vfork posix_spawn getifaddrs getline getrlimit (no RLIMIT_*) initgroups lockf madvise
posix_madvise mallinfo memalign mkdtemp mlock mlockall mmap64 mremap posix_fallocate ppoll
pthread_condattr_setclock pthread_getaffinity_np pthread_getattr_np pthread_mutex_timedlock
pthread_rwlock_timedrdlock pthread_sigmask sched_getcpu sigaltstack strsignal timer_create`.

CMake's `CHECK_FUNCTION_EXISTS` form (no header) fails under clang for ordinary functions
(`strdup`, `strerror`, `strtoull`, `vsnprintf`, `stpcpy`, ...), because the `DECC$` mapping is
done by the headers. Only header-based answers are usable (D1).

## Run time (identical on x86-64/clang and IA64/VSI C unless noted)

**Files** (`r_io.c`, `r_io2.c`; "logicals" = `DECC$EFS_CHARSET`, `EFS_CASE_PRESERVE`,
`FILENAME_UNIX_REPORT`, `FILENAME_UNIX_NO_VERSION`, `READDIR_DROPDOTNOTYPE`, `FILE_SHARING`,
`ALLOW_REMOVE_OPEN_FILES`, `POSIX_SEEK_STREAM_FILE`, `RENAME_NO_INHERIT`):

| Behaviour | Defaults | With logicals |
|---|---|---|
| `pwrite`/`pread` at offsets, holes read as zeros, `ftruncate` grow/shrink, `O_APPEND`, `fsync`, `fcntl(F_SETLK)` | yes | yes |
| `O_DIRECT` / `O_DSYNC` / `O_SYNC` / `O_CLOEXEC` | no / yes / yes / yes | same |
| `fstat().st_size` after `pwrite` on an open file | **0 until `fsync` or `close`**; `lseek(SEEK_END)` is right | same |
| Second `O_RDWR` open of the same file | fails: "file currently locked by another user" | works |
| Write through one descriptor seen by another | n/a | **no**, not even after `fsync`, either direction |
| `unlink` of an open file | fails | works |
| `open(O_TRUNC)` / `rename` onto an existing name | **new version; old one stays** | same; none left in a `/VERSION_LIMIT=1` directory |
| Names `#sql-1a2b_3.frm`, `t@002d1.frm`, `x#P#p0.ibd`, `a.b.c.d`, `sp ace.frm`, `Db.Two/` | fail (ENOENT) | work |
| `readdir` | lower-cased, `ibdata1.` (trailing dot) | exact names and case |
| `getcwd` | VMS syntax | `/DISK$SYSDUMP/IAIN/VMS_MARIADB/...` |
| `realpath` | ENOSYS | ENOSYS |
| `open()` of a directory | fails | fails |
| RMS options to `open()` | `ctx=stm`, `shr=...` change nothing above; `rfm=udf`/`rfm=fix` fail with the logicals | |

**Network** (`r_net.c`): SO_REUSEADDR, bind to 127.0.0.1:0, non-blocking accept
(EWOULDBLOCK) and connect (EINPROGRESS), `poll` on listening/connecting sockets, TCP_NODELAY,
SO_KEEPALIVE, SO_RCVTIMEO, MSG_DONTWAIT, EOF on peer close, `getaddrinfo` (normal and
passive), AF_INET6 with IPV6_V6ONLY=0, `socketpair`: all **yes**. AF_UNIX `bind` to a
relative path: **no** ("no logical name match").

**Process and memory** (`r_proc.c`, x86-64 clang): `_SC_PAGESIZE` 8192,
`_SC_NPROCESSORS_ONLN` 2, 1 MB thread stacks, pthread keys, ERRORCHECK mutexes,
`pthread_cond_timedwait` timeout, `CLOCK_MONOTONIC`, `sigaction` + `raise`, `sigprocmask`:
yes. No `PTHREAD_ADAPTIVE_MUTEX_INITIALIZER_NP`, no `getrlimit`. Anonymous `mmap` of 64 MB
works (address 0x80006000). **`malloc` of 16 × 256 MB succeeds with addresses above 4 GB**
(highest 0x1_9200_6010): clang code gets a 64-bit heap.

## What this means for Stage A (client)

- Toolchain: clang for all C and C++ (D4), `DECC$ARGV_PARSE_STYLE` + extended parse style,
  `define sys$error sys$output` in build procedures.
- Configuration: generate `config.h` from MariaDB's `config.h.cmake` with the answers above;
  hand-set the untrustworthy headers and `realpath`.
- Expected source changes for the client: TLS shim for `libmariadb/plugins/auth/ed25519.c`
  and `parsec.c` (or build without those plugins first), `pthread_sigmask` →
  `sigprocmask` where used, `my_realpath` without `realpath`, `getrlimit` absent.
- Bundled zlib and PCRE2, compiled with clang. TLS (VSI SSL3) is a separate pass.

## Open before Stage B (server)

- Descriptor coherence (DECISIONS D6): needs a CRTL setting, a shared-descriptor design in
  mysys, or RMS/QIO block I/O. Probe further before writing server code.
- `st_size` staleness: mysys must size files with `lseek(SEEK_END)`.
- Directory `fsync`: no-op on VMS.
- Signal handling without `pthread_sigmask` (`sigprocmask` + `sigwait`, verify per-thread
  semantics).
- `time_t` is 32-bit.
