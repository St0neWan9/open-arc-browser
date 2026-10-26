import Foundation
import Combine
import OpenArcEngine
import OpenArcDesign

// State and intents of the Site Control Center: the bubble that opens from the site-controls
// icon in the URL box, plus the URL box's copy-link feedback. [06 §12] observed:
// - Hovering the URL box of the current tab shows two icons: copy link (chain) and site
//   controls (sliders).
// - The bubble (≈ 120 pt wide) has a row of 4 square buttons (Share, New Boost, capture area,
//   capture full page), an "Extensions" section ("+" button; "Manage" at the top right when
//   extensions exist), a "Settings" section with two rows (round icon + title + small status):
//   Developer Mode (Off) and Automatic Picture-In-Picture (Allowed), and at the bottom a
//   "Secure" pill on the left and a "⋯" button on the right.
// - Moving the pointer away makes the bubble disappear.
//
// Engine-backed values go through `SiteSettingsProvider` (ad blocking C16 and extensions C14 are
// the engine's; the rest is fake until C12 settles it).

/// The 4 square buttons at the top of the bubble. [06 §12] observed.
public enum SiteControlsTool: String, CaseIterable, Sendable {
    case share, newBoost, captureArea, captureFullPage

    var title: String {
        switch self {
        case .share: "Share"
        case .newBoost: "New Boost"
        case .captureArea: "Capture Area"
        case .captureFullPage: "Capture Full Page"
        }
    }

    /// SF Symbols stand-ins; icons may differ by design (CLAUDE.md).
    var symbol: String {
        switch self {
        case .share: "square.and.arrow.up"
        case .newBoost: "paintbrush"
        case .captureArea: "camera"
        case .captureFullPage: "doc.viewfinder"
        }
    }
}

/// Why the bubble closed (for tests and diagnostics).
public enum SiteControlsCloseReason: Equatable, Sendable {
    /// The pointer left the bubble. [06 §12] observed.
    case pointerLeft
    /// Escape. inferred.
    case escape
    /// A click outside the bubble (popover dismissed by the system). inferred.
    case clickOutside
    /// The selected tab changed while open. inferred.
    case tabChanged
    /// One of the bubble's actions ran and finished the interaction. inferred.
    case action
}

/// The extension popup the Site Control Center opened (C14). The spec records where extension
/// actions live ([06 §12], [06 §17.2]) but not where their popups appear: we anchor the popup to
/// the same site-controls button, below it, like the Site Control Center itself. inferred.
public struct ExtensionPopupState: Equatable, Sendable {
    public var extensionID: String
    /// The model tab whose action ran.
    public var tabID: UUID
    /// The page's size in points; Chromium's 25×25 minimum until the page reports one.
    public var width: Double
    public var height: Double
    /// The page finished its first load; the bubble shows only then (Chrome does the same).
    public var isLoaded: Bool
}

/// One row of the "Settings" section: round icon + title + small status. [06 §12] observed shape.
public struct SiteControlsSettingRow: Identifiable, Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        case developerMode
        case automaticPictureInPicture
        case permission(SitePermissionKind)
        case cookies
        case zoom
        case adBlocking
        case sound
    }

    public var kind: Kind
    public var title: String
    public var status: String
    public var symbol: String
    public var id: Kind { kind }
}

@MainActor
public final class SiteControlsModel: ObservableObject {

    // MARK: Published state

    @Published public private(set) var isPresented = false
    /// Tab the bubble was opened for (the selected tab at that moment).
    @Published public private(set) var tabID: UUID?
    @Published public private(set) var site: SiteOrigin?
    @Published public private(set) var settings: SiteSettingsState = .defaults
    /// True for a moment after Copy Link. [06 §12] does not describe feedback; inferred.
    @Published public private(set) var isLinkCopied = false
    @Published public private(set) var lastCloseReason: SiteControlsCloseReason?
    /// The open extension popup, if any (C14).
    @Published public private(set) var extensionPopup: ExtensionPopupState?

    // MARK: Dependencies

    /// Engine site settings. Fake until C12 / C14 / C16 plug in Chromium.
    var provider: any SiteSettingsProvider
    var pasteboard: any PasteboardWriter
    /// Runs the 4 top buttons. nil disables them (no Share / Boost / capture surface yet).
    public var toolHandler: ((SiteControlsTool, UUID) -> Void)?
    /// Opens the extension gallery ("+") and the extension manager ("Manage") (C14). nil disables them.
    public var addExtensionHandler: (() -> Void)?
    public var manageExtensionsHandler: (() -> Void)?

