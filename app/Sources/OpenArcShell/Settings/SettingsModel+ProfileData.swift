import Foundation
import AppKit
import OpenArcModel
import OpenArcEngine

// Settings ▸ Profiles data rows (plan B83). [03 §Profiles] observed: per Profile, "Manage search"
// (Search Settings…), "Download location" (dropdown, default Downloads) and "Your Data and
// Settings": Privacy and Security · Passwords · Credit Cards · Notifications · Autofill · Clear
// Browsing Data, each a row with an arrow; "Learn more" next to the pane's description. [03
// §Advanced] observed: "More Settings…" (the engine's settings pages).
//
// Where each row leads is not recorded (inferred):
// - the engine's own settings pages (Chromium's chrome://settings and chrome://password-manager),
//   opened in a new tab of a Space that uses the edited Profile, so they show that Profile's data;
// - Clear Browsing Data: our own sheet (time range + kinds) that calls
//   `BrowserEngine.clearBrowsingData`;
// - Download location: the engine keeps the folder per Profile (`EngineDownloads`), per device.

/// A settings page of the engine that a Profiles row (or Advanced ▸ More Settings…) opens.
/// Chromium 156 paths. inferred (the spec does not record what Arc opens).
public enum ProfileEnginePage: String, CaseIterable, Identifiable, Sendable {
    case privacy, passwords, creditCards, notifications, autofill, searchSettings, allSettings

    public var id: String { rawValue }

    public var url: URL {
        switch self {
        case .privacy: return URL(string: "chrome://settings/privacy")!
        case .passwords: return URL(string: "chrome://password-manager/passwords")!
        case .creditCards: return URL(string: "chrome://settings/payments")!
        case .notifications: return URL(string: "chrome://settings/content/notifications")!
        case .autofill: return URL(string: "chrome://settings/addresses")!
        case .searchSettings: return URL(string: "chrome://settings/searchEngines")!
        case .allSettings: return URL(string: "chrome://settings/")!
        }
    }

    /// The settings control that opens the page.
    public var controlID: String {
        switch self {
        case .privacy: return "profiles.privacy"
        case .passwords: return "profiles.passwords"
        case .creditCards: return "profiles.creditCards"
        case .notifications: return "profiles.notifications"
        case .autofill: return "profiles.autofill"
        case .searchSettings: return "profiles.searchSettings"
        case .allSettings: return "advanced.moreSettings"
        }
    }

    /// Title of the new tab until the page reports its own.
    public var tabTitle: String {
        switch self {
        case .searchSettings: return "Search Engines"
        case .allSettings: return "Settings"
        default: return SettingsCatalog.control(controlID).label
        }
    }
}

/// Our help pages. inferred: Arc's "Learn more" opens its help center; ours points at the project
/// site (the same placeholder host as the update feed, `UpdateChecker.placeholderFeedURL`) until
/// it has real help pages.
public enum ProfileHelpLinks {
    public static let profiles = URL(string: "https://openarc.github.io/help/profiles")!
}

/// "Clear Browsing Data" time range. inferred (the spec records the row only): Chromium's ranges.
public enum ClearBrowsingDataRange: String, CaseIterable, Identifiable, Sendable {
    case lastHour, last24Hours, last7Days, last4Weeks, allTime

    /// Chromium's default. inferred.
    public static let `default`: ClearBrowsingDataRange = .lastHour

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lastHour: return "Last hour"
        case .last24Hours: return "Last 24 hours"
        case .last7Days: return "Last 7 days"
        case .last4Weeks: return "Last 4 weeks"
        case .allTime: return "All time"
        }
    }

    /// Start of the range; nil means all time.
    public func since(now: Date) -> Date? {
        let hour: TimeInterval = 60 * 60
        switch self {
        case .lastHour: return now.addingTimeInterval(-hour)
        case .last24Hours: return now.addingTimeInterval(-24 * hour)
        case .last7Days: return now.addingTimeInterval(-7 * 24 * hour)
        case .last4Weeks: return now.addingTimeInterval(-28 * 24 * hour)
        case .allTime: return nil
        }
    }
}

