#!/usr/bin/env bash
# installcheck.sh [node] - install the VMSMARIADB kit on the x86-64 node (default
# x86), create a data directory and start a server from it (port 3308), query
# it with the installed clients, stop it, and remove the kit and the scratch
# data directory.  Changes the system while it runs (PCSI database,
# SYS$COMMON:[VMSMARIADB], VMSMARIADB$ROOT); run kit.sh first.  Ask first.
# Output: out/install-<node>.txt.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:-x86}
. "$top/upstream.conf"
REMOTE=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
"$top/tools/vms.sh" "$node" put "$top/tools/vms_installcheck.com" >/dev/null
mkdir -p "$top/out"
log=$top/out/install-$node.txt; : > "$log"
phase() {
    local job=$top/cache/installcheck-$node-$1.com
    printf '$ set noon\n$ set default %s\n$ @%sVMS_INSTALLCHECK.COM %s %s\n' \
        "$WORKDIR" "$WORKDIR" "$REMOTE" "$1" > "$job"
    VMS_TIMEOUT=${2:-1800} "$top/tools/vms.sh" "$node" run "$job" 2>&1 | tee -a "$log"
}
phase INSTALL > /dev/null
up=0
for _ in $(seq 1 30); do
    phase STATUS 120 | grep -q INSTALLCHECK_UP && { up=1; break; }
    sleep 10
done
echo "server up: $up" | tee -a "$log"
[ $up = 1 ] && phase QUERY > /dev/null
for _ in $(seq 1 60); do
    phase PROCESS 120 | grep -q INSTALLCHECK_GONE && break
    sleep 10
done
phase REMOVE > /dev/null
grep -aE '=== .* status|startup procedure|VMSMARIADB\$ROOT|server image|english messages|charsets index|INSTALLCHECK_|INSTALL_DB|VMSMARIADB\$SERVER:|ERROR|^11\.|kitrows|after removal|after cleanup|items found|server up' "$log"
ok=1
for check in CLIENT_VERSION DUMP; do grep -aq "INSTALLCHECK_$check: PASS" "$log" || { echo "installcheck: $check did not pass" >&2; ok=0; }; done
grep -aq 'INSTALLCHECK_ROWS: 2' "$log" || { echo "installcheck: row check failed" >&2; ok=0; }
grep -aq 'ERROR 1054' "$log" || { echo "installcheck: no error message text from the server" >&2; ok=0; }
grep -aq 'VMSMARIADB\$ROOT after removal: \[\]' "$log" && grep -aq 'files after removal: \[\]' "$log" &&
    grep -aq 'startup after removal: \[\]' "$log" || { echo "installcheck: removal incomplete" >&2; ok=0; }
[ $ok = 1 ] && echo "INSTALLCHECK: PASS" || { echo "INSTALLCHECK: FAIL"; exit 1; }
