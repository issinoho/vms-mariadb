# MariaDB → OpenVMS x86-64 Port: Working Plan

Status: draft v1. Written to be dropped into a repo and driven by Claude Code.
Items marked **[VERIFY]** are assumptions that have not been confirmed and must be checked in Phase 0.

---

## 1. Goal and scope

**Goal:** a native OpenVMS x86-64 build of MariaDB **10.6 LTS**, reached in stages so each stage is independently useful.

| Stage | Deliverable | Value on its own |
|---|---|---|
| A | Client library + `mariadb` CLI client (`-DWITHOUT_SERVER=ON`) | Native clients talking to a Linux MariaDB server |
| B | `mysqld` with Aria/MyISAM/Heap only, no InnoDB | A working (if limited) native server |
| C | InnoDB enabled and durability-tested | Production-grade engine |
| D | Packaging (PCSI or ZIP), docs, upstream patches | Others can install it |

**Non-goals (for now):** Alpha/Itanium targets, Galera/WSREP, ColumnStore, RocksDB, Spider, Mroonga, CONNECT, embedded server, 11.x/12.x branches.

**Why 10.6:** it is an LTS branch whose build files target C++11 (I confirmed this for 10.5; **[VERIFY]** for 10.6). VSI C++ on x86-64 is Clang-based and documents C++14 support, so the language level should not be the blocker. Newer branches may require C++17, which VSI's bundled libc++ (10.0.1 on x86-64) may not fully cover. **[VERIFY]** before ever considering 11.x.

---

## 2. Known facts and open questions

**Believed true (from VSI docs and public notes):**
- VSI C++ for x86-64 is based on LLVM Clang with OpenVMS extensions. It documents C++14 support, with `/STANDARD=` keywords up to `CXX14`/`GNU14`.
- Clang is available as a UNIX-style command (set up via `SYS$EXAMPLES:CXX$SETUP.COM`), plus the `CXX` DCL front end.
- The compiler defines `__VSIC_VER`/`__VSICXX_VER` rather than `__DECC_VER`/`__DECCXX_VER`. Use `__cplusplus` and `__STDC_VERSION__` for standard levels.
- The x86-64 C++ standard library is LLVM libc++ 10.0.1.
- Earlier MariaDB ports stopped at 5.5. A prior writeup says later versions were blocked by missing C11/C++11 on the older compilers. That reasoning predates the Clang-based x86-64 toolchain.

**Unknown, answer in Phase 0:**
1. Is there a working OpenVMS x86-64 system to build on (V9.2-x, hobbyist licence is fine)? Physical, VM, or emulated?
2. Can Claude Code reach it over SSH? **[VERIFY]**
3. Is CMake available on VMS, and which version? **[VERIFY]**
4. What `make` is available (GNU make via GNV or similar, or only MMS/MMK)? **[VERIFY]**
5. Is the VSI **C** compiler (not just C++) Clang-based on x86-64 and does it accept `-std=gnu11`? **[VERIFY]**
6. Are zlib, OpenSSL, and PCRE2 installed, and which versions? **[VERIFY]**
7. Are prior-art sources available (Berryman or VSI MariaDB 5.5 ports, `vmsmysql.org` patches) for reference on VMS-specific fixes? **[VERIFY]**

---

## 3. Working agreement for Claude Code

Paste this section into `CLAUDE.md`.

```
## Project: MariaDB on OpenVMS x86-64

Read MARIADB_OPENVMS_PLAN.md first. Work phase by phase; do not skip ahead.

Rules:
- Keep VMS-specific changes minimal, isolated, and upstreamable. Guard with
  `#ifdef __VMS` (or a CMake `VMS` check) and put new files under `vms/`.
- Never run destructive commands on the VMS host (no DELETE/PURGE on paths
  outside the build tree, no system-wide installs, no logical-name changes to
  SYSTEM tables) without asking me first.
- Every build failure gets one entry in PORTING_LOG.md: command, error, root
  cause, fix, commit hash. One fix per commit.
- Record every decision in DECISIONS.md with the alternatives considered.
- When something is unverified, say so. Do not claim a feature works until a
  test on the VMS host shows it.
- Prefer small experiments (a 20-line C test program) over speculation when
  checking a libc or filesystem behaviour.
