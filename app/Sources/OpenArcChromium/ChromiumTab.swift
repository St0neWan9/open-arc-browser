import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// One live Chromium tab (`OACTab`) behind the nonisolated `BrowserTab` protocol (decision Q11):
// commands hop to the main actor (`ChromiumTabCore`); state and events live in `TabChannel`, a
// lock-protected cache updated in the same main-thread turn as the bridge callback, so `events()`
// can start every stream with `.snapshot(currentState)` synchronously.

/// The `BrowserTab` the shell holds.
public final class ChromiumTab: BrowserTab, @unchecked Sendable {
    // @unchecked: every stored property is an immutable `let` of a Sendable type, except `channel`
    // (lock-protected, see `TabChannel`) and `core` (main-actor isolated).
    public let id: EngineTabID
    public let profileID: Profile.ID
    public let surface: any TabSurface
    let core: ChromiumTabCore
    private let channel: TabChannel

    @MainActor
    init(tab: OACTab, profileID: Profile.ID, colorScheme: WebColorScheme, engine: ChromiumEngineCore) {
        let id = EngineTabID(tab.identifier)
        var initial = BrowserTabState(tab.state)
        initial.translation = PageTranslation(tab.translationState)
        let channel = TabChannel(state: initial)
        let core = ChromiumTabCore(tab: tab, id: id, channel: channel, engine: engine, colorScheme: colorScheme)
        self.id = id
        self.profileID = profileID
        self.channel = channel
        self.core = core
        self.surface = ChromiumSurface(tabID: id, core: core)
    }

    public func currentState() async -> BrowserTabState {
        channel.state
    }

    public func events() -> AsyncStream<TabEvent> {
        channel.subscribe()
    }

    public func dialogRequests() -> AsyncStream<EngineDialogRequest> {
        channel.dialogs.subscribe()
    }

    public func load(_ url: URL) async throws {
        try await core.run { try $0.load(url) }
    }

    public func goBack() async throws {
        try await core.run { try $0.goBack() }
    }

    public func goForward() async throws {
        try await core.run { try $0.goForward() }
    }

    public func reload(bypassingCache: Bool) async throws {
        try await core.run { try $0.reload(bypassingCache: bypassingCache) }
    }

    public func stopLoading() async throws {
        try await core.run { try $0.stopLoading() }
    }

    public func setMuted(_ muted: Bool) async {
        await core.perform { $0.setMuted(muted) }
    }

    public func snapshot(maxPixelSize: Int) async throws -> EngineSnapshot {
        try await core.snapshot(maxPixelSize: maxPixelSize)
    }

    public func requestClose() async {
        await core.perform { $0.closeRunningUnloadHandlers() }
    }

    public func setZoom(_ factor: Double) async throws {
        guard ZoomLevels.range.contains(factor) else { throw EngineError.invalidArgument }
        try await core.run { try $0.setZoomFactor(factor) }
    }

    public func zoomIn() async {
        await core.perform { try? $0.setZoomFactor(ZoomLevels.next(after: $0.state.zoomFactor)) }
    }

    public func zoomOut() async {
        await core.perform { try? $0.setZoomFactor(ZoomLevels.next(before: $0.state.zoomFactor)) }
    }

    public func resetZoom() async {
        await core.perform { $0.resetZoom() }
    }

    public func find(_ text: String, options: FindOptions) async {
        await core.perform { tab in
            guard !text.isEmpty else {
                tab.stopFinding(keepingSelection: false)
                return
            }
            let bridgeOptions = OACFindOptions()
            bridgeOptions.backwards = options.backwards
            bridgeOptions.matchCase = options.matchCase
            bridgeOptions.findNext = options.findNext
            _ = tab.find(text, options: bridgeOptions)
        }
    }

    public func stopFinding(keepSelection: Bool) async {
        await core.perform { $0.stopFinding(keepingSelection: keepSelection) }
    }

    public func selectedText() async -> String {
        await core.selectedText()
    }

    public func perform(_ command: EditCommand) async {
        // The bridge's command names are `EditCommand`'s raw values (OACTab.h).
        await core.perform { $0.performEditCommand(command.rawValue) }
    }

    /// The macOS print panel (C15; the bridge runs Chromium without its print preview).
    public func print() async {
        await core.perform { tab in tab.printPage() }
    }

