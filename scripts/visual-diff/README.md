# Visual comparison harness (B31)

`scripts/visual-diff.sh` puts Open Arc next to a reference app (Arc by default) at the same window size. It reads element frames from both accessibility trees, pairs the elements through `mapping.json`, and reports per-element position and size deltas in points. When Screen Recording permission is granted, it also writes screenshot side-by-side, overlay and difference images. B16 uses it to iterate until every mapped element is within 1 pt.

## Files

| File | Role |
|---|---|
| `../visual-diff.sh` | Driver: builds the helper, records, resizes and restores window frames, dumps, compares, captures. |
| `axtool.swift` | Swift CLI using `AXUIElement`: `--bundle B [--pid P]` selects the app (default: the lowest pid of B), then `preflight`, `frame`, `set-frame` (with `--fill-if-clamped` for our own app), `dump` (redacts inside the process), `compose` (images). Built into `app/.build/visual-diff/bin/axtool`. |
| `compare.py` | Stdlib-only Python (run with `python3 -I`): mapping, deltas, Markdown and JSON report. |
| `mapping.json` | Privacy allow-lists, window selection and element pairs (Arc matcher ↔ Open Arc matcher). |
| `selftest.sh` | Open Arc vs Open Arc; every delta must be 0 and the window frame must be restored. |

## Usage

```bash
# Default: set both browser windows to 1920×985 pt, compare, restore both frames.
scripts/visual-diff.sh

# Read-only toward Arc: leave Arc's window as it is and size only Open Arc to match it.
scripts/visual-diff.sh --match-ref

# Read frames only; touch neither window.
scripts/visual-diff.sh --no-resize

# Choose our instance: by default "Open Arc Dev" (org.openarc.browser.dev) when it runs, else the
# release build. With several instances of one bundle, pass the pid (see OPENARC_DATA_DIR in
# `ps eww <pid>`); --ref-pid does the same for the reference app.
scripts/visual-diff.sh --ours-bundle org.openarc.browser --ours-pid 12345

# Other options
scripts/visual-diff.sh --size 1440x900 --threshold 0.5 --no-screenshots --out /tmp/vd --fail-on-flag
scripts/visual-diff.sh --help

# Self-test (Open Arc must be running, or pass --launch to start it with a throwaway data dir).
scripts/visual-diff/selftest.sh [--launch]
```

Output goes to `app/.build/visual-diff/latest/` (git-ignored):

