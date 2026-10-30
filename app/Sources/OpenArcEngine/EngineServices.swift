import Foundation
import OpenArcModel

// Downloads (plan C12) and the extensions skeleton (chromium-bridge/SWIFT_PROTOCOL_CHANGES.md §8,
// §9; bridge: OACDownloads.h, OACExtensions.h). The Library's Downloads section ([06 §8] observed:
// "Search Downloads…", "Filter", empty state "Nothing here yet!") lists the downloads; the Site
// Control Center's extension rows read the extensions (C14). Fake implementations live in
// FakeServices.swift.

// MARK: - Downloads

public enum DownloadState: String, Hashable, Sendable {
    case inProgress, paused, complete, cancelled, interrupted
    /// Waiting for the user to keep or discard a file the engine flagged as dangerous.
    case needsConfirmation
}

/// Snapshot of one download (`OACDownloadItem`).
public struct DownloadItem: Identifiable, Hashable, Sendable {
    /// Stable across launches.
    public var id: String
    public var profileID: Profile.ID
    public var sourceURL: URL
    public var referrerURL: URL?
    /// Final file location; nil until decided.
    public var fileURL: URL?
    public var suggestedFilename: String
    public var mimeType: String?
    public var state: DownloadState
    public var receivedBytes: Int64
    /// -1 when unknown.
    public var totalBytes: Int64
    public var startDate: Date
    public var endDate: Date?
    public var isOffTheRecord: Bool
    /// For `.needsConfirmation`: why, in the engine's words. nil otherwise.
    public var warningText: String?

    public init(
        id: String, profileID: Profile.ID, sourceURL: URL, referrerURL: URL? = nil, fileURL: URL? = nil,
        suggestedFilename: String, mimeType: String? = nil, state: DownloadState = .inProgress,
        receivedBytes: Int64 = 0, totalBytes: Int64 = -1, startDate: Date, endDate: Date? = nil,
        isOffTheRecord: Bool = false, warningText: String? = nil
    ) {
        self.id = id
        self.profileID = profileID
        self.sourceURL = sourceURL
        self.referrerURL = referrerURL
        self.fileURL = fileURL
        self.suggestedFilename = suggestedFilename
        self.mimeType = mimeType
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
        self.startDate = startDate
        self.endDate = endDate
        self.isOffTheRecord = isOffTheRecord
        self.warningText = warningText
    }
}

public enum DownloadEvent: Hashable, Sendable {
    case added(DownloadItem)
    /// Progress is coalesced to a few updates per second.
    case updated(DownloadItem)
    case removed(id: String)
}

/// A profile's downloads (`OACDownloads`).
public protocol EngineDownloads: AnyObject, Sendable {
    /// Every download of the profile, newest first.
    func items(profileID: Profile.ID) async -> [DownloadItem]
    /// Changes for one profile. Every call returns a new stream.
    func events(profileID: Profile.ID) -> AsyncStream<DownloadEvent>
    func pause(_ id: String) async
    func resume(_ id: String) async
    func cancel(_ id: String) async
    /// For `.needsConfirmation`: keep (true) or discard (false) the file.
    func confirm(_ id: String, keep: Bool) async
    /// Removes the entry from the list (the file stays on disk).
    func remove(_ id: String) async
    /// Starts a download without navigating (Download Linked File).
    func download(_ url: URL, profileID: Profile.ID) async
    /// Where the profile's files go. [03 §Profiles] observed "Download location" (a per-Profile
    /// dropdown, default Downloads). The engine keeps the choice (Chromium: the profile's
    /// `download.default_directory` pref), so it is per device and survives restarts (plan B83).
    func setDefaultDirectory(_ url: URL, profileID: Profile.ID) async
    /// The profile's download folder; nil when the engine cannot say (then the user's Downloads
    /// folder applies).
    func defaultDirectory(profileID: Profile.ID) async -> URL?
}

// MARK: - Extensions

