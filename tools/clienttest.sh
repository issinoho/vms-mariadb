#!/usr/bin/env bash
# clienttest.sh <node> - Stage A tests: run [.VMS]TEST_CLIENT.COM (the native
# clients against the remote server in tools/testdb.conf, git-ignored).
# Puts the SQL the tests source (clienttest_sql.sh), runs the tests, saves
# out/clienttest-<node>.log; exit status 0 only if every test passed.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
node=${1:?usage: clienttest.sh <node>}
. "$top/upstream.conf"
. "$top/tools/testdb.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
# The test procedure lives in the tree: push it (and anything else changed).
"$top/tools/push.sh" "$node" client >/dev/null
"$top/tools/clienttest_sql.sh" "$node"
job=$top/cache/clienttest-$node.com
printf '$ set noon\n$ @%s.%s.VMS]TEST_CLIENT.COM "%s" "%s" "%s" "%s" "%s"\n' "${WORKDIR%]}" "$remote" \
    "$TESTDB_HOST" "$TESTDB_PORT" "$TESTDB_USER" "$TESTDB_PASSWORD" "$TESTDB_DATABASE" > "$job"
mkdir -p "$top/out"
log=$top/out/clienttest-$node.log
VMS_TIMEOUT=3600 "$top/tools/vms.sh" "$node" run "$job" | sed "s/$TESTDB_PASSWORD/<password>/g" | tee "$log"
grep -q 'CLIENTTEST: [0-9]* passed, 0 failed' "$log"
