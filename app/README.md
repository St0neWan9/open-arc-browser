# OpenArc app (Swift package)

This is the macOS shell of OpenArc, a clean-room browser that recreates Arc's interaction and look. It is written in Swift and SwiftUI and targets macOS 14 or later. The web engine will be Chromium, connected later through an ObjC++ bridge. Sync will use CloudKit.

## Module dependency graph

Arrows point from a module to the modules it depends on.

```
                     OpenArcApp   (executable, @main only)
                         │
                         ▼
                    OpenArcShell  (SwiftUI)          (also depends on OpenArcImport → Model)
          ┌──────────────┼──────────────┬──────────────┐
          │              │              │              ▼
          │              │              │      OpenArcPersistence  (Foundation only)
          │              │              │              │
          ▼              ▼              │              │
   OpenArcEngine   OpenArcSyncAPI ◀─────┼──────────────┤
          │              │              ▼              │
          │              │        OpenArcDesign        │
          └──────────────┼──────────────┘              │
                         ▼                             │
                    OpenArcModel  (Foundation only) ◀──┘
```

Rules for the graph:
- Arrows only point down. Engine, SyncAPI and Design do not depend on each other.
- `OpenArcPersistence` depends on SyncAPI and Model only and imports no UI framework.
- `OpenArcModel` imports only Foundation: no SwiftUI, AppKit or CloudKit.
- `OpenArcEngine`, `OpenArcSyncAPI` and `OpenArcDesign` import no UI framework.
- Only `OpenArcShell` and `OpenArcApp` may import SwiftUI or AppKit.
- Future targets plug in at the edges:
  - The Chromium bridge (ObjC++) implements `BrowserEngine` and depends on Engine and Model.
  - The CloudKit sync target implements `SyncStore` and depends on SyncAPI and Model.

## Modules

