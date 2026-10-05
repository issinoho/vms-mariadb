#!/usr/bin/env bash
# servertest.sh <node> - Stage B tests against the native server on <node>
# (tools/install_db.sh, tools/server.sh x86 start; port 3307, root without a
# password from localhost).  Runs:
#   1. the client suite (vms/test_client.com) against 127.0.0.1:3307, so the
#      VMS clients test the VMS server;
#   2. engine tests: each engine's DDL/DML, joins, CHECK/REPAIR/OPTIMIZE, FLUSH;
#   3. a restart: stop the server, start it again, check the data persisted.
# Log: out/servertest-<node>.log; exit 0 only if everything passed.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: servertest.sh <node>}
port=${PORT:-3307}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
log=$top/out/servertest-$node.log
mkdir -p "$top/out"; : > "$log"
"$top/tools/push.sh" "$node" client >/dev/null

tests=$top/cache/servertests
rm -rf "$tests"; mkdir -p "$tests"
cat > "$tests/engines.sql" <<'SQL'
CREATE DATABASE IF NOT EXISTS vmsengines;
USE vmsengines;
DROP TABLE IF EXISTS t_aria, t_myisam, t_mem, t_csv, t_m1, t_m2, t_merge;
CREATE TABLE t_aria (id INT PRIMARY KEY, v VARCHAR(40), n BIGINT, KEY(n)) ENGINE=Aria;
CREATE TABLE t_myisam (id INT PRIMARY KEY, v VARCHAR(40), n BIGINT, KEY(n)) ENGINE=MyISAM;
CREATE TABLE t_mem (id INT PRIMARY KEY, v VARCHAR(40)) ENGINE=MEMORY;
CREATE TABLE t_csv (id INT NOT NULL, v VARCHAR(40) NOT NULL) ENGINE=CSV;
CREATE TABLE t_m1 (id INT, KEY(id)) ENGINE=MyISAM;
CREATE TABLE t_m2 (id INT, KEY(id)) ENGINE=MyISAM;
CREATE TABLE t_merge (id INT, KEY(id)) ENGINE=MRG_MyISAM UNION=(t_m1,t_m2);
INSERT INTO t_aria SELECT seq, CONCAT('aria-', seq), seq * 5000000000 FROM seq_1_to_20000;
INSERT INTO t_myisam SELECT seq, CONCAT('myisam-', seq), seq * 5000000000 FROM seq_1_to_20000;
INSERT INTO t_mem SELECT seq, CONCAT('mem-', seq) FROM seq_1_to_5000;
INSERT INTO t_csv SELECT seq, CONCAT('csv-', seq) FROM seq_1_to_1000;
INSERT INTO t_m1 SELECT seq FROM seq_1_to_100;
INSERT INTO t_m2 SELECT seq FROM seq_101_to_250;
UPDATE t_aria SET v= 'updated' WHERE id % 1000 = 0;
DELETE FROM t_myisam WHERE id > 19990;
SELECT CONCAT('aria=', COUNT(*), ',upd=', SUM(v='updated'), ',maxn=', MAX(n)) FROM t_aria;
SELECT CONCAT('myisam=', COUNT(*), ',sum=', SUM(id)) FROM t_myisam;
SELECT CONCAT('mem=', COUNT(*), ',csv=', (SELECT COUNT(*) FROM t_csv), ',merge=', (SELECT COUNT(*) FROM t_merge)) FROM t_mem;
SELECT CONCAT('join=', COUNT(*)) FROM t_aria a JOIN t_myisam m ON a.id = m.id JOIN t_mem e ON e.id = a.id WHERE a.n > 10000000000;
SELECT CONCAT('group=', COUNT(*)) FROM (SELECT id % 7 AS g, COUNT(*) c, SUM(n) s FROM t_aria GROUP BY g HAVING c > 100) x;
SELECT CONCAT('order=', GROUP_CONCAT(id ORDER BY n DESC SEPARATOR ',')) FROM (SELECT id, n FROM t_myisam ORDER BY n DESC LIMIT 3) x;
CHECK TABLE t_aria, t_myisam;
REPAIR TABLE t_myisam;
OPTIMIZE TABLE t_aria;
FLUSH TABLES;
SELECT CONCAT('after_flush=', COUNT(*)) FROM t_aria;
SHOW GLOBAL STATUS LIKE 'Uptime';
SELECT CONCAT('engines-done') AS r;
SQL
cat > "$tests/persist.sql" <<'SQL'
USE vmsengines;
SELECT CONCAT('persist aria=', COUNT(*), ',myisam=', (SELECT COUNT(*) FROM t_myisam), ',csv=', (SELECT COUNT(*) FROM t_csv), ',mem=', (SELECT COUNT(*) FROM t_mem)) FROM t_aria;
CHECK TABLE t_aria, t_myisam, t_csv;
DROP DATABASE vmsengines;
SELECT 'persist-done' AS r;
SQL
"$top/tools/vms.sh" "$node" put "$tests"/*.sql -- "$(echo "$remote" | tr A-Z a-z)/vms/tests" >/dev/null

mclient='$ mariadb :== $'"${WORKDIR%]}.$remote"'.VMSOBJ]MARIADB.EXE'
run_sql() {  # run_sql <file> -> output
    local job=$top/cache/servertest-$node-$1.com
    printf '$ set noon\n$ set process/parse_style=extended\n$ define sys$error sys$output\n$ set default %s.%s]\n%s\n$ mariadb "--no-defaults" "--host=127.0.0.1" "--port=%s" "--user=root" "--batch" "-e" "source vms/tests/%s.sql"\n$ write sys$output "SQL-STATUS ", $status\n' \
        "${WORKDIR%]}" "$remote" "$mclient" "$port" "$1" > "$job"
    VMS_TIMEOUT=1800 "$top/tools/vms.sh" "$node" run "$job"
}
pass=0 fail=0
check() {  # check <name> <pattern> <output>
    if grep -q -- "$2" <<< "$3"; then echo "TEST $1: PASS" | tee -a "$log"; pass=$((pass+1))
    else echo "TEST $1: FAIL (no '$2')" | tee -a "$log"; fail=$((fail+1)); fi
}

echo "== client suite against the VMS server" | tee -a "$log"
printf '$ set noon\n$ set process/parse_style=extended\n$ define sys$error sys$output\n$ set default %s.%s]\n%s\n$ mariadb "--no-defaults" "--host=127.0.0.1" "--port=%s" "--user=root" "-e" "CREATE DATABASE IF NOT EXISTS vmstest"\n' \
    "${WORKDIR%]}" "$remote" "$mclient" "$port" > "$top/cache/servertest-mkdb.com"
"$top/tools/vms.sh" "$node" run "$top/cache/servertest-mkdb.com" >/dev/null
TESTDB_CONF=/dev/null
cfgjob=$top/cache/servertest-client.com
printf '$ set noon\n$ @%s.%s.VMS]TEST_CLIENT.COM "127.0.0.1" "%s" "root" "" "vmstest"\n' "${WORKDIR%]}" "$remote" "$port" > "$cfgjob"
out=$(VMS_TIMEOUT=3600 "$top/tools/vms.sh" "$node" run "$cfgjob")
echo "$out" | grep -E '^TEST|CLIENTTEST' | tee -a "$log"
check client_suite 'CLIENTTEST: [0-9]* passed, 0 failed' "$out"

echo "== engines" | tee -a "$log"
out=$(run_sql engines); echo "$out" >> "$log"
check aria 'aria=20000,upd=20,maxn=100000000000000' "$out"
check myisam 'myisam=19990,sum=199810045' "$out"
check mem_csv_merge 'mem=5000,csv=1000,merge=250' "$out"
check join 'join=4998' "$out"
check group_by 'group=7' "$out"
check order_by 'order=19990,19989,19988' "$out"
check check_table 'vmsengines.t_myisam	check	status	OK' "$out"
check flush 'after_flush=20000' "$out"
check engines_done 'engines-done' "$out"

echo "== restart" | tee -a "$log"
VMS_TIMEOUT=600 "$top/tools/server.sh" "$node" stop >> "$log" 2>&1 || true
"$top/tools/server.sh" "$node" start >> "$log" 2>&1
read -r _ _ HOST _ _ _ _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
for _ in $(seq 1 60); do timeout 5 bash -c "exec 3<>/dev/tcp/$HOST/$port" 2>/dev/null && break; sleep 5; done
out=$(run_sql persist); echo "$out" >> "$log"
check persist 'persist aria=20000,myisam=19990,csv=1000,mem=0' "$out"
check persist_check 'vmsengines.t_aria	check	status	OK' "$out"

echo "SERVERTEST: $pass passed, $fail failed" | tee -a "$log"
[ "$fail" -eq 0 ]
