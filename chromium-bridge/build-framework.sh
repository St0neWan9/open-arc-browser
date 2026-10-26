#!/bin/sh
# Builds OpenArcCore.framework in the Chromium checkout and packages it as
# app/Vendor/OpenArcCore.xcframework for the Swift package (plan C8).
#
# Usage: chromium-bridge/build-framework.sh [--no-build] [--universal] [CHROMIUM_SRC] [OUT_DIR]
#   --no-build    skip ninja; package the framework already in OUT_DIR (and X64_OUT_DIR)
#   --universal   also build OUT_DIR_x64 (target_cpu="x64", default out/Release_x64) and merge
#                 both frameworks into one universal (arm64 + x86_64) framework (plan C10b,
#                 deferred: written in C10 but not yet run against an x86_64 build)
#   CHROMIUM_SRC  Chromium's src/ directory (default: ~/chromium/src)
#   OUT_DIR       GN output directory relative to CHROMIUM_SRC (default: out/Release, arm64)
#
# Steps:
#   1. ninja -C OUT_DIR openarc_framework (the GN target in //openarc/BUILD.gn; OUT_DIR's
#      args.gn must list it in root_extra_deps, see chromium-patches/README.md §Building).
#      With --universal, the same in OUT_DIR_x64, whose args.gn is OUT_DIR's with
#      target_cpu = "x64".
#   1b. chromium-bridge/build-adblock-ruleset.sh: downloads EasyList + EasyPrivacy into
#      app/.build/adblock/ and installs the converted ruleset into the framework's
#      Resources/AdBlock/ (plan C16; ninja does not know these files, so this runs after every
#      build). Set OPENARC_SKIP_ADBLOCK=1 to skip it (offline; the ad blocker then matches nothing
#      unless an earlier ruleset was already indexed in the profile directory).
#   2. Check each framework: install name, exported symbols (OAC* and OACChildProcessMain only),
#      headers in sync with chromium-bridge/include, module map, the helper apps (plan C10).
#   3. --universal: merge the two frameworks with Chromium's
#      chrome/installer/mac/universalizer.py (lipo for Mach-O files that differ, Info.plists
#      merged, everything else must be identical; the V8 snapshots differ by name, so both
#      stay) into OUT_DIR_universal/OpenArcCore.framework.
#   4. xcodebuild -create-xcframework into app/Vendor/OpenArcCore.xcframework (one macOS
#      slice: arm64, or arm64 + x86_64 with --universal).
#
# The xcframework is git-ignored (app/Vendor/.gitignore); app/Package.swift adds the
# OpenArcChromium target only when it exists. Long build: run in the background and poll
# (a cold x64 build takes hours). Uses only Chromium's toolchain and Xcode's tools.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

build=1
universal=0
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) build=0; shift ;;
        --universal) universal=1; shift ;;
        *) break ;;
    esac
done
SRC="${1:-$HOME/chromium/src}"
OUT="${2:-out/Release}"
OUT_X64="${OUT}_x64"
OUT_UNIVERSAL="${OUT}_universal"

VENDOR="$REPO/app/Vendor"
XCFRAMEWORK="$VENDOR/OpenArcCore.xcframework"

# Builds and checks the framework in OUT_DIR $1 for architecture $2.
build_and_check() {
    out="$1"
    arch="$2"
    framework="$SRC/$out/OpenArcCore.framework"
    if [ $build -eq 1 ]; then
        echo "==> ninja -C $out openarc_framework" >&2
        "$SRC/third_party/ninja/ninja" -C "$SRC/$out" openarc_framework >&2
    fi
    if [ "${OPENARC_SKIP_ADBLOCK:-0}" != 1 ]; then
        "$HERE/build-adblock-ruleset.sh" "$SRC" "$out" "$SRC/$out/OpenArcCore.framework" >&2
    fi
    [ -d "$framework" ] || { echo "build-framework.sh: missing $framework" >&2; exit 1; }
    # The unbundled helper of C8 must not linger in an incremental build directory.
    rm -f "$framework/Versions/A/Helpers/openarc_helper"
    check_framework "$framework"
    archs="$(lipo -archs "$framework/Versions/A/OpenArcCore")"
    [ "$archs" = "$arch" ] ||
        { echo "build-framework.sh: $framework is $archs, expected $arch" >&2; exit 1; }
}

