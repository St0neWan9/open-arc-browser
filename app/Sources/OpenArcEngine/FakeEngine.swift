import Foundation
import OpenArcModel

/// In-memory engine for UI development and tests. No web content: navigation is simulated
/// instantly and deterministically, and surfaces show a placeholder.
///
/// Simulated navigation emits, in order: loading(0) → urlChanged → committedURLChanged →
/// securityChanged → titleChanged → faviconChanged → navigationStateChanged → [zoomChanged when
/// the site has another zoom level] → loading finished.
///
/// Test hooks (`simulate…`) raise what a real page would: script-opened windows, close requests,
/// dialog requests of every kind, crashes, audio, fullscreen and more.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeEngine: BrowserEngine, @unchecked Sendable {
    /// Produces a page title for a URL. Default: the host name (or "New Tab" for nil).
    public typealias TitleProvider = @Sendable (URL) -> String
    /// The page top color a finished load of a URL reports (plan B45); nil reports nothing, as
    /// before the first sample.
    public typealias PageTopColorProvider = @Sendable (URL) -> PageTopColor?

    /// A script-opened tab the shell has not adopted or declined yet.
    private struct Pending {
        var profileID: Profile.ID
        var isOffTheRecord: Bool
        var opener: EngineTabID?
        var url: URL
        /// The opener's color scheme: a script-opened page starts like its opener (inferred).
        var colorScheme: WebColorScheme
    }

    private let lock = NSLock()
    private var liveTabs: [EngineTabID: FakeTab] = [:]
    private var pendingTabs: [PendingTabToken: Pending] = [:]
    private var isShutDown = false
    private var deletedProfiles: [Profile.ID] = []
    private var clearedData: [ClearedBrowsingData] = []
    private let broadcaster = AsyncBroadcaster<EngineEvent>()
    private let titleProvider: TitleProvider
    private let pageTopColorProvider: PageTopColorProvider?
    private let zoomMap = FakeZoomMap()
    private let fakeDownloads = FakeDownloads()
    private let fakeExtensions = FakeExtensions()
    private let fakeAdBlocking = FakeAdBlocking()
    private let fakeTranslation = FakeTranslation()
    private let fakeImporterService = FakeImporter()
    private let fakeAutocompleteService: FakeAutocomplete

    /// - Parameter clock: visit times of the fake history (plan B66); default the system clock.
    public init(titleProvider: @escaping TitleProvider = FakeEngine.defaultTitle,
                pageTopColorProvider: PageTopColorProvider? = nil,
                clock: @escaping @Sendable () -> Date = { Date() }) {
        self.titleProvider = titleProvider
        self.pageTopColorProvider = pageTopColorProvider
        self.fakeAutocompleteService = FakeAutocomplete(clock: clock)
    }

    public static let defaultTitle: TitleProvider = { url in url.host ?? url.absoluteString }

    public let engineVersion = "FakeEngine 1.0"
    public var downloads: any EngineDownloads { fakeDownloads }
    public var extensions: any EngineExtensions { fakeExtensions }
    /// Typed access for tests.
    public var fakeDownloadService: FakeDownloads { fakeDownloads }
    public var fakeExtensionService: FakeExtensions { fakeExtensions }
    public var adBlocking: any EngineAdBlocking { fakeAdBlocking }
    public var translation: any EngineTranslation { fakeTranslation }
    /// Typed access for tests (plan B47).
    public var fakeTranslationService: FakeTranslation { fakeTranslation }
    /// Typed access for tests (plan C16).
    public var fakeAdBlockingService: FakeAdBlocking { fakeAdBlocking }
    public var importer: any EngineImporter { fakeImporterService }
    /// Typed access for tests (plan D3b).
    public var fakeImporter: FakeImporter { fakeImporterService }
    public var autocomplete: any EngineAutocomplete { fakeAutocompleteService }
    /// Typed access for tests (plan B66).
    public var fakeAutocomplete: FakeAutocomplete { fakeAutocompleteService }

    /// Ids of all live tabs (for tests and debug UI).
    public var tabIDs: Set<EngineTabID> {
        lock.withLock { Set(liveTabs.keys) }
    }

    /// Ids of the live off-the-record tabs (incognito windows). For tests.
    public var offTheRecordTabIDs: Set<EngineTabID> {
        lock.withLock { Set(liveTabs.values.filter(\.isOffTheRecord).map(\.id)) }
    }

    /// Script-opened tabs waiting for `adoptTab` / `declineTab`. For tests.
    public var pendingTabTokens: Set<PendingTabToken> {
        lock.withLock { Set(pendingTabs.keys) }
    }

    /// `shutdown()` ran. For launch-flow tests.
    public var shutdownCalled: Bool { lock.withLock { isShutDown } }
    /// Profiles whose data `deleteProfileData` removed, in call order.
    public var deletedProfileIDs: [Profile.ID] { lock.withLock { deletedProfiles } }
    /// Every `clearBrowsingData` call, in order.
    public var clearedBrowsingData: [ClearedBrowsingData] { lock.withLock { clearedData } }

    public func makeTab(_ configuration: TabConfiguration) async throws -> any BrowserTab {
        let tab = try register(
            id: configuration.requestedID ?? EngineTabID(UUID()),
            profileID: configuration.profileID,
            isOffTheRecord: configuration.isOffTheRecord,
            opener: configuration.opener,
            colorScheme: configuration.preferredColorScheme
        )
        if let url = configuration.initialURL {
            try await tab.load(url)
        }
        return tab
    }

    public func tab(for id: EngineTabID) async -> (any BrowserTab)? {
        lock.withLock { liveTabs[id] }
    }

    public func closeTab(_ id: EngineTabID) async {
        let tab: FakeTab? = lock.withLock {
            // Bridge rule: an unanswered script-opened tab is declined when its opener closes.
            pendingTabs = pendingTabs.filter { $0.value.opener != id }
            return liveTabs.removeValue(forKey: id)
        }
        guard let tab else { return }
        tab.close()
        broadcaster.yield(.tabClosed(id))
    }

    public func events() -> AsyncStream<EngineEvent> {
        broadcaster.subscribe()
    }

    // MARK: Engine-created tabs

    public func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) async throws -> any BrowserTab {
        let pending: Pending = try lock.withLock {
            guard !isShutDown else { throw EngineError.shuttingDown }
            guard let pending = pendingTabs.removeValue(forKey: token) else { throw EngineError.requestFinished }
            return pending
        }
        let tab = try register(
            id: requestedID ?? EngineTabID(UUID()),
            profileID: pending.profileID,
            isOffTheRecord: pending.isOffTheRecord,
            opener: pending.opener,
            colorScheme: pending.colorScheme
        )
        try await tab.load(pending.url)
        return tab
    }

    public func declineTab(_ token: PendingTabToken) async {
        lock.withLock { _ = pendingTabs.removeValue(forKey: token) }
    }

    // MARK: Lifetime and profiles

    public func shutdown() async {
        let tabs: [FakeTab] = lock.withLock {
            isShutDown = true
            pendingTabs.removeAll()
            defer { liveTabs.removeAll() }
            return Array(liveTabs.values)
        }
        for tab in tabs {
            tab.close()
            broadcaster.yield(.tabClosed(tab.id))
        }
    }

    public func deleteProfileData(_ profileID: Profile.ID) async throws {
        try lock.withLock {
            guard !isShutDown else { throw EngineError.shuttingDown }
            guard !liveTabs.values.contains(where: { $0.profileID == profileID }) else { throw EngineError.invalidArgument }
            deletedProfiles.append(profileID)
        }
        zoomMap.removeAll(profileID: profileID)
        fakeAutocompleteService.removeHistory(profileID: profileID)
    }

    public func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async {
        lock.withLock { clearedData.append(ClearedBrowsingData(profileID: profileID, types: types, since: since)) }
        if types.contains(.history) { fakeAutocompleteService.removeHistory(profileID: profileID, since: since) }
    }

    // MARK: Test hooks

    /// Simulates a page asking for a new tab by URL (⌘-click, extension request…).
    public func simulateNewTabRequest(_ request: NewTabRequest) {
        broadcaster.yield(.newTabRequested(request))
    }

    /// Simulates a script-opened window (`window.open`, target=_blank with opener): the engine
    /// makes the tab and asks the shell to adopt it. Returns the token, or nil for an unknown or
    /// closed opener.
    @discardableResult
    public func simulateWindowOpen(
        from opener: EngineTabID,
        url: URL,
        disposition: NewTabDisposition = .foregroundTab,
        hasUserGesture: Bool = true
    ) -> PendingTabToken? {
        let token = PendingTabToken(UUID())
        let added: Bool = lock.withLock {
            guard let tab = liveTabs[opener] else { return false }
            pendingTabs[token] = Pending(
                profileID: tab.profileID, isOffTheRecord: tab.isOffTheRecord, opener: opener, url: url,
                colorScheme: tab.preferredColorScheme
            )
            return true
        }
        guard added else { return nil }
        broadcaster.yield(.newTabRequested(NewTabRequest(
            opener: opener, url: url, disposition: disposition, hasUserGesture: hasUserGesture, pendingTab: token
        )))
        return token
    }

    // MARK: Internals

    private func register(
        id: EngineTabID, profileID: Profile.ID, isOffTheRecord: Bool, opener: EngineTabID?, colorScheme: WebColorScheme
    ) throws -> FakeTab {
        let tab = FakeTab(
            id: id,
            profileID: profileID,
            isOffTheRecord: isOffTheRecord,
            opener: opener,
            colorScheme: colorScheme,
            titleProvider: titleProvider,
            pageTopColorProvider: pageTopColorProvider,
            zoomMap: zoomMap
        )
        tab.onSiteZoomChange = { [weak self] source, key, factor in self?.propagateZoom(from: source, key: key, factor: factor) }
        tab.onNewTabRequest = { [weak self] request in self?.broadcaster.yield(.newTabRequested(request)) }
        // On-disk tabs record their navigations in the profile's history; off-the-record tabs
        // never do (plan B66).
        if !isOffTheRecord {
            let history = fakeAutocompleteService
            tab.onVisit = { url, title in history.addVisit(url: url, title: title, profileID: profileID) }
        }
        try lock.withLock {
            guard !isShutDown else { throw EngineError.shuttingDown }
            guard liveTabs[id] == nil else { throw EngineError.duplicateTabID(id) }
            liveTabs[id] = tab
        }
        fakeExtensions.register(tab: id, profileID: profileID)
        return tab
    }

    /// Other tabs on the same site follow a zoom change (Chromium's per-site zoom map).
    private func propagateZoom(from source: EngineTabID, key: FakeZoomMap.Key, factor: Double) {
        let others: [FakeTab] = lock.withLock { liveTabs.values.filter { $0.id != source } }
        for tab in others { tab.applySiteZoom(key: key, factor: factor) }
    }
}

