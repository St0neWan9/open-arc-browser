#!/bin/sh
# Re-exports Open Arc's Chromium branch as an ordered patch series (plan C5).
#
# Usage: chromium-patches/export.sh [CHROMIUM_SRC] [SERIES]
#   CHROMIUM_SRC  Chromium's src/ directory (default: ~/chromium/src)
#   SERIES        series directory name (default: the newest, e.g. 156)
#
# Writes chromium-patches/SERIES/NNNN-*.patch from the commits BASE..BRANCH
# (BASE and BRANCH files in the series directory), replacing the old patches.
# Output is stable: no signature, a zero hash in the "From" line and a fixed
# abbreviation length, so an unchanged commit gives an unchanged file.
#
# It also checks that //openarc/bridge/public mirrors chromium-bridge/include,
# which is the source of truth for the public headers.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${1:-$HOME/chromium/src}"
SERIES="${2:-$(ls -1 "$HERE" | grep -E '^[0-9]+$' | sort -n | tail -1)}"
DIR="$HERE/$SERIES"

BASE="$(cat "$DIR/BASE")"
BRANCH="$(cat "$DIR/BRANCH")"

cd "$SRC"
git rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null ||
    { echo "export.sh: branch $BRANCH not found in $SRC" >&2; exit 1; }
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "export.sh: warning: uncommitted changes in $SRC are not exported" >&2
fi

# The public headers must match the repository's copy.
if [ -d "$REPO/chromium-bridge/include/OpenArcCore" ]; then
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/oac-export.XXXXXX")"
    trap 'rm -rf "$TMP"' EXIT
    git archive "$BRANCH" openarc/bridge/public/OpenArcCore | tar -x -C "$TMP"
    if ! diff -r "$REPO/chromium-bridge/include/OpenArcCore" \
            "$TMP/openarc/bridge/public/OpenArcCore" >/dev/null; then
        echo "export.sh: openarc/bridge/public/OpenArcCore differs from" >&2
        echo "           chromium-bridge/include/OpenArcCore; copy the headers over" >&2
        echo "           and amend the //openarc commit first." >&2
        exit 1
    fi
fi

rm -f "$DIR"/[0-9][0-9][0-9][0-9]-*.patch
git format-patch --quiet --no-signature --zero-commit --abbrev=12 \
    --no-numbered --output-directory "$DIR" "$BASE..$BRANCH"
echo "export.sh: wrote $(ls "$DIR"/[0-9][0-9][0-9][0-9]-*.patch | wc -l | tr -d ' ') patches to $DIR"
ls -1 "$DIR"/[0-9][0-9][0-9][0-9]-*.patch | sed 's|.*/|  |'
