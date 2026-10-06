# CLAUDE.md

MariaDB for OpenVMS, built natively with VSI's clang-based C++ toolchain and wrapped by the
same tooling as `~/projects/vms-grep`, `vms-curl`, `vms-zlib` and the other sibling ports.
Read vms-grep's `CLAUDE.md` for the ground rules and the VMS/ssh pitfalls; they all apply.
Read `MARIADB_OPENVMS_PLAN.md` (the original plan) and `docs/DECISIONS.md` (where we departed
from it, and why) before starting work. Work phase by phase; stop and ask at each phase exit.

## Ground rules (from the sibling ports)

- **Never edit `staging/`, `cache/` or `out/`.** Every build starts from the signed release
  tarball pinned in `upstream.conf` (key in `keys/`). Upstream files change only through
  `patches/` (listed in `patches/series`); our own files live in `overlay/`, which may only
  add files.
- **Keep VMS changes minimal and upstreamable:** guard with `#ifdef __VMS`, one fix per patch,
  each with a `Subject:` line and the VMS reason.
- **Use `tools/vms.sh`** for remote work; never raw `ssh host cmd`, never `WAIT` over ssh.
  Run long jobs (probes, builds) with `run_in_background`.
- **Committed files must not contain real node details** (they live in the git-ignored
  `tools/nodes.conf`), nor credentials. Use `<ia64-host>`, `<x86-host>`.
- **Nothing destructive or system-wide on the nodes** without asking: no DELETE/PURGE outside
  our work directories, no installs, no system logical names. CRTL feature logicals are set
  per process (`DEFINE/PROCESS`) or in the image via `LIB$INITIALIZE`.
- Every build failure gets one entry in `docs/PORTING_LOG.md` (command, error, triage code from
  the plan's §5, root cause, fix, patch). Every decision goes in `docs/DECISIONS.md` with the
  alternatives considered.
- Prefer a 20-line probe in `probes/` over speculation. Do not claim something works until a
  test on the node shows it.

## Platform facts that shape the port (details in docs/DECISIONS.md)

- **x86-64 only for the server.** IA64's VSI C++ 7.4 is pre-C++11.
- **Compile all of MariaDB with clang (`CXX` / `SYS$SYSTEM:CLANG.EXE`) on x86-64:** it is LP64
  (`long` and pointers 64-bit). VSI C on x86-64 is ILP32 (`long` 4, pointers 32), so objects
  from the two compilers do not share an ABI for any type containing `long` or a pointer.
  Our vms-zlib/vms-pcre2 trees (VSI C) therefore cannot be linked into clang code as is.
- **No `thread_local`/`__thread`** in VSI C++ 10.1 ("OpenVMS does not currently support
  thread_local"); MariaDB 11.4 uses it in ~11 places that need a pthread-key shim.
- **`time_t` is 32-bit** with both compilers.
- C diagnostics go to SYS$ERROR: `define sys$error sys$output` in procedures run by vms.sh.

## Commands

```sh
tools/sysroot.sh x86                  # once: VSI SSL3 headers -> cache/vms-sysroot (host CMake needs them)
tools/prepare.sh                      # fetch+verify, extract, patches, overlay, host CMake, vmsgen/, MMS
tools/replay.sh x86 client            # answer new CMake checks on the node; then prepare.sh again,
                                      #   until replay_gen.py reports 0 checks (REPLAY_ALL=1 redoes all)
tools/build.sh x86 client [target] [KEEP_GOING]   # push + @[.VMS]BUILD CLIENT on the node
tools/kit.sh [x86]                    # PCSI kit (both configs built first) -> out/kits/
tools/installcheck.sh [x86]           # install kit, run a server from it, remove (changes system; ask first)
tools/loadcycle.sh x86 [rows] [cycles]   # Stage B load + stop/start test (server on 3307)
tools/recon.sh <node>; tools/probe.sh <node> [CLANG|CC]   # Phase 0 environment and probes
tools/vms.sh <node> dcl '<cmd>' ...   # run DCL; also run/batch/put/get
```

- `overlay/vms/config/<config>.options` (CMake options) and `<config>.targets` (what to build)
  define a configuration; `clang_common.rsp` holds our clang flags.
- `overlay/vms/config/answers.txt` and `overlay/cmake/os/OpenVMSCache.cmake` are generated
  (replay_answers.py); hand-set answers go in `manual.txt`, each with a reason.
- After changing a check's inputs (clang flags, headers), replay everything: `REPLAY_ALL=1`
  with `VMS_NO_ANSWERS=1 tools/host_configure.sh <config>` first (see tools/replay.sh).

## Pitfalls found in this port

- **Wait on fresh output files only**: delete (or rename) a job's output file before
  starting it. A wait loop on `grep -q '^exit' x.out` returned at once on the previous
  run's file, and its stale result looked like a new failure.
- **A `vms.sh` timeout does not stop the job on VMS**: it keeps running. Give long jobs a
  big `VMS_TIMEOUT`, and check `show system` before re-running a test that timed out.
  Leftover `FTA*_IAIN` sessions of ours can pile up and once stopped the SSH server
  answering; check `show system/process=*IAIN*` and stop only the ones this work started.
- **ODS-5 has no sparse files**: seeking past the end and writing (or `fseek` on a stdio
  stream) allocates and zero-fills real blocks. A test that seeked to 5 GB nearly filled
  the work disk. Never probe large offsets on a new file.
- **MMS tracks neither headers nor compile flags.** After a patch touches a header, or after
  changing `clang_common.rsp`, run `tools/build.sh x86 client CLEAN` before `ALL` (a header
  change once left the old objects in place and the test still failed).

- VSI's clang does not define `__GNUC__`; `clang_common.rsp` does (D4, PORTING_LOG).
- clang finds a response file only by a plain name or an absolute UNIX path; `build.com`
  passes the tree's path to MMS as `ROOT`.
- The CRTL header library ignores directories: `<linux/mman.h>` "exists". Never trust a header
  check with a directory in it; see `manual.txt`.
- Waiting on background jobs: never `until ! pgrep -f '<pattern>'`; the waiting shell's own
  command line contains the pattern, so it never ends (and `pkill -f` kills itself). Wait on
  a marker in the job's output file, or on the job's completion notice.
- CMake ships `Platform/OpenVMS.cmake` itself; it sets no `VMS` variable, so
  `cmake/os/OpenVMS.cmake` does.

## Commits

Commit in logical steps with messages that explain the VMS reason for each change. Don't push
without the user asking.