/// One installed extension, with its action state for a tab when read for one (`OACExtensionInfo`).
public struct EngineExtensionInfo: Identifiable, Hashable, Sendable {
    /// The 32-character extension id.
    public var id: String
    public var name: String
    public var version: String
    public var isEnabled: Bool
    public var isAllowedInIncognito: Bool
    /// Loaded from a folder (developer mode), not installed from the Web Store.
    public var isUnpacked: Bool
    /// Action icon at 16 pt in 2x pixels (32 px), PNG; nil while loading.
    public var iconPNGData: Data?
    public var badgeText: String
    public var actionTitle: String
    /// The action is enabled on that tab.
    public var isActionEnabled: Bool
    /// Clicking the action opens a popup (else it sends a click to the extension).
    public var hasPopup: Bool
    /// Runtime and manifest errors the engine collected for the extension (plan C26; listed in
    /// Manage Extensions). [00 §A] inferred (analysis): extension runtime errors are surfaced.
    /// 0 while the engine collects none (Chromium: developer mode off).
    public var errorCount: Int

    public init(
        id: String, name: String, version: String = "1.0", isEnabled: Bool = true, isAllowedInIncognito: Bool = false,
        isUnpacked: Bool = false, iconPNGData: Data? = nil, badgeText: String = "", actionTitle: String = "",
        isActionEnabled: Bool = true, hasPopup: Bool = false, errorCount: Int = 0
    ) {
        self.errorCount = errorCount
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isAllowedInIncognito = isAllowedInIncognito
        self.isUnpacked = isUnpacked
        self.iconPNGData = iconPNGData
        self.badgeText = badgeText
        self.actionTitle = actionTitle
        self.isActionEnabled = isActionEnabled
        self.hasPopup = hasPopup
    }
}

public enum ExtensionEvent: Hashable, Sendable {
    /// The installed set or an extension's state changed.
    case changed
    /// An action's icon, badge or enabled state changed for a tab (nil: every tab).
    case actionUpdated(extensionID: String, tabID: EngineTabID?)
    /// An extension's error count changed (plan C26, `EngineExtensionInfo.errorCount`).
    case errorsChanged(extensionID: String)
}

/// An extension's `_execute_action` keyboard shortcut (manifest `commands`) opened its popup on a
/// tab (plan C26). [00 §A] inferred (analysis): extension keyboard commands work. The shell shows
/// it as after `EngineExtensions.runAction`. Named commands need no shell part: the engine sends
/// them to the extension while one of the profile's tabs has the keyboard.
public struct ExtensionPopupOpenedFromKeyboard: Sendable {
    public let popup: any ExtensionPopup
    public init(popup: any ExtensionPopup) { self.popup = popup }
}

/// What an extension popup reports (`OACExtensionPopupDelegate`).
public enum ExtensionPopupEvent: Hashable, Sendable {
    /// The page finished its first load: show the popup now (never half loaded).
    case loaded
    /// The page laid out at this size, in points (within 25×25…800×600).
    case resized(width: Double, height: Double)
    /// Closed (by `close()`, by the page, or because the extension or its tab went away). Last
    /// element: the stream finishes after it.
    case closed
}

/// An extension action's popup page (`OACExtensionPopup`). The shell draws the bubble; the page is a
/// native view handed to a `SurfaceHost`, like a tab's. One per engine at a time: running another
/// action closes the open popup.
public protocol ExtensionPopup: AnyObject, Sendable {
    var extensionID: String { get }
    /// The tab the action ran on.
    var tabID: EngineTabID { get }
    /// Every call returns a new stream; it starts with `.loaded` / `.resized` for what already
    /// happened and finishes after `.closed`.
    func events() -> AsyncStream<ExtensionPopupEvent>
    /// The page's view goes into `host` (replacing what it showed).
    @MainActor func attach(to host: any SurfaceHost)
    /// Gives the page the keyboard (after its bubble became key).
    @MainActor func focus()
    func close() async
}

