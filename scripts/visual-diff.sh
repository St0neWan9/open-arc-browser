#!/bin/bash
# Visual comparison harness (plan task B31): compares the main window of a reference app
# (Arc by default) with Open Arc element by element and optionally screenshot by screenshot.
#
# Usage:
#   scripts/visual-diff.sh [options]
#
#   --ref BUNDLE        reference app (default company.thebrowser.Browser)
#   --ours-bundle BUNDLE  our app (default org.openarc.browser.dev when "Open Arc Dev" runs,
#                       else org.openarc.browser); --ours is an alias
#   --ours-pid PID      our app's process, when several instances of that bundle run
#                       (test instances with different OPENARC_DATA_DIRs); default: the
#                       lowest pid of the bundle
#   --ref-pid PID       the same for the reference app
#   --size WxH          window size in points both windows are set to (default 1920x985)
#   --no-resize         only read frames; do not touch either window's size
#   --match-ref         leave the reference window alone and size only our window to the
#                       reference window's current size (read-only toward the reference)
#   --no-screenshots    skip the screenshot capture and images
#   --show-text         do not redact the reference app's text (off by default; private data)
#   --threshold PT      flag deltas larger than this (default 1)
#   --out DIR           output directory (default app/.build/visual-diff/latest)
#   --mapping FILE      element mapping (default scripts/visual-diff/mapping.json)
#   --fail-on-flag      exit 1 if any mapped element is over the threshold or missing
#
# What it does:
#   1. Builds scripts/visual-diff/axtool.swift into app/.build/visual-diff/bin (when stale).
#   2. Records each window's frame, sets both windows to --size (unless --no-resize) and
#      ALWAYS restores the original frames on exit (trap, also on error or Ctrl-C).
#   3. Dumps both accessibility trees (the reference app's text and identifiers are
#      redacted inside axtool, except for the allow-list in mapping.json).
#   4. Maps elements with mapping.json and writes report.md + report.json (Δ in points,
#      sorted by severity, |Δ| > threshold flagged).
#   5. If Screen Recording permission is granted, captures both windows with
#      `screencapture -l <windowID> -o -x` and writes side-by-side, 50 % overlay and
#      difference PNGs.
#
# Toward the reference app the harness is read-only except for the window size: it never
# clicks, types, or performs accessibility actions. Everything stays under app/.build
# (git-ignored); never commit or copy Arc screenshots or dumps into docs/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool_dir="$repo_root/scripts/visual-diff"
build_dir="$repo_root/app/.build/visual-diff"

ref_bundle="company.thebrowser.Browser"
ours_bundle=""
ours_pid=""
ref_pid=""
size="1920x985"
resize=1
match_ref=0
screenshots=1
show_text=0
threshold="1"
out_dir="$build_dir/latest"
mapping="$tool_dir/mapping.json"
fail_on_flag=0

usage() { sed -n "2,27p" "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        --ref) ref_bundle="$2"; shift 2 ;;
        --ours|--ours-bundle) ours_bundle="$2"; shift 2 ;;
        --ours-pid) ours_pid="$2"; shift 2 ;;
        --ref-pid) ref_pid="$2"; shift 2 ;;
        --size) size="$2"; shift 2 ;;
        --no-resize) resize=0; shift ;;
        --match-ref) match_ref=1; shift ;;
        --no-screenshots) screenshots=0; shift ;;
        --show-text) show_text=1; shift ;;
        --threshold) threshold="$2"; shift 2 ;;
        --out) out_dir="$2"; shift 2 ;;
        --mapping) mapping="$2"; shift 2 ;;
        --fail-on-flag) fail_on_flag=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "visual-diff: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$size" in
    [0-9]*x[0-9]*) ;;
    *) echo "visual-diff: --size must look like 1920x985" >&2; exit 2 ;;
esac

