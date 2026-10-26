import Foundation
import OpenArcModel

// Downloads and extensions skeletons (chromium-bridge/SWIFT_PROTOCOL_CHANGES.md §8, §9; bridge:
// OACDownloads.h, OACExtensions.h). Shapes only: the Library's Downloads section ([06 §8]
// observed: "Search Downloads…", "Filter", empty state "Nothing here yet!") and the Site Control
// Center's extension rows (C14) will read them. Fake implementations live in FakeServices.swift.

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

    public init(
        id: String, profileID: Profile.ID, sourceURL: URL, referrerURL: URL? = nil, fileURL: URL? = nil,
        suggestedFilename: String, mimeType: String? = nil, state: DownloadState = .inProgress,
        receivedBytes: Int64 = 0, totalBytes: Int64 = -1, startDate: Date, endDate: Date? = nil,
        isOffTheRecord: Bool = false
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
    /// Where files go. [03] observed "Download location" (default Downloads).
    func setDefaultDirectory(_ url: URL) async
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
    /// Action icon at 32 px, PNG.
    public var iconPNGData: Data?
    public var badgeText: String
    public var actionTitle: String
    /// The action is enabled on that tab.
    public var isActionEnabled: Bool
    /// Clicking the action opens a popup (else it sends a click to the extension).
    public var hasPopup: Bool

    public init(
        id: String, name: String, version: String = "1.0", isEnabled: Bool = true, isAllowedInIncognito: Bool = false,
        iconPNGData: Data? = nil, badgeText: String = "", actionTitle: String = "", isActionEnabled: Bool = true,
        hasPopup: Bool = false
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.isAllowedInIncognito = isAllowedInIncognito
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
}

/// A profile's extensions (`OACExtensions`). Popup hosting and install confirmation are settled
/// in C14.
public protocol EngineExtensions: AnyObject, Sendable {
    func installed(profileID: Profile.ID) async -> [EngineExtensionInfo]
    /// Extensions with an action on the tab, with that tab's icon, badge and enabled state.
    func actions(for tabID: EngineTabID) async -> [EngineExtensionInfo]
    func runAction(_ extensionID: String, on tabID: EngineTabID) async
    func install(webStoreID: String, profileID: Profile.ID) async throws
    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async
    func uninstall(_ extensionID: String, profileID: Profile.ID) async
    /// Changes for one profile. Every call returns a new stream.
    func events(profileID: Profile.ID) -> AsyncStream<ExtensionEvent>
}