- Stop and ask at each phase exit criterion.
```

**Suggested layout**

```
repo/
  MARIADB_OPENVMS_PLAN.md
  CLAUDE.md
  PORTING_LOG.md
  DECISIONS.md
  server/              # fork of MariaDB/server, branch: 10.6-vms
  vms/
    scripts/           # DCL + shell helpers (sync, build, test)
    probes/            # tiny C/C++ programs used to test platform behaviour
    cmake/             # toolchain/cache files
    notes/
```

**Remote workflow (default):** edit on the Linux/macOS host, sync to VMS, build over SSH, pull logs back.

```
vms/scripts/sync.sh      # rsync (or scp) the source tree to the VMS host
vms/scripts/build.sh     # ssh to VMS, run the build, tee output to a local log
vms/scripts/fetch-log.sh # copy logs back for analysis
```

Whether `rsync` exists on VMS **[VERIFY]**; fall back to `git pull` on the VMS side or `scp`.

---

## 4. Phases

### Phase 0: Reconnaissance (no MariaDB code yet)

**Run on the VMS host and capture to `vms/notes/env.txt`:**

```
$ show system/noprocess
$ write sys$output f$getsyi("version")
$ show logical sys$sysdevice
$ product show product
$ cxx/version
$ cc/version
$ type sys$help:cxx.changelog
$ show symbol clang          ! after running SYS$EXAMPLES:CXX$SETUP.COM
$ clang --version
$ cmake --version
$ git --version
$ perl -v
$ python --version
$ gmake --version            ! or make, mmk, mms
$ bash --version             ! GNV
$ show logical decc$*
```

**Write and run probes in `vms/probes/`** (each a small standalone C or C++ program) to answer, empirically:
- Does `-std=gnu++14` build a C++11 program using `<thread>`, `<atomic>`, `<mutex>`, `<condition_variable>`?
- Does `-std=gnu11` build a C11 program using `<stdatomic.h>`?
- `pthread` behaviour: mutex, condvar, `pthread_setname_np` absence, thread-local storage.
- File I/O: `pread`/`pwrite`, `fsync`/`fdatasync`, `ftruncate`, `O_DIRECT` presence, `fcntl` locks, `flock`, sparse file behaviour, behaviour on files >2 GB.
- Filenames: case preservation and special characters on ODS-5, UNIX-style path reporting (see CRTL feature logicals below).
- Sockets: `poll` vs `select`, `epoll` absence, non-blocking accept, `SO_REUSEADDR`.
- Signals, `fork` absence, `vfork`/`exec` and `posix_spawn` availability.
- `getrlimit`, `sysconf(_SC_PAGESIZE)`, `mmap` support.

**CRTL feature logicals worth knowing about** (set in the build process or job table, not system-wide): `DECC$FILENAME_UNIX_REPORT`, `DECC$FILENAME_UNIX_ONLY`, `DECC$EFS_CASE_PRESERVE`, `DECC$EFS_CHARSET`, `DECC$ARGV_PARSE_STYLE`, `DECC$POSIX_COMPLIANT_PATHNAMES`. Confirm exact names and semantics in the VSI C RTL manual before relying on them.

**Decision point D1: how to run CMake**
- **Option A:** native CMake on VMS (preferred if one exists and works).
- **Option B:** "cross-configure". Run CMake on Linux with a custom toolchain/cache file to generate `config.h` and build files, hand-correct the platform probes using results from `vms/probes/`, and drive the build with GNU make or MMS on VMS. More manual work, fewer unknowns.
- **Option C:** build CMake from source on VMS. High effort, treat as a fallback.

**Exit criteria:** `env.txt` complete, probes run, answers to the open questions in §2 recorded in `DECISIONS.md`, decision D1 made.

---

### Phase 1: Source and tooling setup

1. Fork `MariaDB/server`, branch from the 10.6 release branch, create `10.6-vms`. Pin a specific release tag as the base so rebases are tractable.
2. Initialise submodules (libmariadb, wsrep-lib, etc.). Note which can be disabled.
3. On a **Linux** host, do a normal 10.6 build with `-DWITHOUT_SERVER=ON` to produce a reference: the cmake cache, `config.h`, and a list of every probe result. This is your baseline for Option B and for diffing against what VMS produces.
4. Build the sync/build/fetch scripts and prove the round trip with a trivial program.
5. Collect prior art (5.5-era VMS patches) into `vms/notes/prior-art/` for reference only. Check licences before copying anything.

**Exit criteria:** repo builds on Linux, sync/build loop works to the VMS host, reference config captured.

---

### Phase 2 (Stage A): Client-only build

**Target:** `libmariadb` + `mariadb` CLI, no server.

**Suggested CMake options** (names must be verified against the 10.6 tree before use):

```
-DWITHOUT_SERVER=ON
-DWITH_UNIT_TESTS=OFF
-DWITH_SSL=OFF          # first pass; enable system/bundled SSL in a later pass
-DWITH_ZLIB=bundled     # or system if present and recent enough
-DWITH_PCRE=bundled
-DCMAKE_C_FLAGS="-std=gnu11"
-DCMAKE_CXX_FLAGS="-std=gnu++14"
```

**Work loop:**
1. Configure. Triage each failure into one of the categories in §5.
2. Fix the root cause in a `vms/` toolchain/cache file if possible, in source with `#ifdef __VMS` only if necessary.
3. Rebuild. Log every fix.
4. Once it links, run the client against a **MariaDB server on a Linux host**: connect, `SELECT VERSION()`, create/insert/select, large result set, large insert, a failed login, a dropped connection.
5. Second pass: enable SSL, test TLS connect.

