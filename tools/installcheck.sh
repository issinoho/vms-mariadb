#!/usr/bin/env bash
# installcheck.sh [node] - install the VMSMARIADB kit on the x86-64 node (default
# x86), create a data directory and start a server from it (port 3308), query
# it with the installed clients, stop it; then (unless SVC=0) configure the
# service with a temporary account MDBSVCT [361,1] (port 3309), start it
# through the boot job, check it, shut it down and remove the account; then
# remove the kit and the scratch data directories.  CONFIGURE_TTY=1 runs
# configure interactively in a terminal session (tools/configure_tty.py).  Changes the system while
# it runs (PCSI database, SYS$COMMON:[VMSMARIADB], VMSMARIADB$ROOT, the
# temporary account); run kit.sh first.  Ask first.
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
# has <phase> <pattern> [timeout]: run a phase (output to the log) and test
# its output.  Not "phase | grep -q": grep stops at the first match, tee then
# dies of SIGPIPE, and with pipefail the test fails although the text was there.
has() {
    local out
    out=$(phase "$1" "${3:-1800}" || true)
    grep -q -- "$2" <<< "$out"
}
phase() {
    local job=$top/cache/installcheck-$node-${1// /_}.com
    printf '$ set noon\n$ set default %s\n$ @%sVMS_INSTALLCHECK.COM %s %s\n' \
        "$WORKDIR" "$WORKDIR" "$REMOTE" "$1" > "$job"
    VMS_TIMEOUT=${2:-1800} "$top/tools/vms.sh" "$node" run "$job" 2>&1 | tee -a "$log"
}
phase INSTALL > /dev/null
up=0
for _ in $(seq 1 30); do
    has STATUS INSTALLCHECK_UP 120 && { up=1; break; }
    sleep 10
done
echo "server up: $up" | tee -a "$log"
[ $up = 1 ] && phase QUERY > /dev/null
# mariadb-admin's exit status says nothing (it returns from main(): PORTING_LOG),
# so wait for the process itself; never remove the kit under a running server.
gone() {  # gone <port>
    for _ in $(seq 1 60); do
        has "PROCESS $1" INSTALLCHECK_GONE 120 && return 0
        sleep 10
    done
    echo "installcheck: MARIADBD_$1 still running; stopping here (kit left installed)" | tee -a "$log" >&2
    exit 1
}
gone 3308
# The service: configure (test account MDBSVCT), start through the boot job,
# check, shut down as SYSHUTDWN would, remove the account and its data.
svc=0
if [ "${SVC:-1}" = 1 ]; then
    svc=1
    up=0
    if [ "${CONFIGURE_TTY:-0}" = 1 ]; then
        # configure as an administrator runs it: in a terminal, answering prompts
        configured() {
            local out
            out=$(TTY_ROOTPW="Svc'Chk\"pw%1" python3 "$top/tools/configure_tty.py" "$node" \
                "${WORKDIR%]}.SVCTEST.DATA]" 3309 MDBSVCT "[361,1]" 2>&1 || true)
            printf '%s\n' "$out" >> "$log"
            grep -q 'CONFIGURE_TTY: PASS' <<< "$out"
        }
    else
        configured() { has SVC_CONFIGURE 'VMSMARIADB\$CONFIGURE: wrote'; }
    fi
    if configured; then
        phase SVC_START > /dev/null
        for _ in $(seq 1 30); do
            has SVC_STATUS INSTALLCHECK_SVC_UP 120 && { up=1; break; }
            sleep 10
        done
        echo "service up: $up" | tee -a "$log"
        [ $up = 1 ] && phase SVC_QUERY > /dev/null
        phase SVC_SHUTDOWN > /dev/null
        gone 3309     # stops here, account and kit left, if it never exits
    else
        echo "service up: $up (configure failed)" | tee -a "$log"
    fi
    phase SVC_CLEANUP > /dev/null
fi
phase REMOVE > /dev/null
grep -aE '=== .* status|VMSMARIADB\$(CONFIGURE|STARTUP|SHUTDOWN)|server process|service up|after cleanup|startup procedure|VMSMARIADB\$ROOT|server image|english messages|charsets index|INSTALLCHECK_|INSTALL_DB|VMSMARIADB\$SERVER:|ERROR|^11\.|kitrows|after removal|after cleanup|items found|server up' "$log"
ok=1
for check in CLIENT_VERSION DUMP; do grep -aq "INSTALLCHECK_$check: PASS" "$log" || { echo "installcheck: $check did not pass" >&2; ok=0; }; done
grep -aq 'INSTALLCHECK_ROWS: 2' "$log" || { echo "installcheck: row check failed" >&2; ok=0; }
grep -aq 'ERROR 1054' "$log" || { echo "installcheck: no error message text from the server" >&2; ok=0; }
grep -aq 'VMSMARIADB\$ROOT after removal: \[\]' "$log" && grep -aq 'files after removal: \[\]' "$log" &&
    grep -aq 'startup after removal: \[\]' "$log" || { echo "installcheck: removal incomplete" >&2; ok=0; }
if [ $svc = 1 ]; then
    for check in SVC_IDENTITY SVC_ROOTPW SVC_CLEAN_STOP; do
        grep -aq "INSTALLCHECK_$check: PASS" "$log" || { echo "installcheck: $check did not pass" >&2; ok=0; }
    done
    grep -aq "Access denied for user 'root'@'localhost' (using password: NO)" "$log" ||
        { echo "installcheck: root without a password was not refused" >&2; ok=0; }
    grep -aq "SELECT command denied to user 'vmsmariadb_shutdown'" "$log" ||
        { echo "installcheck: the shutdown account could read mysql.user" >&2; ok=0; }
    [ "${CONFIGURE_TTY:-0}" = 1 ] && { grep -aq 'CONFIGURE_TTY: PASS' "$log" ||
        { echo "installcheck: interactive configure did not pass" >&2; ok=0; }; }
    grep -aq 'MARIADBD_3309 is already running' "$log" || { echo "installcheck: second START not refused" >&2; ok=0; }
    grep -aq 'account after cleanup: \[0\]' "$log" && grep -aq 'svctest after cleanup: \[\]' "$log" ||
        { echo "installcheck: service cleanup incomplete" >&2; ok=0; }
fi
[ $ok = 1 ] && echo "INSTALLCHECK: PASS" || { echo "INSTALLCHECK: FAIL"; exit 1; }
