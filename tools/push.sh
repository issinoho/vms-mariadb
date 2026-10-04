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
node=${1:?usage: push.sh <node> <config>}
cfg=${2:?usage: push.sh <node> <config>}
. "$top/upstream.conf"
name=$UPSTREAM_NAME-$UPSTREAM_VERSION
stage=$top/staging/$name
remote=$(echo "$name" | tr . _)
dirs=$stage/vms/build/$cfg/PUSHDIRS.TXT
[ -f "$dirs" ] || { echo "push: run tools/prepare.sh first" >&2; exit 1; }

read -r _ _ HOST PORT USER WORKDIR SFTPDIR < <(awk -v n="$node" '$1==n' "$top/tools/nodes.conf")
manifest=$top/cache/pushed-$name-$node.sha
[ "${PUSH_ALL:-}" = 1 ] && rm -f "$manifest"
touch "$manifest"
list=$top/cache/push-$name-$node.sha
( cd "$stage" && { find . -maxdepth 1 -type f; while read -r d; do find "./$d" -type f; done < "$dirs"; } |
    sed 's|^\./||' | sort -u | tr '\n' '\0' | xargs -0 sha256sum ) > "$list"
changed=$(comm -23 <(awk '{print $2" "$1}' "$list" | sort) \
                   <(awk '{print $2" "$1}' "$manifest" | sort) | awk '{print $1}')
echo "push: -> $node:[.$(echo "$remote" | tr a-z A-Z)]: $(echo "$changed" | grep -c . || true) changed of $(wc -l < "$list") files"
batch=$top/cache/push-$name-$node.sftp
{
    echo "cd $SFTPDIR"
    echo "-mkdir $remote"
    # (grep finds nothing when no file changed: not an error)
    { echo "$changed" | grep . || true; } | xargs -r -n1 dirname | sort -u |
        awk -F/ '{p=""; for(i=1;i<=NF;i++){p=p (i>1?"/":"") $i; print p}}' |
        sort -u | sed "s|^|-mkdir $remote/|"
    { echo "$changed" | grep . || true; } | while read -r f; do echo "put $stage/$f $remote/$f"; done
} > "$batch"
sftp -P "$PORT" -i "${VMS_SSH_KEY:-$HOME/.ssh/vms_ed25519}" -o BatchMode=yes -b "$batch" "$USER@$HOST" \
    2>&1 >/dev/null | grep -vE '^ *Welcome to|^ *$|^remote mkdir .*Failure' >&2 || true
cp "$list" "$manifest"
echo "push: done"
