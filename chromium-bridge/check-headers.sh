#!/bin/sh
# Syntax check of the OpenArcCore public headers against the macOS SDK. No Chromium needed.
#
# 1. Each header alone and the umbrella header, as Objective-C and as Objective-C++ (the bridge's
#    .mm files include them), with ARC, modules, strict warnings as errors and
#    nullability-completeness on.
# 2. Swift import: a temporary module map exposes the headers as module `OpenArcCore`, and a small
#    Swift file (check/SwiftImportCheck.swift) type-checks against it in Swift 6 mode, so the
#    NS_SWIFT_NAME, NS_REFINED_FOR_SWIFT and main-actor annotations are verified as Swift sees them.
#
# Usage: chromium-bridge/check-headers.sh   (from anywhere). Exit status 0 on success.

set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
INCLUDE="$HERE/include"
HEADERS="$INCLUDE/OpenArcCore"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
MIN_OS="14.0"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/oac-header-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ARCH="$(uname -m)"
TARGET="$ARCH-apple-macos$MIN_OS"

WARNINGS="-Wall -Wextra -Werror -Wnullability-completeness -Wnullable-to-nonnull-conversion \
-Wobjc-property-no-attribute -Wstrict-prototypes -Wdocumentation -Wno-unused-parameter"

check() {
    lang="$1"; file="$2"
    # shellcheck disable=SC2086
    xcrun clang -fsyntax-only -fobjc-arc -fmodules -x "$lang" \
        -target "$TARGET" -isysroot "$SDK" -I "$INCLUDE" $WARNINGS "$file"
}

count=0
for header in "$HEADERS"/*.h; do
    name="$(basename "$header")"
    printf '#import <OpenArcCore/%s>\n' "$name" > "$WORK/one.m"
    check objective-c "$WORK/one.m"
    cp "$WORK/one.m" "$WORK/one.mm"
    check objective-c++ "$WORK/one.mm"
    count=$((count + 1))
done
echo "ok: $count headers compile alone (objective-c, objective-c++)"

printf '#import <OpenArcCore/OpenArcCore.h>\n' > "$WORK/all.m"
check objective-c "$WORK/all.m"
cp "$WORK/all.m" "$WORK/all.mm"
check objective-c++ "$WORK/all.mm"
echo "ok: umbrella header compiles (objective-c, objective-c++)"

# Swift import check. The real framework ships Modules/module.modulemap (plan C8); this one points
# at the source headers.
mkdir -p "$WORK/modules/OpenArcCore"
cat > "$WORK/modules/OpenArcCore/module.modulemap" <<EOF
module OpenArcCore {
    umbrella header "$HEADERS/OpenArcCore.h"
    export *
    module * { export * }
}
EOF
xcrun swiftc -typecheck -swift-version 6 -target "$TARGET" -sdk "$SDK" \
    -I "$WORK/modules/OpenArcCore" -Xcc -I -Xcc "$INCLUDE" \
    "$HERE/check/SwiftImportCheck.swift"
echo "ok: Swift 6 imports module OpenArcCore"
