#!/usr/bin/env bash
# kit.sh [node] - build the VMSMARIADB PCSI kit on the x86-64 node (default
# x86) and fetch it to out/kits/.  Builds the client and server
# configurations first (build.sh, incremental), so the kit matches the pushed
# tree; run tools/prepare.sh after any change to patches/ or overlay/.
# Logs: out/build-<node>-<config>.log, out/kit-<node>.log.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:-x86}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _)
REMOTE=$(echo "$remote" | tr a-z A-Z)
read -r _ ARCH _ _ _ WORKDIR _ _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
[ "$ARCH" = X86_64 ] || { echo "kit: the kit is x86-64 only ($node is $ARCH)" >&2; exit 2; }
[ -f "$top/staging/$UPSTREAM_NAME-$UPSTREAM_VERSION/vms/kit/kit.env" ] ||
    { echo "kit: no kit inputs in staging/ (run tools/prepare.sh)" >&2; exit 1; }
mkdir -p "$top/out/kits"

for cfg in client server; do
    "$top/tools/build.sh" "$node" "$cfg" > /dev/null 2>&1 ||
        { tail -20 "$top/out/build-$node-$cfg.log"; echo "kit: $cfg build failed" >&2; exit 1; }
done

job=$top/cache/kit-$node.com
printf '$ set noon\n$ define sys$error sys$output\n$ @%s.%s.VMS.KIT]MAKE_KIT.COM\n' \
    "${WORKDIR%]}" "$REMOTE" > "$job"
VMS_TIMEOUT=3600 "$top/tools/vms.sh" "$node" run "$job" > "$top/out/kit-$node.log" 2>&1 || true
grep -a 'MAKE_KIT\|%PCSI-[EFW]\|-E-\|-F-' "$top/out/kit-$node.log" || true
for kit in $(sed -n 's/^MAKE_KIT: .*kit .*\]\([^;]*\);.*/\1/p' "$top/out/kit-$node.log"); do
    "$top/tools/vms.sh" "$node" get "$remote/KIT_$ARCH/$kit" "$top/out/kits/$kit"
    ls -la "$top/out/kits/$kit"
done
ls "$top"/out/kits/*VMSMARIADB* > /dev/null 2>&1 ||
    { echo "kit: no kit produced (see out/kit-$node.log)" >&2; exit 1; }
