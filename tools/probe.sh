#!/usr/bin/env bash
# probe.sh <node> [CLANG|CC] - Phase 0 platform probes.
#
# Generates one tiny C file per header in probes/headers.list (H_), and two per
# function in probes/functions.list: CMake's CHECK_FUNCTION_EXISTS form with no
# header (F_) and a declared-by-a-header form (G_).  Uploads them with the
# hand-written probes to [.MARIADB_PROBE] and runs tools/vms_probe.com there.
# Output: docs/probes-<node>-<compiler>.txt (raw) - summarised in docs/PHASE0.md.
# PROBE_SETS (default HFGRC: Headers, F_, G_, Runtime, C++) limits the run; a partial
# run writes docs/probes-<node>-<compiler>-<sets>.txt.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: probe.sh <node> [CLANG|CC]}
mode=${2:-CC}
sets=${PROBE_SETS:-HFGRC}
gen=$top/cache/probe-src-$node
rm -rf "$gen"; mkdir -p "$gen"

lists() { grep -v '^#' "$top/probes/$1" | grep .; }

# Headers that are on every VMS node; G_ files include these, plus
# (with clang) anything else from headers.list that __has_include finds.
base_headers="stdio.h stdlib.h string.h strings.h unistd.h fcntl.h time.h signal.h
pthread.h netdb.h errno.h sys/time.h sys/types.h sys/stat.h sys/socket.h
sys/resource.h sys/mman.h sys/times.h sys/utsname.h netinet/in.h arpa/inet.h
dirent.h pwd.h grp.h locale.h langinfo.h stdarg.h poll.h termios.h
sys/ioctl.h sys/file.h sys/statvfs.h sys/wait.h"

while read -r h; do
    n=h_$(echo "$h" | tr '/.' '__')
    printf '#include <%s>\nint main(void) { return 0; }\n' "$h" > "$gen/$n.c"
done < <(lists headers.list)

{
    # VSI C has no __has_include and errors on it even after a false ||, so
    # it gets the fixed base list; clang gets everything __has_include finds.
    echo '#ifdef __has_include'
    while read -r h; do
        printf '#if __has_include(<%s>)\n#include <%s>\n#endif\n' "$h" "$h"
    # <varargs.h> passes __has_include but #errors under clang on purpose.
    done < <({ printf '%s\n' $base_headers; lists headers.list; } | grep -vx varargs.h | sort -u)
    echo '#else'
    for h in $base_headers; do printf '#include <%s>\n' "$h"; done
    echo '#endif'
} > "$gen/probe_hdrs.h"

while read -r f; do
    printf '#ifdef __cplusplus\nextern "C"\n#endif\nchar %s(void);\nint main(void) { return %s(); }\n' "$f" "$f" > "$gen/f_$f.c"
    printf '#include "probe_hdrs.h"\nint main(void) { void *p = (void *) &%s; return p == 0; }\n' "$f" > "$gen/g_$f.c"
done < <(lists functions.list)

cp "$top"/probes/*.c "$top"/probes/*.cpp "$top/tools/vms_probe.com" "$gen/"
nfiles=$(ls "$gen" | wc -l)
echo "probe: uploading $nfiles files to $node"
"$top/tools/vms.sh" "$node" dcl 'if f$search("mariadb_probe.dir") .eqs. "" then create/directory [.mariadb_probe]' >/dev/null
( cd "$gen" && "$top/tools/vms.sh" "$node" put * -- mariadb_probe )

read -r _ _ HOST _ _ WORKDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
job=$top/cache/probe-$node.com
printf '$ set noon\n$ @%s.MARIADB_PROBE]VMS_PROBE.COM %s %s\n' "${WORKDIR%]}" "$mode" "$sets" > "$job"
out=$top/docs/probes-$node-$(echo "$mode" | tr A-Z a-z)$([ "$sets" = HFGRC ] || echo "-$sets").txt
VMS_TIMEOUT=${VMS_TIMEOUT:-5400} "$top/tools/vms.sh" "$node" run "$job" |
    sed -e "s/$HOST/<$node-host>/g" > "$out"
grep -q PROBE-DONE "$out" || { echo "probe: incomplete output in $out" >&2; exit 1; }
echo "probe: $out"
