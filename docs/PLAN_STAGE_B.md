# Stage B plan: `mariadbd` with Aria, MyISAM and MEMORY

Follows the plan's Phase 3 with what Phase 0 and Stage A taught us. Status: proposed.

## 0. Settle the two known blockers first (probes, no server code)

Both would cause silent corruption or random failures in a running server, so they come
before any server build work.

1. **Writes through one descriptor are not seen through another** (D6). MyISAM opens a data
   file once per table instance; Aria and the DDL log also reopen files. Probe further:
   more RMS options to `open()` (`shr=upi`, `mbc`/`mbf`, `rop=wbh/rah` off, `ctx=xplct`),
   `DECC$` feature logicals that affect caching, and `read()`/`write()` after `lseek()` as well
   as `pread()`/`pwrite()`. If no CRTL setting works, choose between (a) one shared descriptor
   per file in mysys (`my_open` keeps a refcounted table) and (b) mysys block I/O through
   RMS/`$QIO` directly. Decision D10, with the user.
2. **Stack mutexes** (D5): `PTHREAD_MUTEX_INITIALIZER` on the stack fails, so `std::mutex`
   locals fail. Probe why (address range? alignment? a lazily-initialised field?) and whether
   a cheap global fix exists; otherwise audit `std::mutex`/`std::condition_variable` locals in
   `sql/`, `tpool/`, `storage/` and patch them.

## 1. Server configuration and build

- `overlay/vms/config/server.options`: `WITHOUT_SERVER=OFF`, `PLUGIN_INNOBASE=NO`,
  `WITH_WSREP=OFF`, `WITH_EMBEDDED_SERVER=OFF`, the big engines and most plugins `NO`
  (`PLUGIN_{ROCKSDB,MROONGA,SPIDER,CONNECT,COLUMNSTORE,S3,...}`), `WITH_SSL=system` (SSL3).
- Replay the new checks (`tools/replay.sh x86 server`) until converged.
- `server.targets`: sql, Aria, MyISAM, MyISAMMRG, HEAP, CSV, sequence, perfschema (or off),
  tpool, mysys, ..., `mariadbd`.
- Expected porting work, from Phase 0: the `thread_local` shim (D5; `THR_THD` is the hot
  one), no `pthread_sigmask` (signal thread with `sigprocmask` + `sigwait`), no `getrlimit`,
  no `fork`, `realpath` (ENOSYS), directory `fsync` (no-op), `st_size` via `lseek(SEEK_END)`,
  `std::mutex` locals (step 0.2), and the OpenSSL audit for the server's `long`-typed calls.
- CRTL feature logicals set inside `mariadbd` by a `LIB$INITIALIZE` module
  (`overlay/vms/vms_crtl_init.c`): EFS charset and case, UNIX file name report, no version in
  names, file sharing, remove-open-files, readdir without trailing dots.

## 2. Bring-up order (plan §3)

1. `mariadbd --version`, then `--help --verbose`.
2. Data directory created `/VERSION_LIMIT=1`; system tables bootstrapped with
   `mariadbd --bootstrap` from a DCL procedure (`mariadb-install-db` is a shell script).
3. Start with `--skip-networking`, then TCP on localhost; connect with our own client.
4. DDL, DML, joins, transactions on Aria, `FLUSH`, `SHOW`, `KILL`; clean shutdown and
   restart, repeated.
5. Exit criterion (plan): repeated start/stop, 100+ MB data load, a remote client (Linux)
   connects over TCP, no crash in a 24-hour idle + light-load soak. Tag `stage-b`.

## Sizes and time

The x86-64 work disk has ~7.8 GB free; a server build is a few thousand objects
(estimate 1-2 GB with debug info). Full builds will take hours on the VM: incremental builds
and `KEEP_GOING` rounds as in Stage A.
