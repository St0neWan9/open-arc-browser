import Foundation
import OpenArcModel

// What the shell needs from a web engine. The real implementation will be a Chromium bridge
// (ObjC++) in its own target; `FakeEngine` stands in for UI work and tests.
//
// Rules for this module:
// - No UI framework imports (no SwiftUI / AppKit). View hosting goes through `TabSurface` /
//   `SurfaceHost` in Surface.swift.
// - async/await for commands, AsyncStream for events.
// - Engine tab ids are separate from model `TabNode` ids: a persisted tab may have no live
//   engine tab (not loaded yet), and the shell owns the mapping.

/// Identifier of a live engine tab (one web contents).
public struct EngineTabID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
    public var description: String { rawValue.uuidString }
}

/// The color scheme a page sees through `prefers-color-scheme`. [04 §dark mode] observed: a page
/// in a dark space gets `prefers-color-scheme: dark` (example.com turned to white on black).
public enum WebColorScheme: String, Hashable, Sendable, CaseIterable {
    case light, dark
}

/// Parameters for creating a tab.
public struct TabConfiguration: Hashable, Sendable {
    /// Model `Profile.id`. The engine keeps one isolated browsing context (cookies, storage,
    /// history) per profile.
    public var profileID: Profile.ID
    /// URL to load right away; nil creates a blank tab.
    public var initialURL: URL?
    /// Tab that opened this one (window.open, link with target), if any.
    public var opener: EngineTabID?
    /// Requested id; nil lets the engine choose. Lets the shell create ids deterministically.
    public var requestedID: EngineTabID?
    /// The tab belongs to an off-the-record (incognito) browsing context: nothing it does may
    /// reach disk (cookies, cache, history), and the context is destroyed with its last tab.
    /// [01 §File] observed "New Incognito Window"; the storage rules are the usual meaning of the
    /// term (inferred, the spec records no detail).
    public var isOffTheRecord: Bool
    /// Color scheme the page sees from its first load (`prefers-color-scheme`); later changes go
    /// through `BrowserTab.setPreferredColorScheme`. B21.
    public var preferredColorScheme: WebColorScheme

    public init(
        profileID: Profile.ID,
        initialURL: URL? = nil,
        opener: EngineTabID? = nil,
        requestedID: EngineTabID? = nil,
        isOffTheRecord: Bool = false,
        preferredColorScheme: WebColorScheme = .light
    ) {
        self.profileID = profileID
        self.initialURL = initialURL
        self.opener = opener
        self.requestedID = requestedID
        self.isOffTheRecord = isOffTheRecord
        self.preferredColorScheme = preferredColorScheme
    }
}

/// Loading state of the main frame.
public struct LoadState: Hashable, Sendable {
    public var isLoading: Bool
    /// 0...1
    public var progress: Double

    public init(isLoading: Bool, progress: Double) {
        self.isLoading = isLoading
        self.progress = progress
    }

    public static let idle = LoadState(isLoading: false, progress: 1)
}

/// Back/forward availability (drives the sidebar's back/forward buttons, 04 §sidebar).
public struct NavigationState: Hashable, Sendable {
    public var canGoBack: Bool
    public var canGoForward: Bool

    public init(canGoBack: Bool, canGoForward: Bool) {
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
    }

    public static let none = NavigationState(canGoBack: false, canGoForward: false)
}

/// Site icon. Either a URL, decoded image bytes (PNG), or both.
public struct Favicon: Hashable, Sendable {
    public var url: URL?
    public var pngData: Data?

    public init(url: URL?, pngData: Data? = nil) {
        self.url = url
        self.pngData = pngData
    }
}

