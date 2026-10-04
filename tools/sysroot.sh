#!/usr/bin/env bash
# sysroot.sh <node> - copy the VMS headers the host-side CMake run must see
# into cache/vms-sysroot/ (not committed: they are VSI's files).
#
# VSI SSL3's OpenSSL headers (SSL3$INCLUDE, flat on VMS) as include/openssl/,
# and vms-pcre2's PCRE2 headers (its x86-64 install tree in the sibling work
# directory, PCRE2_TREE in upstream.conf) as include/pcre2/, with lower-case
# names and LF line ends.
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

. "$top/upstream.conf"
pdst=$top/cache/vms-sysroot/include/pcre2
rm -rf "$pdst"; mkdir -p "$pdst"
psrc=/USER\$ROOT/$USER/vms_grep/$(echo "$PCRE2_TREE" | tr A-Z a-z)/install_x86_64/include
(cd "$pdst" && printf 'cd %s\nmget *\n' "${PCRE2_SFTP:-$psrc}" |
    sftp -P "$PORT" -i "${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}" -o BatchMode=yes -b - "$USER@$HOST" >/dev/null)
for f in "$pdst"/*; do
    n=$pdst/$(basename "$f" | sed 's/;[0-9]*$//' | tr A-Z a-z)
    tr -d '\r' < "$f" > "$f.tmp"; rm -f "$f"; mv "$f.tmp" "$n"
done
[ -f "$pdst/pcre2.h" ] || { echo "sysroot: no pcre2.h fetched (set PCRE2_SFTP)" >&2; exit 1; }
echo "sysroot: PCRE2 headers -> $pdst"