/// One `clearBrowsingData` call, recorded by `FakeEngine`.
public struct ClearedBrowsingData: Hashable, Sendable {
    public var profileID: Profile.ID
    public var types: BrowsingDataTypes
    public var since: Date?
}

/// A command a `FakeTab` received, for tests that check what the shell asked for.
public enum FakeTabCommand: Hashable, Sendable {
    case reload(bypassingCache: Bool)
    case setZoom(Double)
    case zoomIn
    case zoomOut
    case resetZoom
    case find(String, FindOptions)
    case stopFinding(keepSelection: Bool)
    case edit(EditCommand)
    case print
    case savePage(URL, SavePageFormat)
    case showDevTools(DevToolsPanel?)
    case viewSource
    /// `enterPictureInPicture(automatically:)`.
    case enterPictureInPicture(automatically: Bool)
    case exitPictureInPicture
    case exitFullscreen
    case requestClose
    /// Plan B47: `translate(to:)`, `revertTranslation()`, `neverTranslateSite()`.
    case translate(String?)
    case revertTranslation
    case neverTranslateSite
    /// Plan B51: `capture(_:)`.
    case capture(PageCaptureArea)
    /// Plan B71: `evaluateJavaScript(_:)`, with the script source.
    case evaluateJavaScript(String)
}

/// What the fake page answers to `evaluateJavaScript` (plan B71, `simulateJavaScriptOutcome`).
public enum FakeJavaScriptOutcome: Equatable, Sendable {
    /// The script's completion value as the engine hands it over: compact JSON text, nil for
    /// `undefined`. The tab converts it with `JavaScriptResultText`, like the Chromium engine.
    case value(json: String?)
    /// The call fails with this error (`.javaScriptException`, `.unsupported`, …).
    case failure(EngineError)
}

/// The answer a fake dialog request got (or its default when it was dropped).
public enum FakeDialogAnswer: Hashable, Sendable {
    case javaScript(JavaScriptDialogReply)
    case authentication(AuthenticationReply)
    case permission(PermissionReply)
    case fileChooser(FileChooserReply)
    case externalProtocol(ExternalProtocolReply)
    case passwordSave(PasswordSaveReply)
    case autofillPopup(AutofillPopupReply)
    case extensionInstall(ExtensionInstallReply)
}

