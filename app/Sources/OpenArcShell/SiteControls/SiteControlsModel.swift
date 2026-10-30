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
// [06 §17.3] observed: the pill reads "Insecure" or "Secure". [06 §19.1] observed: the "⋯" menu is
// Clear Cache · Clear Cookies ‖ Manage Boosts… · New Boost… ‖ Manage Extensions… · Add Extension… ‖
// All Site Settings… (plan B80).
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

/// Items of an extension action's right-click menu in the "Extensions" section (B116). inferred:
/// the spec records no such menu; see `SiteControlsModel.extensionMenuItems(for:)`.
public enum SiteExtensionMenuItem: String, CaseIterable, Sendable {
    case manage, remove

    /// Title for the extension named `name`. Our wording (unknown in the spec).
    public func title(extensionName name: String) -> String {
        switch self {
        case .manage: "Manage Extension"
        case .remove: "Remove “\(name)”…"
        }
    }
}

/// Items of the "⋯" menu at the bottom right of the bubble. [06 §19.1] observed order and titles.
public enum SiteControlsMenuItem: String, CaseIterable, Sendable {
    case clearCache, clearCookies, manageBoosts, newBoost, manageExtensions, addExtension, allSiteSettings

    public var title: String {
        switch self {
        case .clearCache: "Clear Cache"
        case .clearCookies: "Clear Cookies"
        case .manageBoosts: "Manage Boosts…"
        case .newBoost: "New Boost…"
        case .manageExtensions: "Manage Extensions…"
        case .addExtension: "Add Extension…"
        case .allSiteSettings: "All Site Settings…"
        }
    }

    /// The menu's groups, separated by dividers. [06 §19.1] observed.
    public static let groups: [[SiteControlsMenuItem]] = [
        [.clearCache, .clearCookies],
        [.manageBoosts, .newBoost],
        [.manageExtensions, .addExtension],
        [.allSiteSettings],
    ]
}

/// The system share picker the Share button opened, anchored to that button. The bubble stays
/// open under it and closes once the picker is done. inferred: [06 §12] observed the Share
/// button, not what follows a click.
public struct SiteControlsShareRequest: Equatable, Sendable {
    /// Tells two requests for the same page apart, so the view shows each picker once.
    public var serial: Int
    public var tabID: UUID
    /// The page's link, as Copy Link writes it.
    public var url: URL
}

/// Where "All Site Settings…" goes: Chromium's settings page of the site. inferred (the spec
/// records the item, not its destination; there is no native site settings page).
enum SiteSettingsPages {
    static func details(for site: SiteOrigin) -> URL? {
        let origin = "\(site.scheme)://\(site.displayHost)"
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = origin.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "chrome://settings/content/siteDetails?site=\(encoded)")
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
    /// The system share picker the Share button opened, while it is up (B80).
    @Published public private(set) var shareRequest: SiteControlsShareRequest?

    // MARK: Dependencies

    /// Engine site settings. Fake until C12 / C14 / C16 plug in Chromium.
    var provider: any SiteSettingsProvider
    var pasteboard: any PasteboardWriter
    /// Runs the two capture buttons; nil disables them. Share and New Boost are the model's own.
    public var toolHandler: ((SiteControlsTool, UUID) -> Void)?
    /// Opens Library ▸ Boosts ("Manage Boosts…"); nil disables the item.
    public var manageBoostsHandler: (() -> Void)?
    /// Opens the extension gallery ("+") and the extension manager ("Manage") (C14). nil disables them.
    public var addExtensionHandler: (() -> Void)?
    public var manageExtensionsHandler: (() -> Void)?
    /// The action's right-click menu (B116): opens one extension's details page; nil disables it.
    public var manageExtensionHandler: ((String) -> Void)?
    /// The action's right-click menu (B116): asks before removing the named extension (an app-modal
    /// alert in the app). Answers true to remove. nil disables "Remove" (incognito windows).
    public var confirmExtensionRemoval: ((String) -> Bool)?

    /// Seconds the "Copied" state stays. inferred.
    var copiedFeedbackDuration: Double = SiteControlsLocalTokens.copiedFeedbackDuration
    /// Seconds between the pointer leaving and the bubble closing, so the pointer can travel
    /// from the icon into the bubble. inferred.
    var pointerLeaveGrace: Double = SiteControlsLocalTokens.pointerLeaveGrace

    private let sidebar: SidebarViewModel
    private var work: [Task<Void, Never>] = []
    /// Counts started refreshes; only the latest one writes `settings`.
    private var refreshGeneration = 0
    private var copiedTask: Task<Void, Never>?
    private var leaveTask: Task<Void, Never>?
    private var selectionChanges: AnyCancellable?
    private var sidebarChanges: AnyCancellable?
    private var openPopup: (any ExtensionPopup)?
    private var popupEvents: Task<Void, Never>?
    private var extensionEvents: Task<Void, Never>?
    private var shareSerial = 0

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