/// Full observable state of one tab.
public struct BrowserTabState: Hashable, Sendable {
    /// Visible URL: the pending URL during a browser-initiated navigation, the committed one
    /// otherwise (Chromium's visible-URL rule; `OACTabState.URL`).
    public var url: URL?
    public var title: String
    public var loadState: LoadState
    public var favicon: Favicon?
    public var navigation: NavigationState
    /// The renderer process died; the shell shows a "page crashed" placeholder.
    public var isCrashed: Bool
    /// The page is playing or muted audio (sidebar speaker icon, Mute menu item).
    /// [05 §context menus] observed "Mute".
    public var audio: AudioState
    /// Last committed URL. The Copy URL family copies this one, never a pending URL ([01 §Edit]
    /// observed items; the rule is inferred from the bridge's anti-spoofing contract).
    public var committedURL: URL?
    /// Security of the visible entry ("Secure" pill, [06 §12] observed label).
    public var security: SecurityLevel
    /// Page zoom factor, 1 = 100 %. View ▸ Zoom items ([01 §View] observed).
    public var zoomFactor: Double
    /// Camera, microphone or screen capture in use (recording indicators, inferred).
    public var capture: CaptureState
    /// The page is in HTML fullscreen (the shell hides its chrome, inferred).
    public var isFullscreen: Bool
    /// `<meta name="theme-color">`, if any (plan C17).
    public var themeColor: RGBAColor?
    /// The page's top-right color, sampled once per finished load (plan B45); nil until the first
    /// sample. The web toolbar paints itself with it. [06 §17.4] observed.
    public var pageTopColor: PageTopColor?
    /// Page translation (plan B47). [06 §19] observed surfaces.
    public var translation: PageTranslation

    public init(
        url: URL? = nil,
        title: String = "",
        loadState: LoadState = .idle,
        favicon: Favicon? = nil,
        navigation: NavigationState = .none,
        isCrashed: Bool = false,
        audio: AudioState = .silent,
        committedURL: URL? = nil,
        security: SecurityLevel = .none,
        zoomFactor: Double = 1,
        capture: CaptureState = [],
        isFullscreen: Bool = false,
        themeColor: RGBAColor? = nil,
        pageTopColor: PageTopColor? = nil,
        translation: PageTranslation = .unavailable
    ) {
        self.url = url
        self.title = title
        self.loadState = loadState
        self.favicon = favicon
        self.navigation = navigation
        self.isCrashed = isCrashed
        self.audio = audio
        self.committedURL = committedURL
        self.security = security
        self.zoomFactor = zoomFactor
        self.capture = capture
        self.isFullscreen = isFullscreen
        self.themeColor = themeColor
        self.pageTopColor = pageTopColor
        self.translation = translation
    }
}

/// What the engine found at the top-right of the visible page when a load finished (plan B45).
///
/// [06 §17.4] observed: the web toolbar takes the color of the top row of the page's viewport at
/// its right end (a small area, averaged), sampled once per finished load (navigation, reload; at
/// the scroll position of that moment), not on scroll or later style changes; when a classic
/// (always shown) scrollbar sits there, the toolbar uses a neutral color instead.
public enum PageTopColor: Hashable, Sendable {
    /// The rendered color, in sRGB, opaque.
    case color(RGBAColor)
    /// The sample would land on a classic scrollbar's track; the shell uses its fallback color.
    case scrollbar
}

/// Media capture in progress (`OACCaptureState`).
public struct CaptureState: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let camera = CaptureState(rawValue: 1 << 0)
    public static let microphone = CaptureState(rawValue: 1 << 1)
    public static let screen = CaptureState(rawValue: 1 << 2)
}

/// Audio state of a tab.
public struct AudioState: Hashable, Sendable {
    /// The page is producing sound (regardless of mute).
    public var isAudible: Bool
    public var isMuted: Bool

    public init(isAudible: Bool, isMuted: Bool) {
        self.isAudible = isAudible
        self.isMuted = isMuted
    }

    public static let silent = AudioState(isAudible: false, isMuted: false)
}