# Our app: the development build when it runs (plan B37), else the release build. With
# --ours-pid and no bundle, the bundle of that process.
bundle_of_pid() {  # the bundle id of the app whose executable pid $1 runs
    local exe app
    exe="$(ps -o comm= -p "$1" 2>/dev/null)" || return 0
    case "$exe" in */Contents/MacOS/*) ;; *) return 0 ;; esac
    app="${exe%/Contents/MacOS/*}"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true
}
if [ -z "$ours_bundle" ]; then
    if [ -n "$ours_pid" ]; then
        ours_bundle="$(bundle_of_pid "$ours_pid")"
        [ -n "$ours_bundle" ] || { echo "visual-diff: no running app with pid $ours_pid" >&2; exit 2; }
    elif pgrep -f "/Open Arc Dev.app/Contents/MacOS/" > /dev/null 2>&1; then
        ours_bundle="org.openarc.browser.dev"
    else
        ours_bundle="org.openarc.browser"
    fi
fi
for pid_value in "$ours_pid" "$ref_pid"; do
    case "$pid_value" in
        ""|*[!0-9]*) [ -z "$pid_value" ] || { echo "visual-diff: a pid must be a number" >&2; exit 2; } ;;
    esac
done
ours_pid_args=()
[ -n "$ours_pid" ] && ours_pid_args=(--pid "$ours_pid")
ref_pid_args=()
[ -n "$ref_pid" ] && ref_pid_args=(--pid "$ref_pid")
echo "visual-diff: ours = $ours_bundle${ours_pid:+ (pid $ours_pid)}, reference = $ref_bundle${ref_pid:+ (pid $ref_pid)}" >&2

# The mapping has one matcher set per app family.
side_for() {
    case "$1" in
        org.openarc.*) echo openarc ;;
        *) echo arc ;;
    esac
}
ref_side="$(side_for "$ref_bundle")"
ours_side="$(side_for "$ours_bundle")"

# --- Build the helper --------------------------------------------------------------------
axtool="$build_dir/bin/axtool"
mkdir -p "$build_dir/bin" "$out_dir"
if [ ! -x "$axtool" ] || [ "$tool_dir/axtool.swift" -nt "$axtool" ]; then
    echo "visual-diff: building axtool" >&2
    swiftc -O -o "$axtool" "$tool_dir/axtool.swift"
fi

json_get() {  # json_get FILE python-expression-on-d
    python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
frame_csv() {  # frame_csv FILE -> x,y,w,h of the window
    json_get "$1" '",".join(str(d["window"][k]) for k in ("x","y","w","h"))'
}

# Window selection: the browser window of each app, by the identifier regex in the mapping.
# The pid (when given) travels with the window selection to every axtool call.
ref_win=(--window-identifier "$(json_get "$mapping" 'd["windowIdentifier"]["'"$ref_side"'"]')" ${ref_pid_args[@]+"${ref_pid_args[@]}"})
ours_win=(--window-identifier "$(json_get "$mapping" 'd["windowIdentifier"]["'"$ours_side"'"]')" ${ours_pid_args[@]+"${ours_pid_args[@]}"})

preflight="$out_dir/preflight.json"
"$axtool" preflight > "$preflight"
if [ "$(json_get "$preflight" 'd["accessibility"]')" != "True" ]; then
    echo "visual-diff: this terminal has no Accessibility permission (System Settings > Privacy & Security > Accessibility)" >&2
    exit 3
fi

# --- Original frames and restore trap ----------------------------------------------------
same_app=0
# Same app = same process (the self-test); two instances of one bundle are different apps.
[ "$ref_bundle" = "$ours_bundle" ] && [ "$ref_pid" = "$ours_pid" ] && same_app=1

"$axtool" frame --bundle "$ref_bundle" "${ref_win[@]}" > "$out_dir/ref-frame-before.json"
"$axtool" frame --bundle "$ours_bundle" "${ours_win[@]}" > "$out_dir/ours-frame-before.json"
ref_orig="$(frame_csv "$out_dir/ref-frame-before.json")"
ours_orig="$(frame_csv "$out_dir/ours-frame-before.json")"

ref_resized=""
ours_resized=""
restore() {
    local status=$?
    trap - EXIT INT TERM HUP
    # Restore exactly the windows we resized, found by their current (resized) frame.
    if [ -n "$ref_resized" ]; then
        IFS=, read -r x y w h <<< "$ref_orig"
        "$axtool" set-frame --bundle "$ref_bundle" "${ref_win[@]}" --match-frame "$ref_resized" --size "${w}x${h}" --origin "$x,$y" > /dev/null \
            || echo "visual-diff: WARNING: could not restore $ref_bundle to $ref_orig" >&2
    fi
    if [ -n "$ours_resized" ] && [ "$same_app" = 0 ]; then
        IFS=, read -r x y w h <<< "$ours_orig"
        "$axtool" set-frame --bundle "$ours_bundle" "${ours_win[@]}" --match-frame "$ours_resized" --size "${w}x${h}" --origin "$x,$y" > /dev/null \
            || echo "visual-diff: WARNING: could not restore $ours_bundle to $ours_orig" >&2
    fi
    [ -n "$ref_resized$ours_resized" ] && echo "visual-diff: restored original window frames" >&2
    exit "$status"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

if [ "$match_ref" = 1 ]; then
    resize=1
    size="$(json_get "$out_dir/ref-frame-before.json" '"%gx%g" % (d["window"]["w"], d["window"]["h"])')"
fi
if [ "$resize" = 1 ]; then
    if [ "$match_ref" = 0 ]; then
        "$axtool" set-frame --bundle "$ref_bundle" "${ref_win[@]}" --match-frame "$ref_orig" --size "$size" > "$out_dir/ref-frame.json"
        ref_resized="$(frame_csv "$out_dir/ref-frame.json")"
    fi
    if [ "$same_app" = 0 ]; then
        # Open Arc only: AppKit's AX size setter stops 1 pt short of the visible area's bottom
        # (985 -> 984, also for a plain NSWindow); --fill-if-clamped then uses our own
        # Window > Fill for a full-height frame. With --match-ref our window also takes the
        # reference window's origin.
        ours_extra=(--fill-if-clamped)
        if [ "$match_ref" = 1 ]; then
            ours_extra+=(--origin "$(json_get "$out_dir/ref-frame-before.json" '"%g,%g" % (d["window"]["x"], d["window"]["y"])')")
        fi
        "$axtool" set-frame --bundle "$ours_bundle" "${ours_win[@]}" --match-frame "$ours_orig" --size "$size" "${ours_extra[@]}" > "$out_dir/ours-frame.json"
        ours_resized="$(frame_csv "$out_dir/ours-frame.json")"
    fi
    sleep 0.7  # let both apps lay out at the new size
fi

# --- Accessibility dumps -----------------------------------------------------------------
redact_args=()
if [ "$show_text" = 0 ] && [ "$ref_side" = arc ]; then
    redact_args=(--redact --privacy "$mapping")
fi
"$axtool" dump --bundle "$ref_bundle" "${ref_win[@]}" ${redact_args[@]+"${redact_args[@]}"} > "$out_dir/ref.json"
"$axtool" dump --bundle "$ours_bundle" "${ours_win[@]}" > "$out_dir/ours.json"

ref_size="$(json_get "$out_dir/ref.json" '"%gx%g" % (d["window"]["w"], d["window"]["h"])')"
ours_size="$(json_get "$out_dir/ours.json" '"%gx%g" % (d["window"]["w"], d["window"]["h"])')"
if [ "$match_ref" = 1 ]; then
    echo "visual-diff: --match-ref: reference left at $ref_size pt, ours set to $size pt and measured at $ours_size pt" >&2
elif [ "$resize" = 1 ]; then
    echo "visual-diff: requested $size pt; measured $ref_bundle at $ref_size pt, $ours_bundle at $ours_size pt" >&2
else
    echo "visual-diff: --no-resize; measured $ref_bundle at $ref_size pt, $ours_bundle at $ours_size pt" >&2
fi
if [ "$ref_size" != "$ours_size" ]; then
    echo "visual-diff: WARNING: window sizes differ ($ref_size vs $ours_size); right/bottom-anchored elements will show size-driven deltas" >&2
fi

# --- Screenshots (optional) --------------------------------------------------------------
if [ "$screenshots" = 1 ]; then
    if [ "$(json_get "$preflight" 'd["screenRecording"]')" != "True" ]; then
        echo "visual-diff: screenshots skipped: Screen Recording permission is missing for this terminal" >&2
        echo "             (System Settings > Privacy & Security > Screen & System Audio Recording)" >&2
    else
        ref_wid="$(json_get "$out_dir/ref.json" 'd.get("windowNumber", "")')"
        ours_wid="$(json_get "$out_dir/ours.json" 'd.get("windowNumber", "")')"
        if [ -z "$ref_wid" ] || [ -z "$ours_wid" ]; then
            echo "visual-diff: screenshots skipped: window number not found" >&2
        else
            screencapture -l "$ref_wid" -o -x "$out_dir/ref.png"
            screencapture -l "$ours_wid" -o -x "$out_dir/ours.png"
            "$axtool" compose \
                --a "$out_dir/ref.png" --size-a "$ref_size" \
                --b "$out_dir/ours.png" --size-b "$ours_size" \
                --label-a "$ref_bundle" --label-b "$ours_bundle" \
                --side "$out_dir/side-by-side.png" --overlay "$out_dir/overlay.png" --diff "$out_dir/diff.png" > /dev/null
            echo "visual-diff: images in $out_dir (side-by-side.png, overlay.png, diff.png)" >&2
        fi
    fi
fi

# --- Report ------------------------------------------------------------------------------
python3 -I "$tool_dir/compare.py" \
    --ref "$out_dir/ref.json" --ours "$out_dir/ours.json" --mapping "$mapping" \
    --ref-side "$ref_side" --ours-side "$ours_side" --threshold "$threshold" --out-dir "$out_dir"
echo "visual-diff: report in $out_dir/report.md and report.json" >&2

if [ "$fail_on_flag" = 1 ]; then
    bad="$(json_get "$out_dir/report.json" 'd["flagged"] + d["missing"]')"
    [ "$bad" = 0 ] || exit 1
fi
