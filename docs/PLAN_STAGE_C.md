# Stage C plan: InnoDB

Follows the plan's Phase 5 with what Stages A and B taught us. Status: proposed (2026-10-10).

## What InnoDB needs from the platform (survey of 11.4.13)

InnoDB does **not** use mysys for its files. `storage/innobase/os/os0file.cc` calls `open()`,
`pread()`/`pwrite()`, `fsync()`, `ftruncate()`, `lseek(SEEK_END)` and `fcntl(F_SETLK)`
directly, so none of D10's work (`my_vmsfile.c`: one master descriptor per file, kept file
size, flush before truncate, read clamping) protects it. Every C RTL quirk D10 found applies
again:

| Primitive | InnoDB use | VMS today | Plan |
|---|---|---|---|
| `open()` | `os_file_create_func`, `..._simple_*`; read-only opens during tablespace discovery while a read-write one may exist | each descriptor buffers on its own (D10) | route through `my_vms_open()` (C1) |
| `pread`/`pwrite` | all page and redo I/O (16 KB pages, 512 B-aligned log blocks) | ~0.7-0.9 ms per call, 2-4 QIOs (PLAN_IO) | correctness first via the layer; Tier 3 block I/O later (C6) |
| `lseek(SEEK_END)` | `os_file_get_size` | wrong after `ftruncate()` | the layer's kept size |
| `ftruncate()` | undo truncation, tablespace shrink, `os_file_truncate` | keeps dirty blocks past the new end | the layer flushes first |
| `pread` past EOF | possible in recovery / discovery | moves EOF at close | the layer clamps |
| `fsync()` | flush of data files and redo | exists; **what it guarantees on VMS is unverified** | probe (C0) |
| `fdatasync()` | preferred when present | missing (`HAVE_FDATASYNC` no) | upstream falls back to `fsync` |
| `O_DIRECT` | default `innodb_flush_method` | missing | upstream falls back to buffered + `fsync` |
| `O_DSYNC` | `innodb_flush_method=O_DSYNC`, write-through log | exists | test as an option, not default |
| `posix_fallocate`/`fallocate` | file extension | missing | upstream writes zeros (ODS-5 allocates real blocks anyway) |
| punch hole | `page_compressed` | `HAVE_FALLOC_PUNCH_HOLE...` no | page compression stays off/unsupported |
| `fcntl(F_SETLK)` | `os_file_lock` on ibdata/redo | works on a read-write descriptor; EBADF on the layer's read-only caller channels | lock on the master, as patch 0023 does for mysys |
| `O_TRUNC`, `rename()` onto a name | log resize, `OS_FILE_OVERWRITE` | new file version | VERSION_LIMIT=1 datadir (D6); check every `mkdir()` InnoDB does itself (`os_file_create_directory` calls `mkdir` directly, not `my_mkdir`) |
| `my_mmap` of `ib_logfile0` | `innodb_log_file_mmap` | C RTL file mapping unprobed | force off on VMS |
| `my_virtual_mem_reserve/commit` | buffer pool (`mmap` `MAP_NORESERVE`, then `MAP_FIXED` over it, `mprotect`) | anonymous `mmap` works (PHASE0); the rest unprobed | probe (C0); fallback: commit everything at reserve |
| AIO | `srv_use_native_aio` (libaio/io_uring) | none | tpool's simulated AIO (threads doing `pread`/`pwrite`) |

Non-I/O items found in the source:

- `thread_local` in `log/log0sync.cc` (group commit waiter): already listed in D5; one patch
  using `vms_tls<T>` as patches 0018/0019 do.
- `<cpuid.h>` in `sync/srw_lock.cc` (lock elision via Intel RTM) and `sync/cache.cc` (PMEM
  cache-line flush): VSI C++ ships no intrinsic headers (patch 0008). Lock elision off on VMS
  (`NO_ELISION`); `HAVE_PMEM` off. `srw_lock` already takes its generic (pthread) path,
  since there is no futex on VMS (`SUX_LOCK_GENERIC`).
- `std::mutex`/`std::condition_variable` in 9 InnoDB files: audit for stack instances (D5).
- `getrlimit(RLIMIT_AS)` in `ha_innodb.cc`, `madvise` in `buf0buf.h`/`ut0new.h`, NUMA: check
  they are guarded by the configure answers; patch any that are not.
- CRC-32C: InnoDB checksums every page with it; we build the portable code (patch 0008).
  Measure; an SSE4.2 version through `__builtin_ia32_crc32di` (a builtin, no header) is a
  possible later patch.

## C0. Probes before any build work

1. **`fsync()` semantics** (`probes/r_fsync.c`): does the C RTL's `fsync` write the buffer
   *and* wait for the disk (`$FLUSH`/`IO$_WRITEVBLK` completion), and does XFC hold any
   write-back? Time it against `O_DSYNC` writes. This sets the durability decision.
2. **Virtual memory** (`probes/r_vmem.c`): `mmap(PROT_NONE, MAP_NORESERVE)` of 1 GB,
   `MAP_FIXED` remap of a part read-write, `mprotect`, touch, release; then 8 GB reserve.