    /// Seconds the "Copied" state stays. inferred.
    var copiedFeedbackDuration: Double = SiteControlsLocalTokens.copiedFeedbackDuration
    /// Seconds between the pointer leaving and the bubble closing, so the pointer can travel
    /// from the icon into the bubble. inferred.
    var pointerLeaveGrace: Double = SiteControlsLocalTokens.pointerLeaveGrace

    private let sidebar: SidebarViewModel
    private var work: [Task<Void, Never>] = []
    private var copiedTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var selectionChanges: AnyCancellable?
    private var sidebarChanges: AnyCancellable?
    private var openPopup: (any ExtensionPopup)?
    private var popupEvents: Task<Void, Never>?
    private var extensionEvents: Task<Void, Never>?

    init(sidebar: SidebarViewModel, provider: any SiteSettingsProvider, pasteboard: any PasteboardWriter) {
        self.sidebar = sidebar
        self.provider = provider
        self.pasteboard = pasteboard
        selectionChanges = sidebar.$selectedTabID.dropFirst().sink { [weak self] newID in
            guard let self else { return }
            // A popup belongs to its tab; switching tabs closes it (Chrome does). inferred.
            if let popup = self.extensionPopup, popup.tabID != newID { self.closeExtensionPopup() }
            guard self.isPresented, newID != self.tabID else { return }
            self.close(.tabChanged)
        }
        // Rows read the tab's live audio state from the sidebar; redraw the bubble when it changes.
        sidebarChanges = sidebar.objectWillChange.sink { [weak self] _ in
            guard let self, self.isPresented else { return }
            self.objectWillChange.send()
        }
    }

    // MARK: Derived state

    private var liveState: SidebarTabLiveState? { tabID.flatMap { sidebar.liveState(for: $0) } }

    /// The "Secure" pill. [06 §12] observed "Secure"; the insecure label is inferred.
    public var securityLabel: String { site?.isSecure == false ? "Not Secure" : "Secure" }

    /// "Manage" shows only when extensions exist. [06 §12] observed. Any installed extension
    /// counts, also one without an action on this page. inferred.
    public var showsManageExtensions: Bool { !settings.extensions.isEmpty || hasInstalledExtensions }

    /// The profile has extensions (C14), whether or not they have an action here.
    @Published public private(set) var hasInstalledExtensions = false

    /// Engine extensions (C14): installed list and change events for the bubble's section.
    var engineExtensions: (any EngineExtensions)?

    /// Permissions the "⋯" menu offers: the common four, plus any other kind the site has a
    /// decision for. inferred.
    public var menuPermissionKinds: [SitePermissionKind] {
        SitePermissionKind.allCases.filter { SitePermissionKind.commonKinds.contains($0) || settings.decision(for: $0) != .ask }
    }

    /// Rows of the "Settings" section. The first two are always there [06 §12] observed. The
    /// others show only when they carry state (inferred: none of them was visible on a fresh site).
    public var settingRows: [SiteControlsSettingRow] {
        var rows = [
            SiteControlsSettingRow(kind: .developerMode, title: "Developer Mode",
                                   status: settings.isDeveloperModeOn ? "On" : "Off", symbol: "hammer"),
            SiteControlsSettingRow(kind: .automaticPictureInPicture, title: "Automatic Picture-In-Picture",
                                   status: settings.isAutomaticPictureInPictureAllowed ? "Allowed" : "Blocked",
                                   symbol: "pip"),
        ]
        for kind in SitePermissionKind.allCases {
            let decision = settings.decision(for: kind)
            guard decision != .ask else { continue }
            rows.append(SiteControlsSettingRow(kind: .permission(kind), title: kind.title,
                                               status: decision == .allow ? "Allowed" : "Blocked", symbol: kind.symbol))
        }
        if settings.cookieCount > 0 {
            rows.append(SiteControlsSettingRow(kind: .cookies, title: "Cookies",
                                               status: settings.cookieCount == 1 ? "1 cookie" : "\(settings.cookieCount) cookies",
                                               symbol: "server.rack"))
        }
        if settings.zoomPercent != 100 {
            rows.append(SiteControlsSettingRow(kind: .zoom, title: "Zoom", status: "\(settings.zoomPercent)%",
                                               symbol: "plus.magnifyingglass"))
        }
        if let on = settings.isAdBlockingOn {
            rows.append(SiteControlsSettingRow(kind: .adBlocking, title: "Ad Blocking", status: on ? "On" : "Off",
                                               symbol: "shield.lefthalf.filled"))
        }
        // Mute row while the tab plays audio (same path as the tab menu's Mute). inferred: the
        // spec does not list it in the bubble.
        if let live = liveState, live.isAudible || live.isMuted {
            rows.append(SiteControlsSettingRow(kind: .sound, title: "Sound", status: live.isMuted ? "Muted" : "Playing",
                                               symbol: live.isMuted ? "speaker.slash" : "speaker.wave.2"))
        }
        return rows
    }