- `report.md` / `report.json`: one row per mapped element with Δx, Δy, Δw, Δh, Δcx, Δcy (ours − reference, in points, frames relative to each window's top-left). Rows are sorted by severity, and anything over the threshold (default 1 pt) on the compared fields is flagged ⚠. Rows marked ∅ are elements missing on one side, or sequences such as rows or dock items whose counts differ.
- `ref.json` / `ours.json`: the accessibility dumps (the Arc dump is redacted).
- `ref.png`, `ours.png`, `side-by-side.png`, `overlay.png` (Open Arc at 50 % over Arc) and `diff.png` (black means identical). These are written only when Screen Recording is granted. Each capture is drawn at its point size, so windows on displays with different backing scales still line up point for point.

The script prints the window sizes it requested and the sizes it measured, and warns when they differ. AppKit's accessibility size setter keeps a window's top edge and stops 1 pt short of the visible area's bottom, so `AXSize` can never make a window exactly as tall as the visible area (985 → 984, also for a plain `NSWindow`). For our own app the script passes `set-frame --fill-if-clamped`: when the requested frame is the screen's visible frame and the window came out 1 pt short, `axtool` presses Open Arc's Window ▸ Fill, which sets exactly the visible frame. With `--match-ref` our window also takes the reference window's origin. The reference app is never touched this way.

## Permissions

- **Accessibility** for the terminal that runs the script. It is required, and the script exits with code 3 without it.
- **Screen Recording** for the same terminal is optional. Without it, the screenshot step is skipped with a message and the frame report still runs.

## Safety and privacy rules

- **Read-only toward Arc.** The harness never clicks, types or performs accessibility actions on Arc. The only write to another app is the window size and position (`set-frame`), and with `--match-ref` not even that. The one accessibility action it performs (Window ▸ Fill, `--fill-if-clamped`) goes to Open Arc only. A shell `trap` restores the original frame of every window it resized on exit, error, Ctrl-C or kill. While someone else is driving Arc, use `--match-ref` or `--no-resize`.
- **Redaction.** Arc runs with the user's real account. `axtool dump --redact` replaces every title, description and value with `<redacted>` unless the exact string is in `privacy.allowText` (structure labels such as "Go back", "New Tab" and "More"). It redacts identifiers too, because Arc's dock items and rows carry Space names and page titles. An identifier is kept only when it matches `privacy.identifierRules` (for example, `SidebarDockItem-…` keeps just the prefix). Redaction happens inside the Swift process, so private text never reaches disk. `--show-text` turns it off; do not use it unless the user asks.
- **Screenshots of Arc stay under `app/.build/visual-diff/`.** Never commit them or copy them into `docs/`.
- **Clean room.** Arc identifiers appear in `mapping.json` only to locate Arc's elements. Never reuse them as names in `app/Sources`.

## Mapping reference (`mapping.json`)

`windowIdentifier.{arc,openarc}` is a regex on the window's AXIdentifier that picks the browser window, so Settings and other windows are skipped.

Each entry has `name`, `group`, an `arc` matcher and an `openarc` matcher. A `null` matcher means that app does not expose the element. Entries resolve in file order, so a matcher can only refer to entries listed before it.

| Key | Meaning |
|---|---|
| `role`, `subrole` | Regex, full match. |
| `identifier`, `title`, `description`, `value` | Regex, search. On the Arc side these only see allow-listed or kept text. |
| `depth` | `[lo, hi]` depth in the tree (the window is 0). |
| `frame` | `{x\|y\|w\|h\|cx\|cy: [lo, hi]}` in window points. |
| `visible` | Default `true`. The element must intersect the window and every enclosing scroll area, which excludes rows scrolled away and Space pages paged off to the side. |
| `within` | The element must be a descendant of that entry's element. |
| `above`, `below`, `inside` | Position relative to that entry's frame. |
| `relativeTo` | `{entry, cx: [lo, hi], cy: [lo, hi]}`: center offset from that entry's center. |
| `contains` | Some descendant's identifier matches this regex. |
| `has`, `lacks` | Some descendant does or does not match this attribute matcher. |
| `pick` | `first` (the default, document order), `smallest`, `largest`, or `all` (for `kind: sequence`). |

Entry options:

- `kind: "sequence"` pairs the i-th match on each side and reports a count mismatch once.
- `compare` lists the fields to judge. The default is `x`, `y`, `w`, `h`; others are shown in parentheses.
- `origin` makes positions relative to another entry's top-left, for example rows relative to the divider.
- `optional` hides the row when neither side has the element, such as the command bar while it is closed.
- `anchorOnly` resolves the entry for reference by others but does not report it.
- `note` explains the measurement.

### Arc tree quirks found while writing the mapping

These come from reading Arc 1.170's accessibility tree:

- Toolbar buttons are 32×32 hit areas.
- The URL box exposes only its 18 pt text line (x 20, or x 41 after a 24 pt page icon at (14, 52) for a loaded page). Open Arc exposes the same line (`openarc.sidebar.urlBox.text`) besides the box itself.
- Sidebar rows are full-width 41 pt outline rows (pitch including the 1 pt gap; 268 wide while the scroller shows). Open Arc's rows are the same 41 pt rows, with the icon cell and title line as children (`openarc.sidebar.row.icon` / `.title`).
- The list has no divider row while Today is empty: pinned rows are followed directly by "New Tab". With Today tabs it is pinned rows, the 17 pt divider, "New Tab", then Today.
- The space name element spans the row.
- The dock list excludes the button on its left (Home) and the `+`.
- The command bar panel has no element of its own: the field, icon, ⓘ button and results are direct window children. Measure the panel edges in the screenshot.

When an Arc measurement here disagrees with `docs/arc-spec/`, the spec owner (main session) decides. This tool does not edit the spec.