/// Change notifications for one tab.
///
/// Contract: the first element of every new `events()` stream is `.snapshot(currentState)`,
/// so a subscriber never misses state that changed before it subscribed. The stream finishes
/// after `.closed`.
public enum TabEvent: Hashable, Sendable {
    case snapshot(BrowserTabState)
    case urlChanged(URL?)
    case committedURLChanged(URL?)
    case titleChanged(String)
    case loadStateChanged(LoadState)
    case faviconChanged(Favicon?)
    case navigationStateChanged(NavigationState)
    case audioStateChanged(AudioState)
    case securityChanged(SecurityLevel)
    case zoomChanged(Double)
    case captureStateChanged(CaptureState)
    case fullscreenChanged(Bool)
    case themeColorChanged(RGBAColor?)
    /// A finished load was sampled (`BrowserTabState.pageTopColor`). Plan B45.
    case pageTopColorChanged(PageTopColor?)
    /// `BrowserTabState.translation` changed (plan B47).
    case translationChanged(PageTranslation)
    /// The pointer is over a link (nil: it left). Status bubble, inferred.
    case hoveredLinkChanged(URL?)
    /// The tab dropped a link click for the shell to preview (Peek, plan B49, LinkPreview.swift).
    /// Only for the triggers set with `BrowserTab.setLinkPreviewTriggers`.
    case linkPreviewRequested(LinkPreviewRequest)
    /// Find-in-page results for the current search (`BrowserTab.find`).
    case findResultChanged(FindResult)
    case renderProcessGone
    /// The page asked to close itself (`window.close()`, or `requestClose()` after beforeunload
    /// agreed). The tab stays open: the shell updates the model through `TreeOps` and then calls
    /// `BrowserEngine.closeTab`. Bridge: `-[OACTabDelegate tabDidRequestClose:]`.
    case closeRequested
    /// The page asked to be shown: `window.focus()`, or the "back to tab" button of its Picture
    /// in Picture window (plan C15). The shell selects the tab and brings its window forward
    /// (inferred). Bridge: `-[OACTabDelegate tabDidRequestActivation:]`.
    case activationRequested
    /// The engine withdrew an unanswered dialog request (navigation, the page gave up). The shell
    /// removes its view; a later answer is ignored. Bridge: `tab:didCancelDialogRequest:`.
    case dialogCancelled(UUID)
    case closed
}

/// How the page asked a new tab to be opened.
public enum NewTabDisposition: String, Hashable, Sendable {
    case foregroundTab
    case backgroundTab
    case newWindow
    case popup
}

/// A tab the engine already created for a script-opened window (`window.open`, target=_blank
/// with opener). The page holds a live `window` reference to it, so the shell must adopt it with
/// `BrowserEngine.adoptTab` (or decline it); `makeTab` with the URL would break `window.opener`.
public struct PendingTabToken: Hashable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID) { self.rawValue = rawValue }
}

/// The page asked for a new tab (window.open, ⌘-click…). The shell decides where it goes
/// (Today area, Little Arc window, Peek…).
public struct NewTabRequest: Hashable, Sendable {
    public var opener: EngineTabID?
    public var url: URL
    public var disposition: NewTabDisposition
    public var hasUserGesture: Bool
    /// Set when the engine already made the tab (see `PendingTabToken`). nil: a plain URL request;
    /// the shell creates the tab with `makeTab` (with `opener` set).
    public var pendingTab: PendingTabToken?

    public init(opener: EngineTabID?, url: URL, disposition: NewTabDisposition, hasUserGesture: Bool, pendingTab: PendingTabToken? = nil) {
        self.opener = opener
        self.url = url
        self.disposition = disposition
        self.hasUserGesture = hasUserGesture
        self.pendingTab = pendingTab
    }
}

/// Engine-wide events.
public enum EngineEvent: Hashable, Sendable {
    case newTabRequested(NewTabRequest)
    case tabClosed(EngineTabID)
}