/// One checkbox of the "Clear Browsing Data" sheet. inferred: Chromium's kinds and labels.
public enum ClearBrowsingDataKind: String, CaseIterable, Identifiable, Sendable {
    case history, downloads, cookies, cache, passwords, autofill, siteSettings

    /// Checked when the sheet opens: Chromium's basic set. inferred.
    public static let defaultSelection: Set<ClearBrowsingDataKind> = [.history, .cookies, .cache]

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .history: return "Browsing history"
        case .downloads: return "Download history"
        case .cookies: return "Cookies and other site data"
        case .cache: return "Cached images and files"
        case .passwords: return "Passwords and other sign-in data"
        case .autofill: return "Autofill form data"
        case .siteSettings: return "Site settings"
        }
    }

    /// What the engine removes for this kind.
    public var types: BrowsingDataTypes {
        switch self {
        case .history: return .history
        case .downloads: return .downloads
        case .cookies: return [.cookies, .siteStorage]
        case .cache: return .cache
        case .passwords: return .passwords
        case .autofill: return .autofill
        case .siteSettings: return .siteSettings
        }
    }

    public static func types(of kinds: Set<ClearBrowsingDataKind>) -> BrowsingDataTypes {
        kinds.reduce(into: BrowsingDataTypes()) { $0.formUnion($1.types) }
    }
}

/// One entry of the "Download location" dropdown.
public enum DownloadLocationChoice: Hashable, Sendable {
    case folder(URL)
    /// "Other…": pick a folder in an open panel.
    case other
}

extension SettingsModel {
    // MARK: Engine pages

    /// The Space a page for `profileID` opens in: the active window's Space when it uses the
    /// profile, else the profile's first Space in the dock. nil: no Space uses it. inferred.
    func space(forProfile profileID: UUID) -> UUID? {
        let controller = shell.controller
        let workspace = controller.workspace
        if let active = controller.activeWindow?.selectedSpaceID,
           workspace.spaces[active]?.profileID == profileID,
           workspace.spaces[active]?.meta.isTombstone == false {
            return active
        }
        return workspace.spaces(inProfile: profileID).first?.id
    }

    /// Whether the edited profile's engine pages can open: a Space must use the profile, since a
    /// tab gets its profile from its Space.
    public var canOpenEditedProfilePages: Bool {
        editedProfileID.flatMap { space(forProfile: $0) } != nil
    }

    /// Opens `url` as a new Today tab at the top of `spaceID` and shows it in the browser window
    /// used last (a new window opens when none is), which comes to the front. Returns the tab id.
    @discardableResult
    func openInTab(_ url: URL, title: String, spaceID: UUID) -> UUID? {
        let controller = shell.controller
        let id = controller.makeID()
        let now = controller.now()
        do {
            try controller.mutate(origin: nil) { try TreeOps.openTab($0, id: id, spaceID: spaceID, url: url, title: title, now: now) }
        } catch {
            return nil
        }
        controller.revealInBrowserWindow(id, spaceID: spaceID)
        return id
    }

    /// A Profiles row: the engine's page for the edited profile, in a tab of one of its Spaces.
    /// Returns the new tab id, or nil when no Space uses the profile.
    @discardableResult
    public func openEnginePage(_ page: ProfileEnginePage) -> UUID? {
        guard let profileID = editedProfileID, let spaceID = space(forProfile: profileID) else { return nil }
        return openInTab(page.url, title: page.tabTitle, spaceID: spaceID)
    }

    /// Advanced ▸ More Settings…: the engine's settings for the profile of the window used last
    /// ([03 §Advanced] observed button; "the engine's settings page", inferred target).
    @discardableResult
    public func openMoreSettings() -> UUID? {
        guard let profileID = shell.controller.currentProfileID, let spaceID = space(forProfile: profileID) else { return nil }
        return openInTab(ProfileEnginePage.allSettings.url, title: ProfileEnginePage.allSettings.tabTitle, spaceID: spaceID)
    }

