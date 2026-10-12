#!/usr/bin/env bash
# clienttest_sql.sh <node> - write the SQL that [.VMS]TEST_CLIENT.COM sources
# and put it in the tree's [.VMS.TESTS] on <node>.  Used by clienttest.sh and
# servertest.sh: the files are not in staging/, so a fresh work tree has none
# until one of them runs this.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
node=${1:?usage: clienttest_sql.sh <node>}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
tests=$top/cache/clienttests
rm -rf "$tests"; mkdir -p "$tests"
echo "SELECT VERSION();" > "$tests/version.sql"
cat > "$tests/ddl_dml.sql" <<'SQL'
DROP TABLE IF EXISTS vms_t;
CREATE TABLE vms_t (id INT PRIMARY KEY, s VARCHAR(100));
INSERT INTO vms_t VALUES (1,'one'),(2,'two'),(3,'three');
UPDATE vms_t SET s='TWO' WHERE id=2;
DELETE FROM vms_t WHERE id=3;
SELECT CONCAT('rows=',COUNT(*),',s2=',MAX(IF(id=2,s,NULL))) FROM vms_t;
SQL
cat > "$tests/big_setup.sql" <<'SQL'
DROP TABLE IF EXISTS vms_big;
CREATE TABLE vms_big (id INT PRIMARY KEY, s CHAR(60))
  SELECT seq AS id, REPEAT(CHAR(65 + seq MOD 26 USING ascii), 60) AS s FROM seq_1_to_100000;
SELECT CONCAT('big=',COUNT(*)) FROM vms_big;
SQL
echo "SELECT id, s FROM vms_big ORDER BY id;" > "$tests/big_result.sql"
# One INSERT of 10001 rows (~1 MB), sent by the client.
{
    echo "INSERT INTO vms_t VALUES"
    x=$(printf 'x%.0s' $(seq 1 90))
    for i in $(seq 1000 11000); do
        printf "(%d,'%s')%s\n" "$i" "$x" "$([ "$i" -lt 11000 ] && echo , || echo ';')"
    done
    echo "SELECT CONCAT('after=',COUNT(*)) FROM vms_t;"
} > "$tests/big_insert.sql"
printf "DROP TABLE vms_t;\nDROP TABLE vms_big;\nSELECT 'cleaned';\n" > "$tests/cleanup.sql"
"$top/tools/vms.sh" "$node" put "$tests"/*.sql -- "$(echo "$remote" | tr A-Z a-z)/vms/tests" >/dev/null
