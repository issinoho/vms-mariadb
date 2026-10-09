#!/usr/bin/env bash
# replay.sh <node> <config> - answer a host CMake run's platform checks on a VMS node.
#
# 1. replay_gen.py turns the checks cache/cmake-<config>/ ran (all of which the
#    current answers did not cover) into cache/replay-<config>/.
# 2. The pack is uploaded to [.REPLAY_<config>] and VMS_REPLAY.COM compiles,
#    links and runs each check there with clang.
# 3. replay_answers.py merges the results into overlay/vms/config/answers.txt,
#    from which overlay/cmake/os/OpenVMSCache.cmake is generated.
# Run tools/prepare.sh + tools/host_configure.sh <config> afterwards, and repeat
# until replay_gen.py finds nothing new.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
node=${1:?usage: replay.sh <node> <config>}
cfg=${2:?usage: replay.sh <node> <config>}
bdir=$top/cache/cmake-$cfg
pack=$top/cache/replay-$cfg
answers=$top/overlay/vms/config/answers.txt

rm -rf "$pack"
# REPLAY_ALL=1 replays every check again, not only the unanswered ones.
python3 "$top/tools/replay_gen.py" "$bdir" "$pack" "$([ "${REPLAY_ALL:-}" = 1 ] && echo /dev/null || echo "$answers")"
if [ "$(grep -c . "$pack/manifest.txt" || true)" -eq 0 ]; then
    python3 "$top/tools/replay_answers.py" "$answers" "$pack/policy.txt" /dev/null "$pack/manifest.txt"
    echo "replay: nothing to replay"; exit 0
fi
cp "$top/tools/vms_replay.com" "$pack/"
sub=replay_$cfg
"$top/tools/vms.sh" "$node" dcl "if f\$search(\"$sub.dir\") .eqs. \"\" then create/directory [.$sub]" >/dev/null
"$top/tools/vms.sh" "$node" dcl "if f\$search(\"[.$sub]*.*\") .nes. \"\" then delete/nolog [.$sub]*.*;*" >/dev/null
( cd "$pack" && "$top/tools/vms.sh" "$node" put * -- "$sub" )

read -r _ _ HOST _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
job=$top/cache/replay-$node-$cfg.com
printf '$ set noon\n$ @%s.%s]VMS_REPLAY.COM\n' "${WORKDIR%]}" "$(echo "$sub" | tr a-z A-Z)" > "$job"
results=$top/out/replay-$node-$cfg.txt
mkdir -p "$top/out"
VMS_TIMEOUT=${VMS_TIMEOUT:-7200} "$top/tools/vms.sh" "$node" run "$job" |
    sed -e "s/$HOST/<$node-host>/g" > "$results"
grep -q REPLAY-DONE "$results" || { echo "replay: incomplete results in $results" >&2; exit 1; }
python3 "$top/tools/replay_answers.py" "$answers" "$pack/policy.txt" "$results" "$pack/manifest.txt"