| Module | Responsibility |
|---|---|
| `OpenArcModel` | Codable and Sendable records with stable UUIDs: `Profile`, `Theme`, `Space`, `Folder`, `TabNode` (favorite / pinned / Today), `ArchiveItem`, `SplitLayout`.<br>Sync metadata: per-field-group timestamps, tombstone, version, and an opaque backend blob.<br>`SortKey` provides fractional ordering.<br>`TreeOps` holds the pure tree operations: open, pin, move, create folder, archive, clear Today, auto-archive (with an exclusion set), create/rename/delete space, space icon and theme, profile settings (`Profile.settings`: search engine, Today lifetime; auto-archive uses each tab's profile lifetime) and profile deletion (refused for the Default profile or while Spaces use it), create and edit themes (`ThemeStyle`, including `brightness`), split panes, and moving a whole split group across spaces. |
| `OpenArcEngine` | The `BrowserEngine` and `BrowserTab` protocols (nonisolated, decision Q11): create and close tabs, navigation, an event stream, and snapshots; adopting engine-created tabs (`window.open`, `PendingTabToken`), page close requests (`TabEvent.closeRequested`, `requestClose()`), a per-tab dialog request stream with single-shot `DialogReply`s and default answers (JS dialogs, beforeunload, HTTP auth, permissions, file chooser, external protocol); page commands (force reload, zoom, find, edit commands, print, save, DevTools, view source); extra tab state (committed URL, security, zoom, capture, fullscreen, theme color); engine lifetime (`shutdown`, `deleteProfileData`, `clearBrowsingData`); `EngineDownloads` / `EngineExtensions` skeletons. `SiteOrigin`, `SitePermissionKind` and `SitePermissionDecision` live here (C7b).<br>`TabSurface` and `SurfaceHost` isolate view hosting.<br>`AsyncBroadcaster` provides multi-subscriber streams.<br>`FakeEngine` is the in-memory engine for UI work and tests, with `simulate…` hooks for every request and event. |
| `OpenArcSyncAPI` | The `SyncStore` and `SyncLocalDatabase` protocols, record and status types, and `DisabledSyncStore`.<br>`ConflictPolicy` documents and implements the merge decision: field-group last-writer-wins, delete wins, ties go to the server.<br>`RecordMerge` is the one shared record merge (copies the winning field groups); the local store and every sync backend use it. |
| `OpenArcDesign` | Layout, type and timing tokens measured from `docs/arc-spec` (E11 design system, `07-design-system.md`). Each token cites its spec section and evidence level.<br>`Metrics`: window buttons, sidebar, web panel, command bar, sheets, theme bubble, Library (07 §1–§6, §9). `Typography`: one `TextStyle` (SF size, weight, opacity, line height) per element (07 §3).<br>`ThemeDerivation` (07 §8, rules inferred, samples observed): window = mix(theme, #EBEBEB, 0.36), dark = × 0.90; control fill = window × 0.96; separator × 0.87; selected row = mix(window, #F5F5F5, 0.9); row text and command bar selection are OKLCH tones of the theme hue; command bar #F9F9F9 / #181818; sheets #FAFBFF / #171C30. `Theme.brightness` shifts the theme color first (inferred). |
| `OpenArcPersistence` | `WorkspaceStore` (actor) keeps the workspace as `workspace.json` in `~/Library/Application Support/org.openarc.browser/`: a `{schemaVersion, savedAt, workspace}` envelope, atomic writes (temp file + rename), debounced autosave with an injectable scheduler, and `flush()` for termination.<br>A corrupt file is moved aside as `workspace.corrupt-<timestamp>.json`; a file from a newer schema makes the store read-only.<br>Per-device UI state (the open windows, each with its selected Space and tab and sidebar visibility, as `WindowUIState`; the Library flags) is kept apart from the synced workspace in `ui-state.json` (`UIState`, `UIStateFile`). Files from before multiple windows restore one window from their top-level fields.<br>It implements `SyncLocalDatabase`: `record(for:)`, `apply(_:)` (merged with the shared `RecordMerge`, written before returning) and the sync state blob (`sync-state.bin`).<br>`WorkspaceDiff` turns two workspace values into `PendingChange`s; `events()` streams each change with the changes to enqueue. |
| `OpenArcImport` | Bookmark import from other browsers (D3), Foundation only, depends on Model.<br>Parsers into a `BookmarkTree` (bar + other roots): `ChromiumBookmarksParser` (a Chromium-family profile's `Bookmarks` JSON: `bookmark_bar`, `other`, `synced`), `NetscapeBookmarksParser` (the "Export Bookmarks" HTML of Safari, Firefox and Chrome: unclosed `DT`/`p`, any tag case, entities), `SafariBookmarksParser` (`Bookmarks.plist`, only from a file the user picks: `~/Library/Safari` needs Full Disk Access and is never read). `BookmarkFileReader` detects the format from the content.<br>`BrowserProfileDiscovery` lists Chrome, Brave, Edge, Chromium and Vivaldi profiles that have a `Bookmarks` file under a given home folder (names from `Local State`).<br>`BookmarkImportMapper` (inferred): one new Space "Imported from <Browser>" after the current one; the bar becomes the pinned area (folders nested, top level expanded), the other roots one folder "Other Bookmarks"; empty folders and duplicates kept; only http/https/file URLs, the rest counted as skipped. Built with `TreeOps` only.<br>History and passwords are not here: they come with Chromium's importer in phase C (plan D3b, `ImportDataKind`). |
| `OpenArcShell` | SwiftUI and AppKit. One folder per surface:<br>`Sidebar/`: sidebar view model (one per window: the window's selection; it reads and mutates the shared workspace through the controller), rows, folders, favorites, Today, dock, hover card, context menus, drag-and-drop (pure hit tester and planner), split groups.<br>`CommandBar/`: sources (tabs, archive, commands, spaces, typed input, suggestions), pure ranking, keyboard handling, ⌘T / ⌘L modes, window / pane / Little Arc presentations.<br>`SplitView/`: pane geometry and the split web area.<br>`Spaces/`: new Space flow, rename, icon, theme editor (`ThemeEditor/`).<br>`Library/`: Library mode of the main window (Archived Tabs, Spaces board = Manage Spaces, empty states).<br>`Settings/`: the Settings scene and `AppPreferences` (per-device preferences in `UserDefaults`).<br>`SiteControls/`: the Site Control Center popover and the `SiteSettingsProvider` protocol (fake until Chromium).<br>`LittleArc/`: the Little Arc window.<br>`Import/`: Open Arc ▸ Import from Another Browser… (D3): the sheet (detected profiles or Choose File…, then a summary) and `WorkspaceController.importBookmarks`, which applies the import in one mutation.<br>`Updates/`: software updates (D7): the `UpdateChecker` protocol (the app provides the Sparkle implementation; no Shell file imports Sparkle), `UpdatesModel` shared by Open Arc ▸ Check for Updates… and the Settings ▸ Advanced update controls, and `UpdateConfiguration` (Sparkle is started only when `Info.plist` has a real `SUPublicEDKey`; see `docs/release.md`).<br>`PageTools/`: find in page (B25: `FindBarModel`, one find state per tab, the bar over the focused panel or pane; look is own design), File ▸ Print / Save Page As and View ▸ Developer ▸ items calling the engine's page commands; the Allow JavaScript from Apple Events toggle lives in `AppPreferences`. Quitting flushes the store, then calls `engine.shutdown()` with a timeout (`TerminationTiming`).<br>`ExternalOpen/`: links and HTML/PDF files from other apps (`OpenArcAppDelegate` → `ExternalOpenInbox` → `WorkspaceController.openExternal`: a new Today tab in the frontmost normal window's current Space; `ExternalLinkRouting` is the Air Traffic Control hook) and the default browser (`DefaultBrowserService`, in memory unless the app injects `SystemDefaultBrowserService`).<br>Top level: `AppDependencies` (engine, sync, persistence, preferences), `WorkspaceController` and `ShellModel` (see the layering below), `BrowserWindows` / `BrowserWindowView` (window requests, the incognito tokens, the window root and its AppKit observer), `LaunchFlow` (first launch, data directory, launch notice, termination observer), `AutoArchiveScheduler`, `MainWindowLayout` (pure frames), `Views.swift` (root view), `OpenArcScene` (scenes and menus). |

### Shell layering (B14)

```
OpenArcScene ── one WorkspaceController (app level)
                 │  the WorkspaceState value; every mutation (TreeOps) is committed here
                 │  persistence submit, ui-state.json, sync forwarding, termination flush
                 │  live engine tabs (one per model tab), auto-archive scheduler
                 │  open browser windows, active window, windows to restore
                 ▼
     WindowGroup(for: BrowserWindowRequest) ── one ShellModel per browser window
                 │  SidebarViewModel: selected Space and tab, per-Space memory, split focus
                 │  command bars, Library mode, site controls, sidebar visibility
                 ▼
     Settings and Little Arc act on the active window (or a hidden host on the controller)
```

- Every window observes the same workspace. A change made in one window is committed by the controller, saved, and every other window repairs its selection.
- A tab's page is on screen in one window only (one engine surface): selecting a tab another window shows brings that window to the front (inferred).
- New Window (⌘N) opens on the current Space with its most recent tab not on screen elsewhere; Blank Window (⌃⌘N) opens there with no tab; Close Window (⇧⌘W) closes the key window; closing the last window keeps the app running (all inferred; items and keys observed in `01`, `02`).
- New Incognito Window (⇧⌘N) gets its own in-memory controller (`makeIncognito`): one dark Space (local tokens, the look is not in the spec), no favorites or dock, engine tabs created with `TabConfiguration.isOffTheRecord`; nothing reaches the store or sync, and closing the window closes its tabs.
- `ui-state.json` lists every open browser window. At launch the first window restores the first entry; with Settings ▸ Advanced "restore windows from previous session" on (`03`, off by default) the others reopen too.
- `ShellModel(dependencies:workspace:…)` and `SidebarViewModel(engine:workspace:…)` remain as single-window convenience initializers that make their own controller (tests, previews).
| `OpenArcChromium` | Only with `app/Vendor/OpenArcCore.xcframework` (plan C8; `Package.swift` adds it, the `OpenArcCore` binary target and `OpenArcChromiumTests` only when the xcframework exists). `ChromiumEngine` / `ChromiumTab` implement `BrowserEngine`, `BrowserTab` and `TabSurface` on top of `OpenArcCore.framework` (our Chromium fork's Objective-C API, `chromium-bridge/`): commands hop to the main actor, tab state is cached behind a lock for `events()` (decision Q11). Commands the bridge lacks throw `EngineError.unsupported` or do nothing; the list is at the top of `ChromiumEngine.swift`. The conformance test runs only with `OPENARC_ENGINE_TESTS=1`. |
| `OpenArcApp` | `@main`. It links Sparkle 2 (the only target that does) and provides `SparkleUpdateChecker` (`SPUStandardUpdaterController`) when the bundle is configured for updates. It runs `OpenArcScene` with `AppDependencies.live()`: `FakeEngine` (or Chromium with `OPENARC_ENGINE=chromium` in a build that has `OpenArcChromium`; the app then creates `OACBrowserApplication` as `NSApplication` before SwiftUI starts, Chromium starts at `applicationWillFinishLaunching` with `<data dir>/Chromium` and shuts down in the quit sequence), the on-disk `WorkspaceStore`, and sync disabled (`DisabledSyncStore`) unless `OPENARC_SYNC=cloudkit` is set, which builds `CloudKitSyncStore` (it links `OpenArcSyncCloudKit` for that). Without the iCloud entitlement (D4) the store reports `.unavailable(.notConfigured)` instead of creating a `CKContainer`. `SidebarSyncController` (Shell, `Settings/`) starts the store at launch when "Sync Sidebar" is on, stops/starts it with the toggle, forwards changes, and drives the account card. |

## Build and test

```sh
cd app
swift build          # builds every target, including the OpenArcApp executable
swift test           # runs every test target
swift run OpenArcApp # should open a window running FakeEngine; not verified yet (built, never launched).
                     # It runs as a bare SwiftPM executable, without an app bundle or Info.plist.
```

### Data directory

The app keeps its data in `~/Library/Application Support/<bundle id>/` (`org.openarc.browser`, or `org.openarc.browser.dev` for the development build, see §Development builds): `workspace.json` (the synced workspace), `ui-state.json` (per-device open windows with their selection and sidebar visibility, never synced) and `sync-state.bin`. For development, set `OPENARC_DATA_DIR` to use another directory (created if missing; `~` is expanded, a relative path is resolved against the current directory):

```sh
OPENARC_DATA_DIR=/tmp/openarc-dev swift run OpenArcApp   # starts from a fresh first-launch workspace
```

On first launch (no `workspace.json`) the app creates a "Default" profile and one Space with a default theme and no tabs. A corrupt file is moved aside and the app starts the same way. A file written by a newer version is left untouched: the app runs on a first-launch workspace in memory, shows a one-time notice and saves nothing.

This has only been verified with Xcode 26 and Swift 6.3. It needs Xcode 16 or later (swift-tools 6.0). Every target builds in Swift 6 language mode, so data-race safety is checked fully and concurrency problems are compile errors. The build is expected to have no warnings. `@unchecked Sendable` is allowed only with a one-line comment explaining why it is safe (usually: all mutable state is behind a lock).

## App bundle

`swift run` starts a bare executable. A real `Open Arc.app` (bundle id `org.openarc.browser`, version, icon, drag types, URL schemes, document types) is built without an Xcode project:

```sh
scripts/make-app.sh                                  # arm64, version 0.1.0, build 1
scripts/make-app.sh --version 0.1.0 --build 42       # set CFBundleShortVersionString / CFBundleVersion
scripts/make-app.sh --universal                      # arm64 + x86_64
scripts/make-app.sh --scratch-path app/.build/mine   # private SwiftPM scratch dir for parallel builds
```

The script (run from anywhere) does a release build of the `OpenArcApp` product, assembles `build/Open Arc.app` at the repo root (`Contents/MacOS/OpenArcApp`, `Info.plist`, `Resources/AppIcon.icns`, `PkgInfo`), signs it ad hoc with the hardened runtime, and checks it with `codesign --verify --deep --strict` and `plutil -lint`. It rebuilds the bundle from scratch each time and prints the bundle path on its last line. `build/` is git-ignored.

Bundle inputs live in `app/Bundle/`:
- `Info.plist`: the template. The script fills in the two version keys. `UTExportedTypeDeclarations` must list every `UTType(exportedAs:)` in the sources, as `<release bundle id>.<name>` (today `org.openarc.browser.sidebar-item` and `org.openarc.browser.library-space`); the sources build the identifier from the running bundle id, and `--dev` rewrites the prefix.
- `OpenArc.entitlements`: empty for now. There is no App Sandbox until the Chromium helpers (C10) settle it; the file notes the iCloud keys D4 will add.
- `AppIcon.icns`: a placeholder icon, regenerated with `swift scripts/make-app-icon.swift` (CoreGraphics, `sips`, `iconutil`).

When `app/Vendor/OpenArcCore.xcframework` exists (`chromium-bridge/build-framework.sh`), the script also embeds `OpenArcCore.framework` in `Contents/Frameworks/` and signs its helper (with `app/Bundle/OpenArcHelper.entitlements`: JIT and library validation off, see the file) and libraries before the framework and the app. Launch with `--env OPENARC_ENGINE=chromium` to use it.

Run the bundle against a scratch data directory so it never touches real data in `~/Library/Application Support/org.openarc.browser/`. `open` does not pass the caller's shell environment to the app, so pass the variable with `--env` (or start the binary directly):

```sh
open -n --env OPENARC_DATA_DIR=/tmp/openarc-dev "build/Open Arc.app"
OPENARC_DATA_DIR=/tmp/openarc-dev "build/Open Arc.app/Contents/MacOS/OpenArcApp"
```

The bundle is ad hoc signed, so it only runs on the machine that built it. Building it does not make it the default browser; never set it as the default from these scripts.

### Development builds

`scripts/make-app.sh --dev` builds the same app as **Open Arc Dev**: bundle id `org.openarc.browser.dev`, output `build/Open Arc Dev.app` (plan B37). Every id-keyed thing follows the running bundle's id at runtime (`PersistenceDefaults.bundleIdentifier`, `AppIdentity.bundleIdentifier`):

| | Release (`Open Arc.app`) | Development (`Open Arc Dev.app`) |
|---|---|---|
| Bundle id | `org.openarc.browser` | `org.openarc.browser.dev` |
| Default data dir | `~/Library/Application Support/org.openarc.browser/` | `~/Library/Application Support/org.openarc.browser.dev/` |
| Defaults domain | `org.openarc.browser` | `org.openarc.browser.dev` |
| Exported drag types | `org.openarc.browser.sidebar-item`, `.library-space` | `org.openarc.browser.dev.sidebar-item`, `.library-space` (make-app.sh rewrites them) |
| Chromium Mach rendezvous / sandbox bundle id | `org.openarc.browser.*` | `org.openarc.browser.dev.*` (read from the embedding app, patch 0004) |
| Sparkle updates | on once a release key exists | off: no `SUFeedURL`, and `UpdateConfiguration` refuses any non-release id |
| CloudKit container | `iCloud.org.openarc.browser` (needs D4's entitlement) | unchanged; ad-hoc dev builds have no entitlement, so sync reports "not set up" |
| URL / document types | http, https, HTML, PDF | the same. Declaring them never makes the app the default browser; do not make the dev build the default |

`OPENARC_DATA_DIR` still overrides the data directory in both builds. The UI copy keeps the name "Open Arc", so both builds lay out alike; only the Dock, the app menu and the window server see "Open Arc Dev".

Which build for what:
- **Release** (`/Applications/Open Arc.app`): the build the user runs, release checks (D6, D7), and one long-lived visual test instance.
- **Dev** (`/Applications/Open Arc Dev.app`): any test instance you start yourself (Chromium bring-up, LCU-driven UI checks, `visual-diff.sh`), so it never collides with a release instance another task is driving.

Install and run it against a scratch data directory:

```sh
scripts/make-app.sh --dev --scratch-path app/.build/scratch-mine
ditto "build/Open Arc Dev.app" "/Applications/Open Arc Dev.app"
open -n --env OPENARC_DATA_DIR="$PWD/app/.build/my-data" "/Applications/Open Arc Dev.app"
```

Addressing one instance:
- LCU: `await cua.getApp("Open Arc Dev")` (or `"org.openarc.browser.dev"`); `cua.getApp("Open Arc")` is the release build. The dev app needs its own LCU approval the first time.
- `scripts/visual-diff.sh` picks the dev build when it runs (`--ours-bundle` and `--ours-pid` choose explicitly), see `scripts/visual-diff/README.md`.
- Several instances of one bundle: tell them apart with `ps eww <pid> | grep OPENARC_DATA_DIR` and pass the pid (`--ours-pid`).
- Quitting: use the app's own menu (System Events `click menu item "Quit Open Arc Dev" of menu 1 of menu bar item 2 of menu bar 1 of (first process whose unix id is <pid>)`, or ⌘Q). `osascript -e 'tell application id "…" to quit'` does not quit either build today (found in B37; tccd logs a hardened-runtime Apple-events policy failure for the app, likely the missing `com.apple.security.automation.apple-events` entitlement, not confirmed; see the plan).

## Tests

| Target | What it covers |
|---|---|
| `OpenArcModelTests` | Sort keys: 600 random inserts stay strictly ordered, prepend/append, rebalancing, and the UUID tie-break.<br>Spec behaviors:<br>• a new tab goes to the top of Today<br>• a new folder goes to the top of the pinned area and starts expanded<br>• pinning places the tab after the folders<br>• dragging above the first row places the tab before the folders<br>• a new space is inserted after the current one<br>• deleting a space archives its tabs and keeps favorites<br>• Clear archives only Today tabs<br>• auto-archive happens after 12 hours<br>• restoring from the archive<br>Also: folder cycle rejection, moving across spaces, split add/remove, moving a split group across spaces, auto-archive exclusions, space and theme edits stamping only their groups, `Theme.brightness` decoding old data with its default, field-group stamping, profile settings (old JSON decodes, stamping only `settings`, per-profile auto-archive, delete-profile rules), and a Codable round trip. |
| `OpenArcEngineTests` | The event order, a snapshot as the first event, back and forward history, two subscribers, late subscribers, closing (the stream ends and an engine event fires), duplicate ids, new-tab requests, crashes, cleanup of broadcaster subscribers, and moving a surface between hosts. `EngineProtocolTests` (C7b): adopting and declining pending tabs, close requests and beforeunload, every dialog kind with its answer and its dropped-request default, withdrawal, zoom per site, find, page commands, extra state, downloads, extensions, shutdown and profile data deletion. |
| `OpenArcSyncAPITests` | `RecordMerge`: a whole field group (theme style incl. brightness) wins as one unit, idempotent self-merge, local delete is uploaded, different records do not merge.<br>Edits to different groups both survive a merge, a later write wins within the same group, ties go to the server, a delete beats a later edit, system fields come from the server, record names stay stable, encrypted groups exist in the model, and `DisabledSyncStore`. |
| `OpenArcDesignTests` | The measured token values, sidebar blocks that do not overlap, command bar rows adding up, the white-overlay math, and the palette rules. |
| `OpenArcPersistenceTests` | A round trip of every record type including tombstones, the envelope format, a failed encode leaving the old file, a corrupt file moved aside, a newer schema refused and never overwritten, debounced autosave coalescing 50 edits into one write, `flush`, the sync state blob, the per-device UI state file, the diff to `PendingChange` (create, update, tombstone, purge), and `apply` under the conflict policy (group merge, later write wins, ties to the server, delete wins, idempotent). |
| `OpenArcImportTests` | Chrome JSON with nesting and extra roots, Netscape HTML (nested and unclosed `DL`/`DT`, entities, toolbar mark, Safari "Favorites" fallback, a flat list), Safari plist (binary and XML), format detection, the mapping (Space name and position, order, Other Bookmarks, expansion, duplicates and empty folders kept, skipped schemes counted, stamping), and profile discovery against a temporary fake home folder. All fixtures are written by the tests. |
| `OpenArcShellTests` | The web panel frame at the 1920×985 reference size, the sidebar block offsets, the hidden sidebar, command bar placement, dependency injection through the environment, `ShellModel` with `FakeEngine`, saving and reloading through the persistence store, the launch flow (first launch, relaunch restore, stale ids, the read-only notice, sync forwarding, the termination flush), multiple windows (`MultiWindowTests`: shared workspace, per-window selection, one window per tab, New/Blank/Close, incognito isolation from store and sync, two-window restore, auto-archive across windows, Little Arc adoption), and rendering the full view in an `NSHostingView`, and the import sheet model (`BookmarkImportShellTests`: one new Space after the current one and selected, a chosen file, a failed file changing nothing), and page requests (`PageRequestTests`, C7b: popup adoption and placement next to the opener, new-window requests, `window.close()` archiving, per-tab dialog queues with answers and defaults, permission bubble placement, Zoom and Force Refresh menu actions). |
