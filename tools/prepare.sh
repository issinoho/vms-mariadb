#!/usr/bin/env bash
# prepare.sh - build a VMS-ready MariaDB source tree in staging/<name>-<version>/
#
#   1. fetch + verify the upstream tarball (fetch.sh)
#   2. extract it (without the PRUNE directories in upstream.conf), apply
#      patches/series, lay overlay/ over the top
#   3. for each configuration in CONFIGS (default: client server): host_configure.sh
#      (CMake on this host with the OpenVMS toolchain file and the replayed
#      check answers, cmake/os/OpenVMSCache.cmake), build the generated
#      sources there with the native generators, copy them into vmsgen/, and
#      write the MMS build (gen_mms.py) into vms/build/<config>/
#
# Nothing in staging/ is ever edited by hand: fix things in patches/ or overlay/.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
tarball=$top/cache/$(basename "$UPSTREAM_URL")
stage=$top/staging/$name

step() { echo "prepare: $*"; }
die() { echo "prepare: error: $*" >&2; exit 1; }

"$top/tools/fetch.sh" >/dev/null

step "extracting $name"
rm -rf "$stage"; mkdir -p "$top/staging"
excludes=()
for d in $PRUNE; do excludes+=(--exclude="$name/$d"); done
tar -xzf "$tarball" -C "$top/staging" "${excludes[@]}"
[ -d "$stage" ] || die "tarball did not unpack to $stage"

while read -r p; do
    case $p in ''|'#'*) continue ;; esac
    step "patch $p"
    patch -d "$stage" -p1 -s --no-backup-if-mismatch -F0 < "$top/patches/$p" ||
        die "patch $p does not apply cleanly"
done < "$top/patches/series"

# overlay/ may only add files; changes to upstream files belong in patches/.
(cd "$top/overlay" && find . -type f) | while read -r f; do
    [ -e "$stage/$f" ] && die "overlay/$f would replace an upstream file; use a patch"
    true
done
cp -a "$top/overlay/." "$stage/"

printf 'VERSION=%s\nKIT_VERSION=%s-vms%s\n' "$UPSTREAM_VERSION" "$UPSTREAM_VERSION" \
    "$VMS_PATCH_LEVEL" > "$stage/vms/version.env"

for cfg in ${CONFIGS:-client server}; do
    "$top/tools/host_configure.sh" "$cfg"
    bdir=$top/cache/cmake-$cfg
    # {fmt}: unpack the pinned release where cmake/libfmt.cmake's
    # ExternalProject would have put it (headers only; copied to vmsgen/ below).
    if [ -d "$bdir/extra/libfmt" ]; then
        fmtdir=$bdir/extra/libfmt/src/libfmt
        rm -rf "$fmtdir"; mkdir -p "$fmtdir"
        unzip -q "$top/cache/$(basename "$LIBFMT_URL")" "fmt-$LIBFMT_VERSION/include/*" -d "$fmtdir.tmp"
        mv "$fmtdir.tmp/fmt-$LIBFMT_VERSION/include" "$fmtdir/include"; rm -rf "$fmtdir.tmp"
    fi
    # Generated sources (error-message headers, ...) via the native tools.
    gen=$(sed -n 's/^\([A-Za-z_]*Gen[A-Za-z_]*\):.*/\1/p' "$bdir/Makefile" | sort -u | tr '\n' ' ')
    step "$cfg: generated sources ($gen)"
    make -C "$bdir" -s $gen > "$bdir/gen.out" 2>&1 || { tail "$bdir/gen.out"; die "make $gen failed"; }
    # Everything source-like the host build directory holds -> vmsgen/.
    (cd "$bdir" && find . -path ./CMakeFiles -prune -o -path '*/CMakeFiles' -prune -o \
        -type f \( -name '*.h' -o -name '*.hh' -o -name '*.c' -o -name '*.cc' -o -name '*.ic' \
        -o -name '*.inl' \) -print | cpio -pdm --quiet "$stage/vmsgen")
    python3 "$top/tools/gen_mms.py" "$cfg"
done
step "staged $stage ($(du -sh "$stage" | cut -f1))"
