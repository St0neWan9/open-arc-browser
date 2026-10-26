#!/bin/sh
# Builds OpenArcCore.framework in the Chromium checkout and packages it as
# app/Vendor/OpenArcCore.xcframework for the Swift package (plan C8).
#
# Usage: chromium-bridge/build-framework.sh [--no-build] [CHROMIUM_SRC] [OUT_DIR]
#   --no-build    skip ninja; package the framework already in OUT_DIR
#   CHROMIUM_SRC  Chromium's src/ directory (default: ~/chromium/src)
#   OUT_DIR       GN output directory relative to CHROMIUM_SRC (default: out/Release)
#
# Steps:
#   1. ninja -C OUT_DIR openarc_framework (the GN target in //openarc/BUILD.gn; OUT_DIR's
#      args.gn must list it in root_extra_deps, see chromium-patches/README.md §Building).
#   2. Check the framework: install name, exported symbols (OAC* and OACChildProcessMain only),
#      headers in sync with chromium-bridge/include, module map.
#   3. xcodebuild -create-xcframework into app/Vendor/OpenArcCore.xcframework (macOS arm64 for
#      now; universal comes with plan C10).
#
# The xcframework is git-ignored (app/Vendor/.gitignore); app/Package.swift adds the
# OpenArcChromium target only when it exists. Long build: run in the background and poll.
# Uses only Chromium's toolchain and Xcode's tools.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

build=1
if [ "${1:-}" = "--no-build" ]; then
    build=0
    shift
fi
SRC="${1:-$HOME/chromium/src}"
OUT="${2:-out/Release}"

FRAMEWORK="$SRC/$OUT/OpenArcCore.framework"
VENDOR="$REPO/app/Vendor"
XCFRAMEWORK="$VENDOR/OpenArcCore.xcframework"

if [ $build -eq 1 ]; then
    echo "==> ninja -C $OUT openarc_framework" >&2
    "$SRC/third_party/ninja/ninja" -C "$SRC/$OUT" openarc_framework >&2
fi
[ -d "$FRAMEWORK" ] || { echo "build-framework.sh: missing $FRAMEWORK" >&2; exit 1; }

BINARY="$FRAMEWORK/Versions/A/OpenArcCore"

echo "==> checking $FRAMEWORK" >&2
install_name="$(otool -D "$BINARY" | tail -1)"
[ "$install_name" = "@rpath/OpenArcCore.framework/Versions/A/OpenArcCore" ] ||
    { echo "build-framework.sh: unexpected install name $install_name" >&2; exit 1; }

# Only the public API may be exported (bridge/OpenArcCore.exports).
foreign="$(nm -gU "$BINARY" | awk '{print $3}' |
    grep -v -E '^_(OBJC_CLASS_\$_OAC|OBJC_METACLASS_\$_OAC|OACBridgeAPIVersion$|OACErrorDomain$|OACChildProcessMain$)' || true)"
if [ -n "$foreign" ]; then
    echo "build-framework.sh: unexpected exported symbols:" >&2
    echo "$foreign" | head -20 >&2
    exit 1
fi
echo "exports: $(nm -gU "$BINARY" | wc -l | tr -d ' ') symbols, all public API" >&2

# The framework's headers must be the repository's (the source of truth).
if ! diff -r "$HERE/include/OpenArcCore" "$FRAMEWORK/Versions/A/Headers" >/dev/null; then
    echo "build-framework.sh: framework headers differ from chromium-bridge/include/OpenArcCore;" >&2
    echo "  copy them into //openarc/bridge/public/OpenArcCore and rebuild" >&2
    exit 1
fi
for item in Modules/module.modulemap Helpers/openarc_helper Helpers/chrome_crashpad_handler \
            Resources/resources.pak Resources/chrome_100_percent.pak Resources/en.lproj/locale.pak \
            Resources/icudtl.dat Resources/Info.plist; do
    [ -e "$FRAMEWORK/Versions/A/$item" ] ||
        { echo "build-framework.sh: missing $item in the framework" >&2; exit 1; }
done
echo "architectures: $(lipo -archs "$BINARY")" >&2

echo "==> creating $XCFRAMEWORK" >&2
mkdir -p "$VENDOR"
rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework -framework "$FRAMEWORK" -output "$XCFRAMEWORK" >&2

echo "Chromium $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$FRAMEWORK/Versions/A/Resources/Info.plist")" >&2
echo "$XCFRAMEWORK"