3. **InnoDB's access pattern through `my_vmsfile.c`**: extend `vms/tests/vmsfile_test.c`
   with 16 KB page writes at page offsets, extension by zero-writes, `ftruncate` shrink,
   reads past EOF, a read-only second open, record lock on a read-write file.
4. Disk space on the work disk (InnoDB adds ~114 objects to the build; a fresh datadir
   is ~150 MB: ibdata1 12 MB, ib_logfile0 96 MB, three undo tablespaces, ibtmp1).

## C1. Decisions to make with the user (go into DECISIONS.md)

- **D16. InnoDB's file I/O path.**
  (a) *Recommended first:* patch `os0file.cc` under `#ifdef __VMS` to call the `my_vms_*()`
  layer (about a dozen call sites; the layer may need `pread`/`pwrite` on raw descriptors
  exported). Reuses tested code, coherent, safe; inherits the layer's per-file mutex and
  `pread` cost.
  (b) PLAN_IO Tier 3: RMS `FOP=UFO` + `$QIO` block I/O for InnoDB files, AST completion as a
  tpool AIO backend (`aio_vms.cc`). InnoDB's page-aligned I/O is the ideal customer, but it
  means owning EOF and file headers. Do it after (a) works and is measured, as C6.
  (c) Raw C RTL calls as upstream: rejected, every D10 quirk returns.
- **D17. Durability defaults.** From C0.1: `innodb_flush_method=fsync` (upstream's fallback
  without `O_DIRECT`), `innodb_doublewrite=ON`, `innodb_checksum_algorithm=full_crc32`,
  `innodb_flush_log_at_trx_commit=1`, `innodb_log_file_mmap=OFF`, `innodb_use_native_aio=OFF`.
  Safe and slow first, per the plan.
