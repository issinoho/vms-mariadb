#!/usr/bin/env bash
# vms.sh - run things on the VMS build nodes listed in tools/nodes.conf.
#
#   vms.sh <node> put    <local-file>... [-- <subdir>]  upload files (to workdir or workdir/subdir)
#   vms.sh <node> putdir <local-dir> <subdir>           upload every file in a directory (flat)
#   vms.sh <node> get    <remote-relpath> <local-file>  download a file relative to the workdir
#   vms.sh <node> dcl    '<dcl command>'                run one DCL command, print its output
#   vms.sh <node> run    <local.com> [params...]        upload + run a procedure interactively
#   vms.sh <node> batch  <local.com> [params...]        upload + SUBMIT, wait for the log, print it
#
# Output from `ssh host <cmd>` is unreliable on these nodes, so everything runs
# with /OUTPUT (or a batch log) into the workdir and the log is fetched by sftp.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
. "$here/hostenv.sh"
conf=$here/nodes.conf
key=${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}

usage() { sed -n '2,12p' "$0" >&2; exit 2; }
[ $# -ge 2 ] || usage
node=$1 op=$2; shift 2

# (the trailing _ takes the optional 8th column, the PCRE2 tree)
read -r _ ARCH HOST PORT USER WORKDIR SFTPDIR _ < <(awk -v n="$node" '$1==n' "$conf") || true
[ -n "${HOST:-}" ] || { echo "vms.sh: unknown node '$node' (see $conf)" >&2; exit 2; }

ssh_opts=(-i "$key" -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30)

# A failure is reported, never silent: under set -e and pipefail a bare call
# used to end vms.sh with status 1 and no message (a user's builds, 2026-10-13).
sftp_batch() {  # sftp_batch <commands...>
    local rc=0
    printf '%s\n' "$@" | sftp -P "$PORT" "${ssh_opts[@]}" -b - "$USER@$HOST" 2>&1 >/dev/null |
        { grep -vE '^ *Welcome to|^ *$' >&2 || true; } || rc=$?
    [ "$rc" -eq 0 ] || echo "vms.sh: sftp to $node failed (status $rc): $(printf '%s; ' "$@")" >&2
    return "$rc"
}

# DISK$USER:[USERNAME.VMS_GREP] + sub/dir -> DISK$USER:[USERNAME.VMS_GREP.SUB.DIR]
vms_dir() {
    local sub=${1:-}
    if [ -z "$sub" ]; then echo "$WORKDIR"; return; fi
    echo "${WORKDIR%]}.$(echo "$sub" | tr '/' '.' | tr '[:lower:]' '[:upper:]')]"
}

# Run DCL command(s) with output captured to a log, then print the log.
# The procedure writes <tag>.STARTED as its first act and <tag>.DONE as its
# last; the host waits for DONE rather than for ssh to exit, because the ssh
# session sometimes stays open after the VMS process has finished, and on some
# nodes ends while it still runs (the process carries on without it).  While
# the procedure runs its log is invisible to sftp (not listed, "not a regular
# file"), so only STARTED tells a running procedure from one that never began;
# and its files must stay until DONE: DCL reopens the wrapper when a nested
# procedure returns, and with the file gone it stops with %RMS-E-FNF and
# %RMS-F-ISI (probes/ssh_drop, 2026-10-13).
dcl_logged() {
    local tag=vmsrun_$$_$RANDOM
    local com=$(mktemp) out=$(mktemp) mark=$(mktemp) ssh_err=$(mktemp)
    { echo '$ set noon'
      echo "\$ open/write vmsrun_mark ${WORKDIR}${tag}.STARTED"
      echo '$ close vmsrun_mark'
      echo "\$ set default $WORKDIR"; printf '%s\n' "$@"
      echo '$ write sys$output "VMSRUN-END"'
      echo "\$ open/write vmsrun_mark ${WORKDIR}${tag}.DONE"
      echo '$ close vmsrun_mark'; } > "$com"
    sftp_batch "cd $SFTPDIR" "put $com $tag.com"
    ssh -p "$PORT" "${ssh_opts[@]}" "$USER@$HOST" \
        "@${WORKDIR}${tag}.COM/OUTPUT=${WORKDIR}${tag}.LOG" >/dev/null 2>"$ssh_err" &
    local pid=$! waited=0 limit=${VMS_TIMEOUT:-600} state=running ssh_gone=0
    have() { sftp_batch "cd $SFTPDIR" "get $tag.$1 $mark" 2>/dev/null; }
    while :; do
        sleep 2; waited=$((waited + 2))
        if [ $ssh_gone = 0 ] && ! kill -0 "$pid" 2>/dev/null; then
            ssh_gone=$waited
            # Give a starting procedure a moment to write STARTED.
            have DONE && { state=done; break; }
            sleep 5; waited=$((waited + 5))
            have DONE && { state=done; break; }
            if ! have STARTED; then state=notstarted; break; fi
            echo "vms.sh: the ssh session to $node ended after ${ssh_gone}s; the procedure" \
                 "still runs there: waiting for it${VMS_TIMEOUT:+ (up to ${limit}s)}" >&2
            sed 's/^/vms.sh:   ssh: /' "$ssh_err" | grep -vE 'post-quantum|Welcome to|^vms.sh:   ssh: *$' | tail -3 >&2 || true
        fi
        # Poll every 10 s while ssh is up, every 20 s once it has gone.
        if [ $((waited % (ssh_gone ? 20 : 10))) -lt 2 ] && have DONE; then state=done; break; fi
        [ "$waited" -ge "$limit" ] && { state=timeout; break; }
    done
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
    case $state in
    notstarted)
        # Nothing ran on the node: one retry is safe.
        sftp_batch "cd $SFTPDIR" "-rm $tag.com" >/dev/null 2>&1 || true
        local retried=${VMS_RETRIED:-}
        [ -z "$retried" ] && echo "vms.sh: no session started on $node; retrying once" >&2 ||
            echo "vms.sh: no session started on $node" >&2
        sed 's/^/vms.sh:   ssh: /' "$ssh_err" | grep -vE 'post-quantum|Welcome to|^vms.sh:   ssh: *$' | tail -3 >&2 || true
        rm -f "$com" "$out" "$mark" "$ssh_err"
        [ -n "$retried" ] && return 1
        sleep 15
        VMS_RETRIED=1 dcl_logged "$@"; return ;;
    timeout)
        # It may still be running: leave its files alone (deleting the
        # procedure would stop it at its next return, see above).
        echo "vms.sh: timed out after ${limit}s; the procedure may still be running on $node:" >&2
        echo "vms.sh:   its log is ${WORKDIR}${tag}.LOG (readable when it ends)" >&2
        rm -f "$com" "$out" "$mark" "$ssh_err"
        return 1 ;;
    esac
    # The log is closed only when the process exits, after the DONE marker:
    # fetch until it holds the end line written just before the marker.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        sftp_batch "cd $SFTPDIR" "get $tag.LOG $out" 2>/dev/null &&
            grep -aq '^VMSRUN-END' "$out" && break
        sleep 3
    done
    local rc=0
    if grep -aq '^VMSRUN-END' "$out"; then
        sftp_batch "cd $SFTPDIR" "-rm $tag.com" "-rm $tag.LOG" "-rm $tag.STARTED" "-rm $tag.DONE" || true
    else
        echo "vms.sh: could not read the log ${WORKDIR}${tag}.LOG (left on the node)" >&2; rc=1
    fi
    tr -d '\r' < "$out" | grep -av '^VMSRUN-END' || true
    rm -f "$com" "$out" "$mark" "$ssh_err"
    return $rc
}

