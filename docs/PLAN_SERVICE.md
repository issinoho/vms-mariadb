# Plan: MariaDB as a VMS service (boot start, dedicated account, clean shutdown)

Status: approved direction (2026-10-05, D15); step 1 (probe) done 2026-10-06; step 2 done
2026-10-07: `tools/installcheck.sh x86` PASS with the service phase (kit V11.4-13E2; the server
ran as the test account with its UAF quotas and only TMPMBX,NETMBX, and stopped cleanly through
the shutdown account). Step 3 done 2026-10-07: README.VMS and README.md sections, kit
V11.4-13E2, released as `v11.4.13-vms2`.

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
| Account | `MARIADB` `[360,1]`, its own group (configure checks it is free, else suggests the next free group) |
| Account access | batch only; `/FLAGS=(NODISUSER,DISMAIL,DISNEWMAIL)` - not RESTRICTED (D15 probe); privileges `TMPMBX,NETMBX` |
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

1. ~~Probe~~ done 2026-10-06 (D15): only the `SUBMIT/USER` route gives the account's
   username, UAF quotas and privileges. Configure must give `/FLAGS=NODISUSER`, must not set
   RESTRICTED, and the data directory must be on a path the account can traverse (execute
   access on every directory above it).
2. Write 1-6; extend `tools/installcheck.sh` with a service phase (configure non-interactively
   with a test account, START via the boot job, STATUS, SHUTDOWN, remove account and data).
   Written 2026-10-06, with these departures from the pieces above:
   - **No `VMSMARIADB$BOOT.COM`.** STARTUP submits `VMSMARIADB$SERVER.COM` itself with
     `/PARAMETERS=(START,datadir,port,option)`. The job cannot read `SYS$MANAGER`, so the
     parameters carry the configuration either way; a second procedure added nothing.
   - **INSTALL_DB runs as SYSTEM inside configure**, and configure then gives the data
     directory to the account (`SET SECURITY/OWNER`). Running it in a batch job as the
     account would need configure to wait for the job (`SYNCHRONIZE`), for the same files.
   - **Root's password and the shutdown account are set by a second `mariadbd --bootstrap`**,
     not through a running server (`probes/service/bootstrap_users.com`, 2026-10-06):
     `FLUSH PRIVILEGES` loads the grant tables, `EXECUTE IMMEDIATE ... QUOTE()` sets the
     password, which DCL writes as hex (`X'...'`) so that no character needs quoting; the
     shutdown password is `HEX(RANDOM_BYTES(16))` (OpenSSL) and the server writes the option
     file itself (`SELECT ... INTO DUMPFILE`), so it never passes through DCL. No server has
     to start and be waited for, and the same route adopts an existing data directory
     (its root password is kept; only the shutdown account is added).
   - The shutdown account exists at `localhost` **and** `127.0.0.1`, so it still matches if
     the site sets `skip-name-resolve`.
   - START does not wait for the server to answer (STATUS does that); it refuses a second
     `MARIADBD_<port>` that it can see.
   - A logical name `VMSMARIADB$CONFIG` names another site file (the install check uses it,
     so it never writes `SYS$MANAGER`).
3. README.VMS section; new kit (patch level 2), install check, release `v11.4.13-vms2`.

## Not in scope

- Cluster-wide locking of a shared data directory (one node per data directory instead).
- Several servers per node (the configuration holds one; a later extension).
- Log rotation of `mariadbd.err` (note in README.VMS; `FLUSH ERROR LOGS` exists).
