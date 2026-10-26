#!/bin/bash
# Builds "Open Arc.app" from the Swift package in app/ without an Xcode project.
#
# Usage (from anywhere):
#   scripts/make-app.sh [--dev] [--version 0.1.0] [--build N] [--universal] [--scratch-path DIR]
#                       [--out-dir DIR]
#                       [--sign-identity SHA1 --keychain PATH [--keychain-password-file FILE]]
#
#   --dev           development build (plan B37): bundle id org.openarc.browser.dev, name
#                   "Open Arc Dev", output build/Open Arc Dev.app. The app derives everything
#                   keyed by the bundle id at runtime (default data dir
#                   ~/Library/Application Support/org.openarc.browser.dev, defaults domain, drag
#                   types); this script rewrites the exported drag types to <id>.<name> and drops
#                   the Sparkle feed, so the dev build never updates itself. URL and document
#                   types stay: registering for http/https does not make it the default browser.
#   --version       CFBundleShortVersionString (default 0.1.0)
#   --build         CFBundleVersion, the build number (default 1)
#   --universal     build arm64 + x86_64 (default: arm64 only)
#   --scratch-path  SwiftPM scratch directory (default app/.build/scratch-make-app),
#                   kept apart from app/.build so it does not race with other builds
#   --out-dir       where the bundle is assembled (default build/ in the repo)
#
# Release signing (plan D6, opt-in; without it every build is signed ad-hoc as before):
#   --sign-identity  SHA-1 of the "Developer ID Application" identity. Always a hash, never the
#                    name: two identities with the same name can exist in the search list.
#   --keychain       keychain that holds that identity (passed to codesign --keychain).
#   --keychain-password-file  optional: unlock --keychain with the password in this file first.
#   While signing, --keychain is moved to the front of the user keychain search list and put back
#   afterwards (scripts/signing-keychain.sh): codesign finds the private key through the search
#   list, and a copy of the key in the login keychain makes it fail with errSecInternalComponent
#   when no one can answer the keychain prompt (SSH, agents).
#   Developer ID mode signs with --timestamp (Apple's secure timestamp, needs network) and the
#   hardened runtime, in the same inside-out order as ad-hoc, and drops
#   com.apple.security.cs.disable-library-validation from every entitlements file except the
#   Plugin helper's (one team signs everything, so library validation passes; C18 CDMs need it).
#   Then verifies that every signature carries the identity's Team ID. Notarize the result with
#   scripts/notarize.sh. Example:
#     scripts/make-app.sh --version 0.2.0 --build 2 \
#         --sign-identity 14D84F5327335E27AF84B31C5921A0DEF8E92CA1 \
#         --keychain ~/projects/open-arc-browser-signing/open-arc-signing.keychain-db
#     scripts/notarize.sh "build/Open Arc.app"
#
# Steps: release build of the OpenArcApp product, assemble build/Open Arc.app
# (Contents/MacOS, Info.plist with the version filled in, Resources/AppIcon.icns,
# PkgInfo, Frameworks/Sparkle.framework with an @executable_path/../Frameworks rpath,
# and Frameworks/OpenArcCore.framework when app/Vendor/OpenArcCore.xcframework exists,
# plan C8), give the OpenArcCore helper apps the app's bundle id prefix (plan C10:
# <bundle id>.helper, .helper.renderer, .helper.plugin, .helper.alerts; the GPU helper
# shares <bundle id>.helper), ad-hoc sign inside-out (Sparkle's XPC services, Autoupdate,
# Updater.app; each OpenArcCore helper app with its own app/Bundle/Helpers/*.entitlements,
# crashpad and the libraries; the frameworks; then the app with the hardened runtime and
# app/Bundle/OpenArc.entitlements; Developer ID instead with --sign-identity), then verify with
# codesign --deep --strict and plutil.
# With --universal the app and OpenArcCore.framework must both carry arm64 and x86_64
# (chromium-bridge/build-framework.sh --universal). Idempotent: the bundle is rebuilt from
# scratch. Release steps: docs/release.md.
# Prints the bundle path on the last line. Uses only Xcode / system tools.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_dir="$repo_root/app"
bundle_src="$package_dir/Bundle"

