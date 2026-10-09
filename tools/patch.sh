#!/usr/bin/env bash
# patch.sh - make a patch in patches/ the way the sibling ports do.
#
#   patch.sh start <file>...      copy the files, as staging/ has them now (after
#                                 the earlier patches), to cache/patchwork/a and b
#   (edit cache/patchwork/b/<file>...)
#   patch.sh finish <NNNN-name> "<Subject>" "<explanation>"
#                                 write patches/<NNNN-name>.patch (Subject line,
#                                 explanation, diff -u a/ b/), add it to
#                                 patches/series, and copy b/ into staging/
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
. "$top/upstream.conf"
stage=$top/staging/$UPSTREAM_NAME-$UPSTREAM_VERSION
work=$top/cache/patchwork
case ${1:-} in
start)
    shift
    rm -rf "$work"; mkdir -p "$work/a" "$work/b"
    for f in "$@"; do
        [ -f "$stage/$f" ] || { echo "patch.sh: no $stage/$f" >&2; exit 1; }
        mkdir -p "$work/a/$(dirname "$f")" "$work/b/$(dirname "$f")"
        cp "$stage/$f" "$work/a/$f"; cp "$stage/$f" "$work/b/$f"
    done
    printf '%s\n' "$@" > "$work/files"
    ;;
finish)
    name=${2:?name}; subject=${3:?subject}; why=${4:?explanation}
    out=$top/patches/$name.patch
    [ -e "$out" ] && { echo "patch.sh: $out exists" >&2; exit 1; }
    {
        printf 'Subject: %s\n\n%s\n\n' "$subject" "$(echo "$why" | fold -s -w 76 | sed 's/ *$//')"
        while read -r f; do
            (cd "$work" && diff -u "a/$f" "b/$f") || true
        done < "$work/files"
    } > "$out"
    grep -q '^@@' "$out" || { rm -f "$out"; echo "patch.sh: no changes" >&2; exit 1; }
    echo "$name.patch" >> "$top/patches/series"
    while read -r f; do cp "$work/b/$f" "$stage/$f"; done < "$work/files"
    echo "patch.sh: patches/$name.patch"
    ;;
*) sed -n '2,12p' "$0" >&2; exit 2 ;;
esac
