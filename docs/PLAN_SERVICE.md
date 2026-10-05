# Plan: MariaDB as a VMS service (boot start, dedicated account, clean shutdown)

Status: approved direction (2026-10-05, D15). Not started.

## Goal

After `PRODUCT INSTALL VMSMARIADB` and one run of a configure procedure, the server starts at
boot under its own account, with quotas sized for it, and stops cleanly at system shutdown.
The system manager adds one line to each of `SYSTARTUP_VMS.COM` and `SYSHUTDWN.COM`.

```
$! SYS$MANAGER:SYSTARTUP_VMS.COM, after TCP/IP and the batch queues are started
$ @SYS$STARTUP:VMSMARIADB$STARTUP.COM START

$! SYS$MANAGER:SYSHUTDWN.COM
$ @SYS$STARTUP:VMSMARIADB$SHUTDOWN.COM
```

## Defaults (change on request)

| Item | Default |
|---|---|
| Account | `MARIADB`, UIC in its own group (configure suggests an unused group, e.g. `[360,1]`) |
| Account access | batch only; `/FLAGS=(RESTRICTED,DISMAIL,DISNEWMAIL)`; privileges `TMPMBX,NETMBX` |
| Quotas | PGFLQUOTA 8,000,000; FILLM 1000; BYTLM 1,000,000; BIOLM 500; DIOLM 500; ASTLM 1000; TQELM 500; ENQLM 4000; WSQUOTA/WSEXTENT large |
| Data directory | chosen at configure time, ODS-5, owned by MARIADB, `(S:RWE,O:RWED,G,W)` |
| Port | 3306 |
| Shutdown account | `vmsmariadb_shutdown@localhost`, SHUTDOWN privilege only, random password |
| Site configuration | `SYS$MANAGER:VMSMARIADB$CONFIG.COM` |
| AUTHORIZE | configure shows the commands and asks before running them |

## Pieces

1. **`VMSMARIADB$CONFIG.COM`** (site file, written by configure): symbols for the data
   directory, port, account, node, autostart, start timeout.
2. **`VMSMARIADB$CONFIGURE.COM`** (kit, run by SYSTEM): checks ODS-5 and `CHANNELCNT` >
   FILLM; shows and (on confirmation) runs the AUTHORIZE commands; creates the data
   directory owned by the account; runs INSTALL_DB as the account (through the batch job);
   asks for root's password and sets it; creates the shutdown account and its option file
   (`<datadir>VMSMARIADB$SHUTDOWN.CNF`, owner MARIADB, `(S:R,O:RW,G,W)`); writes the
   configuration file; prints the two lines for SYSTARTUP_VMS and SYSHUTDWN.
3. **`VMSMARIADB$BOOT.COM`** (kit): the batch job body - `VMSMARIADB$SERVER START` from the
   configuration, then exits.
4. **`VMSMARIADB$STARTUP.COM START`**: defines `VMSMARIADB$ROOT` as now; reads the
   configuration; skips with a message if autostart is off, the node differs, or
   `MARIADBD_<port>` already runs; otherwise `SUBMIT/USER=<account>/NOPRINTER/QUEUE=SYS$BATCH
   VMSMARIADB$BOOT.COM`.
5. **`VMSMARIADB$SHUTDOWN.COM`**: `mariadb-admin --defaults-extra-file=<shutdown cnf>
   shutdown`, then waits for `MARIADBD_<port>` to exit (`WAIT` is fine at system shutdown;
   only ssh sessions hang on it), up to a timeout; warns if it is still there.
6. **`VMSMARIADB$SERVER.COM`**: START refuses a second copy, waits until the server answers
   a ping (optional), and passes `--table-open-cache` sized from the account's FILLM (stopgap
   for PORTING_LOG "FILLM exhaustion"); STOP and STATUS take an option file.
7. **README.VMS and README.md**: "Running as a service".

## Steps

1. Probe (needs a temporary UAF account; ask first): from SYSTEM, (a) `SUBMIT/USER=` of a job
   that does `RUN/DETACHED/AUTHORIZE` LOGINOUT - confirm the detached process has the
   account's username and UAF quotas; (b) `RUN/DETACHED/UIC=[account]/AUTHORIZE` directly -
   whose quotas, which username. Remove the account afterwards.
2. Write 1-6; extend `tools/installcheck.sh` with a service phase (configure non-interactively
   with a test account, START via the boot job, STATUS, SHUTDOWN, remove account and data).
3. README.VMS section; new kit (patch level 2), install check, release `v11.4.13-vms2`.

## Not in scope

- Cluster-wide locking of a shared data directory (one node per data directory instead).
- Several servers per node (the configuration holds one; a later extension).
- Log rotation of `mariadbd.err` (note in README.VMS; `FLUSH ERROR LOGS` exists).