/// A profile's extensions (`OACExtensions`, plan C14). Off-the-record tabs use their profile's
/// extensions (only those allowed in incognito have actions there). Install confirmations reach the
/// shell as `EngineDialogRequest.extensionInstall` on the tab that asked (the Web Store page).
public protocol EngineExtensions: AnyObject, Sendable {
    /// Extensions the user manages (no built-in component extensions), enabled or not.
    func installed(profileID: Profile.ID) async -> [EngineExtensionInfo]
    /// Enabled extensions with a toolbar action on the tab, with that tab's icon, badge and state.
    func actions(for tabID: EngineTabID) async -> [EngineExtensionInfo]
    /// Runs an action as a click on Chrome's toolbar button does (grants activeTab, then opens the
    /// popup or sends the click). Returns the popup, not shown yet (wait for `.loaded`), or nil.
    @discardableResult
    func runAction(_ extensionID: String, on tabID: EngineTabID) async -> (any ExtensionPopup)?
    /// Installs from the Chrome Web Store by id; the engine asks for confirmation first on a tab of
    /// the profile (`.extensionInstall`). Throws when declined or failed.
    func install(webStoreID: String, profileID: Profile.ID) async throws
    /// Loads an unpacked extension from a folder (developer mode). Returns its id.
    func loadUnpacked(_ folder: URL, profileID: Profile.ID) async throws -> String
    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async
    func uninstall(_ extensionID: String, profileID: Profile.ID) async
    /// Changes for one profile. Every call returns a new stream.
    func events(profileID: Profile.ID) -> AsyncStream<ExtensionEvent>
    /// Popups the extensions' `_execute_action` shortcuts opened, in every profile (plan C26).
    /// Every call returns a new stream; a popup nobody shows is closed by the engine.
    func popupsOpenedFromKeyboard() -> AsyncStream<ExtensionPopupOpenedFromKeyboard>
    /// The `chrome.contextMenus` items `extensionID` added for its toolbar action
    /// (`contexts: ["action"]`) while `tabID` shows, in the extension's order (plan B124, for the
    /// action's right-click menu of B116). Default: none (PageContextMenu.swift).
    func actionMenuItems(extensionID: String, tabID: EngineTabID) async -> [PageContextMenuItem]
    /// Runs one of those items: the extension's `contextMenus.onClicked` fires with the tab.
    func performActionMenuItem(_ itemID: Int, extensionID: String, tabID: EngineTabID) async
}

extension EngineExtensions {
    /// Engines without keyboard commands open no popups that way.
    public func popupsOpenedFromKeyboard() -> AsyncStream<ExtensionPopupOpenedFromKeyboard> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Ad blocking (plan C16)

/// The engine's built-in ad blocker (bridge: `OACApplication.adBlockingEnabled`,
/// `-[OACSiteSettings setAdBlockingEnabled:forOrigin:]`, `OACTab.blockedAdCount`).
///
/// Chromium's own subresource filter with EasyList + EasyPrivacy (chromium-bridge/README.md §Ad
/// blocking). A global switch for the whole app plus a per-site allow list per profile;
/// off-the-record contexts inherit their profile's list. Changes apply to each tab's next page
/// load. The spec records the feature (a settings switch) but not its surfaces: everything here is
/// inferred ([00 §A 内核继承] "广告拦截": settings toggle known, blocking UI not captured).
public protocol EngineAdBlocking: AnyObject, Sendable {
    /// Version of the filter ruleset in use; nil when the engine has none (the blocker then
    /// matches nothing and the shell hides its controls).
    func rulesetVersion() async -> String?
    /// Each new ruleset version the engine switched to while running (plan C19: a verified update
    /// from our static host, applied without a restart). Does not repeat the current version; read
    /// `rulesetVersion()` first. Engines without updates return a stream that ends at once.
    func rulesetVersionChanges() -> AsyncStream<String>
    /// The global switch (Settings). Default on.
    func isEnabled() async -> Bool
    func setEnabled(_ enabled: Bool) async
    /// False when the site is on the profile's allow list. Independent of the global switch.
    func isEnabled(forOrigin origin: SiteOrigin, profileID: Profile.ID) async -> Bool
    /// False puts the site on the profile's allow list; true removes it.
    func setEnabled(_ enabled: Bool, forOrigin origin: SiteOrigin, profileID: Profile.ID) async
    /// Loads the blocker kept from loading on the tab's current page (0 after each new page, and
    /// for unknown tabs).
    func blockedCount(tabID: EngineTabID) async -> Int
}

public extension EngineAdBlocking {
    /// No live updates: a stream that ends at once.
    func rulesetVersionChanges() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
}

/// An engine without an ad blocker: no ruleset, switches do nothing. The default for engines that
/// do not provide one (test doubles).
public final class UnavailableAdBlocking: EngineAdBlocking {
    public static let shared = UnavailableAdBlocking()
    public init() {}
    public func rulesetVersion() async -> String? { nil }
    public func isEnabled() async -> Bool { false }
    public func setEnabled(_ enabled: Bool) async {}
    public func isEnabled(forOrigin origin: SiteOrigin, profileID: Profile.ID) async -> Bool { true }
    public func setEnabled(_ enabled: Bool, forOrigin origin: SiteOrigin, profileID: Profile.ID) async {}
    public func blockedCount(tabID: EngineTabID) async -> Int { 0 }
}
