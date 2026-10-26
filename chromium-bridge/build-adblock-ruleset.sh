#!/bin/sh
# Builds the ad blocker's filter ruleset (plan C16) for OpenArcCore.framework.
#
# Usage: chromium-bridge/build-adblock-ruleset.sh [CHROMIUM_SRC] [OUT_DIR] [FRAMEWORK]
#   CHROMIUM_SRC  Chromium's src/ directory (default: ~/chromium/src)
#   OUT_DIR       GN output directory relative to CHROMIUM_SRC (default: out/Release); its
#                 ruleset_converter is built if missing
#   FRAMEWORK     framework to install into (default: OUT_DIR/OpenArcCore.framework)
#
# Steps:
#   1. Download EasyList and EasyPrivacy (public filter lists, https://easylist.to) into
#      app/.build/adblock/lists/. The lists are fetched at build time and never committed.
#   2. Convert both with Chromium's ruleset_converter (//components/subresource_filter/tools)
#      from the Adblock Plus filter-list syntax into the subresource filter's "unindexed ruleset"
#      (URL rules only, --output_file_url: element-hiding rules are left out. The filter only
#      blocks loads, and Chromium's style-rule indexer DCHECKs when the lists give a selector
#      both as a global and as a site-specific rule, which crashed DCHECK-enabled builds at
#      startup). The engine indexes it once at first start (openarc/browser/openarc_ad_blocker.h).
#   3. Write ruleset.version (the date and a short hash of the ruleset; a new version makes the
#      engine index again) and ATTRIBUTION (the lists' license and authors).
#   4. Copy ruleset.pb, ruleset.version and ATTRIBUTION into FRAMEWORK/Versions/A/Resources/AdBlock/.
#
# Run after every framework build (build-framework.sh does), since ninja recreates the
# framework's Resources from its own inputs. Network: two HTTPS downloads (~2 MB). When the
# download fails, the last lists in app/.build/adblock/lists/ are used if present.
#
# Updates between app releases come later from our static host (TODO in openarc_ad_blocker.h).

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SRC="${1:-$HOME/chromium/src}"
OUT="${2:-out/Release}"
FRAMEWORK="${3:-$SRC/$OUT/OpenArcCore.framework}"

WORK="$REPO/app/.build/adblock"
LISTS="$WORK/lists"
STAGE="$WORK/ruleset"
mkdir -p "$LISTS" "$STAGE"

EASYLIST_URL="https://easylist.to/easylist/easylist.txt"
EASYPRIVACY_URL="https://easylist.to/easylist/easyprivacy.txt"

fetch() {
    url="$1"; dest="$2"
    if curl --fail --silent --show-error --location --max-time 120 -o "$dest.tmp" "$url"; then
        # A filter list starts with its "[Adblock Plus ...]" header.
        if head -1 "$dest.tmp" | grep -q '^\[Adblock Plus'; then
            mv "$dest.tmp" "$dest"
            return 0
        fi
        echo "build-adblock-ruleset.sh: $url is not a filter list" >&2
    fi
    rm -f "$dest.tmp"
    if [ -s "$dest" ]; then
        echo "build-adblock-ruleset.sh: download failed; using the previous $dest" >&2
        return 0
    fi
    echo "build-adblock-ruleset.sh: could not get $url" >&2
    return 1
}

echo "==> downloading EasyList and EasyPrivacy" >&2
fetch "$EASYLIST_URL" "$LISTS/easylist.txt"
fetch "$EASYPRIVACY_URL" "$LISTS/easyprivacy.txt"

CONVERTER="$SRC/$OUT/ruleset_converter"
if [ ! -x "$CONVERTER" ]; then
    echo "==> ninja -C $OUT ruleset_converter" >&2
    "$SRC/third_party/ninja/ninja" -C "$SRC/$OUT" ruleset_converter >&2
fi

echo "==> converting" >&2
rm -f "$STAGE/ruleset.pb"
# The converter logs every rule it cannot express ($redirect, $removeparam, ...) to stderr;
# keep that out of the build log, it is expected.
"$CONVERTER" --input_format=filter-list --output_format=unindexed-ruleset \
    --input_files="$LISTS/easylist.txt,$LISTS/easyprivacy.txt" \
    --output_file_url="$STAGE/ruleset.pb" 2>"$WORK/converter.log"
[ -s "$STAGE/ruleset.pb" ] || { echo "build-adblock-ruleset.sh: empty ruleset" >&2; exit 1; }

list_version() {
    sed -n 's/^! Version: *//p' "$1" | head -1
}
hash="$(shasum -a 256 "$STAGE/ruleset.pb" | cut -c1-12)"
printf '%s-%s\n' "$(date -u +%Y%m%d)" "$hash" > "$STAGE/ruleset.version"

cat > "$STAGE/ATTRIBUTION" <<EOF
Open Arc's built-in ad blocker uses these filter lists, converted into
Chromium's subresource filter format:

  EasyList     version $(list_version "$LISTS/easylist.txt")    $EASYLIST_URL
  EasyPrivacy  version $(list_version "$LISTS/easyprivacy.txt")    $EASYPRIVACY_URL

The EasyList authors (https://easylist.to/) publish both lists under a dual
license: the Creative Commons Attribution-ShareAlike 3.0 Unported license
(https://creativecommons.org/licenses/by-sa/3.0/) or, at your option, the
GNU General Public License, version 3 or later
(https://www.gnu.org/licenses/gpl.html). Open Arc uses them under
CC BY-SA 3.0. The converted ruleset is a derivative of the lists and is
distributed under the same license.
EOF

echo "==> installing into $FRAMEWORK" >&2
[ -d "$FRAMEWORK/Versions/A/Resources" ] ||
    { echo "build-adblock-ruleset.sh: missing $FRAMEWORK/Versions/A/Resources" >&2; exit 1; }
dest="$FRAMEWORK/Versions/A/Resources/AdBlock"
rm -rf "$dest"
mkdir -p "$dest"
cp "$STAGE/ruleset.pb" "$STAGE/ruleset.version" "$STAGE/ATTRIBUTION" "$dest/"
echo "ad block ruleset $(cat "$STAGE/ruleset.version"): $(wc -c < "$STAGE/ruleset.pb" | tr -d ' ') bytes" >&2
