# MariaDB for OpenVMS

A port of [MariaDB](https://mariadb.org) **11.4 LTS** to OpenVMS **x86-64**, built natively
with VSI's clang-based C/C++ compiler. It belongs to the same family as
[GNU grep](https://github.com/issinoho/vms-grep), [curl](https://github.com/issinoho/vms-curl),
[zlib](https://github.com/issinoho/vms-zlib) and the other `vms-*` ports, and uses the same
method: every build starts from MariaDB's **signed release tarball**, and this repository
holds only our changes (`patches/`, `overlay/`) and the tooling that applies them and drives
the build on the VMS nodes.

**Status: Stage A done (2026-10-04).** Connector/C and the command-line clients (`mariadb`,
`mariadb-dump`, `-admin`, `-check`, `-import`, `-show`, `-slap`, `my_print_defaults`,
`perror`) build natively and pass the client tests against a remote MariaDB 11.8 server,
over TLS 1.3 through VSI's SSL3 kit. The server (Stage B) is next. The original plan is in
[MARIADB_OPENVMS_PLAN.md](MARIADB_OPENVMS_PLAN.md); where we depart from it, and why, is in
[docs/DECISIONS.md](docs/DECISIONS.md).

| Stage | Deliverable | Status |
|---|---|---|
| A | Connector/C + `mariadb` client (no server) | done: 15/15 client tests, TLS, interactive |
| B | `mariadbd` with Aria/MyISAM/MEMORY | builds and runs `--version`/`--help`; bootstrap next |
| C | InnoDB, durability-tested | not started |
| D | PCSI kit, docs, upstream patches | not started |

IA64 is not a server target: its C++ compiler predates C++11, which MariaDB requires.

## Layout

```
upstream.conf      release, tarball URL, SHA-256, signing key fingerprint
keys/              MariaDB's release signing key
patches/           changes to upstream files (quilt-style series)
overlay/           new files only
probes/            small C/C++ programs that answer platform questions on the nodes
tools/             host-side scripts (vms.sh, recon.sh, probe.sh, ...)
docs/              decisions, porting log, environment and probe results
cache/ staging/ out/   generated, not committed
```

`tools/nodes.conf` (not committed; see `tools/nodes.conf.example`) names the build nodes.
Work directories must be on ODS-5 volumes.

## Licence

MariaDB Server is GPLv2; Connector/C is LGPL 2.1. Our patches and VMS files are distributed
under the same terms as the files they change or accompany.

OpenVMS is a trademark of VMS Software, Inc. This project is not affiliated with VMS
Software, Inc. or the MariaDB Foundation.
