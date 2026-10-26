#!/bin/sh
# Applies Open Arc's Chromium patch set onto a clean checkout of the matching
# Chromium tag, as commits on a local branch (plan C5).
#
# Usage: chromium-patches/apply.sh [CHROMIUM_SRC] [SERIES]
#   CHROMIUM_SRC  Chromium's src/ directory (default: ~/chromium/src)
#   SERIES        patch series directory name under chromium-patches/
#                 (default: the newest, e.g. 156)
#
# The series directory holds:
#   BASE          the Chromium tag the patches apply to (e.g. 156.0.8078.48)
#   BRANCH        the local branch name to create (e.g. openarc/156)
#   NNNN-*.patch  `git format-patch` output, applied in name order
#
# Idempotent: if the branch exists and already carries exactly these patches
# (compared by patch-id), nothing happens. If it exists with different content
# the script stops; delete or rename the branch to re-apply.
#
# Requirements: a clean working tree (the script refuses to touch local
# changes), and the tag present locally.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="${1:-$HOME/chromium/src}"
SERIES="${2:-$(ls -1 "$HERE" | grep -E '^[0-9]+$' | sort -n | tail -1)}"
DIR="$HERE/$SERIES"

[ -d "$DIR" ] || { echo "apply.sh: no series directory $DIR" >&2; exit 1; }
BASE="$(cat "$DIR/BASE")"
BRANCH="$(cat "$DIR/BRANCH")"

cd "$SRC"
git rev-parse --verify --quiet "refs/tags/$BASE" >/dev/null ||
    { echo "apply.sh: tag $BASE not found in $SRC" >&2; exit 1; }

if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "apply.sh: $SRC has uncommitted changes; commit or stash them first" >&2
    exit 1
fi

# patch-ids of a list of patch files / a commit range, for the idempotency check.
series_ids() {
    for p in "$DIR"/[0-9][0-9][0-9][0-9]-*.patch; do
        git patch-id --stable < "$p" | cut -d' ' -f1
    done
}
branch_ids() {
    for c in $(git rev-list --reverse "$BASE..$BRANCH"); do
        git show "$c" | git patch-id --stable | cut -d' ' -f1
    done
}

if git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null; then
    if [ "$(series_ids)" = "$(branch_ids)" ]; then
        echo "apply.sh: $BRANCH already carries the $SERIES series; nothing to do"
        exit 0
    fi
    echo "apply.sh: branch $BRANCH exists with different commits." >&2
    echo "          Rename or delete it (git branch -m / -D) and run again." >&2
    exit 1
fi

git checkout --quiet -b "$BRANCH" "refs/tags/$BASE"
# --3way falls back to a three-way merge when context moved (needs the blobs,
# which a full checkout of the tag has). Committer identity comes from the
# patches' author lines; dates are kept for reproducible hashes.
if ! git -c user.name="Open Arc Authors" -c user.email="dev@openarc.invalid" \
        am --3way --committer-date-is-author-date --keep-cr \
        "$DIR"/[0-9][0-9][0-9][0-9]-*.patch; then
    echo "apply.sh: a patch did not apply. Resolve it, then 'git am --continue'," >&2
    echo "          or 'git am --abort' to give up (see README.md, Rebasing)." >&2
    exit 1
fi
echo "apply.sh: applied $(ls "$DIR"/[0-9][0-9][0-9][0-9]-*.patch | wc -l | tr -d ' ') patches onto $BASE as $BRANCH"
