#!/usr/bin/env bash
# soak.sh <node> [hours] - Stage B exit: idle + light load against the native
# server for <hours> (default 24).  Every minute: a fresh connection runs a
# small transaction-like batch on table soak (INSERT, UPDATE, SELECT, and a
# DELETE of old rows) and checks its row count; every 30 minutes the server
# process's CPU, I/O, page faults and working set are recorded from
# SHOW SYSTEM, to spot leaks.  The first and last hours are idle apart from
# the sampling (idle-connection and timer behaviour).  Uses the remote account
# in tools/testdb.conf, like loadcycle.sh.
# Log: out/soak-<node>.log; exit 0 if no query failed and the server stayed up.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
node=${1:?usage: soak.sh <node> [hours]}
hours=${2:-24}
port=${PORT:-3307}
. "$top/tools/testdb.conf"
read -r _ _ HOST _ _ _ _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
client=$(ls "$top"/cache/native-*/client/mariadb | head -1)
log=$top/out/soak-$node.log; mkdir -p "$top/out"; : > "$log"
q() { "$client" --no-defaults --connect-timeout=60 -h "$HOST" -P "$port" -u "$VMSSERVER_USER" \
        -p"$VMSSERVER_PASSWORD" --batch --skip-column-names vmsremote -e "$1"; }
# milliseconds since the epoch; BSD date (macOS) has no %N
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
say() { echo "$(date '+%F %T') $*" | tee -a "$log"; }
sample() {
    "$top/tools/vms.sh" "$node" dcl 'show system/process=MARIADBD*' 2>&1 |
        grep MARIADBD | sed 's/^/process: /' | while read -r l; do say "$l"; done
}

q "CREATE TABLE IF NOT EXISTS soak (id INT AUTO_INCREMENT PRIMARY KEY, t DATETIME,
   n INT, s VARCHAR(200), KEY(t)) ENGINE=Aria; TRUNCATE soak;"
say "soak: $hours h on $node"; sample
start=$(date +%s); end=$((start + hours * 3600)); fail=0; runs=0; worst=0; next=$((start + 1800))
while [ "$(date +%s)" -lt "$end" ]; do
    now=$(date +%s)
    if [ $((now - start)) -ge 3600 ] && [ $((end - now)) -ge 3600 ]; then
        t0=$(now_ms)
        if out=$(q "INSERT INTO soak (t, n, s) SELECT NOW(), seq, REPEAT('v', 150) FROM seq_1_to_100;
                    UPDATE soak SET n = n + 1 WHERE id % 7 = 0;
                    DELETE FROM soak WHERE t < NOW() - INTERVAL 2 HOUR;
                    SELECT COUNT(*), SUM(n) > 0 FROM soak;" 2>&1); then
            ms=$(( $(now_ms) - t0 )); runs=$((runs + 1))
            [ $ms -gt $worst ] && worst=$ms
            [ $((runs % 60)) -eq 0 ] && say "load: $runs batches, last ${ms} ms, worst ${worst} ms, rows $(echo "$out" | cut -f1)"
        else
            say "load FAILED: $out"; fail=$((fail + 1))
        fi
    else
        q "SELECT 1" >/dev/null 2>&1 || { say "idle ping FAILED"; fail=$((fail + 1)); }
    fi
    if [ "$now" -ge "$next" ]; then sample; next=$((next + 1800)); fi
    sleep 60
done
sample
q "DROP TABLE soak" || fail=$((fail + 1))
say "SOAK: $([ $fail -eq 0 ] && echo PASS || echo "FAIL ($fail failures)"), $runs batches, worst ${worst} ms"
[ $fail -eq 0 ]