version="0.1.0"
build_number="1"
universal=0
dev=0
scratch_path="$package_dir/.build/scratch-make-app"
out_dir="$repo_root/build"
sign_identity=""
keychain=""
keychain_password_file=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev) dev=1; shift ;;
        --version) version="$2"; shift 2 ;;
        --build) build_number="$2"; shift 2 ;;
        --universal) universal=1; shift ;;
        --scratch-path) scratch_path="$2"; shift 2 ;;
        --out-dir) out_dir="$2"; shift 2 ;;
        --sign-identity) sign_identity="$2"; shift 2 ;;
        --keychain) keychain="$2"; shift 2 ;;
        --keychain-password-file) keychain_password_file="$2"; shift 2 ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

if [[ -n "$sign_identity" ]]; then
    [[ "$sign_identity" =~ ^[0-9A-Fa-f]{40}$ ]] \
        || { echo "--sign-identity takes the identity's SHA-1 (40 hex digits), not its name" >&2; exit 2; }
    [[ -n "$keychain" ]] || { echo "--sign-identity needs --keychain" >&2; exit 2; }
    [[ -f "$keychain" ]] || { echo "keychain not found: $keychain" >&2; exit 2; }
    keychain="$(cd "$(dirname "$keychain")" && pwd)/$(basename "$keychain")"
    security find-identity -v -p codesigning "$keychain" | grep -qi " $sign_identity \"Developer ID Application: " \
        || { echo "no valid Developer ID Application identity $sign_identity in $keychain" >&2; exit 2; }
    team_id="$(security find-certificate -a -Z -p "$keychain" \
        | awk -v h="$(tr a-f A-F <<<"$sign_identity")" '/^SHA-1 hash:/ {keep = ($3 == h)} keep' \
        | openssl x509 -noout -subject -nameopt multiline | awk -F' = ' '/organizationalUnitName/ {print $2; exit}')"
    [[ -n "$team_id" ]] || { echo "cannot read the Team ID of $sign_identity" >&2; exit 2; }
elif [[ -n "$keychain" || -n "$keychain_password_file" ]]; then
    echo "--keychain and --keychain-password-file need --sign-identity" >&2; exit 2
fi
# shellcheck source=scripts/signing-keychain.sh
source "$repo_root/scripts/signing-keychain.sh"

product="OpenArcApp"           # SwiftPM executable product == CFBundleExecutable
release_bundle_id="org.openarc.browser"   # placeholder id (CLAUDE.md, Decision Q5)
if [[ $dev -eq 1 ]]; then
    bundle_id="$release_bundle_id.dev"     # PersistenceDefaults.developmentBundleIdentifier
    app_name="Open Arc Dev"
else
    bundle_id="$release_bundle_id"
    app_name="Open Arc"        # display name (Decision Q5)
fi
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"

# OpenArcCore's helper apps (plan C10, //openarc/app/helpers.gni) and the entitlements each
# is signed with ("<name suffix>:<file in app/Bundle/Helpers>").
openarc_helpers=(
    ":helper.entitlements"
    " (Renderer):renderer.entitlements"
    " (GPU):gpu.entitlements"
    " (Plugin):plugin.entitlements"
    " (Alerts):alerts.entitlements"
)
app="$out_dir/$app_name.app"

if [[ $universal -eq 1 ]]; then
    arch_args=(--arch arm64 --arch x86_64)
else
    arch_args=(--arch arm64)
fi
build_args=(--package-path "$package_dir" --scratch-path "$scratch_path"
            -c release --product "$product" "${arch_args[@]}")

echo "==> swift build ${build_args[*]}" >&2
swift build "${build_args[@]}" >&2
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
binary="$bin_dir/$product"
[[ -x "$binary" ]] || { echo "missing build output: $binary" >&2; exit 1; }