# Checks the framework at $1.
check_framework() {
    framework="$1"
    binary="$framework/Versions/A/OpenArcCore"
    echo "==> checking $framework" >&2
    install_name="$(otool -D "$binary" | tail -1)"
    [ "$install_name" = "@rpath/OpenArcCore.framework/Versions/A/OpenArcCore" ] ||
        { echo "build-framework.sh: unexpected install name $install_name" >&2; exit 1; }

    # Only the public API may be exported (bridge/OpenArcCore.exports).
    for arch in $(lipo -archs "$binary"); do
        foreign="$(nm -gU -arch "$arch" "$binary" | awk '{print $3}' |
            grep -v -E '^_(OBJC_CLASS_\$_OAC|OBJC_METACLASS_\$_OAC|OACBridgeAPIVersion$|OACErrorDomain$|OACChildProcessMain$)' || true)"
        if [ -n "$foreign" ]; then
            echo "build-framework.sh: unexpected exported symbols ($arch):" >&2
            echo "$foreign" | head -20 >&2
            exit 1
        fi
        echo "exports ($arch): $(nm -gU -arch "$arch" "$binary" | wc -l | tr -d ' ') symbols, all public API" >&2
    done

    # The framework's headers must be the repository's (the source of truth).
    if ! diff -r "$HERE/include/OpenArcCore" "$framework/Versions/A/Headers" >/dev/null; then
        echo "build-framework.sh: framework headers differ from chromium-bridge/include/OpenArcCore;" >&2
        echo "  copy them into //openarc/bridge/public/OpenArcCore and rebuild" >&2
        exit 1
    fi
    for item in Modules/module.modulemap Helpers/chrome_crashpad_handler \
                Resources/resources.pak Resources/chrome_100_percent.pak Resources/en.lproj/locale.pak \
                Resources/icudtl.dat Resources/Info.plist; do
        [ -e "$framework/Versions/A/$item" ] ||
            { echo "build-framework.sh: missing $item in the framework" >&2; exit 1; }
    done
    # The helper apps (plan C10, //openarc/app/helpers.gni).
    for suffix in "" " (Renderer)" " (GPU)" " (Plugin)" " (Alerts)"; do
        helper="Helpers/Open Arc Helper$suffix.app/Contents/MacOS/Open Arc Helper$suffix"
        [ -x "$framework/Versions/A/$helper" ] ||
            { echo "build-framework.sh: missing $helper in the framework" >&2; exit 1; }
    done
}

build_and_check "$OUT" arm64
FRAMEWORK="$SRC/$OUT/OpenArcCore.framework"

if [ $universal -eq 1 ]; then
    build_and_check "$OUT_X64" x86_64
    echo "==> merging into $SRC/$OUT_UNIVERSAL/OpenArcCore.framework" >&2
    mkdir -p "$SRC/$OUT_UNIVERSAL"
    rm -rf "$SRC/$OUT_UNIVERSAL/OpenArcCore.framework"
    # Chromium's own tool for its universal builds; -I keeps the script's directory and
    # the current directory off the module path.
    python3 -I "$SRC/chrome/installer/mac/universalizer.py" \
        "$SRC/$OUT/OpenArcCore.framework" "$SRC/$OUT_X64/OpenArcCore.framework" \
        "$SRC/$OUT_UNIVERSAL/OpenArcCore.framework" >&2
    FRAMEWORK="$SRC/$OUT_UNIVERSAL/OpenArcCore.framework"
    check_framework "$FRAMEWORK"
    for macho in "$FRAMEWORK/Versions/A/OpenArcCore" "$FRAMEWORK/Versions/A/Helpers/"*.app/Contents/MacOS/* \
                 "$FRAMEWORK/Versions/A/Helpers/chrome_crashpad_handler"; do
        case "$(lipo -archs "$macho")" in
            *arm64*x86_64*|*x86_64*arm64*) ;;
            *) echo "build-framework.sh: $macho is not universal" >&2; exit 1 ;;
        esac
    done
fi
echo "architectures: $(lipo -archs "$FRAMEWORK/Versions/A/OpenArcCore")" >&2

echo "==> creating $XCFRAMEWORK" >&2
mkdir -p "$VENDOR"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$XCFRAMEWORK" >&2

echo "Chromium $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$FRAMEWORK/Versions/A/Resources/Info.plist")" >&2
echo "$XCFRAMEWORK"
