#!/usr/bin/env bash
# server.sh <node> start|stop|status|log [datadir-name] [port]
#   start   run @[.VMS]SERVER as a detached process (RUN/DETACHED/AUTHORIZE LOGINOUT: the
#           UAF quotas; without /AUTHORIZE it gets the small PQL_D* defaults),
#           output in [.<datadir>]SERVER.LOG, errors in [.<datadir>]MARIADBD.ERR
#   stop    mariadb-admin shutdown (as root, no password, over TCP)
#   status  mariadb-admin ping and the process list
#   log     print the server's error log
# datadir-name defaults to DATA (tools/install_db.sh), port to 3307.
# EXTRA='--option=value' (start): one more mariadbd option.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: server.sh <node> start|stop|status|log [datadir-name] [port]}
op=${2:?usage: server.sh <node> start|stop|status|log [datadir-name] [port]}
dname=${3:-DATA}
port=${4:-3307}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
tree=${WORKDIR%]}.$remote
data=${WORKDIR%]}.$dname]
job=$top/cache/server-$node-$op.com
admin='$ madmin :== $'"$tree"'.VMSOBJ]MARIADB-ADMIN.EXE'
case $op in
start)
    "$top/tools/push.sh" "$node" server >/dev/null
    cat > "$job" <<DCL
\$ set noon
\$ open/write o ${data}SERVER_START.COM
\$ write o "\$ @${tree}.VMS]SERVER.COM ${data} $port SERVER ${EXTRA:-}"
\$ close o
\$ run/detached/process_name="MARIADBD_$port"/input=${data}SERVER_START.COM -
    /output=${data}SERVER.LOG/error=${data}SERVER.LOG/authorize SYS\$SYSTEM:LOGINOUT.EXE
\$ write sys\$output "SERVER-STARTED ", \$status
DCL
    ;;
stop)
    printf '$ set noon\n%s\n$ madmin "--no-defaults" "--host=127.0.0.1" "--port=%s" "--user=root" "shutdown"\n$ write sys$output "SERVER-STOP ", $status\n' "$admin" "$port" > "$job" ;;
status)
    printf '$ set noon\n%s\n$ madmin "--no-defaults" "--host=127.0.0.1" "--port=%s" "--user=root" "ping"\n$ show system/process=MARIADBD*\n' "$admin" "$port" > "$job" ;;
log)
    printf '$ set noon\n$ type %sMARIADBD.ERR\n$ type %sSERVER.LOG\n' "$data" "$data" > "$job" ;;
*) echo "server.sh: unknown operation $op" >&2; exit 2 ;;
esac
VMS_TIMEOUT=${VMS_TIMEOUT:-600} "$top/tools/vms.sh" "$node" run "$job"
