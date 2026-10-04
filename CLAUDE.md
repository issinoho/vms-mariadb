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
tools/recon.sh <node>                 # Phase 0 environment capture -> docs/env-<node>.txt
tools/probe.sh <node> [CLANG|CC]      # Phase 0 probes -> docs/probes-<node>-<cc>.txt
tools/vms.sh <node> dcl '<cmd>' ...   # run DCL; also run/batch/put/get
```

## Commits

Commit in logical steps with messages that explain the VMS reason for each change. Don't push
without the user asking.
