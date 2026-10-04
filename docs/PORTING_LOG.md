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
