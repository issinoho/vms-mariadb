#!/usr/bin/env bash
# build.sh <node> <config> [target] [KEEP_GOING] - push the prepared tree and
# run @[.VMS]BUILD <config> on <node>.  The log is printed and saved to
# out/build-<node>-<config>.log.
#
# JOBS=n (target ALL): build the library targets in n MMS runs at once, one
# ssh session each, split by estimated compile cost (vms/build/<config>/TARGETS.TXT),
# then link the images in a final ALL run.  The host does the waiting: DCL's
# WAIT hangs in sessions started over ssh.  Logs: ...-part<k>.log.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: build.sh <node> <config> [target] [KEEP_GOING]}
cfg=${2:?usage: build.sh <node> <config> [target] [KEEP_GOING]}
target=${3:-ALL}
keep=${4:-}
jobs=${JOBS:-1}
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
remote=$(echo "$name" | tr . _ | tr a-z A-Z)
read -r _ _ _ _ _ WORKDIR _ PCRE2ROOT < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
if [ "$(echo "$cfg" | tr A-Z a-z)" = server ] && [ -z "${PCRE2ROOT:-}" ]; then
    echo "build.sh: the server needs PCRE2: add vms-pcre2's clang install tree as the" >&2
    echo "  8th column of $node in tools/nodes.conf: dev:[dir.INSTALL_X86_64_CLANG.]" >&2
    exit 1
fi

"$top/tools/push.sh" "$node" "$cfg"
mkdir -p "$top/out"
log=$top/out/build-$node-$cfg.log

# One build run: <job file tag> <MMS target(s)> <log file>
run_build() {
    local tag=$1 tgt=$2 out=$3
    local job=$top/cache/build-$node-$cfg-$tag.com
    # Optional 8th nodes.conf column: the PCRE2 install tree as a rooted device
    # spec (dev:[dir.INSTALL_X86_64_CLANG.]), defined as PCRE2$ROOT for the build.
    printf '$ set noon\n$ @%s.%s.VMS]BUILD.COM %s "%s" "%s" "%s"\n' \
        "${WORKDIR%]}" "$remote" "$cfg" "$tgt" "$keep" "${PCRE2ROOT:-}" > "$job"
    # Under set -e a failing vms.sh would end this script with nothing said:
    # report it and carry on, so the log (if any) is still shown below.
    VMS_TIMEOUT=${VMS_BUILD_TIMEOUT:-28800} "$top/tools/vms.sh" "$node" run "$job" > "$out" ||
        echo "build: vms.sh run on $node ended with status $? ($tag)" >&2
}

purge=$top/cache/purge-$node.com
printf '$ set noon\n$ purge/nolog %s.%s...]*.*\n' "${WORKDIR%]}" "$remote" > "$purge"
"$top/tools/vms.sh" "$node" run "$purge" >/dev/null ||
    echo "build: purge on $node failed; building anyway" >&2

logs=()
# Nothing is printed until the node finishes, which can take hours: say so.
echo "build: $cfg $target running on $node; its log is shown when it ends (live on the node: ${WORKDIR}VMSRUN_*.LOG)"
if [ "$jobs" -gt 1 ] && [ "$target" = ALL ]; then
    targets=$top/staging/$name/vms/build/$cfg/TARGETS.TXT
    # Greedy split, biggest targets first, each to the lightest group.
    mapfile -t groups < <(sort -k2,2nr "$targets" | awk -v n="$jobs" '
        { best=1; for (i=2; i<=n; i++) if (load[i] < load[best]) best=i
          load[best]+=$2; g[best]=g[best] (g[best]==""?"":",") $1 }
        END { for (i=1; i<=n; i++) if (g[i] != "") print g[i] }')
    echo "build: $jobs parallel runs: ${#groups[@]} groups"
    pids=()
    for k in "${!groups[@]}"; do
        part=$top/out/build-$node-$cfg-part$((k+1)).log
        logs+=("$part")
        run_build "part$((k+1))" "${groups[$k]}" "$part" & pids+=($!)
    done
    for p in "${pids[@]}"; do wait "$p" || true; done
    echo "build: parallel library runs done; linking"
fi
run_build all "$target" "$log"
logs+=("$log")
cat "$log"
grep -q 'BUILD: done' "$log" || { echo "build: failed (see $log)" >&2; exit 1; }
# %LIBRAR-I-EMPTYFILE: an empty object (a compile killed half-way) went into a
# library; MMS will think it is up to date.  Delete it and build again.
if grep -aE '%CXX-[EF]-|%MMS-F-|%ILINK-[EWF]-|%LIBRAR-[EF]-|%LIBRAR-I-EMPTYFILE|%DCL-[WEF]-' "${logs[@]}" >&2; then
    echo "build: errors in ${logs[*]}" >&2; exit 1
fi