/// Per-site zoom levels, shared by every tab of one FakeEngine. Keyed by profile, off-the-record
/// flag and host.
// @unchecked: every mutable stored property is read and written only under `lock`.
final class FakeZoomMap: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var profileID: Profile.ID
        var isOffTheRecord: Bool
        var host: String
    }

    private let lock = NSLock()
    private var levels: [Key: Double] = [:]

    func level(_ key: Key) -> Double { lock.withLock { levels[key] ?? 1 } }

    func set(_ factor: Double, for key: Key) {
        lock.withLock { levels[key] = abs(factor - 1) < 0.0001 ? nil : factor }
    }

    func removeAll(profileID: Profile.ID) {
        lock.withLock { levels = levels.filter { $0.key.profileID != profileID } }
    }
}

/// A fake live tab with a simple history stack.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs
// macOS 15); `onSiteZoomChange` / `onNewTabRequest` are set once by FakeEngine before the tab escapes.
public final class FakeTab: BrowserTab, @unchecked Sendable {
    public let id: EngineTabID
    public let profileID: Profile.ID
    /// Created with `TabConfiguration.isOffTheRecord`. The fake keeps nothing on disk anyway; the
    /// flag lets tests check that incognito tabs were created off the record.
    public let isOffTheRecord: Bool
    /// The tab that opened this one (`TabConfiguration.opener` or the adopted window's opener).
    public let opener: EngineTabID?
    public let surface: any TabSurface
    private let fakeSurface: FakeSurface

    private let lock = NSLock()
    private var history: [URL] = []
    private var historyIndex = -1
    private var state = BrowserTabState()
    private var isClosed = false
    private var commandLog: [FakeTabCommand] = []
    /// Page capture sizes (plan B51, `simulateCaptureSizes`).
    private var captureViewport = (width: 800, height: 600)
    private var capturePage = (width: 800, height: 600)
    private var answers: [UUID: FakeDialogAnswer] = [:]
    private var autofillCommandLog: [AutofillPopupCommand] = []
    /// Withdraws an outstanding dialog request (captures the reply weakly).
    private var outstandingDialogs: [UUID: @Sendable () -> Void] = [:]
    private var hasBeforeUnloadHandler = false
    private var pageText: String?
    private var selection = ""
    /// Plan B71: what `evaluateJavaScript` answers; default `undefined` (empty text).
    private var javaScriptOutcome = FakeJavaScriptOutcome.value(json: nil)
    private var findActiveOrdinal = 0
    private var colorScheme: WebColorScheme
    /// The page has a video (`simulateVideo`); `isVideoPlaying` and `isInPictureInPicture` follow
    /// the fake's simple model of one player.
    private var hasVideo = false
    private var isVideoPlaying = false
    private var isInPictureInPicture = false
    /// The site's "Automatic Picture-In-Picture" setting ([06 §12] observed, default Allowed).
    private var allowsAutomaticPictureInPicture = true
    private var colorSchemeLog: [WebColorScheme] = []
    private var pendingTranslationFailure: TranslationFailure?
    /// Clicks the page drops for the shell (plan B49, `setLinkPreviewTriggers`).
    private var linkPreviewTriggers: LinkPreviewTriggers = []
    private let broadcaster = AsyncBroadcaster<TabEvent>()
    private let dialogBroadcaster = AsyncBroadcaster<EngineDialogRequest>()
    private let titleProvider: FakeEngine.TitleProvider
    private let pageTopColorProvider: FakeEngine.PageTopColorProvider?
    private let zoomMap: FakeZoomMap
    var onSiteZoomChange: (@Sendable (EngineTabID, FakeZoomMap.Key, Double) -> Void)?
    var onNewTabRequest: (@Sendable (NewTabRequest) -> Void)?
    /// A navigation committed (URL, title): the engine records it in the history (plan B66).
    /// Set once by FakeEngine before the tab escapes, like `onNewTabRequest`.
    var onVisit: (@Sendable (URL, String) -> Void)?

    init(
        id: EngineTabID,
        profileID: Profile.ID,
        isOffTheRecord: Bool = false,
        opener: EngineTabID? = nil,
        colorScheme: WebColorScheme = .light,
        titleProvider: @escaping FakeEngine.TitleProvider,
        pageTopColorProvider: FakeEngine.PageTopColorProvider? = nil,
        zoomMap: FakeZoomMap = FakeZoomMap()
    ) {
        self.id = id
        self.profileID = profileID
        self.isOffTheRecord = isOffTheRecord
        self.opener = opener
        self.colorScheme = colorScheme
        self.titleProvider = titleProvider
        self.pageTopColorProvider = pageTopColorProvider
        self.zoomMap = zoomMap
        let fakeSurface = FakeSurface(tabID: id)
        self.fakeSurface = fakeSurface
        self.surface = fakeSurface
        fakeSurface.placeholderProvider = { [weak self] in
            guard let self else { return SurfacePlaceholder(title: "", url: nil) }
            let (state, scheme) = self.lock.withLock { (self.state, self.colorScheme) }
            return SurfacePlaceholder(title: state.title, url: state.url, colorScheme: scheme)
        }
    }

    /// Commands received from the shell, in order. For tests. Color scheme changes are kept apart
    /// (`colorSchemeChanges`), so the log stays about what the user asked for.
    public var commands: [FakeTabCommand] { lock.withLock { commandLog } }
    /// The color scheme the page sees (from `TabConfiguration` or `setPreferredColorScheme`).
    public var preferredColorScheme: WebColorScheme { lock.withLock { colorScheme } }
    /// Every `setPreferredColorScheme` call that changed the scheme, in order. For tests.
    public var colorSchemeChanges: [WebColorScheme] { lock.withLock { colorSchemeLog } }
    /// Answers given to dialog requests, by request id (defaults included). For tests.
    public var dialogAnswers: [UUID: FakeDialogAnswer] { lock.withLock { answers } }
    /// Dialog requests that are neither answered nor withdrawn. For tests.
    public var outstandingDialogIDs: Set<UUID> { lock.withLock { Set(outstandingDialogs.keys) } }

    public func currentState() async -> BrowserTabState {
        lock.withLock { state }
    }

    public func events() -> AsyncStream<TabEvent> {
        // Snapshot and subscribe atomically w.r.t. state changes (both happen under `lock`).
        lock.withLock { broadcaster.subscribe(initial: [.snapshot(state)]) }
    }