    /// C15: Chromium's Save Page As, run as a download of the tab's profile.
    public func savePage(to fileURL: URL, format: SavePageFormat) async throws {
        try await core.savePage(to: fileURL, format: format)
    }

    /// C15: DevTools in its own window (one per tab, owned by the bridge).
    public func showDevTools(_ panel: DevToolsPanel?) async {
        await core.perform { $0.showDevTools(panel: panel?.rawValue) }
    }

    public func viewSource() async {
        await core.perform { $0.viewSource() }
    }

    /// C15: Chromium's Picture in Picture window.
    @discardableResult
    public func enterPictureInPicture(automatically: Bool) async -> Bool {
        await core.enterPictureInPicture(automatically: automatically)
    }

    public func exitPictureInPicture() async {
        await core.perform { $0.exitPictureInPicture() }
    }

    public func exitFullscreen() async {
        await core.perform { $0.exitFullscreen() }
    }

    public func setPreferredColorScheme(_ scheme: WebColorScheme) async {
        await core.setPreferredColorScheme(scheme)
    }

    // MARK: Translation (plan B47, OACTranslation.h)

    public func translate(to languageCode: String?) async {
        await core.perform { $0.translate(toLanguage: languageCode) }
    }

    public func revertTranslation() async {
        await core.perform { $0.revertTranslation() }
    }

    public func neverTranslateSite() async {
        await core.perform { $0.neverTranslateSite() }
    }
}

// MARK: - Channel

/// The tab's cached state and its event streams. Thread-safe.
// @unchecked: `cached` and `finished` are read and written only under `lock`; the broadcasters
// are thread-safe themselves.
final class TabChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: BrowserTabState
    private var finished = false
    private let broadcaster = AsyncBroadcaster<TabEvent>()
    let dialogs = AsyncBroadcaster<EngineDialogRequest>()

    init(state: BrowserTabState) {
        cached = state
    }

    var state: BrowserTabState { lock.withLock { cached } }

    func subscribe() -> AsyncStream<TabEvent> {
        // Snapshot and subscription are atomic with respect to updates (both under `lock`).
        lock.withLock { broadcaster.subscribe(initial: [.snapshot(cached)]) }
    }

    /// Replaces the cached state and delivers one event per changed field, in the order a page
    /// load produces them.
    func update(to next: BrowserTabState) {
        lock.withLock {
            guard !finished else { return }
            let previous = cached
            cached = next
            for event in TabChannel.changes(from: previous, to: next) { broadcaster.yield(event) }
        }
    }

    /// Delivers an event that is not a state field (hovered link, find result, crash, close request).
    func send(_ event: TabEvent) {
        lock.withLock {
            guard !finished else { return }
            broadcaster.yield(event)
        }
    }

    /// Ends every stream with `.closed`.
    func finish() {
        let wasFinished: Bool = lock.withLock {
            defer { finished = true }
            if !finished { broadcaster.yield(.closed) }
            return finished
        }
        guard !wasFinished else { return }
        broadcaster.finish()
        dialogs.finish()
    }

    static func changes(from old: BrowserTabState, to new: BrowserTabState) -> [TabEvent] {
        var events: [TabEvent] = []
        if old.url != new.url { events.append(.urlChanged(new.url)) }
        if old.committedURL != new.committedURL { events.append(.committedURLChanged(new.committedURL)) }
        if old.security != new.security { events.append(.securityChanged(new.security)) }
        if old.title != new.title { events.append(.titleChanged(new.title)) }
        if old.favicon != new.favicon { events.append(.faviconChanged(new.favicon)) }
        if old.navigation != new.navigation { events.append(.navigationStateChanged(new.navigation)) }
        if old.audio != new.audio { events.append(.audioStateChanged(new.audio)) }
        if old.zoomFactor != new.zoomFactor { events.append(.zoomChanged(new.zoomFactor)) }
        if old.capture != new.capture { events.append(.captureStateChanged(new.capture)) }
        if old.isFullscreen != new.isFullscreen { events.append(.fullscreenChanged(new.isFullscreen)) }
        if old.themeColor != new.themeColor { events.append(.themeColorChanged(new.themeColor)) }
        if old.pageTopColor != new.pageTopColor { events.append(.pageTopColorChanged(new.pageTopColor)) }
        if old.translation != new.translation { events.append(.translationChanged(new.translation)) }
        if old.loadState != new.loadState { events.append(.loadStateChanged(new.loadState)) }
        return events
    }
}

