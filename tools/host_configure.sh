#!/usr/bin/env bash
# host_configure.sh <config> - run CMake on this host for OpenVMS.
#
# Configures staging/<name>/ with vms/cmake/toolchain-openvms.cmake and the
# options in overlay/vms/config/<config>.options, into cache/cmake-<config>/.
# --debug-trycompile keeps every check's sources so tools/replay.sh can run
# the checks that were not answered from cmake/os/OpenVMSCache.cmake.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
. "$top/upstream.conf"
cfg=${1:?usage: host_configure.sh <config>}
stage=$top/staging/$UPSTREAM_NAME-$UPSTREAM_VERSION
opts=$top/overlay/vms/config/$cfg.options
bdir=$top/cache/cmake-$cfg
[ -f "$opts" ] || { echo "host_configure: no $opts" >&2; exit 2; }
[ -d "$stage/vms" ] || { echo "host_configure: run tools/prepare.sh first" >&2; exit 1; }
sysroot=$top/cache/vms-sysroot
[ -f "$sysroot/include/openssl/ssl.h" ] || {
    echo "host_configure: no $sysroot/include/openssl (tools/sysroot.sh)" >&2; exit 1; }
mkdir -p "$sysroot/lib"; touch "$sysroot/lib/libssl.so" "$sysroot/lib/libcrypto.so"
mapfile -t args < <(grep -v -e '^#' -e '^$' "$opts" | sed "s|@SYSROOT@|$sysroot|g")
# MariaDB's cross-compile support runs its build-time generators (comp_err,
# comp_sql, factorial, uca-dump, gen_lex_hash, gen_lex_token) from a native
# build: make them once on this host.  Their output is platform-independent.
native=$top/cache/native-$UPSTREAM_VERSION
if [ ! -f "$native/import_executables.cmake" ]; then
    echo "host_configure: native build of the generators -> $native"
    rm -rf "$native"; mkdir -p "$native"
    (cd "$native" && cmake "$stage" -DWITH_SSL=system -DWITH_UNIT_TESTS=OFF \
        -DWITH_WSREP=OFF -DPLUGIN_INNOBASE=NO -DWITH_EMBEDDED_SERVER=OFF \
        > cmake.out 2>&1 && make -j"$(getconf _NPROCESSORS_ONLN)" import_executables > make.out 2>&1) || {
        echo "host_configure: native generator build failed (see $native)" >&2
        rm -f "$native/import_executables.cmake"; exit 1; }
fi
args+=(-DIMPORT_EXECUTABLES="$native/import_executables.cmake")
[ "${VMS_NO_ANSWERS:-}" = 1 ] && args+=(-DVMS_NO_ANSWERS=ON)
rm -rf "$bdir"; mkdir -p "$bdir/.cmake/api/v1/query"
# File API: per-target sources, defines and includes for the MMS generator.
touch "$bdir/.cmake/api/v1/query/codemodel-v2" "$bdir/.cmake/api/v1/query/cache-v2"
echo "host_configure: cmake $cfg -> $bdir"
(cd "$bdir" && cmake "$stage" -G "Unix Makefiles" --debug-trycompile \
    -DCMAKE_TOOLCHAIN_FILE="$stage/vms/cmake/toolchain-openvms.cmake" \
    -DVMS_SYSROOT="$sysroot" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "${args[@]}" > cmake.out 2>&1) || {
    grep -E 'CMake Error|Error' -A5 "$bdir/cmake.out" | head -40 >&2
    echo "host_configure: cmake failed (see $bdir/cmake.out)" >&2; exit 1; }
echo "host_configure: done"
