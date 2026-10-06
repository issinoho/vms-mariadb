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
    # Everything source-like the host build directory holds -> vmsgen/,
    # with the compiled error messages (sql/share/*/errmsg.sys) and the
    # bootstrap SQL (scripts/*.sql) that vms/install_db.com feeds mariadbd.
    (cd "$bdir" && find . -path ./CMakeFiles -prune -o -path '*/CMakeFiles' -prune -o \
        -type f \( -name '*.h' -o -name '*.hh' -o -name '*.c' -o -name '*.cc' -o -name '*.ic' \
        -o -name '*.inl' -o -name '*.sys' -o -name '*.sql' \) -print | cpio -pdm --quiet "$stage/vmsgen")
    python3 "$top/tools/gen_mms.py" "$cfg"
done

# --- PCSI kit inputs (vms/kit/MAKE_KIT.COM builds the kit on x86-64) ---
# (needs the server configuration: the error messages and bootstrap SQL)
if [ -d "$stage/vmsgen/sql/share" ] && [ -d "$stage/vmsgen/scripts" ]; then
    step "PCSI kit inputs"
    kit=$stage/vms/kit
    : "${KIT_PRODUCER:=ISSINOHO}" "${KIT_PRODUCT:=VMSMARIADB}"
    # MariaDB versions have three parts (11.4.13): the third is the PCSI update and
    # our VMS patch level the ECO, as in the sibling ports: 11.4.13-vms1 is V11.4-13E1.
    IFS=. read -r major minor update _ <<< "$UPSTREAM_VERSION"
    pcsiversion="V$major.$minor-${update:-0}E$VMS_PATCH_LEVEL"
    kitversion="$UPSTREAM_VERSION-vms$VMS_PATCH_LEVEL"
    # The share/ and scripts/ files, from what the server build pushes (as
    # MAKE_KIT.COM gathers them): one directory per error-message language.
    files=$top/cache/kit-files.pdf
    {
        for d in $(cd "$stage/vmsgen/sql/share" && ls -d */ | tr -d / | sort); do
            D=$(echo "$d" | tr a-z A-Z)
            echo "    directory [VMSMARIADB.SHARE.$D] ;"
            # Material is looked up by name in one flat directory: MAKE_KIT.COM
        # gives each language's ERRMSG.SYS a unique name there (PCSI ignores
        # the directory in "source"; it needs one for the syntax).
        echo "    file [VMSMARIADB.SHARE.$D]ERRMSG.SYS source [000000]${D}_ERRMSG.SYS ;"
        done
        for f in $(cd "$stage/sql/share/charsets" && ls | sort); do
            F=$(echo "$f" | tr a-z A-Z); case $F in *.*) ;; *) F=$F. ;; esac
            echo "    file [VMSMARIADB.SHARE.CHARSETS]$F ;"
        done
        for f in BOOTSTRAP_HEADER MARIADB_SYSTEM_TABLES MARIADB_PERFORMANCE_TABLES \
                 MARIADB_SYSTEM_TABLES_DATA FILL_HELP_TABLES MARIA_ADD_GIS_SP_BOOTSTRAP MARIADB_SYS_SCHEMA; do
            echo "    file [VMSMARIADB.SCRIPTS]$f.SQL ;"
        done
    } > "$files"
    subst() {
        sed -e "s/@PRODUCER@/$KIT_PRODUCER/g" -e "s/@BASE@/X86VMS/g" \
            -e "s/@PCSIVERSION@/$pcsiversion/g" -e "s/@VERSION@/$UPSTREAM_VERSION/g" \
            -e "s/@KITVERSION@/$kitversion/g"
    }
    lc=$(echo "$KIT_PRODUCT" | tr A-Z a-z)
    subst < "$kit/$lc.pcsi\$desc_template" | sed -e "/^@FILES@\$/{r $files" -e 'd}' \
        > "$kit/PRODUCT-X86VMS.PCSI\$DESC"
    subst < "$kit/$lc.pcsi\$text_template" > "$kit/PRODUCT-X86VMS.PCSI\$TEXT"
    rm -f "$kit/$lc.pcsi\$desc_template" "$kit/$lc.pcsi\$text_template"
    for p in startup shutdown setup server configure; do
        P=$(echo "$p" | tr a-z A-Z)
        subst < "$kit/$lc\$$p.com" > "$kit/$KIT_PRODUCT\$$P.COM"; rm -f "$kit/$lc\$$p.com"
    done
    subst < "$kit/readme.vms" > "$kit/README.VMS"; rm -f "$kit/readme.vms"
    printf 'KIT_PRODUCER=%s\nKIT_PRODUCT=%s\nPCSI_VERSION=%s\nKIT_VERSION=%s\n' "$KIT_PRODUCER" \
        "$KIT_PRODUCT" "$pcsiversion" "$kitversion" > "$kit/kit.env"
fi
step "staged $stage ($(du -sh "$stage" | cut -f1))"