**Exit criteria:** native `mariadb` client runs interactive and batch sessions against a remote server, including TLS. Tag `stage-a`.

---

### Phase 3 (Stage B): Server, no InnoDB

**Target:** `mysqld` running with Aria, MyISAM, and Heap (MEMORY).

**Suggested additional options** (verify names):

```
-DWITHOUT_SERVER=OFF
-DPLUGIN_INNOBASE=NO
-DPLUGIN_ROCKSDB=NO
-DPLUGIN_TOKUDB=NO
-DPLUGIN_MROONGA=NO
-DPLUGIN_SPIDER=NO
-DPLUGIN_CONNECT=NO
-DWITH_WSREP=OFF
-DWITH_EMBEDDED_SERVER=OFF
```

Make sure `io_uring`, `libaio`, and NUMA probes resolve to "not found" and the code falls back to portable paths. Confirm in the cache.

**Expected trouble spots** (investigate with probes first, then fix):
- **Threading:** thread creation, thread-local storage, thread names/priorities, condvar timeouts.
- **Networking:** event loop. MariaDB's `poll`/`select` fallback must work. The Linux `epoll` path must be disabled.
- **File layer:** `my_*` wrappers (`my_open`, `my_pread`, `my_sync`, `my_lock`, `my_realpath`). Most porting fixes will land in `mysys/`.
- **Datadir layout:** handling of `.` in filenames, case rules, path separators, and file versioning (the `;n` suffix). A UNIX-style path mode and a careful datadir location help a lot.
- **Signals and shutdown:** SIGTERM handling, clean shutdown path.
- **Startup:** `mariadb-install-db` is a shell script. Use the `--bootstrap` mechanism directly from a DCL wrapper or GNV bash.
- **Process model:** `mysqld_safe` assumes `fork`. Replace with a DCL procedure plus a detached process.

**Bring-up order:**
1. Build `mysqld` and link.
2. Run `mysqld --version`, then `--help --verbose`.
3. Bootstrap the system tables into a fresh datadir.
4. Start with `--skip-networking` and connect using the native client over the socket/pipe path available, or enable TCP on localhost.
5. Run basic SQL: DDL, DML, joins, transactions on Aria, `FLUSH`, `SHOW`, `KILL`.
6. Clean shutdown and restart, repeated.

**Exit criteria:** repeated start/stop cycles, 100+ MB data load, remote client connects over TCP, no crashes in a 24 h idle+light-load soak. Tag `stage-b`.

---

### Phase 4: Test suite