    /// "Learn more" next to the Profiles description: our help page in a tab of the window used
    /// last. inferred.
    @discardableResult
    public func openProfilesHelp() -> UUID? {
        let controller = shell.controller
        guard let spaceID = controller.activeWindow?.selectedSpaceID ?? controller.workspace.allLiveSpaces.first?.id else { return nil }
        return openInTab(ProfileHelpLinks.profiles, title: "Profiles", spaceID: spaceID)
    }

    // MARK: Download location

    /// The user's Downloads folder: the default location. [03 §Profiles] observed "default Downloads".
    public static var userDownloadsFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Downloads", isDirectory: true)
    }

    /// The folder the dropdown shows for the edited profile.
    public var downloadDirectory: URL {
        editedProfileID.flatMap { loadedDownloadDirectories[$0] } ?? Self.userDownloadsFolder
    }

    /// Reads the edited profile's download folder from the engine. The view runs it whenever the
    /// edited profile changes.
    public func loadDownloadDirectory() async {
        guard let profileID = editedProfileID else { return }
        let folder = await shell.controller.dependencies.engine.downloads.defaultDirectory(profileID: profileID)
        loadedDownloadDirectories[profileID] = folder
    }

    /// Sets the edited profile's download folder in the engine.
    public func setDownloadDirectory(_ url: URL) async {
        guard let profileID = editedProfileID, url.isFileURL else { return }
        loadedDownloadDirectories[profileID] = url
        await shell.controller.dependencies.engine.downloads.setDefaultDirectory(url, profileID: profileID)
    }

    /// The dropdown: the current folder, Downloads when that is not the current one, then
    /// "Other…". inferred (only the default, Downloads, is recorded).
    public var downloadLocationChoices: [DownloadLocationChoice] {
        let current = downloadDirectory.standardizedFileURL
        let downloads = Self.userDownloadsFolder.standardizedFileURL
        var choices: [DownloadLocationChoice] = [.folder(current)]
        if current.path != downloads.path { choices.append(.folder(downloads)) }
        choices.append(.other)
        return choices
    }

    /// Name shown for a folder in the dropdown (Finder's display name).
    public static func displayName(of folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path)
    }

    /// A dropdown choice: a folder is used right away; "Other…" asks for a folder first.
    public func chooseDownloadLocation(_ choice: DownloadLocationChoice) async {
        switch choice {
        case .folder(let url):
            await setDownloadDirectory(url)
        case .other:
            guard let picked = pickFolder(downloadDirectory) else { return }
            await setDownloadDirectory(picked)
        }
    }

    // MARK: Clear Browsing Data

    /// Opens the "Clear Browsing Data" sheet for the edited profile.
    public func requestClearBrowsingData() {
        guard let profileID = editedProfileID else { return }
        profileClearingData = profileID
    }

    public func cancelClearBrowsingData() { profileClearingData = nil }

    /// Name of the profile the sheet clears.
    public var profileClearingDataName: String? {
        profileClearingData.flatMap { shell.workspace.profiles[$0]?.name }
    }

    /// "Clear data" in the sheet: removes the chosen kinds written in `range` from the profile's
    /// engine data, then closes the sheet. Returns false when nothing was asked for.
    @discardableResult
    public func confirmClearBrowsingData(range: ClearBrowsingDataRange, kinds: Set<ClearBrowsingDataKind>) async -> Bool {
        guard let profileID = profileClearingData, !kinds.isEmpty else { return false }
        isClearingBrowsingData = true
        let since = range.since(now: shell.controller.now())
        await shell.controller.dependencies.engine.clearBrowsingData(profileID, types: ClearBrowsingDataKind.types(of: kinds), since: since)
        isClearingBrowsingData = false
        if profileClearingData == profileID { profileClearingData = nil }
        return true
    }

    /// Default folder picker: an open panel that chooses one folder.
    static func runFolderPanel(_ start: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = start
        panel.prompt = "Select"
        return panel.runModal() == .OK ? panel.url : nil
    }
}
