#!/usr/bin/env bash
# recon.sh <node> - run tools/vms_recon.com on <node> (read-only) and save the
# output as docs/env-<node>.txt, with the node name and address left out.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: recon.sh <node>}
read -r _ _ HOST _ _ _ _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
out=$top/docs/env-$node.txt
VMS_TIMEOUT=900 "$top/tools/vms.sh" "$node" run "$top/tools/vms_recon.com" |
    sed -e "s/$HOST/<$node-host>/g" > "$out"
grep -q RECON-DONE "$out" || { echo "recon: incomplete output in $out" >&2; exit 1; }
echo "recon: $out"
