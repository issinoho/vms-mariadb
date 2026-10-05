#!/usr/bin/env bash
# install_db.sh <node> [datadir-name] - run @[.VMS]INSTALL_DB on <node> to
# create a data directory [.<datadir-name>] (default DATA) in the work
# directory, next to the source tree.  Refuses a non-empty directory.
# Log: out/install_db-<node>.log; exit 0 only on "INSTALL_DB: done".
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: install_db.sh <node> [datadir-name]}
dname=${2:-DATA}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
"$top/tools/push.sh" "$node" server >/dev/null
job=$top/cache/install_db-$node.com
printf '$ set noon\n$ set process/parse_style=extended\n$ @%s.%s.VMS]INSTALL_DB.COM %s.%s]\n' \
    "${WORKDIR%]}" "$remote" "${WORKDIR%]}" "$dname" > "$job"
mkdir -p "$top/out"
VMS_TIMEOUT=${VMS_TIMEOUT:-3600} "$top/tools/vms.sh" "$node" run "$job" | tee "$top/out/install_db-$node.log"
grep -q 'INSTALL_DB: done' "$top/out/install_db-$node.log"