// MARK: - Core (main actor)

/// Owns the `OACTab` (the bridge never keeps a tab alive on its own) and receives its callbacks.
@MainActor
final class ChromiumTabCore: NSObject, OACTabDelegate, OACDialogDelegate {
    private(set) var tab: OACTab?
    let id: EngineTabID
    private let channel: TabChannel
    private weak var engine: ChromiumEngineCore?
    /// Withdraws an outstanding dialog request, by the bridge request's identity. Weak toward the
    /// reply, so a request the shell dropped still gets its default answer.
    private var outstandingDialogs: [ObjectIdentifier: (id: UUID, withdraw: () -> Void)] = [:]
    /// Live autofill dropdowns (C13), by the bridge request's identity, for row updates.
    private var autofillSessions: [ObjectIdentifier: AutofillPopupSession] = [:]
    /// Re-reads the bridge state a few times after a load settles (see `scheduleSettleResync`).
    private var settleResync: Task<Void, Never>?

    /// Delays (seconds after the load settled) of the follow-up state reads. C9 workaround for a
    /// bridge bug: `-[OACTab faviconDownload:…]` stores the decoded icon before taking the
    /// "before" snapshot, so `tab:didChangeFaviconURL:pngData:` is never sent and the icon only
    /// reaches `OACTab.state`. Reading the state again picks it up. Remove when the bridge fix
    /// (chromium-bridge/SWIFT_PROTOCOL_CHANGES.md, "C9 requests") lands.
    static let settleResyncDelays: [Double] = [0.3, 1, 2.5, 6, 15]

    init(tab: OACTab, id: EngineTabID, channel: TabChannel, engine: ChromiumEngineCore, colorScheme: WebColorScheme) {
        self.tab = tab
        self.id = id
        self.channel = channel
        self.engine = engine
        super.init()
        tab.delegate = self
        tab.dialogDelegate = self
        tab.preferredColorScheme = OACColorScheme(colorScheme)
        // An adopted tab may have finished loading before this wrapper existed: no load event will
        // come to trigger the follow-up reads, so start them now.
        scheduleSettleResync()
    }

    // MARK: Commands

    /// Runs a throwing bridge command; a closed tab throws `EngineError.tabClosed`.
    func run(_ body: @MainActor (OACTab) throws -> Void) throws {
        guard let tab, !tab.isClosed else { throw EngineError.tabClosed(id) }
        do {
            try body(tab)
        } catch {
            throw EngineError(bridge: error, tabID: id)
        }
        sync()
    }

    /// Runs a bridge command that cannot fail; nothing happens on a closed tab.
    func perform(_ body: @MainActor (OACTab) -> Void) {
        guard let tab, !tab.isClosed else { return }
        body(tab)
        sync()
    }

    func snapshot(maxPixelSize: Int) async throws -> EngineSnapshot {
        guard let tab, !tab.isClosed else { throw EngineError.tabClosed(id) }
        let id = self.id
        return try await withCheckedThrowingContinuation { continuation in
            tab.snapshot(maxPixelSize: maxPixelSize) { png, size, error in
                if let png {
                    continuation.resume(returning: EngineSnapshot(
                        pngData: png, pixelWidth: Int(size.width), pixelHeight: Int(size.height)
                    ))
                } else {
                    continuation.resume(throwing: error.map { EngineError(bridge: $0, tabID: id) } ?? EngineError.snapshotUnavailable)
                }
            }
        }
    }

