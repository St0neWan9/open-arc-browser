import Foundation
import OpenArcModel

/// "Archive tabs after" choices. [03 §Profiles] observed: a dropdown, default 12 hours. Only the
/// default was recorded; the other options are inferred. The value itself is stored in
/// `ProfileSettings.todayLifetime` (seconds); this enum is the picker's list.
public enum ArchiveLifetime: String, CaseIterable, Identifiable, Sendable {
    // Raw values were persisted in legacy per-device preferences (read once for migration);
    // never rename them.
    case twelveHours, twentyFourHours, sevenDays, thirtyDays

    public static let `default`: ArchiveLifetime = .twelveHours

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }

    public var interval: TimeInterval {
        let hour: TimeInterval = 60 * 60
        switch self {
        case .twelveHours: return ArchivePolicy.defaultTodayLifetime
        case .twentyFourHours: return 24 * hour
        case .sevenDays: return 7 * 24 * hour
        case .thirtyDays: return 30 * 24 * hour
        }
    }

    /// The choice closest to `interval`, for showing a stored value in the picker. A value no
    /// choice matches exactly (e.g. written by a newer build) shows as its nearest neighbour and
    /// is only replaced when the user picks something.
    public static func closest(to interval: TimeInterval) -> ArchiveLifetime {
        allCases.min { abs($0.interval - interval) < abs($1.interval - interval) } ?? .default
    }
}