    // MARK: Presentation

    /// Opens the bubble for the selected tab (`SidebarRequest.showSiteControls`). Does nothing
    /// without a page: the icon only shows for a loaded page. [06 §12] observed.
    public func present() {
        guard let id = sidebar.selectedTabID, let url = sidebar.linkURL(for: id), let origin = SiteOrigin(url: url) else { return }
        leaveTask?.cancel()
        tabID = id
        site = origin
        settings = .defaults
        lastCloseReason = nil
        isPresented = true
        reload()
    }

    public func close(_ reason: SiteControlsCloseReason) {
        leaveTask?.cancel()
        leaveTask = nil
        guard isPresented else { return }
        isPresented = false
        lastCloseReason = reason
        extensionEvents?.cancel()
        extensionEvents = nil
    }

    /// The pointer left the bubble (or the icon it opened from). [06 §12] observed: it closes.
    public func pointerExited() {
        guard isPresented else { return }
        leaveTask?.cancel()
        guard pointerLeaveGrace > 0 else { close(.pointerLeft); return }
        let grace = pointerLeaveGrace
        leaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.close(.pointerLeft)
        }
    }

    /// The pointer is over the bubble or its icon: cancels a pending close.
    public func pointerEntered() {
        leaveTask?.cancel()
        leaveTask = nil
    }

    // MARK: Copy link

    /// Copies the selected tab's link and shows "Copied" briefly. [06 §12] observed icon;
    /// the feedback is inferred.
    public func copyLink() {
        guard let id = sidebar.selectedTabID, let url = sidebar.linkURL(for: id) else { return }
        pasteboard.writeURL(url)
        isLinkCopied = true
        copiedTask?.cancel()
        let duration = copiedFeedbackDuration
        copiedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isLinkCopied = false
        }
    }

    // MARK: Top buttons and extensions

    public var canRunTools: Bool { toolHandler != nil }

    public func run(_ tool: SiteControlsTool) {
        guard let id = tabID, let toolHandler else { return }
        close(.action)
        toolHandler(tool, id)
    }

    /// Runs an extension's action on the bubble's tab, as a click on Chrome's toolbar button does.
    /// The Site Control Center closes and the extension's popup, if it has one, opens in its own
    /// bubble at the same button once its page loaded. inferred (see `ExtensionPopupState`).
    public func runExtension(_ extensionID: String) {
        guard let id = tabID, let site else { return }
        let profile = sidebar.currentProfileID
        let provider = provider
        closeExtensionPopup()
        close(.action)
        work.append(Task { [weak self] in
            guard let popup = await provider.runExtensionAction(extensionID, tabID: id, site: site, profileID: profile) else { return }
            self?.show(popup, tabID: id)
        })
    }

    // MARK: Extension popup

    private func show(_ popup: any ExtensionPopup, tabID: UUID) {
        // The tab changed while the engine opened it.
        guard sidebar.selectedTabID == tabID else {
            Task { await popup.close() }
            return
        }
        openPopup = popup
        let minimum = SiteControlsLocalTokens.extensionPopupMinimumSize
        extensionPopup = ExtensionPopupState(extensionID: popup.extensionID, tabID: tabID,
                                             width: minimum, height: minimum, isLoaded: false)
        let events = popup.events()
        popupEvents?.cancel()
        popupEvents = Task { [weak self, weak popup] in
            for await event in events {
                guard let self, let popup, self.openPopup === popup else { return }
                self.apply(event)
            }
        }
    }

    private func apply(_ event: ExtensionPopupEvent) {
        switch event {
        case .loaded:
            extensionPopup?.isLoaded = true
        case .resized(let width, let height):
            let size = SiteControlsLocalTokens.clampedExtensionPopupSize(width: width, height: height)
            extensionPopup?.width = size.width
            extensionPopup?.height = size.height
        case .closed:
            openPopup = nil
            extensionPopup = nil
            popupEvents?.cancel()
            popupEvents = nil
        }
    }

    /// The popup's page view goes into `host` (the bubble's container).
    func attachExtensionPopup(to host: any SurfaceHost) {
        openPopup?.attach(to: host)
    }

    /// Gives the popup's page the keyboard once its bubble is up.
    func focusExtensionPopup() {
        openPopup?.focus()
    }

    /// Closes the popup (click outside, Escape, tab switch, another action).
    public func closeExtensionPopup() {
        guard let popup = openPopup else {
            extensionPopup = nil
            return
        }
        openPopup = nil
        extensionPopup = nil
        popupEvents?.cancel()
        popupEvents = nil
        work.append(Task { await popup.close() })
    }

    // MARK: Settings rows

    /// Default action of a row: toggles on/off rows, flips a permission between Allowed and
    /// Blocked, resets zoom, clears cookies, mutes / unmutes. inferred.
    public func activate(_ kind: SiteControlsSettingRow.Kind) {
        switch kind {
        case .developerMode: apply(.developerMode(!settings.isDeveloperModeOn))
        case .automaticPictureInPicture: apply(.automaticPictureInPicture(!settings.isAutomaticPictureInPictureAllowed))
        case .permission(let p): setPermission(p, settings.decision(for: p) == .allow ? .block : .allow)
        case .cookies: apply(.clearSiteData)
        case .zoom: apply(.zoom(percent: 100))
        case .adBlocking: apply(.adBlocking(!(settings.isAdBlockingOn ?? false)))
        case .sound: toggleMute()
        }
    }

    public func setPermission(_ kind: SitePermissionKind, _ decision: SitePermissionDecision) {
        apply(.permission(kind, decision))
    }

    public func clearSiteData() { apply(.clearSiteData) }

    /// Mute / unmute through the sidebar's engine path (same as the tab menu).
    public func toggleMute() {
        guard let id = tabID else { return }
        sidebar.toggleMute(id)
    }

    // MARK: Engine plumbing

    /// Sends one change to the provider, then reloads the state it reports.
    private func apply(_ change: SiteSettingChange) {
        guard let site else { return }
        let profile = sidebar.currentProfileID
        let provider = provider
        work.append(Task { [weak self] in
            await provider.apply(change, for: site, profileID: profile)
            await self?.refresh(site: site, profileID: profile)
        })
    }

    private func reload() {
        guard let site else { return }
        let profile = sidebar.currentProfileID
        observeExtensions(profileID: profile)
        work.append(Task { [weak self] in await self?.refresh(site: site, profileID: profile) })
    }

    private func refresh(site: SiteOrigin, profileID: UUID?) async {
        var state = await provider.settings(for: site, profileID: profileID)
        if let id = tabID, let actions = await provider.extensionActions(tabID: id, profileID: profileID) {
            state.extensions = actions
        }
        var installed: [EngineExtensionInfo] = []
        if let profileID, let engineExtensions { installed = await engineExtensions.installed(profileID: profileID) }
        guard self.site == site else { return }
        settings = state
        hasInstalledExtensions = !installed.isEmpty
    }

    /// Follows the profile's extension changes (installs, badges, icons) while the bubble is open.
    private func observeExtensions(profileID: UUID?) {
        extensionEvents?.cancel()
        extensionEvents = nil
        guard let engineExtensions, let profileID else { return }
        let events = engineExtensions.events(profileID: profileID)
        extensionEvents = Task { [weak self] in
            for await _ in events {
                guard let self, self.isPresented, let site = self.site else { continue }
                await self.refresh(site: site, profileID: profileID)
            }
        }
    }

    /// Waits for pending provider calls (tests).
    func settle() async {
        while !work.isEmpty {
            let pending = work
            work.removeAll()
            for task in pending { await task.value }
        }
    }

    func stop() {
        closeExtensionPopup()
        extensionEvents?.cancel()
        work.forEach { $0.cancel() }
        work.removeAll()
        copiedTask?.cancel()
        leaveTask?.cancel()
    }
}

