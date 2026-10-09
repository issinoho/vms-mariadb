# hostenv.sh - sourced by the host scripts (after "top=").  What differs between a
# Linux host and a macOS one, checked once here rather than at the first failure:
#   - bash 4 or later (mapfile, and set -u with empty arrays); macOS's /bin/bash is
#     3.2, so "#!/usr/bin/env bash" must find a newer one (e.g. Homebrew's) first;
#   - SHA256SUM: sha256sum, or "shasum -a 256" where there is none (older macOS).
# need_tools <cmd>...: stop, naming every one that is missing.
# GNU-only options (sed {r ...;d}, xargs -r) are not used: see docs/PORTING_LOG.md.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "$(basename "$0"): needs bash 4 or later; this is ${BASH_VERSION:-not bash}" \
         "($(command -v bash))." >&2
    echo "  On macOS: brew install bash, and put Homebrew's bin before /bin in PATH." >&2
    exit 2
fi

if command -v sha256sum >/dev/null 2>&1; then
    SHA256SUM=sha256sum
else
    SHA256SUM="shasum -a 256"
fi

need_tools() {
    local t missing=
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
    [ -z "$missing" ] && return 0
    echo "$(basename "$0"): not found on this host:$missing" >&2
    exit 2
}