- **D18. What InnoDB means for existing installations.** Built in (static, as the other
  engines) or left out of the kit by default? With InnoDB present, 11.4's
  `default_storage_engine` becomes InnoDB and `mariadb-install-db` makes
  `mysql.innodb_table_stats`, `innodb_index_stats`, `transaction_registry` and
  `gtid_slave_pos` InnoDB tables. An existing Aria-only datadir (the user's 3306 board)
  needs `mariadb-upgrade` and may want `default_storage_engine=Aria` kept in its `MY.CNF`.
  Proposal: build it in; CONFIGURE asks which default engine for a new datadir; README.VMS
  documents the upgrade; never touch 3306 without the user.
- **D19. Crash testing.** `STOP/ID` of `mariadbd` under load is ours to run. A VM hard reset
  (closer to power loss) also takes down the user's 3306 server and anything else on the
  node: only by the user, at a time they choose.

## C2. Build

- `server.options`: drop `-DPLUGIN_INNOBASE=NO` (STATIC); add `-DWITH_URING=OFF`,
  `-DWITH_LIBAIO=OFF`, `-DWITH_INNODB_PMEM=OFF`, `-DWITH_INNODB_SNAPPY=OFF`, `-DWITH_NUMA=OFF`
  (compression stays with the provider plugins, already off).
- `server.targets`: `innobase` before `sql_builtins`.
- Replay the new checks (`tools/replay.sh x86 server`) until 0 remain; check `HAVE_PMEM`,
  `HAVE_URING`, `HAVE_LIBAIO`, `HAVE_LIBNUMA`, `HAVE_FDATASYNC` are off in the cache.
- Patches, one per fix: `log0sync.cc` thread_local; elision/cpuid off; `os0file.cc` through
  the layer (D16a); `innodb_log_file_mmap` off; any `getrlimit`/`madvise` guards; stack
  `std::mutex` sites met at run time.
- `KEEP_GOING` rounds, every failure in PORTING_LOG; `CLEAN` after header patches.

## C3. Bring-up

1. `mariadbd --help --verbose` lists the `innodb_*` variables.
2. Fresh datadir: `install_db.com` with InnoDB; check the system tables' engines.
3. Start, `SHOW ENGINES`, create/insert/select/update/delete, transactions with
   `ROLLBACK`, `SAVEPOINT`, two sessions with row locks and a deadlock, `ALTER TABLE`
   (copy and inplace), `OPTIMIZE`, `TRUNCATE`, `DROP`, file-per-table and system tablespace.
4. Clean shutdown (`innodb_fast_shutdown` 1 and 0) and restart, repeated.
5. Undo truncation and redo log resize (`SET GLOBAL innodb_log_file_size`): both exercise
   `ftruncate`, `rename` and `O_TRUNC`.

## C4. Tests

- `servertest.sh`: an InnoDB section (the C3 SQL), plus the existing 14 cases unchanged.
- `loadcycle.sh`: the 1M-row load into InnoDB tables, `CHECKSUM TABLE` before and after
  each stop/start (`CHECK TABLE` too).
- **`tools/crashcycle.sh`** (new): load in a loop (inserts, updates, deletes with known
  totals), `STOP/ID` of `mariadbd` at a random moment, restart, wait for recovery, verify
  committed totals and `CHECK TABLE ... EXTENDED`, scan the error log for checksum or
  corruption messages. Target: 100+ cycles, zero corruption (plan exit criterion). Any
  checksum failure is stop-ship.
- VM hard-reset runs only with the user (D19).

## C5. Release

README.VMS (InnoDB settings, buffer pool and page file quota, upgrade of an Aria-only
datadir), sample `MY.CNF`, kit, servertest + loadcycle + crashcycle on the kit. Tag
`stage-c`. Release only when the user asks (vms3 is on hold).

## C6. Performance (after C5, measured)

PLAN_IO Tier 1 (`lseek`+`read` instead of `pread` in the layer) helps InnoDB too. Then
Tier 3 block I/O for InnoDB files (D16b), CRC-32C with SSE4.2, and a recommended
`innodb_buffer_pool_size`. Expect few hundred commits/s with `fsync` per commit until then
(PLAN_IO: ~1.5-2 ms per write + fsync).

## Order and stops

C0 probes → stop: D16-D19 with the user → C2 build → C3 bring-up → C4 tests → stop: exit
review → C5. Each step logs failures in PORTING_LOG.

## C0 results (2026-10-10, x86-64 E9.2-4; `probes/r_fsync.c`, `probes/r_vmem.c`)

**Writes and `fsync()`** (`r_fsync`):
- A `pwrite()` reaches the file at once: a separate `$QIO` channel reads the new data
  before any `fsync()`, buffered or `O_DSYNC`. The C RTL does no write-behind.
- `STOP`-like death (`$DELPRC`) without `fsync()`: the rewritten page and the 32 pages
  appended past the end are all there afterwards, and the header's end of file is right
  (48 pages), with or without `fsync()`. Process death loses nothing; the crash test with
  `STOP/ID` will show InnoDB's recovery, not C RTL losses. Power loss is untested: there
  the header's end of file may lag until `fsync()` (InnoDB fsyncs after extending).
- Costs: 16 KB `pwrite`+`fsync` 4 QIOs, 1.9 ms; `fsync` with nothing dirty 1 QIO, 0.4 ms;
  16 KB `O_DSYNC` write 3 QIOs, 1.6 ms; 512 B redo-style write+`fsync` 1.9 ms, with
  `O_DSYNC` 2.4 ms. So `innodb_flush_method=fsync` (the fallback) is the default; `O_DSYNC`
  buys nothing for the log.

**Buffer pool memory** (`r_vmem`): blocks the build as is.
- The C RTL's `mmap()` returns addresses at 0x8000_6000 (P2), but every size of 4 GB or
  more fails (errno 65535): likely a 32-bit length. 11.4 reserves
  `innodb_buffer_pool_size_max` = **8 TB** by default, so InnoDB would refuse to start.
- A `PROT_NONE` reservation is charged in full against the page file quota (1 GB costs
  1 GB): nothing is "reserved but free". Commit (`MAP_FIXED`), touch, decommit
  (`mprotect`), recommit (zeroed) and `munmap` all work within 1 GB.
- A **failed** 4095 MB reservation was still charged 4127 MB of quota, and the next ones
  failed for want of quota. Running sizes up to 6000 MB, one per process, then left the
  node unable to run `SHOW SYSTEM`/`SHOW MEMORY` over ssh (SHOW TIME still worked, 3306
  kept answering): probably a probe process stuck waiting for page file space.
  **Never probe large mappings again without a size cap well under the page file.**
- Consequence: on VMS, `innodb_buffer_pool_size_max` must default to the pool size (as
  upstream does for 32-bit and AIX: `size_in_bytes_max_default{0}`), and pools of 4 GB or
  more need a different allocator (64-bit `malloc`, or `$CREATE_REGION_64`/`$EXPREG_64`).

**InnoDB's file pattern through the D10 layer** (`vms/tests/vmsfile_test.c`, 35/35, 15 new):
16 KB pages; extension by 1 MB zero writes (size right before `fsync`, header right
after); a read-only open sees the read-write one's unsynced page, and closing it leaves the
header's size alone; reads past the end return 0; truncation to 16 pages with a dirty page
past the new end; `rename()` of the open file, then writes and `fsync` through it, the new
name has the data and the old one is gone. A `F_SETLK` write lock works on the master
(`my_vms_lock_fd`) and fails with EBADF on the caller's descriptor, so `os_file_lock`
must lock the master. The layer's prototypes are in `mysys/mysys_priv.h`; InnoDB needs
them in a public header (`include/my_sys.h`, under `__VMS`).

**Disk** (DISK$SYSDUMP): 8.3M blocks free (~4.0 GB); the source tree with the server
build uses 1.3 GB. Enough for the InnoDB objects, a datadir (~150 MB) and the crash
tests' data, but `loadcycle.sh` (290 MB per engine) and crash tests should clean up after
themselves.

**Outcome:** D16(a) is supported by the tests; D17 as proposed (`fsync`); a new item for
the build, the buffer pool's reservation (patch `buf0buf.h`: `size_in_bytes_max_default{0}`
on VMS, pools under 4 GB), with a 64-bit allocator for bigger pools left to C6.