echo "==> assembling $app" >&2
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$binary" "$app/Contents/MacOS/$product"
cp "$bundle_src/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
cp "$bundle_src/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"
if [[ $dev -eq 1 ]]; then
    info="$app/Contents/Info.plist"
    plutil -replace CFBundleIdentifier -string "$bundle_id" "$info"
    plutil -replace CFBundleName -string "$app_name" "$info"
    plutil -replace CFBundleDisplayName -string "$app_name" "$info"
    # Exported types must be unique per app: <bundle id>.<name>, matching the identifiers the
    # app builds from its own bundle id (SidebarDragPayload.itemType, LibraryBoardDragPayload).
    type_count="$(plutil -extract UTExportedTypeDeclarations raw "$info")"
    for ((i = 0; i < type_count; i++)); do
        type_id="$(plutil -extract "UTExportedTypeDeclarations.$i.UTTypeIdentifier" raw "$info")"
        [[ "$type_id" == "$release_bundle_id".* ]] \
            || { echo "unexpected exported type $type_id" >&2; exit 1; }
        plutil -replace "UTExportedTypeDeclarations.$i.UTTypeIdentifier" \
            -string "$bundle_id.${type_id#"$release_bundle_id".}" "$info"
        type_description="$(plutil -extract "UTExportedTypeDeclarations.$i.UTTypeDescription" raw "$info")"
        plutil -replace "UTExportedTypeDeclarations.$i.UTTypeDescription" \
            -string "${type_description/#Open Arc /$app_name }" "$info"
    done
    # No update feed: UpdateConfiguration reports "This build has no update feed".
    plutil -remove SUFeedURL "$info"
    plutil -replace SUEnableAutomaticChecks -bool NO "$info"
fi
plutil -convert xml1 "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

