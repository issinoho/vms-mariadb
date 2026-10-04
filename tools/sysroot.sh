#!/usr/bin/env bash
# sysroot.sh <node> - copy the VMS headers the host-side CMake run must see
# into cache/vms-sysroot/ (not committed: they are VSI's files).
#
# Today that is VSI SSL3's OpenSSL headers (SSL3$INCLUDE, flat on VMS), laid
# out as include/openssl/*.h with lower-case names and LF line ends.
set -euo pipefail
top=$(cd "$(dirname "$0")/.." && pwd)
node=${1:?usage: sysroot.sh <node>}
read -r _ _ HOST PORT USER _ _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
dst=$top/cache/vms-sysroot/include/openssl
rm -rf "$dst"; mkdir -p "$dst"
# mget '*' (not '*.H'): the remote names carry a ;version suffix.
(cd "$dst" && printf 'cd /SSL3$INCLUDE\nmget *\n' |
    sftp -P "$PORT" -i "${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}" -o BatchMode=yes -b - "$USER@$HOST" >/dev/null)
for f in "$dst"/*; do
    n=$dst/$(basename "$f" | sed 's/;[0-9]*$//' | tr A-Z a-z)
    tr -d '\r' < "$f" > "$f.tmp"; rm -f "$f"; mv "$f.tmp" "$n"
done
[ -f "$dst/ssl.h" ] || { echo "sysroot: no ssl.h fetched" >&2; exit 1; }
echo "sysroot: $(ls "$dst" | wc -l) SSL3 headers -> $dst"