    func savePage(to fileURL: URL, format: SavePageFormat) async throws {
        guard let tab, !tab.isClosed else { throw EngineError.tabClosed(id) }
        guard fileURL.isFileURL, let bridgeFormat = OACSavePageFormat(rawValue: format.rawValue) else {
            throw EngineError.invalidArgument
        }
        let id = self.id
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            tab.savePage(to: fileURL, format: bridgeFormat) { error in
                if let error {
                    continuation.resume(throwing: EngineError(bridge: error, tabID: id))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func enterPictureInPicture(automatically: Bool) -> Bool {
        guard let tab, !tab.isClosed else { return false }
        return tab.enterPictureInPicture(automatically: automatically)
    }

    func selectedText() async -> String {
        guard let tab, !tab.isClosed else { return "" }
        return await withCheckedContinuation { continuation in
            tab.selectedText { continuation.resume(returning: $0) }
        }
    }

    func setPreferredColorScheme(_ scheme: WebColorScheme) {
        tab?.preferredColorScheme = OACColorScheme(scheme)
    }

    /// Closes the bridge tab (`BrowserEngine.closeTab`). The stream ends with `.closed` now, not
    /// when the bridge's `tabDidClose:` arrives.
    func close() {
        guard let tab else { return }
        tab.close()
        finish()
    }

    private func finish() {
        settleResync?.cancel()
        settleResync = nil
        for entry in outstandingDialogs.values { entry.withdraw() }
        outstandingDialogs.removeAll()
        for session in autofillSessions.values { session.finish() }
        autofillSessions.removeAll()
        channel.finish()
        tab?.delegate = nil
        tab?.dialogDelegate = nil
        tab = nil
    }

    /// Copies the bridge's state into the cache, emitting one event per change.
    private func sync() {
        guard let tab, !tab.isClosed else { return }
        var state = BrowserTabState(tab.state)
        state.translation = PageTranslation(tab.translationState)
        channel.update(to: state)
    }

    /// Reads the bridge state again at `settleResyncDelays` after a load stopped or a navigation
    /// finished, so state the bridge changed without a delegate call (the favicon) still arrives.
    /// A newer load restarts the schedule. Bounded: at most five cheap reads per load.
    private func scheduleSettleResync() {
        settleResync?.cancel()
        settleResync = Task { @MainActor [weak self] in
            var elapsed = 0.0
            for delay in ChromiumTabCore.settleResyncDelays {
                try? await Task.sleep(nanoseconds: UInt64((delay - elapsed) * 1_000_000_000))
                elapsed = delay
                guard !Task.isCancelled, let self else { return }
                self.sync()
            }
        }
    }

    // MARK: Hosting

    var nativeView: AnyObject? { tab?.nativeView }

    /// The page is attached to a host on screen.
    private(set) var isVisible = false

    func setVisible(_ visible: Bool) {
        isVisible = visible
        tab?.setVisible(visible)
        // Pick up state the bridge changed without telling (see `settleResyncDelays`).
        if visible {
            sync()
            scheduleSettleResync()
        }
    }

    func setFocused(_ focused: Bool) { tab?.setFocused(focused) }

    // MARK: OACTabDelegate

    func tab(_ tab: OACTab, didChangeURL url: URL?) { sync() }
    func tab(_ tab: OACTab, didChangeTitle title: String) { sync() }
    func tab(_ tab: OACTab, didChangeLoading isLoading: Bool, progress: Double) {
        sync()
        if !isLoading { scheduleSettleResync() }
    }
    func tab(_ tab: OACTab, didChangeFaviconURL faviconURL: URL?, pngData: Data?) { sync() }
    func tab(_ tab: OACTab, didChangeCanGoBack canGoBack: Bool, canGoForward: Bool) { sync() }
    func tab(_ tab: OACTab, didChange audioState: OACAudioState) { sync() }
    func tab(_ tab: OACTab, didChange securityLevel: OACSecurityLevel) { sync() }
    func tab(_ tab: OACTab, didChangeZoomFactor zoomFactor: Double) { sync() }
    func tab(_ tab: OACTab, didChangeFullscreen isFullscreen: Bool) { sync() }
    func tab(_ tab: OACTab, didChangeThemeColor color: OACColor, hasThemeColor: Bool) { sync() }
    func tabDidSamplePageTopColor(_ tab: OACTab) { sync() }
    func tabDidChangeTranslationState(_ tab: OACTab) { sync() }
    func tab(_ tab: OACTab, didFinish navigation: OACNavigation) {
        sync()
        scheduleSettleResync()
    }

    func tab(_ tab: OACTab, renderProcessDidTerminate reason: OACRenderProcessTermination) {
        sync()
        channel.send(.renderProcessGone)
    }

    func tab(_ tab: OACTab, didHoverLinkURL url: URL?) {
        channel.send(.hoveredLinkChanged(url))
    }

    func tab(
        _ tab: OACTab, didUpdateFindResultForRequest requestIdentifier: Int, numberOfMatches: Int,
        activeMatchOrdinal: Int, isFinal: Bool
    ) {
        channel.send(.findResultChanged(FindResult(matches: numberOfMatches, activeOrdinal: activeMatchOrdinal, isFinal: isFinal)))
    }

    func tabDidRequestClose(_ tab: OACTab) {
        channel.send(.closeRequested)
    }

    func tabDidRequestActivation(_ tab: OACTab) {
        channel.send(.activationRequested)
    }

    func tab(_ tab: OACTab, didRequestNewTab request: OACNewTabRequest) {
        guard let engine else {
            request.decline()
            return
        }
        engine.newTabRequested(request, opener: id)
    }

    func tabDidClose(_ tab: OACTab) {
        // Closed by the bridge itself (engine shutdown); `close()` already finished otherwise.
        guard self.tab != nil else { return }
        finish()
        engine?.tabDidClose(id)
    }

    // MARK: OACDialogDelegate

    /// Every request kind of `OACDialogDelegate` goes to the shell's dialog stream (plans C8, C12).
    /// With no subscriber the bridge answers with the request's default right away.
    func tab(_ tab: OACTab, runJavaScriptDialog request: OACJavaScriptDialogRequest) -> Bool {
        deliver(request, default: JavaScriptDialogReply.dismissed, answer: { request, answer in
            if answer.accepted {
                request.accept(promptText: answer.promptText, suppressFurtherDialogs: answer.suppressFurtherDialogs)
            } else {
                request.dismiss(suppressFurtherDialogs: answer.suppressFurtherDialogs)
            }
        }, make: { id, reply in
            .javaScript(JavaScriptDialog(
                id: id,
                origin: request.origin.map(SiteOrigin.init(bridge:)),
                isFromSubframe: request.isFromSubframe,
                kind: JavaScriptDialog.Kind(request.kind),
                message: request.message,
                defaultPromptText: request.defaultPromptText,
                isReload: request.isReload,
                showsSuppressOption: request.showsSuppressOption,
                reply: reply
            ))
        })
    }

    func tab(_ tab: OACTab, requestAuthentication request: OACAuthenticationRequest) -> Bool {
        deliver(request, default: AuthenticationReply.cancel, answer: { request, answer in
            switch answer {
            case .proceed(let username, let password): request.proceed(withUsername: username, password: password)
            case .cancel: request.cancel()
            }
        }, make: { id, reply in
            .authentication(AuthenticationChallenge(
                id: id,
                origin: request.origin.map(SiteOrigin.init(bridge:)),
                isFromSubframe: request.isFromSubframe,
                realm: request.realm,
                challengerHostPort: request.challengerHostPort,
                isProxy: request.isProxyChallenge,
                isInsecureConnection: request.isInsecureConnection,
                suggestedUsername: request.suggestedUsername,
                reply: reply
            ))
        })
    }

    func tab(_ tab: OACTab, requestPermission request: OACPermissionRequest) -> Bool {
        let kinds = request.permissionKinds
        guard !kinds.isEmpty else { return false }
        return deliver(request, default: PermissionReply.dismiss, answer: { request, answer in
            switch answer {
            case .allow(let remember): request.allow(remembering: remember)
            case .deny(let remember): request.deny(remembering: remember)
            case .dismiss: request.dismiss()
            }
        }, make: { id, reply in
            .permission(PermissionPrompt(
                id: id,
                origin: request.origin.map(SiteOrigin.init(bridge:)),
                isFromSubframe: request.isFromSubframe,
                kinds: kinds,
                hasUserGesture: request.hasUserGesture,
                supportsAllowingOnce: request.supportsAllowingOnce,
                reply: reply
            ))
        })
    }

    func tab(_ tab: OACTab, runFileChooser request: OACFileChooserRequest) -> Bool {
        deliver(request, default: FileChooserReply.cancel, answer: { request, answer in
            switch answer {
            case .select(let urls): request.select(urls)
            case .cancel: request.cancel()
            }
        }, make: { id, reply in
            .fileChooser(FileChooserRequest(
                id: id,
                origin: request.origin.map(SiteOrigin.init(bridge:)),
                isFromSubframe: request.isFromSubframe,
                mode: FileChooserRequest.Mode(request.mode),
                acceptedTypeIdentifiers: request.acceptedTypeIdentifiers,
                defaultURL: request.defaultURL,
                reply: reply
            ))
        })
    }

    func tab(_ tab: OACTab, openExternalProtocol request: OACExternalProtocolRequest) -> Bool {
        deliver(request, default: ExternalProtocolReply.block, answer: { request, answer in
            switch answer {
            case .open(let remember): request.open(rememberingForOrigin: remember)
            case .block: request.cancel()
            }
        }, make: { id, reply in
            .externalProtocol(ExternalProtocolRequest(
                id: id,
                origin: request.origin.map(SiteOrigin.init(bridge:)),
                isFromSubframe: request.isFromSubframe,
                url: request.url,
                handlerApplicationName: request.handlerApplicationName,
                handlerApplicationURL: request.handlerApplicationURL,
                hasUserGesture: request.hasUserGesture,
                canRememberForOrigin: request.canRememberForOrigin,
                reply: reply
            ))
        })
    }

    func tab(_ tab: OACTab, offerToSavePassword prompt: OACPasswordSavePrompt) -> Bool {
        deliver(prompt, default: PasswordSaveReply.dismiss, answer: { prompt, answer in
            switch answer {
            case .save(let username): prompt.save(username: username)
            case .neverForThisSite: prompt.neverForThisSite()
            case .decline: prompt.decline()
            case .dismiss: prompt.cancel()
            }
        }, make: { id, reply in
            .passwordSave(PasswordSavePrompt(
                id: id,
                origin: prompt.origin.map(SiteOrigin.init(bridge:)),
                kind: prompt.kind == .update ? .update : .save,
                username: prompt.username,
                passwordLength: Int(prompt.passwordLength),
                reply: reply
            ))
        })
    }

    /// C13: the autofill dropdown. Its rows change while it is open (`didUpdateAutofillPopup`), so
    /// besides the single-shot reply it carries an `AutofillPopupSession`.
    func tab(_ tab: OACTab, showAutofillPopup popup: OACAutofillPopup) -> Bool {
        let box = MainActorBox(popup)
        let session = AutofillPopupSession(state: AutofillPopupState(popup)) { command in
            ChromiumTabCore.onMain {
                let popup = box.value
                switch command {
                case .select(let index): popup.selectSuggestion(at: index ?? -1)
                case .accept(let index): popup.acceptSuggestion(at: index)
                case .pointerInside(let inside): popup.containsPointer = inside
                }
            }
        }
        let key = ObjectIdentifier(popup)
        let delivered = deliver(popup, default: AutofillPopupReply.dismiss, answer: { [weak self] popup, _ in
            self?.autofillSessions.removeValue(forKey: key)?.finish()
            popup.cancel()
        }, make: { id, reply in
            .autofillPopup(AutofillPopup(
                id: id, origin: popup.origin.map(SiteOrigin.init(bridge:)), session: session, reply: reply
            ))
        })
        if delivered { autofillSessions[key] = session }
        return delivered
    }

    /// C14: an extension install confirmation for this tab (the Web Store page, or the tab the
    /// engine chose for a tab-less install). Comes from `OACExtensions`, not `OACDialogDelegate`.
    func deliverExtensionInstall(_ request: OACExtensionInstallRequest) -> Bool {
        guard channel.dialogs.subscriberCount > 0 else { return false }
        let box = MainActorBox(request)
        let reply = DialogReply<ExtensionInstallReply>(default: .cancel) { answer in
            ChromiumTabCore.onMain {
                if answer == .add { box.value.approve() } else { box.value.cancel() }
            }
        }
        let origin = tab?.state.committedURL.flatMap(SiteOrigin.init(url:))
        channel.dialogs.yield(.extensionInstall(ExtensionInstallPrompt(
            id: UUID(),
            origin: origin,
            extensionID: request.extensionIdentifier,
            extensionName: request.extensionName,
            iconPNGData: request.iconPNGData,
            title: request.title,
            acceptTitle: request.acceptButtonTitle,
            cancelTitle: request.cancelButtonTitle,
            permissionWarnings: request.permissionWarnings,
            reply: reply
        )))
        return true
    }

    func tab(_ tab: OACTab, didUpdateAutofillPopup popup: OACAutofillPopup) {
        autofillSessions[ObjectIdentifier(popup)]?.update(AutofillPopupState(popup))
    }

    /// Wraps a bridge request in an `EngineDialogRequest` with a single-shot reply and yields it.
    /// The reply holds the bridge request until answered (answering on the main actor); the
    /// outstanding table holds the reply weakly, so a request the shell dropped still gets its
    /// default answer from the reply's deinit. Returns false (the bridge answers with its default)
    /// when nobody listens.
    private func deliver<Request: OACDialogRequest, Answer: Sendable>(
        _ request: Request,
        default defaultAnswer: Answer,
        answer apply: @escaping @MainActor (Request, Answer) -> Void,
        make: (UUID, DialogReply<Answer>) -> EngineDialogRequest
    ) -> Bool {
        guard channel.dialogs.subscriberCount > 0 else { return false }
        let id = UUID()
        let key = ObjectIdentifier(request)
        // The bridge request is main-actor bound; the reply may be answered from any thread.
        let box = MainActorBox(request)
        let reply = DialogReply<Answer>(default: defaultAnswer) { [weak self] answer in
            ChromiumTabCore.onMain {
                self?.outstandingDialogs.removeValue(forKey: key)
                apply(box.value, answer)
            }
        }
        outstandingDialogs[key] = (id, { [weak reply] in reply?.withdraw() })
        channel.dialogs.yield(make(id, reply))
        return true
    }

    func tab(_ tab: OACTab, didCancel request: OACDialogRequest) {
        autofillSessions.removeValue(forKey: ObjectIdentifier(request))?.finish()
        guard let entry = outstandingDialogs.removeValue(forKey: ObjectIdentifier(request)) else { return }
        entry.withdraw()
        channel.send(.dialogCancelled(entry.id))
    }

    /// Runs `body` on the main actor: right away when already there, else from a task.
    nonisolated static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in body() }
        }
    }
}

