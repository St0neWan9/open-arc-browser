#!/bin/sh
# Publishes an ad-block filter ruleset for in-app updates (plan C19).
#
# Usage: scripts/publish-adblock-ruleset.sh [options]
#   --out DIR            site root to write into (default: build/adblock-site); the files land in
#                        DIR/adblock/, the path the app's manifest URL points to
#   --key FILE           Ed25519 private key, PEM (default:
#                        ~/projects/open-arc-browser-signing/adblock-ruleset-ed25519.pem)
#   --from DIR           publish an existing ruleset directory (ruleset.pb, ruleset.version,
#                        ATTRIBUTION) instead of building one; for test rulesets
#   --chromium-src DIR   passed to build-adblock-ruleset.sh (default: ~/chromium/src)
#   --out-dir DIR        GN output dir, passed to build-adblock-ruleset.sh (default: out/Release)
#   --serial N           manifest serial (default: UTC yyyymmddHHMMSS); must exceed the serial of
#                        the manifest already in --out
#   --allow-unknown-key  sign even when the key is not the one built into the app (only for the
#                        bad-signature test; the app rejects such a manifest)
#
# Steps:
#   1. Build the ruleset with chromium-bridge/build-adblock-ruleset.sh (EasyList + EasyPrivacy ->
#      ruleset.pb, ruleset.version, ATTRIBUTION; staged in app/.build/adblock/ruleset/), unless
#      --from is given.
#   2. Copy the files to OUT/adblock/rulesets/<version>/ (older versions stay; the host is a plain
#      static tree, and a client mid-download keeps finding its files).
#   3. Write OUT/adblock/manifest.json: type, format, serial, version, published, and for
#      ruleset.pb and ATTRIBUTION their path (relative to the manifest), size and SHA-256.
#   4. Sign the exact bytes of manifest.json with Ed25519 (OpenSSL 3+, `pkeyutl -rawin`) into
#      manifest.json.sig (base64 of the 64-byte signature), then verify the signature again with
#      the key the app has built in (AdBlockRulesetTrust.openArcPublicKeys).
#
# Upload OUT/adblock/ to the static host so that manifest.json is the LAST file to change: the
# rulesets directory first, then manifest.json.sig and manifest.json together (a client that reads
# a new manifest with the old signature rejects it and retries at its next check).
#
# The private key never enters a repository. Back it up offline; losing it means a release with a
# new public key before rulesets can be published again. Local test host: chromium-bridge/README.md
# §Ad blocking.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

OUT="$REPO/build/adblock-site"
KEY="$HOME/projects/open-arc-browser-signing/adblock-ruleset-ed25519.pem"
FROM=""
SRC="$HOME/chromium/src"
GN_OUT="out/Release"
SERIAL=""
ALLOW_UNKNOWN_KEY=0

die() { echo "publish-adblock-ruleset.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --key) KEY="$2"; shift 2 ;;
        --from) FROM="$2"; shift 2 ;;
        --chromium-src) SRC="$2"; shift 2 ;;
        --out-dir) GN_OUT="$2"; shift 2 ;;
        --serial) SERIAL="$2"; shift 2 ;;
        --allow-unknown-key) ALLOW_UNKNOWN_KEY=1; shift ;;
        -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option $1" ;;
    esac
done

[ -r "$KEY" ] || die "no private key at $KEY"

# An OpenSSL with Ed25519 (macOS's LibreSSL has none): Homebrew's first, then PATH.
OPENSSL=""
for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl \
                 /usr/local/opt/openssl@3/bin/openssl "$(command -v openssl || true)"; do
    [ -n "$candidate" ] && [ -x "$candidate" ] || continue
    if "$candidate" pkey -in "$KEY" -noout 2>/dev/null &&
       "$candidate" pkey -in "$KEY" -text -noout 2>/dev/null | grep -qi 'ED25519'; then
        OPENSSL="$candidate"
        break
    fi
done
[ -n "$OPENSSL" ] || die "need OpenSSL 3 with Ed25519 support (brew install openssl@3), and an Ed25519 key in $KEY"

# 1. The ruleset.
if [ -z "$FROM" ]; then
    "$REPO/chromium-bridge/build-adblock-ruleset.sh" "$SRC" "$GN_OUT" -
    FROM="$REPO/app/.build/adblock/ruleset"
