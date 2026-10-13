#!/usr/bin/env bash
# ssh_drop.sh <node> - what happens when the ssh session ends while the procedure
# it started still runs (a user's node, 2026-10-13): is the /OUTPUT log readable
# or listable by sftp, can sftp delete the running procedure, and what then?
# x86 E9.2-4: the process runs on; its log is neither listed nor readable ("not a
# regular file"); rm of the running procedure succeeds, and when inner.com returns
# DCL stops with %RMS-E-FNF and %RMS-F-ISI (no OUTER-AFTER-INNER, no marker).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd); top=$here/../..
node=${1:?usage: ssh_drop.sh <node>}
read -r _ _ HOST PORT USER WORKDIR SFTPDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
key=${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}
o=(-i "$key" -o BatchMode=yes)
sf() { printf '%s\n' "cd $SFTPDIR" "$@" | sftp -P "$PORT" "${o[@]}" -b - "$USER@$HOST" 2>&1 | grep -v "^sftp> cd" || true; }
sf "-rm sd_outer.done" "-rm sd_outer.log" "put $here/outer.com sd_outer.com" "put $here/inner.com inner.com" >/dev/null
ssh -p "$PORT" "${o[@]}" "$USER@$HOST" "@${WORKDIR}sd_outer.com/output=${WORKDIR}sd_outer.log" >/dev/null 2>&1 & pid=$!
sleep 8; kill "$pid"; wait "$pid" 2>/dev/null || true
echo "== ssh killed after 8 s; ls"; sf "ls -l sd_outer*"
echo "== get the log"; sf "get sd_outer.log /dev/null" || true
echo "== rm the running procedure"; sf "rm sd_outer.com" || true
echo "== ls"; sf "ls -l sd_outer*"
sleep 50
echo "== after 58 s: ls, log"; sf "ls -l sd_outer* outer*"
log=$(mktemp); sf "get sd_outer.log $log" >/dev/null || true; tr -d '\r' < "$log"; rm -f "$log"
sf "-rm sd_outer.log" "-rm sd_outer.done" "-rm inner.com" >/dev/null