// MARK: - Surface

/// The displayable side of a tab: hands the page's NSView to the shell's `SurfaceHost`.
@MainActor
final class ChromiumSurface: TabSurface {
    nonisolated let tabID: EngineTabID
    private weak var core: ChromiumTabCore?
    private weak var host: (any SurfaceHost)?

    init(tabID: EngineTabID, core: ChromiumTabCore) {
        self.tabID = tabID
        self.core = core
    }

    func attach(to newHost: any SurfaceHost) {
        if let host, host !== newHost { host.clear() }
        host = newHost
        guard let core, let view = core.nativeView else {
            newHost.show(.placeholder(SurfacePlaceholder(title: "", url: nil)))
            return
        }
        newHost.show(.native(view))
        core.setVisible(true)
    }

    func detach() {
        host?.clear()
        host = nil
        core?.setVisible(false)
    }

    func setFocused(_ focused: Bool) {
        core?.setFocused(focused)
    }
}

// MARK: - Value mapping

extension BrowserTabState {
    init(_ state: OACTabState) {
        let favicon: Favicon? = (state.faviconURL != nil || state.faviconPNGData != nil)
            ? Favicon(url: state.faviconURL, pngData: state.faviconPNGData) : nil
        let color = state.themeColor
        self.init(
            url: state.url,
            title: state.title,
            loadState: LoadState(isLoading: state.isLoading, progress: state.isLoading ? state.loadProgress : 1),
            favicon: favicon,
            navigation: NavigationState(canGoBack: state.canGoBack, canGoForward: state.canGoForward),
            isCrashed: state.isCrashed,
            audio: AudioState(isAudible: state.audioState.contains(.audible), isMuted: state.audioState.contains(.muted)),
            committedURL: state.committedURL,
            security: SecurityLevel(state.securityLevel),
            zoomFactor: state.zoomFactor,
            capture: CaptureState(rawValue: Int(state.captureState.rawValue)),
            isFullscreen: state.isFullscreen,
            themeColor: state.hasThemeColor
                ? RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha) : nil,
            pageTopColor: PageTopColor(kind: state.pageTopColorKind, color: state.pageTopColor)
        )
    }
}