/// A rendered image of a page (tab previews, hover cards, archive thumbnails).
public struct EngineSnapshot: Hashable, Sendable {
    public var pngData: Data
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(pngData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum EngineError: Error, Equatable, Sendable {
    case tabNotFound(EngineTabID)
    case tabClosed(EngineTabID)
    case duplicateTabID(EngineTabID)
    case snapshotUnavailable
    /// The profile's browsing context could not be loaded, or it was deleted.
    case profileUnavailable
    case invalidURL
    /// The engine is shutting down (or shut down) and refuses new work.
    case shuttingDown
    /// A parameter is out of range (zoom factor), or the call is not allowed now (deleting the
    /// data of a profile that still has live tabs).
    case invalidArgument
    /// The request (pending tab, dialog) was already answered or withdrawn.
    case requestFinished
    /// Any other engine failure, with the engine's description.
    case engineFailure(String)
    /// The engine does not implement this command yet; the payload names it (for example
    /// "savePage"). The Chromium engine lists its unsupported commands in
    /// app/Sources/OpenArcChromium/ChromiumEngine.swift.
    case unsupported(String)
    /// `BrowserTab.evaluateJavaScript` (plan B71): the page's script threw, or its promise was
    /// rejected. The payload is the exception's message as the page reports it (for example
    /// "ReferenceError: x is not defined").
    case javaScriptException(String)
}

/// What `BrowserEngine.clearBrowsingData` removes.
public struct BrowsingDataTypes: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let history = BrowsingDataTypes(rawValue: 1 << 0)
    public static let cookies = BrowsingDataTypes(rawValue: 1 << 1)
    public static let cache = BrowsingDataTypes(rawValue: 1 << 2)
    public static let siteStorage = BrowsingDataTypes(rawValue: 1 << 3)
    public static let downloads = BrowsingDataTypes(rawValue: 1 << 4)
    public static let all: BrowsingDataTypes = [.history, .cookies, .cache, .siteStorage, .downloads]
}

/// The web engine as seen by the shell.
///
/// Isolation (decision Q11): the protocols stay nonisolated and `Sendable` for v1. A Chromium
/// implementation hops to the main actor per command and caches state for `events()`.
public protocol BrowserEngine: AnyObject, Sendable {
    /// Creates a live tab. Loads `initialURL` if given.
    func makeTab(_ configuration: TabConfiguration) async throws -> any BrowserTab
    /// Looks up a live tab.
    func tab(for id: EngineTabID) async -> (any BrowserTab)?
    /// Closes and destroys a tab. Its event stream ends with `.closed`. No-op for unknown ids.
    func closeTab(_ id: EngineTabID) async
    /// Engine-wide events. Every call returns a new independent stream.
    func events() -> AsyncStream<EngineEvent>

    // MARK: Engine-created tabs (SWIFT_PROTOCOL_CHANGES.md §1)

    /// Keeps a script-opened tab (`NewTabRequest.pendingTab`) as a live tab. Throws
    /// `EngineError.requestFinished` when it was already adopted or declined (or its opener
    /// closed), `.duplicateTabID` for a live duplicate id.
    func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) async throws -> any BrowserTab
    /// Discards a pending tab. Idempotent.
    func declineTab(_ token: PendingTabToken) async

    // MARK: Lifetime and profiles (§10)

    /// Engine version shown in Settings ▸ About (e.g. "Chromium 156.0…").
    var engineVersion: String { get }
    /// Closes every tab without unload handlers and flushes profile data. Afterwards `makeTab`
    /// throws `EngineError.shuttingDown`. Idempotent. Starting the engine stays outside the
    /// protocol (the implementation's factory starts it).
    func shutdown() async
    /// Deletes a profile's engine data (cookies, storage, history, cache). Every tab of the
    /// profile must be closed first, else `EngineError.invalidArgument`.
    func deleteProfileData(_ profileID: Profile.ID) async throws
    /// Clears some of a profile's browsing data, from `since` (nil: all time) until now.
    func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async