    /// The pill at the bottom left. [06 §12] observed "Secure"; [06 §17.3] observed "Insecure".
    public var securityLabel: String { site?.isSecure == false ? "Insecure" : "Secure" }

    /// "Manage" shows only when extensions exist. [06 §12] observed. Any installed extension
    /// counts, also one without an action on this page. inferred.
    public var showsManageExtensions: Bool { !settings.extensions.isEmpty || hasInstalledExtensions }

    /// The profile has extensions (C14), whether or not they have an action here.
    @Published public private(set) var hasInstalledExtensions = false
    /// Each listed extension's `chrome.contextMenus` items for its action (`contexts: ["action"]`)
    /// on the bubble's tab, by extension id (plan B124). Refreshed with the section.
    @Published public private(set) var extensionActionMenuItems: [String: [PageContextMenuItem]] = [:]

    /// Engine extensions (C14): installed list and change events for the bubble's section.
    var engineExtensions: (any EngineExtensions)?

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
        shareRequest = nil
        extensionEvents?.cancel()
        extensionEvents = nil
    }

    /// The pointer left the bubble (or the icon it opened from). [06 §12] observed: it closes.
    public func pointerExited() {
        // The share picker's menu hangs off the bubble: moving into it keeps the bubble open.
        guard isPresented, shareRequest == nil else { return }
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

    /// The capture buttons have a handler (the shell installs it, B51).
    public var canRunTools: Bool { toolHandler != nil }

    /// Share and New Boost are always enabled ([06 §12] observed New Boost clickable, opening
    /// nothing); the capture buttons need the shell's handler.
    public func canRun(_ tool: SiteControlsTool) -> Bool {
        switch tool {
        case .share, .newBoost: true
        case .captureArea, .captureFullPage: canRunTools
        }
    }

    public func run(_ tool: SiteControlsTool) {
        guard let id = tabID, canRun(tool) else { return }
        switch tool {
        case .share:
            beginShare(tabID: id)
        case .newBoost:
            // Inert: [06 §12] observed that New Boost opened no editor; Boosts are out of v1.
            break
        case .captureArea, .captureFullPage:
            close(.action)
            toolHandler?(tool, id)
        }
    }

    // MARK: Share

    /// Share: the system share picker for the page's link, below the Share button. [06 §12],
    /// [06 §17.3] observed button; the picker is the system's (plan B80).
    private func beginShare(tabID id: UUID) {
        guard let url = sidebar.linkURL(for: id) else { return }
        leaveTask?.cancel()
        leaveTask = nil
        shareSerial += 1
        shareRequest = SiteControlsShareRequest(serial: shareSerial, tabID: id, url: url)
    }

    /// The picker closed, with a service chosen or not: the bubble closes too. inferred.
    public func finishShare(serial: Int) {
        guard shareRequest?.serial == serial else { return }
        shareRequest = nil
        close(.action)
    }

    // MARK: "⋯" menu

    public func isEnabled(_ item: SiteControlsMenuItem) -> Bool {
        switch item {
        case .clearCache: tabID.flatMap { sidebar.liveTab(for: $0) } != nil
        case .clearCookies, .newBoost: site != nil
        case .manageBoosts: manageBoostsHandler != nil
        case .manageExtensions: manageExtensionsHandler != nil
        case .addExtension: addExtensionHandler != nil
        case .allSiteSettings: site.flatMap(SiteSettingsPages.details(for:)) != nil
        }
    }

    /// Runs one "⋯" item. [06 §19.1] observed items; what each does is inferred:
    /// - Clear Cache reloads the page bypassing the cache (the engine clears caches per profile
    ///   only); Clear Cookies clears the site's data through the provider (C12). Both keep the
    ///   bubble open.
    /// - New Boost… is inert, like the New Boost button (Boosts are out of v1).
    /// - The others open their page and close the bubble.
    public func perform(_ item: SiteControlsMenuItem) {
        guard isEnabled(item) else { return }
        switch item {
        case .clearCache:
            guard let id = tabID, let live = sidebar.liveTab(for: id) else { return }
            work.append(Task { try? await live.reload(bypassingCache: true) })
        case .clearCookies:
            apply(.clearSiteData)
        case .newBoost:
            break
        case .manageBoosts:
            close(.action)
            manageBoostsHandler?()
        case .manageExtensions:
            manageExtensionsHandler?()
        case .addExtension:
            addExtensionHandler?()
        case .allSiteSettings:
            guard let site, let url = SiteSettingsPages.details(for: site) else { return }
            close(.action)
            _ = sidebar.newTab(url: url, title: "Settings")
        }
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

    // MARK: Action context menu (B116)

    /// Items of an extension action's right-click menu, in order. The spec records no such menu
    /// (`06 §12` observed only the section's buttons); Chrome's toolbar action has one, and these
    /// are the items of it that need no browser window: Manage Extension (the extension's details
    /// page) and Remove. inferred.
    public func extensionMenuItems(for extensionID: String) -> [SiteExtensionMenuItem] {
        guard settings.extensions.contains(where: { $0.id == extensionID }) else { return [] }
        return [.manage, .remove]
    }

    /// The extension's own items for its action menu (`chrome.contextMenus` with
    /// `contexts: ["action"]`), shown before Manage / Remove, as Chrome's action menu lists them
    /// after the extension's name (inferred). Plan B124.
    public func extensionOwnMenuItems(for extensionID: String) -> [PageContextMenuItem] {
        guard settings.extensions.contains(where: { $0.id == extensionID }) else { return [] }
        return extensionActionMenuItems[extensionID] ?? []
    }

    /// Runs one of the extension's own action menu items on the bubble's tab: the extension's
    /// `contextMenus.onClicked` fires. The bubble closes (inferred, as for Manage).
    public func performExtensionOwnMenuItem(_ itemID: Int, extensionID: String) {
        guard let engineExtensions, let id = tabID, let engineTab = sidebar.liveTab(for: id)?.id else { return }
        close(.action)
        work.append(Task { await engineExtensions.performActionMenuItem(itemID, extensionID: extensionID, tabID: engineTab) })
    }

    public func isEnabled(_ item: SiteExtensionMenuItem, extensionID: String) -> Bool {
        switch item {
        case .manage: manageExtensionHandler != nil
        case .remove: confirmExtensionRemoval != nil && engineExtensions != nil && sidebar.currentProfileID != nil
        }
    }

    /// Runs one item of the action's right-click menu. Both close the bubble; Remove asks first
    /// and then uninstalls through the engine (the section updates from the engine's events).
    public func perform(_ item: SiteExtensionMenuItem, extensionID: String) {
        guard isEnabled(item, extensionID: extensionID),
              let action = settings.extensions.first(where: { $0.id == extensionID }) else { return }
        switch item {
        case .manage:
            close(.action)
            manageExtensionHandler?(extensionID)
        case .remove:
            guard let engineExtensions, let profile = sidebar.currentProfileID,
                  confirmExtensionRemoval?(action.name) == true else { return }
            close(.action)
            if openPopup?.extensionID == extensionID { closeExtensionPopup() }
            work.append(Task { await engineExtensions.uninstall(extensionID, profileID: profile) })
        }
    }

    // MARK: Extension popup

    /// An extension's `_execute_action` keyboard shortcut (plan C26) opened `popup` on the engine
    /// tab whose model tab is `tabID`: it shows in this window's popup bubble when that tab is
    /// selected here, as after a click on its action. [00 §A] inferred (analysis): extension
    /// keyboard commands work. Returns whether this window took it.
    @discardableResult
    func showPopupFromKeyboard(_ popup: any ExtensionPopup, tabID: UUID) -> Bool {
        guard sidebar.selectedTabID == tabID else { return false }
        closeExtensionPopup()
        close(.action)
        show(popup, tabID: tabID)
        return true
    }

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
        // Refreshes overlap (two quick toggles each refresh after their change); the one started
        // last read the newest state, so an earlier one that finishes later is dropped.
        refreshGeneration &+= 1
        let generation = refreshGeneration
        var state = await provider.settings(for: site, profileID: profileID)
        if let id = tabID, let actions = await provider.extensionActions(tabID: id, profileID: profileID) {
            state.extensions = actions
        }
        var installed: [EngineExtensionInfo] = []
        if let profileID, let engineExtensions { installed = await engineExtensions.installed(profileID: profileID) }
        var actionItems: [String: [PageContextMenuItem]] = [:]
        if let engineExtensions, let engineTab = tabID.flatMap({ sidebar.liveTab(for: $0) })?.id {
            for action in state.extensions {
                let items = await engineExtensions.actionMenuItems(extensionID: action.id, tabID: engineTab)
                if !items.isEmpty { actionItems[action.id] = items }
            }
        }
        guard self.site == site, generation == refreshGeneration else { return }
        settings = state
        hasInstalledExtensions = !installed.isEmpty
        extensionActionMenuItems = actionItems
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