fi
for file in ruleset.pb ruleset.version ATTRIBUTION; do
    [ -s "$FROM/$file" ] || die "missing $FROM/$file"
done
VERSION="$(tr -d ' \t\r\n' < "$FROM/ruleset.version")"
# Same rule as AdBlockRulesetVersion.isValid: <yyyymmdd>-<6..64 lowercase hex>.
echo "$VERSION" | grep -Eq '^[0-9]{8}-[0-9a-f]{6,64}$' ||
    die "ruleset.version '$VERSION' is not <yyyymmdd>-<hex>"

# Serial: increasing, so a client never accepts an older manifest again.
[ -n "$SERIAL" ] || SERIAL="$(date -u +%Y%m%d%H%M%S)"
echo "$SERIAL" | grep -Eq '^[1-9][0-9]{0,17}$' || die "serial must be a positive integer"
SITE="$OUT/adblock"
if [ -f "$SITE/manifest.json" ]; then
    previous="$(sed -n 's/.*"serial": *\([0-9][0-9]*\).*/\1/p' "$SITE/manifest.json" | head -1)"
    if [ -n "$previous" ] && [ "$SERIAL" -le "$previous" ]; then
        die "serial $SERIAL is not above the published $previous"
    fi
fi

# 2. Files.
DEST="$SITE/rulesets/$VERSION"
mkdir -p "$DEST"
cp "$FROM/ruleset.pb" "$FROM/ATTRIBUTION" "$FROM/ruleset.version" "$DEST/"

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
size() { wc -c < "$1" | tr -d ' '; }

# 3. Manifest (written to a temporary name, renamed after signing).
TMP="$(mktemp -d "${TMPDIR:-/tmp}/oa-adblock.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/manifest.json" <<EOF
{
  "type": "org.openarc.adblock-ruleset",
  "format": 1,
  "serial": $SERIAL,
  "version": "$VERSION",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ruleset": {
    "path": "rulesets/$VERSION/ruleset.pb",
    "size": $(size "$DEST/ruleset.pb"),
    "sha256": "$(sha256 "$DEST/ruleset.pb")"
  },
  "attribution": {
    "path": "rulesets/$VERSION/ATTRIBUTION",
    "size": $(size "$DEST/ATTRIBUTION"),
    "sha256": "$(sha256 "$DEST/ATTRIBUTION")"
  }
}
EOF

# 4. Signature over the exact bytes.
"$OPENSSL" pkeyutl -sign -rawin -inkey "$KEY" -in "$TMP/manifest.json" -out "$TMP/manifest.sig.bin"
[ "$(size "$TMP/manifest.sig.bin")" = 64 ] || die "unexpected signature length"
base64 < "$TMP/manifest.sig.bin" | tr -d '\n' > "$TMP/manifest.json.sig"
echo >> "$TMP/manifest.json.sig"

"$OPENSSL" pkey -in "$KEY" -pubout -out "$TMP/public.pem"
"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$TMP/public.pem" \
    -in "$TMP/manifest.json" -sigfile "$TMP/manifest.sig.bin" >/dev/null ||
    die "the signature does not verify"

# The raw 32-byte public key is the tail of its 44-byte DER form.
"$OPENSSL" pkey -in "$KEY" -pubout -outform DER -out "$TMP/public.der"
PUBLIC_KEY="$(tail -c 32 "$TMP/public.der" | base64)"
TRUST="$REPO/app/Sources/OpenArcEngine/AdBlockRulesetUpdates.swift"
if ! grep -F "openArcPublicKeys" "$TRUST" | grep -Fq "\"$PUBLIC_KEY\""; then
    if [ "$ALLOW_UNKNOWN_KEY" = 1 ]; then
        echo "publish-adblock-ruleset.sh: warning: key $PUBLIC_KEY is not built into the app; it will reject this manifest" >&2
    else
        die "public key $PUBLIC_KEY is not in AdBlockRulesetTrust.openArcPublicKeys ($TRUST)"
    fi
fi

mv "$TMP/manifest.json.sig" "$SITE/manifest.json.sig"
mv "$TMP/manifest.json" "$SITE/manifest.json"

echo "published ad block ruleset $VERSION (serial $SERIAL) in $SITE" >&2
echo "  manifest.json, manifest.json.sig, rulesets/$VERSION/{ruleset.pb,ATTRIBUTION,ruleset.version}" >&2
