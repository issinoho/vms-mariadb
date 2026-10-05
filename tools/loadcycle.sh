#!/usr/bin/env bash
# loadcycle.sh <node> [rows] [cycles] - Stage B exit tests on the native server:
# load <rows> (default 1000000, ~120 MB per table) into an Aria and a MyISAM
# table, take CHECKSUM TABLE, then stop and start the server <cycles> times
# (default 5), checking row counts, checksums and CHECK TABLE after each start.
# Uses the remote account in tools/testdb.conf (VMSSERVER_*) from this host,
# with the native host client (cache/native-*/client/mariadb).
# Log: out/loadcycle-<node>.log; exit 0 only if every cycle matched.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: loadcycle.sh <node> [rows] [cycles]}
rows=${2:-1000000}
cycles=${3:-5}
port=${PORT:-3307}
. "$top/upstream.conf"; . "$top/tools/testdb.conf"
read -r _ _ HOST _ _ _ _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
client=$(ls "$top"/cache/native-*/client/mariadb | head -1)
log=$top/out/loadcycle-$node.log; mkdir -p "$top/out"; : > "$log"
q() { "$client" --no-defaults -h "$HOST" -P "$port" -u "$VMSSERVER_USER" -p"$VMSSERVER_PASSWORD" \
        --batch --skip-column-names vmsremote -e "$1"; }
wait_up() { for _ in $(seq 1 120); do q "SELECT 1" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
say() { echo "$*" | tee -a "$log"; }

say "load: $rows rows into Aria and MyISAM"
# While loading, time a fresh connection every 30 s: the server must keep
# answering other clients (a busy thread once starved them for minutes).
( while :; do t=$(date +%s.%N); q "SELECT 1" >/dev/null 2>&1
    printf 'probe: connect+query %.1fs\n' "$(echo "$(date +%s.%N) - $t" | bc)" >> "$log"; sleep 30; done ) &
probe=$!
q "DROP TABLE IF EXISTS big_aria, big_myisam;
   CREATE TABLE big_aria (id INT PRIMARY KEY, k BIGINT, s VARCHAR(100), KEY(k)) ENGINE=Aria;
   CREATE TABLE big_myisam LIKE big_aria; ALTER TABLE big_myisam ENGINE=MyISAM;"
t0=$(date +%s)
q "INSERT INTO big_aria SELECT seq, seq * 7919 % 1000003, REPEAT(CHAR(65 + seq % 26), 100) FROM seq_1_to_$rows"
t1=$(date +%s); say "load: Aria $((t1 - t0))s"
q "INSERT INTO big_myisam SELECT * FROM big_aria"
say "load: MyISAM $(( $(date +%s) - t1 ))s"
kill $probe 2>/dev/null; wait $probe 2>/dev/null || true
grep '^probe' "$log" | sort -t' ' -k3 -n | tail -1 | sed 's/^probe:/slowest probe:/'
q "SELECT table_name, ROUND((data_length + index_length) / 1048576) FROM information_schema.tables
   WHERE table_schema = 'vmsremote' AND table_name LIKE 'big%'" | sed 's/^/size MB: /' | tee -a "$log"
want=$(q "CHECKSUM TABLE big_aria, big_myisam" | awk '{print $2}' | tr '\n' ' ')
say "checksums: $want"
fail=0
for c in $(seq 1 "$cycles"); do
    VMS_TIMEOUT=900 "$top/tools/server.sh" "$node" stop >> "$log" 2>&1 || true
    "$top/tools/server.sh" "$node" start >> "$log" 2>&1
    if ! wait_up; then say "cycle $c: server did not come back"; fail=1; break; fi
    got=$(q "CHECKSUM TABLE big_aria, big_myisam" | awk '{print $2}' | tr '\n' ' ')
    n=$(q "SELECT (SELECT COUNT(*) FROM big_aria) + (SELECT COUNT(*) FROM big_myisam)")
    chk=$(q "CHECK TABLE big_aria, big_myisam" | awk '$3=="status"{print $4}' | tr '\n' ' ')
    if [ "$got" = "$want" ] && [ "$n" = $((rows * 2)) ] && [ "$chk" = "OK OK " ]; then
        say "cycle $c: PASS (rows $n, checksums match, check $chk)"
    else
        say "cycle $c: FAIL (rows $n, checksums '$got' want '$want', check '$chk')"; fail=1
    fi
done
q "DROP TABLE big_aria, big_myisam"
say "LOADCYCLE: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
[ $fail -eq 0 ]
