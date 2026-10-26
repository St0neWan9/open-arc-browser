#!/bin/bash
# Notarizes and staples a Developer ID signed "Open Arc.app" (plan D6).
#
# Usage:
#   scripts/notarize.sh [--keychain-profile NAME] [--keychain PATH] [--keychain-password-file FILE]
#                       [--dmg] <path/to/Open Arc.app>
#
#   --keychain-profile  notarytool credentials profile (default open-arc-notary), created once with
#                       `xcrun notarytool store-credentials <name> --key … --key-id … --issuer …
#                       --keychain <keychain>`.
#   --keychain          keychain that holds the profile (default: the user's search list).
#   --keychain-password-file  optional: unlock --keychain with the password in this file first.
#   --dmg               also build "<app name>.dmg" next to the app (a compressed UDZO image with
#                       the stapled app and an /Applications link), sign it with the app's
#                       Developer ID, notarize and staple it.
#
# Steps: check the app is Developer ID signed with the hardened runtime and a secure timestamp;
# zip it with `ditto -c -k --keepParent` (a temporary upload archive, not the release archive);
# `notarytool submit --wait`; if the status is not Accepted, print `notarytool log` and fail;
# otherwise `stapler staple`, `stapler validate` and `spctl --assess --type execute -vv`, which
# must say "source=Notarized Developer ID". Needs network. Prints the app path on the last line.
# Build and sign first with scripts/make-app.sh --sign-identity … --keychain ….
set -euo pipefail

profile="open-arc-notary"
keychain=""
keychain_password_file=""
make_dmg=0
app=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keychain-profile) profile="$2"; shift 2 ;;
        --keychain) keychain="$2"; shift 2 ;;
        --keychain-password-file) keychain_password_file="$2"; shift 2 ;;
        --dmg) make_dmg=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
        -*) echo "unknown argument: $1" >&2; exit 2 ;;
        *) [[ -z "$app" ]] || { echo "only one app path" >&2; exit 2; }; app="$1"; shift ;;
    esac
done
[[ -n "$app" ]] || { echo "usage: $0 [options] <path/to/App.app>" >&2; exit 2; }
[[ -d "$app" ]] || { echo "not a bundle: $app" >&2; exit 2; }
app="$(cd "$app" && pwd)"

# shellcheck source=scripts/signing-keychain.sh
source "$(dirname "${BASH_SOURCE[0]}")/signing-keychain.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"; restore_signing_keychain_order' EXIT

notary_auth=(--keychain-profile "$profile")
if [[ -n "$keychain" ]]; then
    notary_auth+=(--keychain "$keychain")
    if [[ $make_dmg -eq 1 ]]; then
        # Unlocks it and puts it first in the search list until exit, for codesigning the DMG.
        use_signing_keychain "$keychain" "$keychain_password_file"
    elif [[ -n "$keychain_password_file" ]]; then
        # The password goes straight from the file to security(1); it is never printed.
        security unlock-keychain -p "$(<"$keychain_password_file")" "$keychain"
    fi
elif [[ -n "$keychain_password_file" ]]; then
    echo "--keychain-password-file needs --keychain" >&2; exit 2
fi

# notarize <file>: submits a zip, dmg or pkg and waits; prints the log and fails unless Accepted.
notarize() {
    local file="$1" result submission_id status
    echo "==> notarytool submit ${file##*/} (waits for Apple)" >&2
    # notarytool exits non-zero for some failures and zero for "Invalid"; read the status itself.
    result="$(xcrun notarytool submit "$file" "${notary_auth[@]}" --wait --output-format plist)" || true
    submission_id="$(plutil -extract id raw - <<<"$result" 2>/dev/null || true)"
    status="$(plutil -extract status raw - <<<"$result" 2>/dev/null || true)"
    echo "submission id: ${submission_id:-none}, status: ${status:-unknown}" >&2
    if [[ "$status" != "Accepted" ]]; then
        echo "$result" >&2
        if [[ -n "$submission_id" ]]; then
            echo "==> notarytool log $submission_id" >&2
            xcrun notarytool log "$submission_id" "${notary_auth[@]}" >&2 || true
        fi
        echo "notarization failed for $file" >&2
        exit 1
    fi
}

echo "==> checking the signature of $app" >&2
codesign --verify --deep --strict --verbose=2 "$app" >&2
details="$(codesign -dvv "$app" 2>&1)"
grep -q '^Authority=Developer ID Application: ' <<<"$details" \
    || { echo "$app is not signed with a Developer ID Application identity" >&2; exit 1; }
grep -q '^Timestamp=' <<<"$details" || { echo "$app has no secure timestamp" >&2; exit 1; }
grep -q 'flags=.*(runtime)' <<<"$details" || { echo "$app lacks the hardened runtime" >&2; exit 1; }
team_id="$(sed -n 's/^TeamIdentifier=//p' <<<"$details")"
echo "team: $team_id" >&2

upload="$work/${app##*/}.zip"
ditto -c -k --keepParent "$app" "$upload"
notarize "$upload"

echo "==> stapling" >&2
xcrun stapler staple "$app" >&2
xcrun stapler validate "$app" >&2
spctl_out="$(spctl --assess --type execute -vv "$app" 2>&1)"
echo "$spctl_out" >&2
grep -q 'accepted' <<<"$spctl_out" && grep -q 'source=Notarized Developer ID' <<<"$spctl_out" \
    || { echo "Gatekeeper does not accept $app as notarized" >&2; exit 1; }

if [[ $make_dmg -eq 1 ]]; then
    app_base="$(basename "$app" .app)"
    dmg="$(dirname "$app")/$app_base.dmg"
    echo "==> building $dmg" >&2
    stage="$work/dmg"
    mkdir -p "$stage"
    ditto "$app" "$stage/${app##*/}"
    ln -s /Applications "$stage/Applications"
    rm -f "$dmg"
    hdiutil create -volname "$app_base" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$dmg" >&2
    # Sign the image with the identity that signed the app (same leaf certificate).
    identity="$(codesign -d --extract-certificates="$work/cert" "$app" 2>/dev/null \
        && openssl x509 -inform DER -in "$work/cert0" -noout -fingerprint -sha1 \
        | sed 's/.*=//; s/://g')"
    codesign_args=(--force --sign "$identity" --timestamp)
    [[ -n "$keychain" ]] && codesign_args+=(--keychain "$keychain")
    codesign "${codesign_args[@]}" "$dmg" >&2
    notarize "$dmg"
    xcrun stapler staple "$dmg" >&2
    xcrun stapler validate "$dmg" >&2
    spctl --assess --type open --context context:primary-signature -vv "$dmg" >&2
    echo "dmg: $dmg" >&2
fi

echo "$app"
