# Plan: file I/O performance

Status: proposed (2026-10-05). Not started.

## The problem

The Stage B load/restart test (PORTING_LOG, "data load and restart cycles") spent ~35 minutes
per cycle in `CHECKSUM TABLE` + `CHECK TABLE` over 290 MB: ~3.8M direct I/Os, about 75 bytes
each. MyISAM's checksum scan has no read cache, so each dynamic row is two small `pread()`s,
and on VMS every `pread()` is expensive. Anything that does many small positioned reads or
writes is slow the same way: uncached MyISAM row fetches, index probes past the key cache,
repair, and later InnoDB's page I/O.

## Measurements (x86-64 VM, E9.2-4; `probes/io_count.c`, `probes/io_paths.c`)

16 MB file, 4,096 calls each:

| Path | Size | QIOs/call | us/call |
|---|---|---|---|
| C RTL `read()`, sequential, no seek | 512 | 0.03 | 14 |
| C RTL `lseek()` to the current offset + `read()` | 512 | 0.03 | 14 |
| C RTL `pread()`, sequential | 512 | 1.98 | 658 |
| C RTL `pread()`, random | 512 | 2.03 | 699 |
| C RTL `pread()`, random | 8192 | 2.49 | 892 |
| C RTL `lseek()` + `read()`, random | 512 | 1.03 | 376 |
| C RTL `lseek()` + `read()`, random | 8192 | 1.49 | 490 |
| `$QIOW IO$_READVBLK`, random (data in XFC) | 512 / 8192 | 1.00 | 282 / 370-390 |
| C RTL `pwrite()`, random, + `fsync()` | 8192 | 3.98 | 1937 |
| C RTL `lseek()` + `write()`, random, + `fsync()` | 8192 | 2.98 | 1552 |
| C RTL `lseek()` + `write()`, sequential, + `fsync()` | 8192 | 1.12 | 881 |

XFC is enabled (3 GB, 78% read hit rate), yet a QIO costs ~0.28 ms even when the data is
cached. What we learn:

1. **`pread()` throws away the C RTL's buffer.** The C RTL reads a stream file through a
   per-descriptor buffer (about 16 KB); `read()` and `lseek()`+`read()` reuse it, so small
   sequential reads cost 14 us. `pread()` costs a buffer fill plus one more QIO on every
   call: ~47x slower for small sequential reads, ~2x for random ones.
2. **A QIO is the unit of cost, and it is ~0.3 ms whatever the cache does.** Replacing the
   C RTL with `$QIO` saves at most ~25% per I/O over `lseek()`+`read()`. Speed comes from
   *not issuing* I/Os: buffering, caching, larger transfers.
3. **Writes cost 3-4 QIOs** through `pwrite()`; `lseek()`+`write()` saves one.

## Options

### Tier 0 - configuration (no code)

Bigger engine caches keep pages out of the file layer: `key_buffer_size` (MyISAM indexes),
`aria_pagecache_buffer_size` (Aria data and indexes), `read_buffer_size` and
`read_rnd_buffer_size` (scans), `myisam_sort_buffer_size` and `aria_sort_buffer_size`
(repair). Document recommended values for VMS in README.VMS and a sample `MY.CNF`; the
server already has the UAF page file quota for them. Does not help MyISAM's uncached row
reads, which is the case that hurt.

### Tier 1 - positioned I/O through `lseek()` + `read()`/`write()` (small, low risk)

In `mysys/my_vmsfile.c`, implement `my_vms_pread()`/`my_vms_pwrite()` as `lseek()` +
`read()`/`write()` on the shared master descriptor, under the file's existing mutex. All of
a file's I/O already goes through its master (D10), so the C RTL's buffer stays coherent.

- Expected: small sequential-ish reads (MyISAM checksum and check scans, row-by-row fetches
  of neighbouring rows) from ~0.66 ms to ~14 us; random reads 2x; random writes ~1.25x.
  The 35-minute scan should drop to a few minutes or less.
- Cost: reads and writes on one file are serialised by its mutex. Every QIO is synchronous
  and ~0.3 ms anyway, and the node has 2 CPUs, so we expect little lost parallelism; the
  benchmark's concurrent lookups will show it.
- Check: writes must still reach the file system at `write()` (the probe's 1.12 QIOs per
  sequential 8 KB write says they do: no write-behind in the C RTL buffer), so a process
  crash loses nothing that Linux would keep; `fsync()` stays the durability point.
- About 60 lines in `my_vmsfile.c`, no new patch to upstream files.

### Tier 2 - a block cache in the file layer (medium)

A process-wide cache of file blocks (e.g. 16 KB, LRU), keyed by (device, inode, block),
inside `my_vmsfile.c`, in front of the master descriptor:

- reads served from the cache; misses read a whole block (one QIO) and may read ahead on
  sequential access;
- writes are written through at once (the same durability as today) and update cached
  blocks; truncate and close invalidate;
- size from a logical name, say `VMSMARIADB_FILE_CACHE` (default 64 MB), 0 to disable.

Expected: re-reads of hot data that the engines do not cache (MyISAM data files, Aria
files outside the page cache, `.frm` and log reads) cost microseconds. Risks: memory, and
bugs in a cache sitting under every table (needs its own test program like
`vms/tests/vmsfile_test.c`, plus the server suites). Engine caches already hold most index
traffic, so do Tier 1 first and measure whether Tier 2 is still worth it.

### Tier 3 - block I/O without the C RTL (large; for InnoDB)

Open data files through RMS with `FOP=UFO` and do `$QIO IO$_READVBLK`/`WRITEVBLK` on the
channel, keeping the end of file ourselves (the file header's EOF updated at close or
`fsync`). Benefits: one QIO per call whatever the size, no stale `st_size`, no
`ftruncate`/EOF quirks (D10's workarounds go away), and asynchronous I/O with ASTs, which
InnoDB can use. Saves ~25% per I/O over Tier 1 on its own; the real gain is for Stage C,
whose 16 KB page I/O and `fsync` pattern needs it. Plan it with InnoDB rather than now.

### Not pursued

- Patching MyISAM's checksum to use a read cache (`HA_EXTRA_CACHE`): fixes one statement;
  Tier 1 fixes the class.
- `mmap()` for MyISAM (`myisam_use_mmap`): VMS's C RTL mapping of files needs its own probes;
  revisit only if Tiers 1-2 fall short.

## How we measure

`tools/iobench.sh x86` (to write): against the native server on port 3307, after a
restart (cold engine caches), with the server's `DIRIO` count from `SHOW SYSTEM` before and
after each step:

1. `CHECKSUM TABLE` and `CHECK TABLE` on the 1M-row MyISAM and Aria tables (the case that hurt);
2. 10,000 random primary-key lookups on each;
3. 10,000 single-row UPDATEs by primary key;
4. the 1M-row load (`INSERT ... SELECT`), and `ALTER TABLE ... ENGINE=` (a full copy).

Baseline first, then after each tier; correctness gates are unchanged: `servertest.sh`
12/12, `loadcycle.sh` checksums, `vmsfile_test`.

## Proposed order

1. `iobench.sh` and a baseline (about an hour, most of it the slow checksums).
2. Tier 1, with `vmsfile_test` extended for positioned I/O mixed with sequential reads.
3. Re-measure; Tier 0 values documented in README.VMS and a sample `MY.CNF`.
4. Decide on Tier 2 from the numbers.
5. Tier 3 goes into the Stage C (InnoDB) plan.
