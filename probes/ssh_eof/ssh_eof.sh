#!/usr/bin/env bash
# ssh_eof.sh [node...] - does an exec command run when the client sends EOF at
# once (ssh -n)? Runs `ssh -n <node> 'show time'` RUNS times per node and
# classifies each session by what came back and how it ended:
#
#   ok        output arrived and the session ended by itself
#   empty     the session ended by itself with no output: the command was lost
#             (V9.9-2A's symptom per the report below)
#   out+hung  output arrived, but the session stayed open until we killed it
#   hung      no output, and the session stayed open until we killed it
#   connfail  ssh exited 255 with no output (no session at all)
#
# Why: a user's report for VSI (2026-11) traces this to sshd deleting the
# command's pseudo-terminal on client EOF. On V9.9-2A the session usually ends
# at once and the command never runs; on V9.9-2C the session is said to stay
# open instead, and whether the command runs there was untested. Our IA64 node
# (V9.9-2C) lost commands to vms.sh's </dev/null runs in October, so this
# counts the outcomes per node rather than inferring them.
#
# Nodes come from tools/nodes.conf (NODES_CONF overrides; this repository has
# no alpha line, so for AXPBOX use e.g.
#   NODES_CONF=~/projects/vms-lighttpd/tools/nodes.conf ssh_eof.sh alpha
# Nodes run one after another, never together, so one node's load does not
# colour another's timings.
#
# Settings (environment):
#   RUNS=50     sessions per node
#   LIMIT=30    seconds before a session is called hung and killed; a login on
#               the Alpha can take well over 10 s, so do not cut this much lower
#   GAP=2       seconds between sessions (the report says the first command
#               after a quiet period fails more often; raise this to test that)
#   MODE=n      n: ssh -n (EOF at once). open: stdin held open for LIMIT-2 s and
#               then closed, as a control that should never lose the command
#
# Writes one line per session to ssh_eof-<node>-<time>.tsv in the current
# directory and prints a summary per node. It changes nothing on the node; a
# killed session is ended from our side only.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd); top=$here/../..
conf=${NODES_CONF:-$top/tools/nodes.conf}
key=${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}
RUNS=${RUNS:-50} LIMIT=${LIMIT:-30} GAP=${GAP:-2} MODE=${MODE:-n}
case $MODE in n|open) ;; *) echo "ssh_eof.sh: MODE must be n or open" >&2; exit 2 ;; esac
[ $# -gt 0 ] || set -- $(awk '!/^#/ && NF { print $1 }' "$conf")
o=(-i "$key" -o BatchMode=yes -o ConnectTimeout=60)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

one() {  # one <host> <port> <user> -> prints "class rc secs lastline"
    local host=$1 port=$2 user=$3 t0 t1 rc out cls
    t0=$(date +%s.%N)
    if [ "$MODE" = n ]; then
        timeout -k 5 "$LIMIT" ssh -n -p "$port" "${o[@]}" "$user@$host" 'show time' \
            >"$tmp/out" 2>"$tmp/err"
    else
        # stdin from sleep, closed when it ends: EOF after LIMIT-2 s. A process
        # substitution, not a pipe, so the run does not wait for sleep when ssh
        # ends sooner and the time measured is ssh's own.
        timeout -k 5 "$LIMIT" ssh -p "$port" "${o[@]}" "$user@$host" 'show time' \
            < <(sleep $((LIMIT - 2))) >"$tmp/out" 2>"$tmp/err"
    fi
    rc=$?
    t1=$(date +%s.%N)
    # SHOW TIME prints e.g. "  21-NOV-2026 14:03:07"
    if grep -qE '[0-9]{1,2}-[A-Z]{3}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}' "$tmp/out"; then out=1; else out=0; fi
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        [ "$out" = 1 ] && cls=out+hung || cls=hung
    elif [ "$out" = 1 ]; then cls=ok
    elif [ "$rc" -eq 255 ]; then cls=connfail
    else cls=empty
    fi
    local last; last=$(tr -d '\r' < "$tmp/err" | grep -v '^ *$' | tail -1)
    LC_ALL=C printf '%s\t%s\t%.1f\t%s\n' "$cls" "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN { print b - a }')" "${last:--}"
}

for node in "$@"; do
    read -r _ arch host port user _ < <(awk -v n="$node" '$1==n' "$conf") || true
    if [ -z "${host:-}" ]; then echo "ssh_eof.sh: unknown node '$node' (see $conf)" >&2; continue; fi
    tsv=ssh_eof-$node-$(date +%Y%m%d-%H%M%S).tsv
    printf '# node=%s arch=%s mode=%s runs=%s limit=%s gap=%s start=%s\n' \
        "$node" "$arch" "$MODE" "$RUNS" "$LIMIT" "$GAP" "$(date -u +%FT%TZ)" > "$tsv"
    printf 'run\tutc\tclass\trc\tsecs\tstderr\n' >> "$tsv"
    echo "== $node ($arch): $RUNS sessions, MODE=$MODE, LIMIT=${LIMIT}s, GAP=${GAP}s -> $tsv"
    for i in $(seq 1 "$RUNS"); do
        printf '%s\t%s\t%s\n' "$i" "$(date -u +%T)" "$(one "$host" "$port" "$user")" >> "$tsv"
        printf '\r   %d/%d  %s' "$i" "$RUNS" "$(tail -1 "$tsv" | cut -f3)   "
        [ "$i" -lt "$RUNS" ] && sleep "$GAP"
    done
    echo
    awk -F'\t' 'NR > 2 { n[$3]++; s[$3] += $5; t++ }
        END { for (c in n) printf "   %-9s %3d / %d   mean %.1f s\n", c, n[c], t, s[c] / n[c] }' "$tsv" | sort
done
