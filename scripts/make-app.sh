#!/bin/bash
# Builds "Open Arc.app" from the Swift package in app/ without an Xcode project.
#
# Usage (from anywhere):
#   scripts/make-app.sh [--dev] [--version 0.1.0] [--build N] [--universal] [--scratch-path DIR]
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
#
# Steps: release build of the OpenArcApp product, assemble build/Open Arc.app
# (Contents/MacOS, Info.plist with the version filled in, Resources/AppIcon.icns,
# PkgInfo, Frameworks/Sparkle.framework with an @executable_path/../Frameworks rpath,
# and Frameworks/OpenArcCore.framework when app/Vendor/OpenArcCore.xcframework exists,
# plan C8), ad-hoc sign inside-out (Sparkle's XPC services, Autoupdate, Updater.app,
# the OpenArcCore helper and libraries, the frameworks, then the app with the hardened
# runtime and app/Bundle/OpenArc.entitlements), then verify with codesign and plutil. Idempotent: the bundle is rebuilt from scratch.
# Developer ID signing and notarization are plan task D6 (docs/release.md).
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

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev) dev=1; shift ;;
        --version) version="$2"; shift 2 ;;
        --build) build_number="$2"; shift 2 ;;
        --universal) universal=1; shift ;;
        --scratch-path) scratch_path="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

product="OpenArcApp"           # SwiftPM executable product == CFBundleExecutable
release_bundle_id="org.openarc.browser"   # placeholder id (CLAUDE.md, Decision Q5)
if [[ $dev -eq 1 ]]; then
    bundle_id="$release_bundle_id.dev"     # PersistenceDefaults.developmentBundleIdentifier
    app_name="Open Arc Dev"
else
    bundle_id="$release_bundle_id"
    app_name="Open Arc"        # display name (Decision Q5)
fi
out_dir="$repo_root/build"
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
fi

sign() {
    codesign --force --sign - --timestamp=none --options runtime "$@" >&2
}

echo "==> signing Sparkle.framework inside-out (ad-hoc, hardened runtime)" >&2
# Order and flags follow Sparkle's "sandboxing / code signing" guide: nested code first, keep the
# entitlements Sparkle ships with each helper. D6 swaps "-" for the Developer ID identity.
sparkle_b="$sparkle/Versions/B"
sign --preserve-metadata=entitlements "$sparkle_b/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle_b/XPCServices/Downloader.xpc"
sign --preserve-metadata=entitlements "$sparkle_b/Autoupdate"
sign --preserve-metadata=entitlements "$sparkle_b/Updater.app"
sign "$sparkle"

if [[ -n "$openarc_core" ]]; then
    echo "==> signing OpenArcCore.framework inside-out (ad-hoc, hardened runtime)" >&2
    # The helper runs the renderer, GPU and utility processes (one unbundled executable until
    # the helper apps of plan C10); its entitlements are the union they need under the
    # hardened runtime (app/Bundle/OpenArcHelper.entitlements).
    sign --entitlements "$bundle_src/OpenArcHelper.entitlements" "$openarc_core/Versions/A/Helpers/openarc_helper"
    shopt -s nullglob
    for library in "$openarc_core/Versions/A/Libraries"/*.dylib; do
        sign "$library"
    done
    shopt -u nullglob
    sign "$openarc_core"
fi

echo "==> signing the app (ad-hoc, hardened runtime)" >&2
sign --entitlements "$bundle_src/OpenArc.entitlements" "$app"

echo "==> verifying" >&2
codesign --verify --deep --strict --verbose=2 "$sparkle" >&2
if [[ -n "$openarc_core" ]]; then
    codesign --verify --deep --strict --verbose=2 "$openarc_core" >&2
    echo "OpenArcCore: Chromium $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$openarc_core/Resources/Info.plist")" >&2
fi
codesign --verify --deep --strict --verbose=2 "$app" >&2
plutil -lint "$app/Contents/Info.plist" >&2
[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == "$bundle_id" ]] \
    || { echo "unexpected bundle id in $app" >&2; exit 1; }
echo "bundle id: $bundle_id" >&2
otool -l "$app/Contents/MacOS/$product" | grep -q "path $frameworks_rpath " \
    || { echo "missing rpath $frameworks_rpath" >&2; exit 1; }
echo "Sparkle: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$sparkle/Resources/Info.plist")" >&2
echo "architectures: $(lipo -archs "$app/Contents/MacOS/$product")" >&2

echo "$app"