extension PageTranslation {
    /// The bridge's translation snapshot (plan B47).
    init(_ state: OACTranslationState) {
        let status: Status = switch state.status {
        case .available: .available
        case .translating: .translating
        case .translated: .translated
        case .failed: .failed(TranslationFailure(state.error))
        default: .unavailable
        }
        self.init(
            status: status,
            sourceLanguage: state.sourceLanguage.map(TranslationLanguage.init),
            targetLanguage: state.targetLanguage.map(TranslationLanguage.init)
        )
    }
}

extension TranslationLanguage {
    init(_ language: OACTranslationLanguage) {
        self.init(code: language.code, name: language.name)
    }
}

extension TranslationFailure {
    init(_ error: OACTranslationError) {
        switch error {
        case .network: self = .network
        case .initialization: self = .serviceUnavailable
        case .unknownLanguage: self = .unknownLanguage
        case .unsupportedLanguage: self = .unsupportedLanguage
        case .identicalLanguages: self = .identicalLanguages
        default: self = .translationFailed
        }
    }
}

extension PageTopColor {
    /// The bridge's sample (plan B45); nil before the first finished load was sampled.
    init?(kind: OACPageTopColorKind, color: OACColor) {
        switch kind {
        case .color: self = .color(RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: 1))
        case .scrollbar: self = .scrollbar
        default: return nil
        }
    }
}