extension SitePermissionKind {
    /// Kinds the "⋯" menu always offers; any other kind appears once the site has a decision for
    /// it. inferred (the spec shows no permission rows, [06 §12]).
    static let commonKinds: [SitePermissionKind] = [.camera, .microphone, .location, .notifications]

    /// Row and menu title. Our wording (the spec records none): unknown.
    var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        case .clipboardRead: "Clipboard"
        case .midi: "MIDI Devices"
        case .storageAccess: "Third-Party Storage"
        case .screenWakeLock: "Keep Screen On"
        case .multipleDownloads: "Automatic Downloads"
        case .localFonts: "Fonts"
        case .windowManagement: "Window Management"
        case .idleDetection: "Device Use"
        case .protectedMedia: "Protected Content"
        }
    }

    /// SF Symbol. unknown.
    var symbol: String {
        switch self {
        case .camera: "video"
        case .microphone: "mic"
        case .location: "location"
        case .notifications: "bell"
        case .clipboardRead: "doc.on.clipboard"
        case .midi: "pianokeys"
        case .storageAccess: "externaldrive"
        case .screenWakeLock: "sun.max"
        case .multipleDownloads: "arrow.down.circle"
        case .localFonts: "textformat"
        case .windowManagement: "macwindow.on.rectangle"
        case .idleDetection: "person.crop.circle.badge.clock"
        case .protectedMedia: "lock.rectangle"
        }
    }
}