- Use MariaDB Test Run (`mysql-test-run.pl`). Perl exists on VMS **[VERIFY version]**, but MTR makes heavy use of `fork`, process control, and UNIX paths. Expect to either adapt it or write a thin harness.
- Start with a small subset: `main` suite basics (select, insert, update, delete, join, alter), Aria and MyISAM engine tests.
- Maintain a **known-failures list** with root causes. Do not delete failing tests; classify them as port bugs, test-harness issues, or unsupported features.
- Add a separate **durability test set** (see Phase 5) because MTR does not cover power-loss semantics.

**Exit criteria:** documented pass rate on the chosen subset and a known-failures file.

---

### Phase 5 (Stage C): InnoDB and durability

InnoDB is the highest-risk piece because it makes strong assumptions about I/O.

1. Enumerate every I/O primitive InnoDB uses (`pread`/`pwrite`, `fsync`/`fdatasync`, `O_DIRECT`/`O_DSYNC`, sparse file extension, file size/truncate semantics, `posix_fallocate`, AIO paths). Check each against probe results.
2. Decide on a durability strategy for each unsupported primitive and **record it in `DECISIONS.md`**. Prefer the safe-but-slower option first (for example, `fsync` after every write, no direct I/O) and optimise later.
3. Build with InnoDB, run with `innodb_flush_method` set to the safest option the platform supports.
4. **Crash-recovery testing:** kill the process hard mid-write (`STOP/ID` or the VMS equivalent) many times under load, then verify recovery and run `CHECK TABLE`/checksum comparisons.
5. If possible, test with the VM hard-reset to approximate power loss, and compare data before and after.
6. Run with doublewrite on and checksums on; any checksum failure is a stop-ship bug.

**Exit criteria:** 100+ crash/recover cycles with zero corruption, documented I/O assumptions. Tag `stage-c`.

---

### Phase 6 (Stage D): Packaging and upstreaming

- Produce a PCSI kit or ZIP with a DCL startup/shutdown procedure and a sample `my.cnf`.
- Write an install guide including required CRTL feature logicals and a recommended datadir layout.
- Split the changes into small, reviewable patches. Open a discussion with the MariaDB project (the Jira/mailing lists) before sending large patches. Many core fixes (portability cleanups, `#ifdef` removal, probe fixes) have value upstream.
- Decide on licence-compliant redistribution (MariaDB server is GPLv2; client libs are LGPL).

---

## 5. Error triage categories

Classify every failure so patterns emerge:

| Code | Meaning | Typical fix location |
|---|---|---|
| T | Toolchain/flag issue | `vms/cmake`, compiler flags |
| P | Probe false negative/positive | toolchain/cache file, hand-set |
| H | Missing/different header | shim header under `vms/include/` |
| L | libc function missing or different | wrapper in `mysys/` or `vms/` shim |
| F | Filesystem/semantics (ODS-5, paths, locking) | `mysys/`, config logicals |
| N | Networking/event loop | `sql/`, `vio/` |
| X | Threading/atomics | `include/`, `mysys/` |
| S | Shell/process-model assumption | DCL wrappers, scripts |
| D | Dependency (OpenSSL, zlib, PCRE2) | dependency build/config |
| U | Upstream bug exposed by new platform | candidate for upstream patch |

---

## 6. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| CMake unusable on VMS | Blocks all phases | Decision D1 Option B (cross-configure); build files generated off-box |
| Silent data-corruption bugs in I/O layer | Severe | Safe-first durability defaults, crash-test harness, checksums on |
| libc++ 10.0.1 too old for later branches | Limits upgrades | Stay on 10.6 until verified; plan for newer libc++ or backports |
| Prior-art licences or access | Delays reference | Treat as reference only; check licences |
| Single-person bus factor | Project stalls | Keep `PORTING_LOG.md` and `DECISIONS.md` current, upstream early |
| Hobbyist licence limits | Environment loss | Back up VM images; document env setup |

---

## 7. First session checklist for Claude Code

1. Create the repo layout from §3.
2. Ask me the open questions in §2 (host access, SSH, existing tools) before running anything on the VMS box.
3. Write `vms/scripts/sync.sh`, `build.sh`, `fetch-log.sh` and test with a hello-world C and C++ program.
4. Run the Phase 0 reconnaissance commands and write `vms/notes/env.txt`.
5. Write the Phase 0 probes, run them, and summarise results in `DECISIONS.md`.
6. Propose decision D1 with evidence. Stop and wait for approval before Phase 1.