# SwiftPM puts resource bundles (<Package>_<Target>.bundle) next to the binary.
# There are none today; copy any that appear so Bundle.module keeps working.
shopt -s nullglob
for resource_bundle in "$bin_dir"/*.bundle; do
    cp -R "$resource_bundle" "$app/Contents/Resources/"
done
shopt -u nullglob

# Sparkle 2 (plan D7). SwiftPM copies the binary framework next to the executable; ditto keeps
# its Versions/ symlinks. The executable links @rpath/Sparkle.framework, so it needs an rpath to
# Contents/Frameworks (SwiftPM only adds @loader_path, i.e. Contents/MacOS).
sparkle_src="$bin_dir/Sparkle.framework"
[[ -d "$sparkle_src" ]] || { echo "missing Sparkle.framework in $bin_dir" >&2; exit 1; }
sparkle="$app/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle_src" "$sparkle"
# Headers are only needed to compile against Sparkle; drop them from the shipped bundle.
rm -rf "$sparkle/Headers" "$sparkle/PrivateHeaders" "$sparkle/Modules" \
       "$sparkle/Versions/B/Headers" "$sparkle/Versions/B/PrivateHeaders" "$sparkle/Versions/B/Modules"
frameworks_rpath="@executable_path/../Frameworks"
if ! otool -l "$app/Contents/MacOS/$product" | grep -q "path $frameworks_rpath "; then
    install_name_tool -add_rpath "$frameworks_rpath" "$app/Contents/MacOS/$product"
fi

# OpenArcCore.framework (plan C8): our Chromium fork. SwiftPM copies the binary target's framework
# next to the executable when the package has it (app/Vendor/OpenArcCore.xcframework); the
# executable links @rpath/OpenArcCore.framework/Versions/A/OpenArcCore, found through the same
# Contents/Frameworks rpath as Sparkle.
openarc_core_src="$bin_dir/OpenArcCore.framework"
openarc_core=""
if [[ -d "$package_dir/Vendor/OpenArcCore.xcframework" ]]; then
    [[ -d "$openarc_core_src" ]] || { echo "missing OpenArcCore.framework in $bin_dir" >&2; exit 1; }
    openarc_core="$app/Contents/Frameworks/OpenArcCore.framework"
    ditto "$openarc_core_src" "$openarc_core"
    # Headers and the module map are only needed to compile against the framework.
    rm -rf "$openarc_core/Headers" "$openarc_core/Modules" \
           "$openarc_core/Versions/A/Headers" "$openarc_core/Versions/A/Modules"
    if [[ $universal -eq 1 ]]; then
        core_archs="$(lipo -archs "$openarc_core/Versions/A/OpenArcCore")"
        [[ "$core_archs" == *arm64* && "$core_archs" == *x86_64* ]] \
            || { echo "OpenArcCore.framework is not universal ($core_archs);" \
                      "run chromium-bridge/build-framework.sh --universal" >&2; exit 1; }
    fi

    # Helper apps (plan C10): Chromium's Mac helper model, one app per code-signing variant.
    # The framework ships them with the release ids (org.openarc.browser.helper…); every id
    # takes the embedding app's id as its prefix, so the development build's helpers are
    # org.openarc.browser.dev.helper…, matching the base bundle id the engine reads from the
    # embedding app (patch 0009).
    helpers_dir="$openarc_core/Versions/A/Helpers"
    helper_count=0
    for helper_app in "$helpers_dir"/*.app; do
        [[ -d "$helper_app" ]] || continue
        helper_info="$helper_app/Contents/Info.plist"
        helper_id="$(plutil -extract CFBundleIdentifier raw "$helper_info")"
        [[ "$helper_id" == "$release_bundle_id.helper" || "$helper_id" == "$release_bundle_id.helper".* ]] \
            || { echo "unexpected helper bundle id $helper_id in $helper_app" >&2; exit 1; }
        plutil -replace CFBundleIdentifier -string "$bundle_id${helper_id#"$release_bundle_id"}" "$helper_info"
        helper_count=$((helper_count + 1))
    done
    [[ $helper_count -eq ${#openarc_helpers[@]} ]] \
        || { echo "expected ${#openarc_helpers[@]} helper apps in $helpers_dir, found $helper_count" >&2; exit 1; }
    # Plan C16: the ad blocker's filter lists (EasyList + EasyPrivacy, CC BY-SA 3.0) need their
    # attribution in the app; the framework carries it next to the ruleset
    # (chromium-bridge/build-adblock-ruleset.sh), and a copy goes to the app's Resources.
    adblock_attribution="$openarc_core/Versions/A/Resources/AdBlock/ATTRIBUTION"
    if [[ -f "$adblock_attribution" ]]; then
        cp "$adblock_attribution" "$app/Contents/Resources/ATTRIBUTION-AdBlock.txt"
    else
        echo "warning: OpenArcCore.framework has no ad block ruleset (run chromium-bridge/build-adblock-ruleset.sh)" >&2
    fi
    # Notifications shown by the alerts helper carry the app's icon.
    alerts_app="$helpers_dir/Open Arc Helper (Alerts).app"
    mkdir -p "$alerts_app/Contents/Resources"
    cp "$bundle_src/AppIcon.icns" "$alerts_app/Contents/Resources/AppIcon.icns"
    plutil -replace CFBundleIconFile -string AppIcon "$alerts_app/Contents/Info.plist"
fi

if [[ -n "$sign_identity" ]]; then
    sign_mode="Developer ID, team $team_id"
    sign() {
        codesign --force --sign "$sign_identity" --keychain "$keychain" --timestamp \
            --options runtime "$@" >&2
    }
else
    sign_mode="ad-hoc"
    sign() {
        codesign --force --sign - --timestamp=none --options runtime "$@" >&2
    }
fi

# entitlements <file in app/Bundle>: the path to sign with. Ad-hoc signatures carry no Team ID,
# so library validation would refuse our own frameworks; the files therefore turn it off. With a
# Developer ID every image carries one Team ID and validation passes, so a stripped copy is used,
# except for the Plugin helper, which loads CDMs signed by other teams (plan C18).
entitlements_tmp="$(mktemp -d)"
trap 'rm -rf "$entitlements_tmp"; restore_signing_keychain_order' EXIT
if [[ -n "$sign_identity" ]]; then
    # Unlocks the keychain (if a password file is given) and puts it first in the search list
    # until the script exits; see scripts/signing-keychain.sh for why.
    use_signing_keychain "$keychain" "$keychain_password_file"
fi
entitlements() {
    local src="$bundle_src/$1"
    if [[ -z "$sign_identity" || "$1" == "Helpers/plugin.entitlements" ]]; then
        echo "$src"
        return
    fi
    local dst="$entitlements_tmp/${1//\//_}"
    cp "$src" "$dst"
    # PlistBuddy, not plutil: plutil reads the dots in the key as a key path.
    if /usr/libexec/PlistBuddy -c "Print :com.apple.security.cs.disable-library-validation" "$dst" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Delete :com.apple.security.cs.disable-library-validation" "$dst" >/dev/null
    fi
    echo "$dst"
}

echo "==> signing Sparkle.framework inside-out ($sign_mode, hardened runtime)" >&2
# Order and flags follow Sparkle's "sandboxing / code signing" guide: nested code first, keep the
# entitlements Sparkle ships with each helper.
sparkle_b="$sparkle/Versions/B"
sign --preserve-metadata=entitlements "$sparkle_b/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle_b/XPCServices/Downloader.xpc"
sign --preserve-metadata=entitlements "$sparkle_b/Autoupdate"
sign --preserve-metadata=entitlements "$sparkle_b/Updater.app"
sign "$sparkle"

if [[ -n "$openarc_core" ]]; then
    echo "==> signing OpenArcCore.framework inside-out ($sign_mode, hardened runtime)" >&2
    # Each helper app with its own entitlements (app/Bundle/Helpers/*.entitlements, the
    # minimum per process type; see the comments in each file), then crashpad and the
    # libraries, then the framework.
    for helper in "${openarc_helpers[@]}"; do
        helper_suffix="${helper%%:*}"
        helper_entitlements="$(entitlements "Helpers/${helper#*:}")"
        sign --entitlements "$helper_entitlements" "$helpers_dir/Open Arc Helper$helper_suffix.app"
    done
    sign "$helpers_dir/chrome_crashpad_handler"
    shopt -s nullglob
    for library in "$openarc_core/Versions/A/Libraries"/*.dylib; do
        sign "$library"
    done
    shopt -u nullglob
    sign "$openarc_core"
fi

echo "==> signing the app ($sign_mode, hardened runtime)" >&2
sign --entitlements "$(entitlements OpenArc.entitlements)" "$app"

echo "==> verifying" >&2
codesign --verify --deep --strict --verbose=2 "$sparkle" >&2
if [[ -n "$openarc_core" ]]; then
    for helper in "${openarc_helpers[@]}"; do
        codesign --verify --strict --verbose=2 "$helpers_dir/Open Arc Helper${helper%%:*}.app" >&2
    done
    codesign --verify --deep --strict --verbose=2 "$openarc_core" >&2
    echo "OpenArcCore: Chromium $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$openarc_core/Resources/Info.plist")" >&2
fi
codesign --verify --deep --strict --verbose=2 "$app" >&2
if [[ -n "$sign_identity" ]]; then
    # Every Mach-O image must carry our Team ID and a secure timestamp (notarization requires both).
    while IFS= read -r -d '' image; do
        file -b "$image" | grep -q '^Mach-O' || continue
        details="$(codesign -dvv "$image" 2>&1)"
        grep -q "^TeamIdentifier=$team_id\$" <<<"$details" \
            || { echo "not signed by team $team_id: $image" >&2; exit 1; }
        grep -q '^Timestamp=' <<<"$details" \
            || { echo "no secure timestamp: $image" >&2; exit 1; }
    done < <(find "$app" -type f -print0)
    # Only the Plugin helper may turn library validation off (see entitlements()).
    for code in "$app" "${helpers_dir:-/nonexistent}"/*.app; do
        [[ -d "$code" ]] || continue
        [[ "$code" == *"(Plugin).app" ]] && continue
        if codesign -d --entitlements - --xml "$code" 2>/dev/null \
            | grep -q 'com.apple.security.cs.disable-library-validation'; then
            echo "library validation still disabled in $code" >&2; exit 1
        fi
    done
    echo "signed: Developer ID, team $team_id, every Mach-O image timestamped, library validation on" >&2
fi
plutil -lint "$app/Contents/Info.plist" >&2
[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == "$bundle_id" ]] \
    || { echo "unexpected bundle id in $app" >&2; exit 1; }
echo "bundle id: $bundle_id" >&2
otool -l "$app/Contents/MacOS/$product" | grep -q "path $frameworks_rpath " \
    || { echo "missing rpath $frameworks_rpath" >&2; exit 1; }
echo "Sparkle: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$sparkle/Resources/Info.plist")" >&2
echo "architectures: $(lipo -archs "$app/Contents/MacOS/$product")" >&2
if [[ -n "$openarc_core" ]]; then
    echo "OpenArcCore architectures: $(lipo -archs "$openarc_core/Versions/A/OpenArcCore")" >&2
    for helper_app in "$helpers_dir"/*.app; do
        echo "helper: ${helper_app##*/} $(plutil -extract CFBundleIdentifier raw "$helper_app/Contents/Info.plist")" >&2
    done
fi

echo "$app"