case $op in
put)
    files=() sub=
    while [ $# -gt 0 ]; do
        if [ "$1" = -- ]; then sub=$2; break; fi
        files+=("$1"); shift
    done
    cmds=("cd $SFTPDIR")
    [ -n "$sub" ] && cmds+=("-mkdir $sub" "cd $sub")
    for f in "${files[@]}"; do cmds+=("put $f"); done
    sftp_batch "${cmds[@]}"
    ;;
putdir)
    [ $# -eq 2 ] || usage
    sftp_batch "cd $SFTPDIR" "-mkdir $2" "cd $2" "lcd $1" "mput *"
    ;;
get)
    [ $# -eq 2 ] || usage
    sftp_batch "cd $SFTPDIR" "get $1 $2"
    ;;
dcl)
    [ $# -ge 1 ] || usage
    cmds=()
    for c in "$@"; do cmds+=("\$ $c"); done
    dcl_logged "${cmds[@]}"
    ;;
run)
    [ $# -ge 1 ] || usage
    com=$1; shift
    sftp_batch "cd $SFTPDIR" "put $com"
    params=""
    for p in "$@"; do params+=" \"$p\""; done
    dcl_logged "\$ @${WORKDIR}$(basename "$com")$params"
    ;;
batch)
    [ $# -ge 1 ] || usage
    com=$1; shift
    name=$(basename "$com" .com)
    log=${name}_batch.log
    sftp_batch "cd $SFTPDIR" "put $com" "-rm $log"
    plist=""
    for p in "$@"; do plist+="${plist:+,}\"$p\""; done
    dcl_logged "\$ submit/noprint/log_file=${WORKDIR}${log}${plist:+/parameters=($plist)} ${WORKDIR}$(basename "$com")" >&2
    # The log is held open by the batch job until it ends; sftp cannot read it until then.
    out=$(mktemp)
    for _ in $(seq 1 ${VMS_BATCH_POLLS:-360}); do
        if sftp_batch "cd $SFTPDIR" "get $log $out" 2>/dev/null && [ -s "$out" ]; then
            tr -d '\r' < "$out"; rm -f "$out"; exit 0
        fi
        sleep ${VMS_BATCH_POLL_SECS:-20}
    done
    echo "vms.sh: timed out waiting for batch log $log" >&2; rm -f "$out"; exit 1
    ;;
*) usage ;;
esac
