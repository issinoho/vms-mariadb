#!/usr/bin/env bash
# push.sh <node> <config> - upload what <config>'s build needs from staging/ to
# <node>'s work directory, as [.MARIADB-<version with dots as underscores>].
#
# The directories come from staging/<name>/vms/build/<config>/PUSHDIRS.TXT
# (written by gen_mms.py: every top-level directory a source or include path
# of the configuration uses, plus vms/ and vmsgen/).  Only files whose content
# changed since the last push to this node are sent, so MMS sees new
# timestamps only on what really changed.
set -euo pipefail
export LC_ALL=C   # sort and comm must agree on collation

top=$(cd "$(dirname "$0")/.." && pwd)
. "$top/tools/hostenv.sh"
node=${1:?usage: push.sh <node> <config>}
cfg=${2:?usage: push.sh <node> <config>}
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
stage=$top/staging/$name
remote=$(echo "$name" | tr . _)
dirs=$stage/vms/build/$cfg/PUSHDIRS.TXT
[ -f "$dirs" ] || { echo "push: run tools/prepare.sh first" >&2; exit 1; }

# (the trailing _ takes the optional 8th column, the PCRE2 tree)
read -r _ _ HOST PORT USER WORKDIR SFTPDIR _ < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
need_tools sftp ${SHA256SUM%% *}
manifest=$top/cache/pushed-$name-$node.sha
[ "${PUSH_ALL:-}" = 1 ] && rm -f "$manifest"
touch "$manifest"
list=$top/cache/push-$name-$node.sha
( cd "$stage" && { find . -maxdepth 1 -type f; while read -r d; do find "./$d" -type f; done < "$dirs"; } |
    sed 's|^\./||' | sort -u | tr '\n' '\0' | xargs -0 $SHA256SUM ) > "$list"
changed=$(comm -23 <(awk '{print $2" "$1}' "$list" | sort) \
                   <(awk '{print $2" "$1}' "$manifest" | sort) | awk '{print $1}')
# The build's own files on the node (vms/, its procedures, options and response
# files) must still be what was pushed: a user's hand-edited linker options once
# stayed through every push, since only files changed in staging/ are sent.  Fetch
# the ones not being sent anyway; any that differ (or are gone) are sent again.
edited=
check=$(comm -12 <(awk '{print $2" "$1}' "$list" | sort) <(awk '{print $2" "$1}' "$manifest" | sort) |
    awk '{print $1}' | grep -E "^vms/([^/]*|kit/.*|config/.*|build/$cfg/[^/]*)\$" || true)
if [ -n "$check" ]; then
    fetched=$top/cache/push-check-$node
    rm -rf "$fetched"; mkdir -p "$fetched"
    { echo "cd $SFTPDIR/$remote"
      echo "$check" | while read -r f; do
          mkdir -p "$fetched/$(dirname "$f")"; echo "-get $f $fetched/$f"; done
    } | sftp -P "$PORT" -i "${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}" -o BatchMode=yes -b - "$USER@$HOST" \
        >/dev/null 2>&1 || true
    edited=$(echo "$check" | while read -r f; do
        cmp -s "$fetched/$f" "$stage/$f" || echo "$f"; done)
    if [ -n "$edited" ]; then
        echo "push: on $node, not as pushed (edited there?); sending staging/'s copy again" >&2
        echo "  (the node keeps the old one as the previous version):" >&2
        echo "$edited" | sed 's/^/    /' >&2
        changed=$(printf '%s\n%s\n' "$changed" "$edited" | grep . | sort -u)
    fi
fi
echo "push: -> $node:[.$(echo "$remote" | tr a-z A-Z)]: $(echo "$changed" | grep -c . || true) changed of $(wc -l < "$list") files"
batch=$top/cache/push-$name-$node.sftp
{
    echo "cd $SFTPDIR"
    echo "-mkdir $remote"
    # Every directory above each changed file (awk, not "xargs -r dirname":
    # -r is a GNU option).  grep finds nothing when no file changed: not an error.
    { echo "$changed" | grep . || true; } |
        awk -F/ '{p=""; for(i=1;i<NF;i++){p=p (i>1?"/":"") $i; print p}}' |
        sort -u | sed "s|^|-mkdir $remote/|"
    { echo "$changed" | grep . || true; } | while read -r f; do echo "put $stage/$f $remote/$f"; done
} > "$batch"
rc=0
sftp -P "$PORT" -i "${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}" -o BatchMode=yes -b "$batch" "$USER@$HOST" \
    2>&1 >/dev/null | { grep -vE '^ *Welcome to|^ *$|^remote mkdir .*Failure' >&2 || true; } || rc=$?
# A failed batch (no work directory, a put refused) must not reach the manifest:
# the files would count as pushed, and later pushes would never send them.
if [ "$rc" -ne 0 ]; then
    echo "push: sftp to $node failed (status $rc; is $SFTPDIR there?); nothing recorded as pushed" >&2
    exit 1
fi
# Merge, not replace: the manifest covers every configuration pushed to this
# node.  Replacing it with the client's list once made the next server push
# resend ~3,000 server-only files, and MMS then rebuilt the whole server.
awk 'NR == FNR { seen[$2] = 1; print; next } !($2 in seen)' "$list" "$manifest" |
    sort -k2,2 > "$manifest.new"
mv "$manifest.new" "$manifest"
echo "push: done"