/// App preferences, stored per device in `UserDefaults` (keys prefixed `openarc.`).
///
/// [03 §对复刻的含义] observed: settings come in three levels: account (synced), profile (search,
/// archive, downloads, privacy) and app (General / Links / Advanced). App-level settings stay on
/// this device. Profile-level settings live in `Profile.settings` and sync with the profile (A18);
/// the per-profile keys older builds wrote here are only read once, by
/// `WorkspaceController.migrateLegacyProfileSettings()`, and then removed.
///
/// Thread safety: `UserDefaults` is documented as thread-safe; the in-memory backend locks.
// @unchecked: `defaults` is a `let` to thread-safe `UserDefaults`; `memory` (holds non-Sendable `Any`) is only touched under `lock`.
public final class AppPreferences: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var memory: [String: Any] = [:]

    /// Preferences backed by `defaults`. Tests pass a `UserDefaults(suiteName:)`.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private init() {
        defaults = nil
    }

    /// The app's defaults domain, its bundle id (`org.openarc.browser`, or `org.openarc.browser.dev`
    /// for the development build). Inside the app bundle that is the standard domain; a bare
    /// SwiftPM executable has no bundle id, so it opens the release domain by name.
    public static var standard: AppPreferences {
        if Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier {
            return AppPreferences(defaults: .standard)
        }
        return AppPreferences(defaults: UserDefaults(suiteName: AppIdentity.bundleIdentifier) ?? .standard)
    }

    /// Preferences that live only in memory and never touch the disk (previews, `.fake()`).
    public static func inMemory() -> AppPreferences { AppPreferences() }

    // MARK: Keys (persisted; never rename)

    public static let keyPrefix = "openarc."

    static func profileKey(_ profileID: UUID, _ name: String) -> String {
        "\(keyPrefix)profile.\(profileID.uuidString).\(name)"
    }

    static let syncSidebarKey = "\(keyPrefix)account.syncSidebar"
    static let syncFullUploadKey = "\(keyPrefix)sync.needsFullUpload"

    // MARK: Legacy profile-scoped settings (B12, per device; migration only)

    static func legacySearchEngineKey(_ profileID: UUID) -> String { profileKey(profileID, "searchEngine") }
    static func legacyArchiveLifetimeKey(_ profileID: UUID) -> String { profileKey(profileID, "archiveTabsAfter") }

    /// Values an older build stored on this device for a profile; nil fields were never set (or
    /// hold an unknown raw value).
    public func legacyProfileSettings(for profileID: UUID) -> (searchEngine: SearchEngine?, archiveLifetime: ArchiveLifetime?) {
        let engine = (value(Self.legacySearchEngineKey(profileID)) as? String).flatMap(SearchEngine.init(rawValue:))
        let lifetime = (value(Self.legacyArchiveLifetimeKey(profileID)) as? String).flatMap(ArchiveLifetime.init(rawValue:))
        return (engine, lifetime)
    }

    /// Whether any legacy key exists for the profile (valid or not).
    public func hasLegacyProfileSettings(for profileID: UUID) -> Bool {
        value(Self.legacySearchEngineKey(profileID)) != nil || value(Self.legacyArchiveLifetimeKey(profileID)) != nil
    }

    /// Writes legacy values the way older builds did. Used by migration tests.
    func setLegacyProfileSettings(searchEngine: SearchEngine?, archiveLifetime: ArchiveLifetime?, for profileID: UUID) {
        if let searchEngine { setValue(searchEngine.rawValue, Self.legacySearchEngineKey(profileID)) }
        if let archiveLifetime { setValue(archiveLifetime.rawValue, Self.legacyArchiveLifetimeKey(profileID)) }
    }

    /// Deletes the legacy keys of a profile, so migration runs only once.
    public func removeLegacyProfileSettings(for profileID: UUID) {
        removeValue(Self.legacySearchEngineKey(profileID))
        removeValue(Self.legacyArchiveLifetimeKey(profileID))
    }

    // MARK: Account-level settings

    /// "Sync Sidebar" (account card). [03 §账号卡] observed toggle; on by default (inferred).
    /// Read at launch by `SidebarSyncController.launch()` before the sync store is started.
    public var isSidebarSyncEnabled: Bool {
        get { value(Self.syncSidebarKey) as? Bool ?? true }
        set { setValue(newValue, Self.syncSidebarKey) }
    }

    /// True while local changes may exist that no running sync store was told about (sync never
    /// ran on this device, or it was off or failed to start). The next successful start announces
    /// every record and clears it. Per device; true until the first upload.
    public var needsFullSyncUpload: Bool {
        get { value(Self.syncFullUploadKey) as? Bool ?? true }
        set { setValue(newValue, Self.syncFullUploadKey) }
    }

    // MARK: App-level settings: Links

    static let littleArcExternalKey = "\(keyPrefix)links.littleArcExternal"

    /// "Open links from other apps in Little Arc". [03 §Links] observed toggle; the spec records
    /// no default, so off (inferred; keeps the D2 behavior until the user opts in). Per device.
    public var opensExternalLinksInLittleArc: Bool {
        get { boolValue(Self.littleArcExternalKey) ?? false }
        set { setBool(newValue, Self.littleArcExternalKey) }
    }

    // MARK: App-level settings: Advanced

    static let pictureInPictureKey = "\(keyPrefix)advanced.pictureInPicture"

    /// "Enable Picture in Picture when you leave a video tab". [03 §Advanced] observed toggle, on
    /// by default. Per device. Read by `AutoPictureInPicture` (plan C15).
    public var entersPictureInPictureOnLeavingVideoTab: Bool {
        get { boolValue(Self.pictureInPictureKey) ?? true }
        set { setBool(newValue, Self.pictureInPictureKey) }
    }

    // MARK: App-level settings: Developer

    static let javaScriptFromAppleEventsKey = "\(keyPrefix)developer.allowJavaScriptFromAppleEvents"

    /// View ▸ Developer ▸ Allow JavaScript from Apple Events. [01 §View] observed menu item; off
    /// by default ([06 §29.4] inferred). Per device. Gates AppleScript's `execute` (running
    /// JavaScript in a page from an Apple Event, B70).
    public var allowsJavaScriptFromAppleEvents: Bool {
        get { boolValue(Self.javaScriptFromAppleEventsKey) ?? false }
        set { setBool(newValue, Self.javaScriptFromAppleEventsKey) }
    }

    // MARK: Sidebar

    static let favoritesEmptyCardDismissedKey = "\(keyPrefix)sidebar.favoritesEmptyCardDismissed"

    /// The favorites empty-state card was dismissed with its ✕. [06 §21.2] observed button; that
    /// it stays dismissed, per device, is inferred (B55).
    public var isFavoritesEmptyCardDismissed: Bool {
        get { boolValue(Self.favoritesEmptyCardDismissedKey) ?? false }
        set { setBool(newValue, Self.favoritesEmptyCardDismissedKey) }
    }

    // MARK: Storage

    func boolValue(_ key: String) -> Bool? { value(key) as? Bool }

    func setBool(_ newValue: Bool, _ key: String) { setValue(newValue, key) }

    func stringValue(_ key: String) -> String? { value(key) as? String }

    func setString(_ newValue: String, _ key: String) { setValue(newValue, key) }

    private func value(_ key: String) -> Any? {
        if let defaults { return defaults.object(forKey: key) }
        return lock.withLock { memory[key] }
    }

    private func removeValue(_ key: String) {
        if let defaults {
            defaults.removeObject(forKey: key)
        } else {
            _ = lock.withLock { memory.removeValue(forKey: key) }
        }
    }

    private func setValue(_ newValue: Any, _ key: String) {
        if let defaults {
            defaults.set(newValue, forKey: key)
        } else {
            lock.withLock { memory[key] = newValue }
        }
    }
}