extension AutofillPopupState {
    @MainActor
    init(_ popup: OACAutofillPopup) {
        self.init(
            suggestions: popup.suggestions.map(AutofillSuggestion.init),
            elementBounds: EngineRect(
                x: popup.elementBounds.minX, y: popup.elementBounds.minY,
                width: popup.elementBounds.width, height: popup.elementBounds.height
            ),
            isRightToLeft: popup.isRightToLeft,
            selectedIndex: popup.selectedIndex >= 0 ? popup.selectedIndex : nil
        )
    }
}

extension AutofillSuggestion {
    init(_ suggestion: OACAutofillSuggestion) {
        let kind: Kind = switch suggestion.kind {
        case .password: .password
        case .address: .address
        case .creditCard: .creditCard
        case .autocomplete: .autocomplete
        case .dataList: .dataList
        case .title: .title
        case .separator: .separator
        default: .action
        }
        self.init(
            kind: kind, mainText: suggestion.mainText, minorText: suggestion.minorText, label: suggestion.label,
            isSelectable: suggestion.isSelectable, isAcceptable: suggestion.isAcceptable
        )
    }
}

extension SecurityLevel {
    init(_ level: OACSecurityLevel) {
        switch level {
        case .secure: self = .secure
        case .warning: self = .warning
        case .dangerous: self = .dangerous
        default: self = .none
        }
    }
}

