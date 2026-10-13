#!/usr/bin/env bash
# vmssh_test.sh <node> - tests of vms.sh's waiting, with stand-in ssh commands:
#   1. the ssh session ends while the procedure still runs (a user's node,
#      2026-10-13): vms.sh must wait for it and print its log, not retry;
#   2. the session never starts: one retry, then "no session started";
#   3. a timeout: vms.sh must leave the running procedure's files alone, and
#      the procedure must still finish (writes its .DONE marker).
# About 3 minutes.  Leaves nothing in the work directory.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
node=${1:?usage: vmssh_test.sh <node>}
vms=$top/tools/vms.sh
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
real=$(command -v ssh)
mkdir "$tmp/drop" "$tmp/none"
cat > "$tmp/drop/ssh" <<EOS
#!/usr/bin/env bash
# real ssh, cut off after 8 s
"$real" "\$@" & p=\$!
( sleep 8; kill \$p 2>/dev/null ) & wait \$p
EOS
printf '#!/bin/sh\necho "stand-in: connection closed" >&2; exit 255\n' > "$tmp/none/ssh"
chmod +x "$tmp/drop/ssh" "$tmp/none/ssh"
# A 30 s procedure (busy wait: WAIT hangs over ssh).
cat > "$tmp/vmssh_slow.com" <<'EOS'
$ until = f$cvtime("+0-00:00:30.00")
$loop:
$ if f$cvtime() .lts. until then goto loop
$ write sys$output "VMSSH-SLOW-END"
EOS
fails=0
check() {  # check <name> <condition...>
    local name=$1; shift
    if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fails=$((fails + 1)); fi
}

rc=0; PATH=$tmp/drop:$PATH "$vms" "$node" run "$tmp/vmssh_slow.com" > "$tmp/1.out" 2> "$tmp/1.err" || rc=$?
check "1 ssh ends early: status 0" [ $rc = 0 ]
check "1 ssh ends early: the log is printed" grep -q VMSSH-SLOW-END "$tmp/1.out"
check "1 ssh ends early: waited, no retry" \
    sh -c "grep -q 'still runs there' '$tmp/1.err' && ! grep -q 'no session' '$tmp/1.err'"

rc=0; PATH=$tmp/none:$PATH "$vms" "$node" dcl 'show time' > "$tmp/2.out" 2> "$tmp/2.err" || rc=$?
check "2 no session: status 1" [ $rc = 1 ]
check "2 no session: one retry, then reported" \
    [ "$(grep -c 'no session started' "$tmp/2.err")" = 2 ]

rc=0; VMS_TIMEOUT=10 "$vms" "$node" run "$tmp/vmssh_slow.com" > "$tmp/3.out" 2> "$tmp/3.err" || rc=$?
check "3 timeout: status 1, reported" sh -c "[ $rc = 1 ] && grep -q 'timed out' '$tmp/3.err'"
log=$(sed -n 's/.*its log is .*\]\([^ ]*\)\.LOG.*/\1/p' "$tmp/3.err")
check "3 timeout: names the log" [ -n "$log" ]
sleep 35
if [ -n "$log" ]; then
    "$vms" "$node" dcl "directory/nohead/notrail ${log}.*" > "$tmp/3.dir" 2>&1 || true
    check "3 timeout: the procedure finished (.DONE)" grep -qi "${log}\.DONE" "$tmp/3.dir"
    "$vms" "$node" dcl "delete/nolog ${log}.*;*" > /dev/null 2>&1 || true
fi
"$vms" "$node" dcl "delete/nolog vmssh_slow.com;*" > /dev/null 2>&1 || true

echo "vmssh_test: $fails failed"
[ $fails = 0 ]
