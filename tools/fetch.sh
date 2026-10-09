#!/usr/bin/env bash
# fetch.sh - download the MariaDB release tarball named in upstream.conf into
# cache/, verify its SHA-256, and verify its GPG signature against
# keys/mariadb-signing-key.asc.
set -euo pipefail

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
. "$top/upstream.conf"

need_tools curl gpg ${SHA256SUM%% *}
cache=$top/cache
mkdir -p "$cache"
tarball=$cache/$(basename "$UPSTREAM_URL")

[ -f "$tarball" ] || { echo "fetch: downloading $UPSTREAM_URL"
                       curl -fsSL -o "$tarball.tmp" "$UPSTREAM_URL"; mv "$tarball.tmp" "$tarball"; }
[ -f "$tarball.asc" ] || curl -fsSL -o "$tarball.asc" "$UPSTREAM_URL.asc"

echo "$UPSTREAM_SHA256  $tarball" | $SHA256SUM -c --quiet - ||
    { echo "fetch: SHA-256 mismatch for $tarball" >&2; exit 1; }

# A throwaway keyring holding only the pinned key shipped in the repo.
keyring=$cache/mariadb-keyring.gpg
rm -f "$keyring"
gpg --no-default-keyring --keyring "$keyring" --import "$top/keys/mariadb-signing-key.asc" 2>/dev/null
status=$(gpg --no-default-keyring --keyring "$keyring" --status-fd 1 \
             --verify "$tarball.asc" "$tarball" 2>/dev/null || true)
# VALIDSIG ends with the primary key's fingerprint.
echo "$status" | grep -q "^\[GNUPG:\] VALIDSIG .* $UPSTREAM_GPG_KEY\$" ||
    { echo "fetch: no valid signature by $UPSTREAM_GPG_KEY on $tarball" >&2; exit 1; }
echo "fetch: signature OK ($UPSTREAM_GPG_KEY)"
echo "fetch: $tarball"

# {fmt} (no signature published): pinned by SHA-256.
fmtzip=$cache/$(basename "$LIBFMT_URL")
[ -f "$fmtzip" ] || { echo "fetch: downloading $LIBFMT_URL"
                      curl -fsSL -o "$fmtzip.tmp" "$LIBFMT_URL"; mv "$fmtzip.tmp" "$fmtzip"; }
echo "$LIBFMT_SHA256  $fmtzip" | $SHA256SUM -c --quiet - ||
    { echo "fetch: SHA-256 mismatch for $fmtzip" >&2; exit 1; }
echo "fetch: $fmtzip"