    // MARK: Services (§8, §9)

    /// Downloads of every profile.
    var downloads: any EngineDownloads { get }
    /// Installed extensions of every profile.
    var extensions: any EngineExtensions { get }
    /// The built-in ad blocker (plan C16). Engines without one get `UnavailableAdBlocking`.
    var adBlocking: any EngineAdBlocking { get }
    /// Page translation (plan B47). Engines without it get `UnavailableTranslation`.
    var translation: any EngineTranslation { get }
    /// History and password import from other browsers (plan D3b). Engines without one get
    /// `UnavailableImporter`.
    var importer: any EngineImporter { get }
}

extension BrowserEngine {
    public var adBlocking: any EngineAdBlocking { UnavailableAdBlocking.shared }
    public var translation: any EngineTranslation { UnavailableTranslation.shared }
    public var importer: any EngineImporter { UnavailableImporter.shared }
}

/// One live web contents.
public protocol BrowserTab: AnyObject, Sendable {
    var id: EngineTabID { get }
    var profileID: Profile.ID { get }

    /// Current state (also delivered as the first `.snapshot` event of every stream).
    func currentState() async -> BrowserTabState
    /// Tab events. Every call returns a new independent stream; see `TabEvent` for the contract.
    func events() -> AsyncStream<TabEvent>
    /// Dialog requests of this tab (JavaScript dialogs, HTTP auth, permissions, file choosers,
    /// external protocols). Every call returns a new stream; it finishes when the tab closes.
    /// A request nobody keeps is answered with its default (see `DialogReply`), so with no
    /// subscriber every request gets its default right away. The shell keeps one subscriber.
    func dialogRequests() -> AsyncStream<EngineDialogRequest>

    func load(_ url: URL) async throws
    func goBack() async throws
    func goForward() async throws
    /// Reload. `bypassingCache`: View ▸ Force Refresh the Page ([01 §View] observed item).
    func reload(bypassingCache: Bool) async throws
    func stopLoading() async throws
    /// Mutes or unmutes the tab's audio.
    func setMuted(_ muted: Bool) async

    /// Renders the visible page, scaled so the longer side is at most `maxPixelSize`.
    func snapshot(maxPixelSize: Int) async throws -> EngineSnapshot
    /// Renders part of the visible page or the whole page at the screen's pixel density, for the
    /// capture tools (plan B51, [06 §24] observed). See `PageCaptureArea` (PageCapture.swift);
    /// engines without it throw `EngineError.unsupported("capture")`.
    func capture(_ area: PageCaptureArea) async throws -> EngineSnapshot

    /// Runs the page's beforeunload handler (it may raise a `.beforeUnload` dialog); the tab then
    /// reports `.closeRequested` if the page agreed. `BrowserEngine.closeTab` stays the immediate
    /// close. For ⌘W on a page that may hold unsaved input.
    func requestClose() async

    // MARK: Page commands (SWIFT_PROTOCOL_CHANGES.md §4)

    /// Zoom ([01 §View] observed Zoom to Actual Size / Zoom In / Zoom Out). The engine keeps the
    /// level per site and profile, so other tabs of the site follow. Valid 0.25...5, else
    /// `EngineError.invalidArgument`. Results arrive as `.zoomChanged`.
    func setZoom(_ factor: Double) async throws
    /// Next preset level up / down; back to 100 %.
    func zoomIn() async
    func zoomOut() async
    func resetZoom() async

