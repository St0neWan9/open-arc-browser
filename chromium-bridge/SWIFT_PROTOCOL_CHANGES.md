# Proposed changes to the Swift engine protocols

Plan task C7 designed the Chromium bridge (`chromium-bridge/include/OpenArcCore/`) against the protocols in `app/Sources/OpenArcEngine/` (`BrowserEngine.swift`, `Surface.swift`) and `app/Sources/OpenArcShell/SiteControls/SiteSettingsProvider.swift`. The sections below list what the bridge can do that the Swift protocols cannot express yet. Plan task C7b applied these changes (status per section below). Protocol and model changes belong to Opus with review (CLAUDE.md §Model division).

Each section gives the gap, why it matters, a proposed Swift shape, and the `FakeEngine` work it implies. Section numbers are referenced from the header comments.

Priority: **P1** blocks C9/C12 acceptance, **P2** needed before the feature's plan task, **P3** nice to have.

## §1 Adopting engine-created tabs (`window.open`) — P1, C9

**Status: applied (C7b).** As proposed (`NewTabRequest.pendingTab`, `PendingTabToken`, `adoptTab`, `declineTab`); FakeEngine: `simulateWindowOpen(from:url:disposition:)`, plus `pendingTabTokens`. Shell: `WorkspaceController+PageRequests.swift` places the tab in the opener's Space, in Today below the opener (inferred), selects foreground tabs and popups, opens a window for `.newWindow`; popups become Today tabs, not Little Arc windows (inferred, documented there).

**Gap.** `EngineEvent.newTabRequested(NewTabRequest)` carries a URL, and the shell answers by calling `makeTab` with that URL. For script-opened windows (`window.open`, `target=_blank` without `noopener`) Chromium has already created the new web contents: the opener holds a live `window` reference, and OAuth popups, payment flows and `postMessage` depend on it. Re-creating the tab from the URL breaks `window.opener` and loses POST bodies.

**Proposal.**
```swift
public struct NewTabRequest: Hashable, Sendable {
    // existing fields …
    /// Set when the engine already made the tab (script-opened window). The shell must call
    /// `BrowserEngine.adoptTab(_:requestedID:)` or `declineTab(_:)`; `makeTab` would lose the opener link.
    public var pendingTab: PendingTabToken?
}
public struct PendingTabToken: Hashable, Sendable { public let rawValue: UUID }

extension BrowserEngine {
    func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) async throws -> any BrowserTab
    func declineTab(_ token: PendingTabToken) async
}
```
Bridge: `OACNewTabRequest.hasPendingContents`, `-adoptWithIdentifier:error:`, `-decline`.
FakeEngine: `simulateNewTabRequest(_:pending:)` that keeps a fake tab until adopted.

## §2 Close requests from the page — P1, C9

**Status: applied (C7b).** `TabEvent.closeRequested` and `BrowserTab.requestClose()`. The shell archives a Today tab (reason `.closed`), unloads a pinned tab or favorite, and selects the opener again (inferred). Little Arc closes its window.

**Gap.** `window.close()` on a script-opened tab, and ⌘W after a beforeunload handler agreed, have no event. Closing the tab inside the engine would desynchronize the sidebar (the model tab would stay with no page).

**Proposal.** `TabEvent.closeRequested` (the shell archives or removes the `TabNode` with `TreeOps`, then calls `closeTab`), and `BrowserTab.requestClose() async` that runs beforeunload first (⌘W) while `closeTab` stays the immediate close.
Bridge: `-[OACTabDelegate tabDidRequestClose:]`, `-[OACTab closeRunningUnloadHandlers]`.

## §3 Shell-drawn dialogs — P1, C12

