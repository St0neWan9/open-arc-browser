#!/bin/sh
# Publishes Open Arc's phishing list for in-app updates (plan B234).
#
# Usage: scripts/publish-phishing-list.sh [options]
#   --out DIR      site root to write into (default: build/phishing-site); the files land in
#                  DIR/phishing/, the path PhishingList.hostedManifestURL points to
#   --key FILE     Ed25519 private key, PEM (default: the ad-block ruleset key,
#                  ~/projects/open-arc-browser-signing/adblock-ruleset-ed25519.pem); the app
#                  checks it against AdBlockRulesetTrust.openArcPublicKeys
#   --source FILE  use this host list instead of downloading one (tests)
#   --serial N     manifest serial (default: UTC yyyymmddHHMMSS); must exceed the published one
#
# Steps:
#   1. Download Phishing.Database's ACTIVE phishing domains (MIT licence,
#      https://github.com/Phishing-Database/Phishing.Database) into a fresh temporary directory.
#   2. Build the list file with scripts/phishing-list/build_list.py, dropping the hosts of
#      scripts/phishing-list/allowlist.txt; version <yyyymmdd>-<hex>.
#   3. Copy list.bin and ATTRIBUTION to OUT/phishing/lists/<version>/.
#   4. Write OUT/phishing/manifest.json (type org.openarc.phishing-list; the ad-block ruleset's
#      manifest shape) and sign its exact bytes into manifest.json.sig.
#
# Upload like the ad-block ruleset: lists/ first, then manifest.json.sig and manifest.json.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# The project's own host first, then its GitHub copy (same file).
SOURCE_URLS="https://phish.co.za/latest/phishing-domains-ACTIVE.txt https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-domains-ACTIVE.txt"

OUT="$REPO/build/phishing-site"
KEY="$HOME/projects/open-arc-browser-signing/adblock-ruleset-ed25519.pem"
SOURCE=""
SERIAL=""

die() { echo "publish-phishing-list.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
done

[ -r "$KEY" ] || die "no private key at $KEY"
OPENSSL=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl \
                 /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" pkey -in "$KEY" -text -noout 2>/dev/null | grep -qi 'ED25519'; then
        OPENSSL="$candidate"; break
    fi
done
[ -n "$OPENSSL" ] || die "need OpenSSL 3 with Ed25519 support and an Ed25519 key in $KEY"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/oa-phishing.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/source" "$TMP/build"

# 1. Source.
if [ -z "$SOURCE" ]; then
    for url in $SOURCE_URLS; do
        curl -fsSL --max-time 300 -o "$TMP/source/hosts.txt" "$url" && break
        echo "publish-phishing-list.sh: $url failed, trying the next source" >&2
        rm -f "$TMP/source/hosts.txt"
    done
    [ -s "$TMP/source/hosts.txt" ] || die "download failed: $SOURCE_URLS"
    SOURCE="$TMP/source/hosts.txt"
fi
[ -s "$SOURCE" ] || die "empty source $SOURCE"

# 2. List file.
VERSION="$(python3 -I "$HERE/phishing-list/build_list.py" "$SOURCE" "$HERE/phishing-list/allowlist.txt" "$TMP/build/list.bin")"
echo "$VERSION" | grep -Eq '^[0-9]{8}-[0-9a-f]{12}$' || die "bad version '$VERSION'"
cat > "$TMP/build/ATTRIBUTION" <<ATTR
Open Arc phishing list $VERSION
Hosts from Phishing.Database (https://github.com/Phishing-Database/Phishing.Database),
phishing-domains-ACTIVE.txt, MIT License:
Copyright (c) 2018-2025 Mitchell Krog, Nissar Chababy and the Phishing.Database contributors.
Stored as truncated SHA-256 hashes of the hosts.
ATTR

[ -n "$SERIAL" ] || SERIAL="$(date -u +%Y%m%d%H%M%S)"
echo "$SERIAL" | grep -Eq '^[1-9][0-9]{0,17}$' || die "serial must be a positive integer"
SITE="$OUT/phishing"
if [ -f "$SITE/manifest.json" ]; then
    previous="$(sed -n 's/.*"serial": *\([0-9][0-9]*\).*/\1/p' "$SITE/manifest.json" | head -1)"
    if [ -n "$previous" ] && [ "$SERIAL" -le "$previous" ]; then
        die "serial $SERIAL is not above the published $previous"
    fi
fi

# 3. Files.
DEST="$SITE/lists/$VERSION"
mkdir -p "$DEST"
cp "$TMP/build/list.bin" "$TMP/build/ATTRIBUTION" "$DEST/"
sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { wc -c < "$1" | tr -d ' '; }

# 4. Manifest and signature.
cat > "$TMP/manifest.json" <<JSON
{
  "type": "org.openarc.phishing-list",
  "format": 1,
  "serial": $SERIAL,
  "version": "$VERSION",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ruleset": {
    "path": "lists/$VERSION/list.bin",
    "size": $(size "$DEST/list.bin"),
    "sha256": "$(sha256 "$DEST/list.bin")"
  },
  "attribution": {
    "path": "lists/$VERSION/ATTRIBUTION",
    "size": $(size "$DEST/ATTRIBUTION"),
    "sha256": "$(sha256 "$DEST/ATTRIBUTION")"
  }
}
JSON
"$OPENSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$TMP/manifest.json" -out "$TMP/manifest.sig.bin"
[ "$(size "$TMP/manifest.sig.bin")" = 64 ] || die "unexpected signature length"
"$OPENSSL" pkey -in "$KEY" -pubout -out "$TMP/public.pem"
"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$TMP/public.pem" \
    -in "$TMP/manifest.json" -sigfile "$TMP/manifest.sig.bin" >/dev/null || die "the signature does not verify"
"$OPENSSL" pkey -in "$KEY" -pubout -outform DER -out "$TMP/public.der"
PUBLIC_KEY="$(tail -c 32 "$TMP/public.der" | base64)"
grep -F "openArcPublicKeys" "$REPO/app/Sources/OpenArcEngine/AdBlockRulesetUpdates.swift" | grep -Fq "\"$PUBLIC_KEY\"" ||
    die "public key $PUBLIC_KEY is not built into the app"
base64 < "$TMP/manifest.sig.bin" | tr -d '\n' > "$SITE/manifest.json.sig"
echo >> "$SITE/manifest.json.sig"
mv "$TMP/manifest.json" "$SITE/manifest.json"

echo "published phishing list $VERSION (serial $SERIAL) in $SITE" >&2
