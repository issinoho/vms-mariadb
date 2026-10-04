#!/usr/bin/env bash
# build.sh <node> <config> [target] [KEEP_GOING] - push the prepared tree and
# run @[.VMS]BUILD <config> on <node>.  The log is printed and saved to
# out/build-<node>-<config>.log.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: build.sh <node> <config> [target] [KEEP_GOING]}
cfg=${2:?usage: build.sh <node> <config> [target] [KEEP_GOING]}
target=${3:-ALL}
keep=${4:-}
. "$top/upstream.conf"
remote=$(echo "$UPSTREAM_NAME-$UPSTREAM_VERSION" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")

"$top/tools/push.sh" "$node" "$cfg"
mkdir -p "$top/out"
job=$top/cache/build-$node-$cfg.com
printf '$ set noon\n$ purge/nolog %s.%s...]*.*\n$ @%s.%s.VMS]BUILD.COM %s %s %s\n' \
    "${WORKDIR%]}" "$remote" "${WORKDIR%]}" "$remote" "$cfg" "$target" "$keep" > "$job"
log=$top/out/build-$node-$cfg.log
VMS_TIMEOUT=${VMS_BUILD_TIMEOUT:-14400} "$top/tools/vms.sh" "$node" run "$job" | tee "$log"
grep -q 'BUILD: done' "$log" || { echo "build: failed (see $log)" >&2; exit 1; }
if grep -aE '%CXX-[EF]-|%MMS-F-|%ILINK-[EWF]-|%LIBRAR-[EF]-|%DCL-[WEF]-' "$log" >&2; then
    echo "build: errors in $log" >&2; exit 1
fi