    public func dialogRequests() -> AsyncStream<EngineDialogRequest> {
        dialogBroadcaster.subscribe()
    }

    public func load(_ url: URL) async throws {
        try mutate {
            history.removeSubrange((historyIndex + 1)...)
            history.append(url)
            historyIndex = history.count - 1
            return url
        }
    }

    public func goBack() async throws {
        try mutate {
            guard historyIndex > 0 else { return nil }
            historyIndex -= 1
            return history[historyIndex]
        }
    }

    public func goForward() async throws {
        try mutate {
            guard historyIndex + 1 < history.count else { return nil }
            historyIndex += 1
            return history[historyIndex]
        }
    }

    public func reload(bypassingCache: Bool) async throws {
        try mutate {
            commandLog.append(.reload(bypassingCache: bypassingCache))
            return historyIndex >= 0 ? history[historyIndex] : nil
        }
    }

    public func stopLoading() async throws {
        try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            // Navigation is instantaneous, so there is never anything to stop.
        }
    }

    public func setMuted(_ muted: Bool) async {
        lock.withLock {
            guard !isClosed, state.audio.isMuted != muted else { return }
            state.audio.isMuted = muted
            broadcaster.yield(.audioStateChanged(state.audio))
        }
    }

    /// Returns a 1×1 transparent PNG; good enough to exercise thumbnail code paths.
    public func snapshot(maxPixelSize: Int) async throws -> EngineSnapshot {
        try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
        }
        return EngineSnapshot(pngData: FakeTab.transparentPixelPNG, pixelWidth: 1, pixelHeight: 1)
    }

    /// Page capture (plan B51) of the fake page (`FakePageImage`: each pixel encodes its page
    /// point), at 1 pixel per point. The visible page is the top of the page; both are 800 × 600
    /// unless a test sets them (`simulateCaptureSizes`).
    public func capture(_ area: PageCaptureArea) async throws -> EngineSnapshot {
        let (viewport, page) = try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            commandLog.append(.capture(area))
            return (captureViewport, capturePage)
        }
        var rect: (x: Int, y: Int, width: Int, height: Int)
        switch area {
        case .visible(let selection):
            guard let selection else {
                rect = (0, 0, viewport.width, viewport.height)
                break
            }
            let minX = max(0, Int(selection.x.rounded(.down))), minY = max(0, Int(selection.y.rounded(.down)))
            let maxX = min(viewport.width, Int((selection.x + selection.width).rounded(.up)))
            let maxY = min(viewport.height, Int((selection.y + selection.height).rounded(.up)))
            guard maxX > minX, maxY > minY else { throw EngineError.invalidArgument }
            rect = (minX, minY, maxX - minX, maxY - minY)
        case .fullPage(let ratio):
            var height = page.height
            if let ratio, ratio > 0 { height = min(height, Int((Double(page.width) * ratio).rounded(.down))) }
            rect = (0, 0, page.width, max(1, height))
        }
        let png = FakePageImage.png(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        return EngineSnapshot(pngData: png, pixelWidth: rect.width, pixelHeight: rect.height)
    }

    /// The visible page and whole page sizes the fake captures from (points = pixels). For tests.
    public func simulateCaptureSizes(viewport: (width: Int, height: Int), page: (width: Int, height: Int)) {
        lock.withLock {
            captureViewport = viewport
            capturePage = page
        }
    }

    /// Without a beforeunload handler the page agrees at once (`.closeRequested`). With one
    /// (`simulateBeforeUnloadHandler`), a `.beforeUnload` dialog asks first; accepting it closes.
    public func requestClose() async {
        let hasHandler: Bool? = lock.withLock {
            guard !isClosed else { return nil }
            commandLog.append(.requestClose)
            return hasBeforeUnloadHandler
        }
        guard let hasHandler else { return }
        if hasHandler {
            raiseJavaScriptDialog(kind: .beforeUnload, message: FakeTab.beforeUnloadMessage, closesOnAccept: true)
        } else {
            lock.withLock { broadcaster.yield(.closeRequested) }
        }
    }

    // MARK: Zoom

    public func setZoom(_ factor: Double) async throws {
        guard ZoomLevels.range.contains(factor) else { throw EngineError.invalidArgument }
        try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            commandLog.append(.setZoom(factor))
        }
        changeZoom { _ in factor }
    }

    public func zoomIn() async {
        guard record(.zoomIn) else { return }
        changeZoom { ZoomLevels.next(after: $0) }
    }

    public func zoomOut() async {
        guard record(.zoomOut) else { return }
        changeZoom { ZoomLevels.next(before: $0) }
    }

    public func resetZoom() async {
        guard record(.resetZoom) else { return }
        changeZoom { _ in 1 }
    }

    /// Applies a zoom change to this tab and stores it for the site; other tabs on the site follow.
    private func changeZoom(_ next: (Double) -> Double) {
        let change: (FakeZoomMap.Key, Double)? = lock.withLock {
            let factor = next(state.zoomFactor)
            if factor != state.zoomFactor {
                state.zoomFactor = factor
                broadcaster.yield(.zoomChanged(factor))
            }
            guard let key = zoomKey(for: state.url) else { return nil }
            zoomMap.set(factor, for: key)
            return (key, factor)
        }
        if let (key, factor) = change { onSiteZoomChange?(id, key, factor) }
    }

    /// Another tab changed the zoom of `key`'s site.
    func applySiteZoom(key: FakeZoomMap.Key, factor: Double) {
        lock.withLock {
            guard !isClosed, zoomKey(for: state.url) == key, state.zoomFactor != factor else { return }
            state.zoomFactor = factor
            broadcaster.yield(.zoomChanged(factor))
        }
    }

    /// Call under `lock`.
    private func zoomKey(for url: URL?) -> FakeZoomMap.Key? {
        guard let host = url?.host, !host.isEmpty else { return nil }
        return FakeZoomMap.Key(profileID: profileID, isOffTheRecord: isOffTheRecord, host: host.lowercased())
    }

    // MARK: Find, editing and page commands

    /// Searches the page text (`simulatePageText`, default "<title> <url>"); case-insensitive
    /// unless `matchCase`. Find Next / Previous cycle through the matches.
    public func find(_ text: String, options: FindOptions) async {
        lock.withLock {
            guard !isClosed else { return }
            commandLog.append(.find(text, options))
            guard !text.isEmpty else {
                findActiveOrdinal = 0
                return
            }
            let haystack = pageText ?? "\(state.title) \(state.url?.absoluteString ?? "")"
            let matches = FakeTab.count(text, in: haystack, matchCase: options.matchCase)
            if matches == 0 {
                findActiveOrdinal = 0
            } else if !options.findNext || findActiveOrdinal == 0 {
                findActiveOrdinal = options.backwards ? matches : 1
            } else if options.backwards {
                findActiveOrdinal = findActiveOrdinal == 1 ? matches : findActiveOrdinal - 1
            } else {
                findActiveOrdinal = findActiveOrdinal >= matches ? 1 : findActiveOrdinal + 1
            }
            broadcaster.yield(.findResultChanged(FindResult(matches: matches, activeOrdinal: findActiveOrdinal, isFinal: true)))
        }
    }

    public func stopFinding(keepSelection: Bool) async {
        lock.withLock {
            guard !isClosed else { return }
            commandLog.append(.stopFinding(keepSelection: keepSelection))
            findActiveOrdinal = 0
        }
    }

    public func selectedText() async -> String { lock.withLock { selection } }

    /// Plan B71: answers with the outcome a test set (`simulateJavaScriptOutcome`); the script is
    /// logged as `.evaluateJavaScript`, never run.
    public func evaluateJavaScript(_ source: String) async throws -> String {
        let outcome = try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            commandLog.append(.evaluateJavaScript(source))
            return javaScriptOutcome
        }
        switch outcome {
        case .value(let json): return JavaScriptResultText.text(fromJSON: json)
        case .failure(let error): throw error
        }
    }

    public func perform(_ command: EditCommand) async { _ = record(.edit(command)) }

    public func print() async { _ = record(.print) }

    public func savePage(to fileURL: URL, format: SavePageFormat) async throws {
        try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            guard fileURL.isFileURL else { throw EngineError.invalidArgument }
            commandLog.append(.savePage(fileURL, format))
        }
    }

    public func showDevTools(_ panel: DevToolsPanel?) async { _ = record(.showDevTools(panel)) }

    /// Asks for a `view-source:` tab next to this one, like the bridge does.
    public func viewSource() async {
        let url: URL? = lock.withLock {
            guard !isClosed else { return nil }
            commandLog.append(.viewSource)
            return state.url.flatMap { URL(string: "view-source:\($0.absoluteString)") }
        }
        guard let url else { return }
        onNewTabRequest?(NewTabRequest(opener: id, url: url, disposition: .foregroundTab, hasUserGesture: true))
    }

    public func setPreferredColorScheme(_ scheme: WebColorScheme) async {
        let changed: Bool = lock.withLock {
            guard !isClosed, colorScheme != scheme else { return false }
            colorScheme = scheme
            colorSchemeLog.append(scheme)
            return true
        }
        guard changed else { return }
        let surface = fakeSurface
        await MainActor.run { surface.refresh() }
    }

    public func exitFullscreen() async {
        guard record(.exitFullscreen) else { return }
        simulateFullscreen(false)
    }

    // MARK: Translation (plan B47)

    /// Finishes at once: `.translating`, then `.translated` into the requested language (or the
    /// offered one). Ignored without a known source language, as the engine does. A failure set
    /// with `simulateTranslationFailure` is reported instead, once.
    public func translate(to languageCode: String?) async {
        lock.withLock {
            guard !isClosed else { return }
            commandLog.append(.translate(languageCode))
            let current = state.translation
            guard let source = current.sourceLanguage else { return }
            var target = current.targetLanguage
            if let languageCode { target = TranslationLanguage(code: languageCode, name: FakeTab.languageName(languageCode)) }
            setTranslation(PageTranslation(status: .translating, sourceLanguage: source, targetLanguage: target))
            if let failure = pendingTranslationFailure {
                pendingTranslationFailure = nil
                setTranslation(PageTranslation(status: .failed(failure), sourceLanguage: source, targetLanguage: target))
            } else {
                setTranslation(PageTranslation(status: .translated, sourceLanguage: source, targetLanguage: target))
            }
        }
    }

    public func revertTranslation() async {
        lock.withLock {
            guard !isClosed else { return }
            commandLog.append(.revertTranslation)
            guard state.translation.status == .translated else { return }
            var next = state.translation
            next.status = .available
            setTranslation(next)
        }
    }

    public func neverTranslateSite() async {
        lock.withLock {
            guard !isClosed else { return }
            commandLog.append(.neverTranslateSite)
            setTranslation(.unavailable)
        }
    }

    /// Simulates the engine detecting a page language other than the user's: translation becomes
    /// available, offering `target`. nil source: nothing to offer.
    public func simulatePageLanguage(_ source: TranslationLanguage?, target: TranslationLanguage = TranslationLanguage(code: "en", name: "English")) {
        lock.withLock {
            guard !isClosed else { return }
            setTranslation(source.map { PageTranslation(status: .available, sourceLanguage: $0, targetLanguage: target) } ?? .unavailable)
        }
    }

    /// The next `translate(to:)` fails with `failure`.
    public func simulateTranslationFailure(_ failure: TranslationFailure) {
        lock.withLock { pendingTranslationFailure = failure }
    }

    /// Must hold `lock`.
    private func setTranslation(_ translation: PageTranslation) {
        guard state.translation != translation else { return }
        state.translation = translation
        broadcaster.yield(.translationChanged(translation))
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    /// Logs a command; false when the tab is closed.
    private func record(_ command: FakeTabCommand) -> Bool {
        lock.withLock {
            guard !isClosed else { return false }
            commandLog.append(command)
            return true
        }
    }

    /// Same rules as the Chromium engine: automatic entry needs a playing video, not already in
    /// Picture in Picture, on a site that allows it; a manual one needs a video.
    @discardableResult
    public func enterPictureInPicture(automatically: Bool) async -> Bool {
        lock.withLock {
            guard !isClosed else { return false }
            commandLog.append(.enterPictureInPicture(automatically: automatically))
            guard hasVideo else { return false }
            if automatically {
                guard isVideoPlaying, !isInPictureInPicture, allowsAutomaticPictureInPicture else { return false }
            }
            isInPictureInPicture = true
            return true
        }
    }

    public func exitPictureInPicture() async {
        lock.withLock {
            guard !isClosed else { return }
            commandLog.append(.exitPictureInPicture)
            isInPictureInPicture = false
        }
    }

    // MARK: Test hooks: page state

    /// Simulates the page asking to be shown (`window.focus()`, Picture in Picture's "back to tab").
    public func simulateActivationRequest() {
        lock.withLock {
            guard !isClosed else { return }
            broadcaster.yield(.activationRequested)
        }
    }

    /// Simulates a page with one video, playing or paused.
    public func simulateVideo(playing: Bool) {
        lock.withLock {
            hasVideo = true
            isVideoPlaying = playing
        }
    }

    /// Simulates the site's "Automatic Picture-In-Picture" setting.
    public func simulateAutomaticPictureInPicture(allowed: Bool) {
        lock.withLock { allowsAutomaticPictureInPicture = allowed }
    }

    /// Whether the fake's video is in Picture in Picture.
    public var isPictureInPictureActive: Bool { lock.withLock { isInPictureInPicture } }

    /// Simulates the page starting or stopping sound.
    public func simulateAudio(_ audible: Bool) {
        lock.withLock {
            guard !isClosed, state.audio.isAudible != audible else { return }
            state.audio.isAudible = audible
            broadcaster.yield(.audioStateChanged(state.audio))
        }
    }

    /// Simulates a renderer crash.
    public func simulateCrash() {
        lock.withLock {
            state.isCrashed = true
            state.loadState = .idle
            broadcaster.yield(.renderProcessGone)
        }
    }

    /// Simulates the page entering or leaving HTML fullscreen.
    public func simulateFullscreen(_ on: Bool) {
        update(\.isFullscreen, on, event: .fullscreenChanged(on))
    }

    /// Simulates the favicon arriving (Chromium sends PNG bytes, C9).
    public func simulateFavicon(_ favicon: Favicon?) {
        update(\.favicon, favicon, event: .faviconChanged(favicon))
    }

    /// Simulates load progress (FakeEngine navigations are instantaneous otherwise).
    public func simulateLoadState(_ loadState: LoadState) {
        update(\.loadState, loadState, event: .loadStateChanged(loadState))
    }

    /// Simulates a navigation that commits without a page load: a same-document navigation
    /// (fragment, `history.pushState`) or the final URL of a server redirect. The URL becomes a new
    /// history entry; the title changes when given.
    public func simulateURLChange(_ url: URL, title: String? = nil) {
        lock.withLock {
            guard !isClosed else { return }
            history.removeSubrange((historyIndex + 1)...)
            history.append(url)
            historyIndex = history.count - 1
            state.url = url
            broadcaster.yield(.urlChanged(url))
            state.committedURL = url
            broadcaster.yield(.committedURLChanged(url))
            if let title, title != state.title {
                state.title = title
                broadcaster.yield(.titleChanged(title))
            }
            let navigation = NavigationState(canGoBack: historyIndex > 0, canGoForward: false)
            if navigation != state.navigation {
                state.navigation = navigation
                broadcaster.yield(.navigationStateChanged(navigation))
            }
        }
    }

    public func simulateThemeColor(_ color: RGBAColor?) {
        update(\.themeColor, color, event: .themeColorChanged(color))
    }

    /// Simulates the engine's sample of the page's top-right color after a load (plan B45).
    public func simulatePageTopColor(_ color: PageTopColor?) {
        update(\.pageTopColor, color, event: .pageTopColorChanged(color))
    }

    public func simulateCapture(_ capture: CaptureState) {
        update(\.capture, capture, event: .captureStateChanged(capture))
    }

    public func simulateSecurity(_ level: SecurityLevel) {
        update(\.security, level, event: .securityChanged(level))
    }

    /// Plan B49: the triggers last set with `setLinkPreviewTriggers`. For tests.
    public var currentLinkPreviewTriggers: LinkPreviewTriggers { lock.withLock { linkPreviewTriggers } }

    public func setLinkPreviewTriggers(_ triggers: LinkPreviewTriggers) async {
        lock.withLock { linkPreviewTriggers = triggers }
    }

    /// Simulates the user clicking a link to `url` in the page, as the Chromium engine treats it
    /// (plan B49, LinkPreview.swift): with Shift, a `.shiftClick` tab reports
    /// `.linkPreviewRequested`, else the page asks for a new window; without, an `.otherSiteLink`
    /// tab reports a link to another site, else the tab navigates.
    /// `optionCommand`: a ⌥⌘-click, which asks for a `.littleArc` tab (plan B82) whatever the triggers.
    public func simulateLinkClick(to url: URL, shift: Bool = false, optionCommand: Bool = false) async throws {
        enum Outcome { case preview(LinkPreviewTriggers), newWindow, littleArc, navigate }
        let outcome: Outcome = try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            let isWeb = url.scheme == "http" || url.scheme == "https"
            if optionCommand { return .littleArc }
            if shift {
                return isWeb && linkPreviewTriggers.contains(.shiftClick) ? .preview(.shiftClick) : .newWindow
            }
            if isWeb, linkPreviewTriggers.contains(.otherSiteLink), let current = state.url,
               current.scheme == "http" || current.scheme == "https",
               !LinkPreviewTriggers.isSameSite(current, url) {
                return .preview(.otherSiteLink)
            }
            return .navigate
        }
        switch outcome {
        case .preview(let trigger):
            lock.withLock {
                guard !isClosed else { return }
                broadcaster.yield(.linkPreviewRequested(LinkPreviewRequest(url: url, trigger: trigger)))
            }
        case .newWindow:
            onNewTabRequest?(NewTabRequest(opener: id, url: url, disposition: .newWindow, hasUserGesture: true))
        case .littleArc:
            onNewTabRequest?(NewTabRequest(opener: id, url: url, disposition: .littleArc, hasUserGesture: true))
        case .navigate:
            try await load(url)
        }
    }

    public func simulateHoveredLink(_ url: URL?) {
        lock.withLock {
            guard !isClosed else { return }
            broadcaster.yield(.hoveredLinkChanged(url))
        }
    }

    /// Text that find in page searches (default: title and URL).
    public func simulatePageText(_ text: String?) { lock.withLock { pageText = text } }

    /// The page's current selection (`selectedText()`).
    public func simulateSelection(_ text: String) { lock.withLock { selection = text } }

    /// What later `evaluateJavaScript` calls answer (plan B71).
    public func simulateJavaScriptOutcome(_ outcome: FakeJavaScriptOutcome) { lock.withLock { javaScriptOutcome = outcome } }

    /// Simulates `window.close()` (or a page that agreed to close): `.closeRequested`.
    public func simulateWindowClose() {
        lock.withLock {
            guard !isClosed else { return }
            broadcaster.yield(.closeRequested)
        }
    }

    /// Gives the page a beforeunload handler: `requestClose()` then raises a `.beforeUnload` dialog.
    public func simulateBeforeUnloadHandler(_ installed: Bool = true) {
        lock.withLock { hasBeforeUnloadHandler = installed }
    }

    private func update<Value: Equatable>(_ keyPath: WritableKeyPath<BrowserTabState, Value>, _ value: Value, event: TabEvent) {
        lock.withLock {
            guard !isClosed, state[keyPath: keyPath] != value else { return }
            state[keyPath: keyPath] = value
            broadcaster.yield(event)
        }
    }

    // MARK: Test hooks: dialogs

    /// Raises alert / confirm / prompt (or beforeunload). Returns the request id.
    @discardableResult
    public func simulateJavaScriptDialog(_ kind: JavaScriptDialog.Kind, message: String, defaultPromptText: String = "") -> UUID {
        raiseJavaScriptDialog(kind: kind, message: kind == .beforeUnload ? FakeTab.beforeUnloadMessage : message,
                              defaultPromptText: defaultPromptText, closesOnAccept: false)
    }

    @discardableResult
    public func simulateAuthentication(realm: String, challengerHostPort: String? = nil, suggestedUsername: String? = nil) -> UUID {
        let requestID = UUID()
        let origin = currentOrigin()
        let reply = DialogReply<AuthenticationReply>(default: .cancel, handler: answerHandler(requestID) { .authentication($0) })
        let request = AuthenticationChallenge(
            id: requestID, origin: origin, realm: realm,
            challengerHostPort: challengerHostPort ?? origin?.displayHost ?? "",
            isInsecureConnection: origin?.isSecure == false, suggestedUsername: suggestedUsername, reply: reply
        )
        deliver(.authentication(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    @discardableResult
    public func simulatePermissionPrompt(
        _ kinds: [SitePermissionKind], hasUserGesture: Bool = true, supportsAllowingOnce: Bool = true
    ) -> UUID {
        let requestID = UUID()
        let reply = DialogReply<PermissionReply>(default: .dismiss, handler: answerHandler(requestID) { .permission($0) })
        let request = PermissionPrompt(id: requestID, origin: currentOrigin(), kinds: kinds, hasUserGesture: hasUserGesture,
                                       supportsAllowingOnce: supportsAllowingOnce, reply: reply)
        deliver(.permission(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    @discardableResult
    public func simulateFileChooser(_ mode: FileChooserRequest.Mode, acceptedTypeIdentifiers: [String] = []) -> UUID {
        let requestID = UUID()
        let reply = DialogReply<FileChooserReply>(default: .cancel, handler: answerHandler(requestID) { .fileChooser($0) })
        let request = FileChooserRequest(id: requestID, origin: currentOrigin(), mode: mode,
                                         acceptedTypeIdentifiers: acceptedTypeIdentifiers, reply: reply)
        deliver(.fileChooser(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    @discardableResult
    public func simulateExternalProtocol(_ url: URL, handlerApplicationName: String?, canRememberForOrigin: Bool = true) -> UUID {
        let requestID = UUID()
        let reply = DialogReply<ExternalProtocolReply>(default: .block, handler: answerHandler(requestID) { .externalProtocol($0) })
        let request = ExternalProtocolRequest(id: requestID, origin: currentOrigin(), url: url,
                                              handlerApplicationName: handlerApplicationName,
                                              canRememberForOrigin: canRememberForOrigin, reply: reply)
        deliver(.externalProtocol(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    /// The password manager offers to save (C13). Returns the request id.
    @discardableResult
    public func simulatePasswordSavePrompt(username: String, passwordLength: Int = 8, kind: PasswordSavePrompt.Kind = .save) -> UUID {
        let requestID = UUID()
        let reply = DialogReply<PasswordSaveReply>(default: .dismiss, handler: answerHandler(requestID) { .passwordSave($0) })
        let request = PasswordSavePrompt(id: requestID, origin: currentOrigin(), kind: kind, username: username,
                                         passwordLength: passwordLength, reply: reply)
        deliver(.passwordSave(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    /// Asks to confirm an extension install, as the Web Store page does (C14).
    @discardableResult
    public func simulateExtensionInstallPrompt(
        extensionID: String, name: String, permissionWarnings: [String] = []
    ) -> UUID {
        let requestID = UUID()
        let reply = DialogReply<ExtensionInstallReply>(default: .cancel, handler: answerHandler(requestID) { .extensionInstall($0) })
        let request = ExtensionInstallPrompt(
            id: requestID, origin: currentOrigin(), extensionID: extensionID, extensionName: name,
            title: "Add “\(name)”?", permissionWarnings: permissionWarnings, reply: reply
        )
        deliver(.extensionInstall(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    /// Shows an autofill dropdown (C13). Commands the shell sends to it are recorded in
    /// `autofillCommands`; `.accept` withdraws the dropdown, as the engine does after filling.
    @discardableResult
    public func simulateAutofillPopup(_ state: AutofillPopupState) -> (id: UUID, session: AutofillPopupSession) {
        let requestID = UUID()
        let session = AutofillPopupSession(state: state) { [weak self] command in
            guard let self else { return }
            self.lock.withLock { self.autofillCommandLog.append(command) }
            if case .accept = command { self.simulateDialogCancel(requestID) }
        }
        let record = answerHandler(requestID) { FakeDialogAnswer.autofillPopup($0) }
        let reply = DialogReply<AutofillPopupReply>(default: .dismiss) { [weak session] answer in
            record(answer)
            session?.finish()
        }
        let request = AutofillPopup(id: requestID, origin: currentOrigin(), session: session, reply: reply)
        deliver(.autofillPopup(request), withdraw: { [weak reply, weak session] in
            reply?.withdraw()
            session?.finish()
        })
        return (requestID, session)
    }

    /// Commands the shell sent to autofill dropdowns, oldest first. For tests.
    public var autofillCommands: [AutofillPopupCommand] { lock.withLock { autofillCommandLog } }

    /// The engine withdraws an unanswered request (`TabEvent.dialogCancelled`).
    public func simulateDialogCancel(_ requestID: UUID) {
        let withdraw: (@Sendable () -> Void)? = lock.withLock {
            guard let withdraw = outstandingDialogs.removeValue(forKey: requestID) else { return nil }
            broadcaster.yield(.dialogCancelled(requestID))
            return withdraw
        }
        withdraw?()
    }

    @discardableResult
    private func raiseJavaScriptDialog(kind: JavaScriptDialog.Kind, message: String, defaultPromptText: String = "", closesOnAccept: Bool) -> UUID {
        let requestID = UUID()
        let record = answerHandler(requestID) { FakeDialogAnswer.javaScript($0) }
        let handler: DialogReply<JavaScriptDialogReply>.Handler = { [weak self] answer in
            record(answer)
            if closesOnAccept, answer.accepted { self?.simulateWindowClose() }
        }
        let reply = DialogReply<JavaScriptDialogReply>(default: .dismissed, handler: handler)
        let request = JavaScriptDialog(
            id: requestID, origin: currentOrigin(), kind: kind, message: message,
            defaultPromptText: defaultPromptText, reply: reply
        )
        deliver(.javaScript(request), withdraw: { [weak reply] in reply?.withdraw() })
        return requestID
    }

    /// Hands a request to the subscribers. With none, the request is released here, which answers
    /// it with its default (bridge rule).
    private func deliver(_ request: EngineDialogRequest, withdraw: @escaping @Sendable () -> Void) {
        let closed: Bool = lock.withLock {
            guard !isClosed else { return true }
            outstandingDialogs[request.id] = withdraw
            return false
        }
        if closed {
            request.withdraw()
            return
        }
        dialogBroadcaster.yield(request)
    }

    /// Records the answer of request `requestID`.
    private func answerHandler<Answer: Sendable>(_ requestID: UUID, _ wrap: @escaping @Sendable (Answer) -> FakeDialogAnswer) -> @Sendable (Answer) -> Void {
        { [weak self] answer in
            guard let self else { return }
            self.lock.withLock {
                self.answers[requestID] = wrap(answer)
                self.outstandingDialogs[requestID] = nil
            }
        }
    }

    private func currentOrigin() -> SiteOrigin? {
        lock.withLock { state.url.flatMap(SiteOrigin.init(url:)) }
    }

    // MARK: Lifetime

    func close() {
        let pending: [@Sendable () -> Void] = lock.withLock {
            isClosed = true
            broadcaster.yield(.closed)
            defer { outstandingDialogs.removeAll() }
            return Array(outstandingDialogs.values)
        }
        // A closed tab's requests are withdrawn, not answered.
        pending.forEach { $0() }
        broadcaster.finish()
        dialogBroadcaster.finish()
    }

    // MARK: Internals

    /// Runs a history change under the lock; if it yields a URL, simulates loading it and emits
    /// the documented event sequence.
    private func mutate(_ change: () -> URL?) throws {
        let changed = try applyNavigation(change)
        if changed, let onVisit {
            let (url, title) = lock.withLock { (state.url, state.title) }
            if let url, url.scheme == "http" || url.scheme == "https" { onVisit(url, title) }
        }
        if changed {
            let surface = fakeSurface
            Task { @MainActor in surface.refresh() }
        }
    }

    private func applyNavigation(_ change: () -> URL?) throws -> Bool {
        try lock.withLock {
            guard !isClosed else { throw EngineError.tabClosed(id) }
            guard let url = change() else { return false }
            let loading = LoadState(isLoading: true, progress: 0)
            state.loadState = loading
            state.isCrashed = false
            findActiveOrdinal = 0
            broadcaster.yield(.loadStateChanged(loading))

            state.url = url
            broadcaster.yield(.urlChanged(url))
            state.committedURL = url
            broadcaster.yield(.committedURLChanged(url))
            // A new document: the engine detects its language again (`simulatePageLanguage`).
            setTranslation(.unavailable)
            state.security = url.scheme?.lowercased() == "https" ? .secure : .none
            broadcaster.yield(.securityChanged(state.security))

            state.title = titleProvider(url)
            broadcaster.yield(.titleChanged(state.title))

            let favicon = Favicon(url: FakeTab.faviconURL(for: url))
            state.favicon = favicon
            broadcaster.yield(.faviconChanged(favicon))

            let navigation = NavigationState(canGoBack: historyIndex > 0, canGoForward: historyIndex + 1 < history.count)
            state.navigation = navigation
            broadcaster.yield(.navigationStateChanged(navigation))

            // The site's stored zoom level applies to the new page.
            let zoom = zoomKey(for: url).map(zoomMap.level) ?? 1
            if zoom != state.zoomFactor {
                state.zoomFactor = zoom
                broadcaster.yield(.zoomChanged(zoom))
            }

            state.loadState = .idle
            broadcaster.yield(.loadStateChanged(.idle))

            // The engine samples the page's top color once the load finished (plan B45). A
            // provider answer of nil leaves the previous sample, as a failed copy does.
            if let color = pageTopColorProvider?(url), color != state.pageTopColor {
                state.pageTopColor = color
                broadcaster.yield(.pageTopColorChanged(color))
            }
            return true
        }
    }

    private static func count(_ needle: String, in haystack: String, matchCase: Bool) -> Int {
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive]
        var count = 0
        var range = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, options: options, range: range) {
            count += 1
            range = found.upperBound..<haystack.endIndex
        }
        return count
    }

    private static func faviconURL(for url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }

    /// The engine's own beforeunload text (pages cannot set it). Chromium's wording; Arc's is not
    /// in the spec (unknown).
    static let beforeUnloadMessage = "Changes you made may not be saved."

    static let transparentPixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGBgAAAABQABpfZFQAAAAABJRU5ErkJggg=="
    )!
}

/// Placeholder surface: hands the host a description of the page instead of a native view.
// @unchecked: `placeholderProvider` is set once by the owning `FakeTab` init before the surface escapes; the rest is `let` or `@MainActor`.
public final class FakeSurface: TabSurface, @unchecked Sendable {
    public let tabID: EngineTabID
    var placeholderProvider: (@Sendable () -> SurfacePlaceholder)?

    @MainActor private weak var host: (any SurfaceHost)?
    @MainActor public private(set) var isFocused = false

    init(tabID: EngineTabID) {
        self.tabID = tabID
    }

    @MainActor public var isAttached: Bool { host != nil }

    @MainActor public func attach(to newHost: any SurfaceHost) {
        if let host, host !== newHost { host.clear() }
        host = newHost
        let placeholder = placeholderProvider?() ?? SurfacePlaceholder(title: "", url: nil)
        newHost.show(.placeholder(placeholder))
    }

    @MainActor public func detach() {
        host?.clear()
        host = nil
    }

    /// Re-sends the placeholder so the host shows the latest title/URL.
    @MainActor func refresh() {
        guard let host else { return }
        let placeholder = placeholderProvider?() ?? SurfacePlaceholder(title: "", url: nil)
        host.show(.placeholder(placeholder))
    }

    @MainActor public func setFocused(_ focused: Bool) {
        isFocused = focused
    }
}
