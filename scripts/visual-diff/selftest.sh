#!/bin/bash
# Self-test for the visual comparison harness: compares Open Arc with itself.
#
# Usage: scripts/visual-diff/selftest.sh [--launch] [--size WxH]
#
#   --launch   start Open Arc (with a throwaway data dir under app/.build) if it is not running,
#              and quit it again afterwards
#   --size     window size used for the resize round trip (default 1920x985)
#
# Checks:
#   1. visual-diff.sh with --ref and --ours both set to org.openarc.browser, resizing the
#      window to --size, reports every paired element with Δ = 0 on all fields and pairs at
#      least MIN_PAIRS elements (so the mapping really matches our tree).
#   2. The window frame after the run equals the frame before it (the restore trap works).
#   3. The same comparison with --no-resize also gives all-zero deltas.
# Only Open Arc is touched; the reference app (Arc) is never involved.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bundle="org.openarc.browser"
size="1920x985"
launch=0
MIN_PAIRS=12

while [ $# -gt 0 ]; do
    case "$1" in
        --launch) launch=1; shift ;;
        --size) size="$2"; shift 2 ;;
        *) echo "selftest: unknown option $1" >&2; exit 2 ;;
    esac
done

out="$repo_root/app/.build/visual-diff/selftest"
axtool="$repo_root/app/.build/visual-diff/bin/axtool"
mkdir -p "$out"

launched=0
cleanup() {
    if [ "$launched" = 1 ]; then
        osascript -e "tell application id \"$bundle\" to quit" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

running() { pgrep -f "/Open Arc.app/Contents/MacOS/" > /dev/null 2>&1; }
if ! running; then
    if [ "$launch" = 1 ]; then
        open --env OPENARC_DATA_DIR="$repo_root/app/.build/b19-data" "/Applications/Open Arc.app"
        launched=1
        for _ in $(seq 1 40); do
            if "$axtool" frame --bundle "$bundle" > /dev/null 2>&1; then break; fi
            sleep 0.25
        done
        sleep 1
    else
        echo "selftest: Open Arc is not running (pass --launch to start it)" >&2
        exit 2
    fi
fi

check() {  # check REPORT_JSON LABEL
    python3 -I - "$1" "$2" "$MIN_PAIRS" <<'EOF'
import json, sys
path, label, min_pairs = sys.argv[1], sys.argv[2], int(sys.argv[3])
report = json.load(open(path))
paired = [r for r in report["rows"] if "delta" in r]
nonzero = [r for r in paired if any(v != 0 for v in r["delta"].values())]
one_sided = [r["name"] for r in report["rows"] if r["status"] in ("missing-ours", "missing-ref", "count-mismatch")]
ok = not nonzero and not one_sided and len(paired) >= min_pairs
print(f"selftest [{label}]: {len(paired)} paired elements, {len(nonzero)} with non-zero delta, "
      f"{len(one_sided)} one-sided -> {'PASS' if ok else 'FAIL'}")
for r in nonzero:
    print(f"  non-zero: {r['name']} {r['delta']}")
for name in one_sided:
    print(f"  one-sided: {name}")
if len(paired) < min_pairs:
    print(f"  only {len(paired)} paired elements (expected at least {min_pairs})")
sys.exit(0 if ok else 1)
EOF
}

frame_of() { "$axtool" frame --bundle "$bundle" | python3 -I -c 'import json,sys; w=json.load(sys.stdin)["window"]; print("%g,%g,%g,%g" % (w["x"], w["y"], w["w"], w["h"]))'; }

status=0
# axtool is built by visual-diff.sh on first use; build it here if the frame probe needs it.
[ -x "$axtool" ] || swiftc -O -o "$axtool" "$repo_root/scripts/visual-diff/axtool.swift"

before="$(frame_of)"
"$repo_root/scripts/visual-diff.sh" --ref "$bundle" --ours "$bundle" --size "$size" \
    --no-screenshots --out "$out/resize" > /dev/null
after="$(frame_of)"
check "$out/resize/report.json" "resize to $size" || status=1
if [ "$before" = "$after" ]; then
    echo "selftest [restore]: frame restored to $before -> PASS"
else
    echo "selftest [restore]: frame before $before, after $after -> FAIL"
    status=1
fi
measured="$(python3 -I -c 'import json,sys; w=json.load(open(sys.argv[1]))["meta"]["ref_window"]; print("%gx%g" % (w["w"], w["h"]))' "$out/resize/report.json")"
echo "selftest [size]: requested $size, measured $measured"

"$repo_root/scripts/visual-diff.sh" --ref "$bundle" --ours "$bundle" --no-resize \
    --no-screenshots --out "$out/no-resize" > /dev/null
check "$out/no-resize/report.json" "no-resize" || status=1

[ "$status" = 0 ] && echo "selftest: PASS" || echo "selftest: FAIL"
exit "$status"