**Status: applied (C7b).** Shape changed slightly: each payload holds a `DialogReply<Answer>` (single-shot, thread-safe, answers its default from `deinit`, `withdraw()` for engine cancellation) instead of a bare closure, so dropping a request gives the bridge's default. Payloads are `JavaScriptDialog`, `AuthenticationChallenge`, `PermissionPrompt`, `FileChooserRequest`, `ExternalProtocolRequest`. `TabEvent.dialogCancelled(UUID)` as proposed. Shell: `Dialogs/DialogCenter.swift` (per-tab FIFO queues, defaults when the page goes away), `Dialogs/TabDialogViews.swift` (sheet over the tab's panel or pane, permission bubble under the URL box, `NSOpenPanel`/`NSSavePanel`).

**Gap.** No way to show JavaScript dialogs, HTTP auth, permission prompts, file choosers or external-protocol prompts. C12 requires a SwiftUI view for each.

**Proposal.** One stream per tab of request values with reply closures:
```swift
public enum EngineDialogRequest: Sendable {
    case javaScript(JavaScriptDialog)        // kind: alert/confirm/prompt/beforeUnload, message, default text
    case authentication(AuthenticationChallenge)
    case permission(PermissionPrompt)        // kinds: [EnginePermissionKind], origin
    case fileChooser(FileChooserRequest)
    case externalProtocol(ExternalProtocolRequest)
}
// Every payload carries `id: UUID`, `origin: SiteOrigin?` (SiteOrigin would move from Shell to
// Engine, see §5) and a `reply` with the case's answer type, e.g.
public struct JavaScriptDialog: Sendable, Identifiable {
    public let id: UUID
    public let kind: Kind; public let message: String; public let defaultPromptText: String
    public let reply: @Sendable (JavaScriptDialogReply) -> Void
}
extension BrowserTab {
    /// Bounded: finishes with the tab. A request may be cancelled by the engine (`dialogCancelled(id)` on `events()`).
    func dialogRequests() -> AsyncStream<EngineDialogRequest>
}
```
Plus `TabEvent.dialogCancelled(UUID)`. With no subscriber, the engine answers each request with its default (see `OACDialogDelegate.h`), which is also what `FakeEngine` does unless a test injects requests (`simulateDialog(_:)`).

## §4 Page commands: find, zoom, force reload, edit, print, DevTools — P2, C12/C15

**Status: applied (C7b).** `reload()` became `reload(bypassingCache:)` with a `reload()` extension; `find(_:options:)` takes `FindOptions` and reports through `.findResultChanged` (no return value, like the bridge); `perform(EditCommand)`, `print()`, `savePage(to:)`, `showDevTools(_:)`, `viewSource()`, `exitFullscreen()`, `setZoom`/`zoomIn`/`zoomOut`/`resetZoom` (`ZoomLevels` presets). View menu: Force Refresh the Page (⇧⌘R), Zoom to Actual Size (⌘0), Zoom In (⌘+), Zoom Out (⌘-). Find bar, Edit-menu routing for the command bar, Print/Save/Developer menu items: deferred to C12/C15 (no UI in this task).

**Gap.** Menu items observed in `docs/arc-spec/01-menus.md` (§Edit Find ▸, §View Zoom In/Out/Actual Size, Force Refresh the Page, Developer ▸, §File Print / Save Page As) have no engine call.

**Proposal.** Extend `BrowserTab`:
```swift
func reload(bypassingCache: Bool) async throws          // keeps reload() as reload(bypassingCache: false)
func find(_ text: String, backwards: Bool, matchCase: Bool, findNext: Bool) async -> FindResult
func stopFinding(keepSelection: Bool) async
func selectedText() async -> String
func setZoom(_ factor: Double) async throws; func zoomIn() async; func zoomOut() async; func resetZoom() async
func perform(_ command: EditCommand) async              // undo, redo, cut, copy, paste, pasteAndMatchStyle, delete, selectAll
func print() async; func savePage(to url: URL) async throws
func showDevTools(_ panel: DevToolsPanel?) async; func viewSource() async  // viewSource arrives as a NewTabRequest
```
with `TabEvent.findResultChanged(FindResult)` (`matches`, `activeOrdinal`, `isFinal`).