extension SiteOrigin {
    init(bridge origin: OACOrigin) {
        self.init(scheme: origin.scheme, host: origin.host, port: origin.port?.intValue)
    }
}

/// Carries a main-actor object through a `@Sendable` closure; read only on the main actor.
final class MainActorBox<Value: AnyObject>: @unchecked Sendable {
    // @unchecked: `value` is immutable and only dereferenced inside `MainActor` code
    // (`ChromiumTabCore.onMain`).
    let value: Value
    init(_ value: Value) { self.value = value }
}

extension OACPermissionRequest {
    /// The prompt's kinds that the engine protocol knows, in the bridge's order.
    var permissionKinds: [SitePermissionKind] {
        __kinds.compactMap { OACPermissionKind(rawValue: $0.intValue).flatMap(SitePermissionKind.init) }
    }
}

extension SitePermissionKind {
    init?(_ kind: OACPermissionKind) {
        switch kind {
        case .camera: self = .camera
        case .microphone: self = .microphone
        case .location: self = .location
        case .notifications: self = .notifications
        case .clipboardRead: self = .clipboardRead
        case .MIDI: self = .midi
        case .storageAccess: self = .storageAccess
        case .screenWakeLock: self = .screenWakeLock
        case .multipleDownloads: self = .multipleDownloads
        case .localFonts: self = .localFonts
        case .windowManagement: self = .windowManagement
        case .idleDetection: self = .idleDetection
        case .protectedMedia: self = .protectedMedia
        @unknown default: return nil
        }
    }
}

extension FileChooserRequest.Mode {
    init(_ mode: OACFileChooserMode) {
        switch mode {
        case .openMultiple: self = .openMultiple
        case .openFolder: self = .openFolder
        case .save: self = .save
        default: self = .open
        }
    }
}

extension JavaScriptDialog.Kind {
    init(_ kind: OACJavaScriptDialogKind) {
        switch kind {
        case .confirm: self = .confirm
        case .prompt: self = .prompt
        case .beforeUnload: self = .beforeUnload
        default: self = .alert
        }
    }
}