    /// Starts or continues find in page ([01 §Edit] Find ▸ observed items). Results arrive as
    /// `.findResultChanged`; an empty `text` ends the search like `stopFinding`.
    func find(_ text: String, options: FindOptions) async
    /// Ends find in page. `keepSelection` leaves the active match selected.
    func stopFinding(keepSelection: Bool) async
    /// The page's current selection (Use Selection to Find).
    func selectedText() async -> String
    /// Runs `source` as a script in the main frame's page world (the page's own globals are
    /// visible) and returns its completion value as text by `JavaScriptResultText`'s rules; a
    /// promise is awaited first. For the AppleScript `execute` command (plan B71, [06 §29.3]
    /// observed command; the shell enforces the [06 §29.4] gate before calling). Throws
    /// `EngineError.javaScriptException` when the script throws or its promise rejects,
    /// `.tabClosed` on a closed tab, and `.unsupported("evaluateJavaScript")` when the engine
    /// build cannot run scripts.
    func evaluateJavaScript(_ source: String) async throws -> String
    /// Edit menu commands on the focused frame ([01 §Edit] observed items).
    func perform(_ command: EditCommand) async
    /// File ▸ Print ([01 §File] observed item): the engine's print UI for the page (the Chromium
    /// engine shows the macOS print panel, plan C15).
    func print() async
    /// File ▸ Save Page As ([01 §File] observed item): writes the page to `fileURL` in `format`. A
    /// page that is not HTML (a PDF, an image, media) is saved as its original file whatever the
    /// format. Throws when the save cannot start; finishing is not awaited.
    func savePage(to fileURL: URL, format: SavePageFormat) async throws
    /// View ▸ Developer ▸ items ([01 §View] observed). nil opens the last panel used.
    func showDevTools(_ panel: DevToolsPanel?) async
    /// View ▸ Developer ▸ View Source: the engine asks for a new tab (`EngineEvent.newTabRequested`).
    func viewSource() async
    /// Puts the page's video in Picture in Picture (plan C15). `automatically`: the user left the
    /// tab ([03 §Advanced] observed "Enable Picture in Picture when you leave a video tab"), so
    /// only a playing video qualifies and the site's "Automatic Picture-In-Picture" setting
    /// ([06 §12] observed) must allow it. Returns whether a video was asked to enter.
    @discardableResult
    func enterPictureInPicture(automatically: Bool) async -> Bool
    /// Closes the Picture in Picture window if it shows this tab's video.
    func exitPictureInPicture() async
    /// Leaves HTML fullscreen.
    func exitFullscreen() async

    /// Sets the color scheme the page sees (`prefers-color-scheme`, and the default colors of
    /// pages without their own). Pages that listen for the media query update live. B21:
    /// [04 §dark mode] observed that a dark space's pages get the dark scheme, and that
    /// View ▸ Appearance decides what "websites, Easels, and Notes" use. Idempotent.
    func setPreferredColorScheme(_ scheme: WebColorScheme) async

    // MARK: Translation (plan B47, [06 §19])

    /// Translates the page into `languageCode` (nil: `translation.targetLanguage`). [06 §19.2]
    /// observed "Translate"; [06 §19.3] "Choose Another Language ▸". Also retries after a failure.
    /// Ignored while the page language is unknown.
    func translate(to languageCode: String?) async
    /// Shows the original page. [06 §19.4] observed "Use Original". No-op when not translated.
    func revertTranslation() async
    /// Never offer translation on this site again, and show the original. [06 §19.3] observed
    /// "Never Translate This Site". Undone by `EngineTranslation.resetDecisions`.
    func neverTranslateSite() async

    // MARK: Link preview (plan B49, [06 §22.1])

    /// Which link clicks this tab drops and reports as `.linkPreviewRequested` instead of
    /// navigating (none by default). Takes effect for the next click. See LinkPreview.swift.
    func setLinkPreviewTriggers(_ triggers: LinkPreviewTriggers) async

    /// View hosting for this tab (one surface per tab; several can be on screen in split view).
    var surface: any TabSurface { get }
}

extension BrowserTab {
    /// Normal reload (View ▸ Refresh the Page).
    public func reload() async throws {
        try await reload(bypassingCache: false)
    }

    /// Save Page As with the default format (a complete page).
    public func savePage(to fileURL: URL) async throws {
        try await savePage(to: fileURL, format: .complete)
    }
}