## §5 Permission kinds and `SiteOrigin` location — P2, C12

**Status: applied (C7b), except moving `SiteSettingsProvider`.** `SiteOrigin`, `SitePermissionKind` (13 kinds) and `SitePermissionDecision` are in `OpenArcEngine/SiteOrigin.swift`, plus `SecurityLevel`. `SiteSettingsProvider` stays in the Shell (it is `@MainActor` and its final shape is decided with the Chromium target, C12/C14/C16). The Site Control Center menu offers the four common kinds plus any kind with a decision (inferred).

**Gap.** `SitePermissionKind` has camera, microphone, location, notifications. Chromium also prompts for clipboard read, MIDI, storage access, screen wake lock, multiple downloads, local fonts, window management, idle detection and protected media. A prompt for one of those would have no Swift value. Also `SiteOrigin` lives in the Shell, so the engine protocols (§3) cannot use it.

**Proposal.** Move `SiteOrigin`, `SitePermissionKind` and `SitePermissionDecision` into `OpenArcEngine` (the Shell re-exports nothing; it already imports Engine), and add the cases above to `SitePermissionKind`. The Site Control Center keeps showing only the kinds a site has a decision for (inferred). `SiteSettingsProvider` can then move to Engine as well, implemented by the Chromium target directly.

## §6 Extra tab state — P2, C9/C17

**Status: applied (C7b).** All six fields, one event each (`committedURLChanged`, `securityChanged`, `zoomChanged`, `captureStateChanged`, `fullscreenChanged`, `themeColorChanged`) plus `hoveredLinkChanged`. `navigationFinished` deferred (no consumer yet). The shell's live state mirrors them; Copy URL, the Secure pill and the sidebar still read the visible URL until their tasks switch (C9/C17).

**Gap.** `BrowserTabState` lacks fields the bridge reports and the shell will need:

| Field | Use | Bridge |
|---|---|---|
| `committedURL: URL?` | Copy URL family ([01 §Edit] observed) must copy the committed URL, not a pending one | `OACTabState.committedURL` |
| `security: SecurityLevel` (none/secure/warning/dangerous) | "Secure" pill ([06 §12] observed label); today derived from the scheme only | `securityLevel` |
| `zoomFactor: Double` | Site Control Center zoom row, View ▸ Zoom items | `zoomFactor` |
| `capture: CaptureState` (camera/mic/screen option set) | recording indicators (inferred) | `captureState` |
| `isFullscreen: Bool` | hide the sidebar for page fullscreen (inferred) | `isFullscreen` |
| `themeColor: RGBAColor?` | `<meta name="theme-color">` (C17 is not needed, `06 §17.4`) | `themeColor` |
| `pageTopColor: PageTopColor?` (B45, applied) | web toolbar background, `06 §17.4` | `pageTopColorKind` / `pageTopColor`, `tabDidSamplePageTopColor:` |

Each gets a `TabEvent` case (`securityChanged`, `zoomChanged`, `captureStateChanged`, `fullscreenChanged`, `themeColorChanged`) or one `TabEvent.stateChanged(BrowserTabState)` for the less frequent ones. Also useful: `TabEvent.hoveredLinkChanged(URL?)` (status bubble, inferred) and `TabEvent.navigationFinished(...)` for engine conformance tests.

## §7 Crash reason — P3, C9

**Status: deferred (P3).** `renderProcessGone` keeps no reason; revisit in C9 with the crash placeholder.

`TabEvent.renderProcessGone` carries no reason. Proposal: `renderProcessGone(RenderProcessGoneReason)` with `crashed / killed / outOfMemory / launchFailed`, so the placeholder can say "ran out of memory" (inferred wording, not in the spec). Bridge: `OACRenderProcessTermination`.

## §8 Downloads — P2, C12 and Library ▸ Downloads

**Status: applied as a skeleton (C7b).** `EngineDownloads` (`items`, `events`, pause/resume/cancel/confirm/remove, `download(_:profileID:)`, `setDefaultDirectory`), reached as `BrowserEngine.downloads`; `FakeDownloads`. Library wiring deferred to C12.

**B83 (applied).** The download folder is per Profile ([03 §Profiles] observed: "Download location" sits in each Profile's settings): `setDefaultDirectory(_:profileID:)` replaces `setDefaultDirectory(_:)`, and `defaultDirectory(profileID:) async -> URL?` reads it back for the Settings dropdown. Chromium side unchanged: `OACDownloads.defaultDirectory` is the profile's `download.default_directory` pref (patch 0017), so the choice is per device and survives restarts. `BrowsingDataTypes` gains `.passwords`, `.autofill`, `.siteSettings` (the bridge's `OACBrowsingDataTypes` has had them since C11) for the Clear Browsing Data sheet.

**Gap.** Library has a Downloads section ([06 §8] observed: "Search Downloads…", "Filter", empty state) and Window ▸ View Downloads… ([01 §Window] observed), but the engine has no downloads API.

**Proposal.** A per-profile protocol:
```swift
public protocol EngineDownloads: AnyObject, Sendable {
    func items(profileID: Profile.ID) async -> [DownloadItem]
    func events(profileID: Profile.ID) -> AsyncStream<DownloadEvent>   // added / updated / removed
    func pause(_ id: String) async; func resume(_ id: String) async; func cancel(_ id: String) async
    func confirm(_ id: String, keep: Bool) async; func remove(_ id: String) async
    func setDefaultDirectory(_ url: URL) async                          // [03] observed "Download location"
}
```
reached as `BrowserEngine.downloads`. Bridge: `OACDownloads`.

## §9 Extensions beyond the action row — P2, C14

**Status: applied (C14).** `EngineExtensions` (installed list, per-tab actions, `runAction` returning an `ExtensionPopup`, `install(webStoreID:)`, `loadUnpacked`, enable / uninstall, events), `EngineExtensionInfo.isUnpacked`, `ExtensionPopup` / `ExtensionPopupEvent` (the popup page hosted through `SurfaceHost` like a tab, with load / resize / close events) and `EngineDialogRequest.extensionInstall` (`ExtensionInstallPrompt`, reply `.add` / `.cancel`); `FakeExtensions` / `FakeExtensionPopup`. `SiteExtensionAction` carries the icon, badge, title and popup flag; `SiteSettingsProvider.runExtensionAction` returns the popup.

**Gap.** `SiteSettingsProvider` has `runExtensionAction` and `SiteExtensionAction` (id, name, SF Symbol). C14 needs installing, enabling, uninstalling, the real icon and badge, and hosting the popup (which is a native view, like a tab surface).

**Proposal.** `EngineExtensions` (installed list, install from Web Store by id, enable/disable, uninstall, events), `SiteExtensionAction` gains `iconPNGData`, `badgeText`, `isEnabled`, `hasPopup`; popups reuse `SurfaceContent.native` through a `PopupSurface` handed out by `runExtensionAction`. Bridge: `OACExtensions`.

## §10 Engine lifetime and profile management — P2, C6/C11

**Status: applied (C7b).** `engineVersion`, `shutdown()`, `deleteProfileData(_:)`, `clearBrowsingData(_:types:since:)` (`BrowsingDataTypes`); FakeEngine records them (`shutdownCalled`, `deletedProfileIDs`, `clearedBrowsingData`). Calling `shutdown` from the termination flush and `deleteProfileData` after `TreeOps.deleteProfile` is left to C6/C11 (the flush lives in `LaunchFlow.swift`, owned by D5 at the time).

**Gap.** `BrowserEngine` has no start/stop, version or profile calls. Today the engine exists when `AppDependencies` is built and dies with the process.

**Proposal.**
```swift
public protocol BrowserEngine {
    // existing …
    var engineVersion: String { get }                       // Settings ▸ About ("Chromium 156…")
    func shutdown() async                                    // called by the termination flush after WorkspaceStore.flush()
    func deleteProfileData(_ profileID: Profile.ID) async throws   // after TreeOps profile deletion succeeds
    func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async
}
```
Start stays outside the protocol (the Chromium target starts the engine in its factory, before `AppDependencies` exists). `FakeEngine`: no-ops plus a `shutdownCalled` flag for `LaunchFlow` tests.

## §11 Actor isolation of the protocols — P2, C8 (decision)

**Status: decided (Q11): option (a), protocols stay nonisolated for v1.**

**Gap.** `BrowserEngine` / `BrowserTab` are `Sendable` with nonisolated async methods, and `events()` is synchronous and nonisolated. Every Chromium call must run on the main thread, so the wrapper hops for each command, and `events()` must return its `.snapshot` without awaiting: the wrapper has to cache the state under a lock to meet the contract.

**Options.**
- (a) Keep the protocols as they are. The wrapper keeps a lock-protected `lastState` and hops with `MainActor.run`. Works; costs one hop per command.
- (b) Mark `BrowserEngine`, `BrowserTab` `@MainActor` (`TabSurface` methods already are). Simpler wrapper, no locks; `FakeEngine` becomes `@MainActor` too, and tests that call it from nonisolated contexts change.

Recommendation: (a) for v1 (no shell changes), revisit after C9 if hop latency shows in profiling.

## §12 Tab creation hints — P3, C8

**Status: deferred (P3).** No consumer yet; add with C8.

`TabConfiguration` could carry `startsHidden: Bool` (background tabs restored from the sidebar should not paint until selected; default true except for the selected tab) and `initialSize: CGSize?` in points (first layout matches the web panel, avoiding a resize flash). `setVisible` is otherwise implied by `TabSurface.attach` / `detach`, so no protocol change is needed for visibility itself. Bridge: `OACTabConfiguration.startsHidden`, `initialSize`, `-[OACTab setVisible:]`.

## §13 Errors — P3, C8

**Status: applied (C7b).** `EngineError` gained `profileUnavailable`, `invalidURL`, `shuttingDown`, `invalidArgument`, `requestFinished` and `engineFailure(String)`.

`EngineError` has `tabNotFound`, `tabClosed`, `duplicateTabID`, `snapshotUnavailable`. The bridge adds `notStarted`, `profileUnavailable`, `invalidURL`, `shuttingDown`, `invalidArgument`, `requestFinished` (`OACErrorCode` in `OACDefines.h`). Proposal: add the cases the shell reacts to (`profileUnavailable`, `invalidURL`, `shuttingDown`) and map the rest to a generic `engineFailure(String)`.

## C9 requests (bridge, for C6b / C9b)

Found while wiring engine events end to end in the shell (plan C9). The Swift side already works against the current protocol; these make it cleaner or richer.

1. **Favicon change is never reported (bug).** `-[OACTab faviconDownload:URL:bitmaps:]` writes `_fields.faviconURL` / `_fields.faviconPNGData` and then calls `webContentsDidChangeState`, whose `refreshState` takes its "before" snapshot from `_fields`, which already holds the new icon. So `tab:didChangeFaviconURL:pngData:` is never sent, and the icon only shows up in `OACTab.state`. Fix: keep the downloaded icon in separate ivars that `refreshState` copies into `_fields` (like the other fields), or snapshot `previous` before assigning. Also clear the icon on a cross-document primary-page commit so a new site never inherits the old icon. **Swift workaround in place:** `ChromiumTabCore` re-reads `OACTab.state` 0.3 / 1 / 2.5 / 6 / 15 s after every load stop and navigation finish, on adoption and when the surface becomes visible (`settleResyncDelays`). Remove it after the fix. **Fixed in C6b:** the bridge keeps the icon apart from the state snapshot, so `tab:didChangeFaviconURL:pngData:` fires; the icon is cleared on every cross-document primary-page commit.
2. **Favicon quality (C6b).** The bridge decodes only the first `kFavicon` candidate at 32 px. With `//chrome`, use `favicon::ContentFaviconDriver` (history-backed, best size, touch icons, cached across launches) and report its image. **Done in C6b:** the bridge reports the driver's 16 DIP favicon at 2x (32 px PNG).
3. **Crash reason (§7, still P3).** `renderProcessGone` carries no reason; the shell's crash page could say "out of memory" vs "crashed" with `OACRenderProcessTermination` passed through (`TabEvent.renderProcessGone(RenderProcessGoneReason)`, a protocol change for Opus).
4. **Crash recovery event (P3).** `BrowserTabState.isCrashed` goes back to false on reload, but no event says so; the shell clears its flag when a load starts. A `crashRecovered` / `isCrashed` field event would make that explicit.
5. **Audio:** no request. `OnAudioStateChanged` / `IsCurrentlyAudible` / `IsAudioMuted` / `SetAudioMuted` are wired and verified in the app (speaker icon on the row, Mute in the context menu).

## §14 Little Arc disposition for ⌥⌘-click — P3, B82

**Status: Swift side applied (B82); bridge pending.** `NewTabDisposition.littleArc` reports a ⌥⌘-click on a link ([03 §Links] observed: "⌥⌘-click a link opens Little Arc"). The shell opens the link in a Little Arc window when that setting is on, else it treats the request as `.backgroundTab`.

**Gap.** Chromium's `ui::DispositionFromClick` folds ⌥⌘-click into `NEW_BACKGROUND_TAB` (⌘ wins over ⌥), and `OACNewTabDisposition` has no Little Arc case. **Workaround in place:** `ChromiumEngine.newTabRequested` reads `CGEventSource.flagsState(.combinedSessionState)` and maps a user-gesture URL request for a background tab with ⌥⌘ (no ⇧) still held to `.littleArc`.

**Proposal.** `OACNewTabDispositionLittleArc = 4`, set by the embedder's `OpenURLFromTab` / `AddNewContents` when the triggering mouse event had both the meta and alt modifiers (from `NavigationHandle`/`OpenURLParams` user-gesture input). Then remove the workaround.

## §15 Windows for extensions (`chrome.windows.*`, `action.openPopup()`) — P2, B125 / B126

**Status: applied (B126), needs Opus review.** `BrowserEngine.setWindows(_ windows: [EngineWindowInfo]) async`, with a default no-op in a protocol extension, so engines without extension window APIs (and the test engines) need nothing. `EngineWindowInfo` holds: id (UUID, stable per window), profileID, isOffTheRecord, isFocused, isPopup, frame (x, y, width, height in AppKit screen points), tabIDs and activeTabIDs (`EngineTabID`). FakeEngine records the last list (`windows`, `windowReports`).

**Shell.** `EngineWindowReporter` (one per app, `WorkspaceController.engineWindows`) lists the browser windows (`ShellModel`: normal; the selected Space's live tabs, Favorites → Pinned → Today, active = the tabs on screen) and the Little Arc windows (popup, inferred; its page). Focus order follows key-window changes, and frames follow `NSWindow` move and resize notifications. An incognito window is reported off the record. Changes are coalesced per main-actor turn, and an unchanged list is not sent again.

**Bridge.** `OACExtensions.windows` (class property) of `OACExtensionWindow` objects (`OACExtensions.h`). `-extensions:didOpenPopup:fromKeyboardOnTab:` is renamed `-extensions:didOpenPopup:onTab:`: `chrome.action.openPopup()` popups use the same path (`EngineExtensions.popupsOpenedFromKeyboard()` keeps its name; it now also carries API popups).
