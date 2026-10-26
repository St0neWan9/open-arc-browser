import Foundation
import AppKit
import OpenArcModel
import OpenArcSyncAPI
import OpenArcPersistence

/// What the iCloud sync card shows. It replaces Arc's account card: [03 §账号卡] observed a
/// "Sync Sidebar" toggle and a "Last synced: <time>" line; Arc's account, membership card and
/// referral items are out of scope (plan B12) and have no counterpart here. The wording of every
/// state other than "Last synced: <time>" is ours (inferred, D5).
public struct SyncCardState: Hashable, Sendable {
    /// A button the card offers next to the status line.
    public enum Action: Hashable, Sendable {
        /// "Sync Now": retry after a failure (`SidebarSyncController.syncNow`).
        case syncNow
        /// After an iCloud account switch: sync this Mac's sidebar with the new account
        /// (`SidebarSyncController.resumeAfterAccountChange`).
        case useNewAccount

        public var title: String {
            switch self {
            case .syncNow: return "Sync Now"
            case .useNewAccount: return "Sync with This Account"
            }
        }
    }

    /// Whether the "Sync Sidebar" toggle can be used.
    public var isToggleEnabled: Bool
    /// The status line under the toggle.
    public var statusLine: String
    /// True when the card shows a problem (drawn in a warning color).
    public var isWarning: Bool
    /// The button shown with the status line, if any.
    public var action: Action?

    public init(isToggleEnabled: Bool, statusLine: String, isWarning: Bool, action: Action? = nil) {
        self.isToggleEnabled = isToggleEnabled
        self.statusLine = statusLine
        self.isWarning = isWarning
        self.action = action
    }

    /// - Parameters:
    ///   - backendAvailable: false when the app runs with `DisabledSyncStore` (no sync backend).
    ///   - isSyncOn: the "Sync Sidebar" preference.
    ///   - actionError: why the last start or "Sync Now" threw, if it did.
    ///   - formatDate: formats `lastSyncedAt`; the app passes a relative format with its clock.
    public static func make(
        status: SyncStatus,
        backendAvailable: Bool,
        isSyncOn: Bool = true,
        actionError: String? = nil,
        formatDate: (Date) -> String = SyncCardState.defaultDateFormat
    ) -> SyncCardState {
        guard backendAvailable else {
            return SyncCardState(isToggleEnabled: false, statusLine: "iCloud sync is not available in this version.", isWarning: false)
        }
        guard isSyncOn else {
            return SyncCardState(isToggleEnabled: true, statusLine: "Sync is off.", isWarning: false)
        }
        let lastSynced = status.lastSyncedAt.map { "Last synced: \(formatDate($0))" } ?? "Not synced yet"
        switch status.phase {
        case .unavailable(let reason):
            switch reason {
            case .noAccount:
                return warning("Sign in to iCloud in System Settings to sync your sidebar.")
            case .restricted:
                return SyncCardState(isToggleEnabled: false, statusLine: "iCloud is restricted on this Mac.", isWarning: true)
            case .accountChanged:
                return warning("The iCloud account changed. Sync is paused.", action: .useNewAccount)
            case .temporarilyUnavailable:
                return warning("iCloud is temporarily unavailable. \(lastSynced)")
            case .notConfigured:
                return warning("This build of \(AppIdentity.displayName) is not set up for iCloud.")
            }
        case .failed(let message):
            return warning("Sync failed: \(message). \(lastSynced)", action: .syncNow)
        case _ where actionError != nil:
            // The store threw (start or "Sync Now") without reporting a status of its own.
            return warning("Sync failed: \(actionError ?? ""). \(lastSynced)", action: .syncNow)
        case .disabled:
            // On, but the store has not reported since it was asked to start.
            return SyncCardState(isToggleEnabled: true, statusLine: "Starting sync…", isWarning: false)
        case .idle:
            return SyncCardState(isToggleEnabled: true, statusLine: lastSynced, isWarning: false)
        case .syncing:
            return SyncCardState(isToggleEnabled: true, statusLine: "Syncing…", isWarning: false)
        }
    }

    private static func warning(_ line: String, action: Action? = nil) -> SyncCardState {
        SyncCardState(isToggleEnabled: true, statusLine: line, isWarning: true, action: action)
    }

    public static func defaultDateFormat(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// A row of the Profiles pane list. [03 §Profiles] observed: each profile shows how many Spaces
/// use it.
public struct SettingsProfileRow: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let spaceCount: Int
    /// The oldest profile is the Default one, which cannot be deleted. [03 §Profiles] observed
    /// (`WorkspaceState.defaultProfileID`).
    public let isDefault: Bool

    public var detail: String { spaceCount == 1 ? "1 Space" : "\(spaceCount) Spaces" }
}

/// Where crash reports are kept. Plan decision Q8: stored locally only, never uploaded. D8 points
/// Chromium's crash database here; the folder may not exist before the first report.
public enum CrashReportLocation {
    /// Persisted folder name; never rename.
    public static let folderName = "Crash Reports"

    public static func directory(in base: URL = PersistenceDefaults.defaultDirectory) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
    }
}

/// State and actions of the Settings window. Reads the workspace through the shell (the app's
/// `WorkspaceController` is its single owner). Profile settings are written through `TreeOps` on the edited profile;
/// app- and account-level preferences through `AppPreferences`.
@MainActor
public final class SettingsModel: ObservableObject {
    public let shell: ShellModel

    @Published public var selectedPane: SettingsPane = .account
    /// Profile whose settings the Profiles pane shows; nil means the current window's profile.
    @Published public var selectedProfileID: UUID?
    /// Text typed into the Shortcuts pane search field.
    @Published public var shortcutQuery = ""

    /// Opens a folder in Finder. Injectable so tests do not open Finder.
    var revealInFinder: (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public init(shell: ShellModel) {
        self.shell = shell
    }

    public var preferences: AppPreferences { shell.dependencies.preferences }

    /// Default-browser status and action (D2), shared with the app menu.
    public var defaultBrowser: DefaultBrowserModel { shell.controller.defaultBrowser }

    // MARK: Account card (iCloud sync)

    /// The app's sync controller (one per app, on the workspace controller).
    public var sync: SidebarSyncController { shell.controller.sidebarSync }

    /// False with `DisabledSyncStore`: this build has no sync backend.
    public var isSyncBackendAvailable: Bool { sync.isBackendAvailable }

    /// Latest status from `SyncStore.statusUpdates()`.
    public var syncStatus: SyncStatus { sync.status }

    public var syncCard: SyncCardState { sync.card }

    /// Follows the sync store's status until the stream ends or the calling task is cancelled.
    /// The view runs this in `.task`, so it stops when the window closes.
    public func observeSync() async {
        await sync.observeStatus()
    }

    /// "Sync Sidebar" toggle. Shown off when there is no backend.
    public var isSidebarSyncOn: Bool { sync.isEnabled }

    /// Stores the choice, then stops the sync store or starts it against the workspace store.
    public func setSidebarSync(_ isOn: Bool) {
        objectWillChange.send()
        sync.setEnabled(isOn)
    }

    /// The account card's button.
    public func performSyncAction(_ action: SyncCardState.Action) {
        switch action {
        case .syncNow: sync.syncNow()
        case .useNewAccount: sync.resumeAfterAccountChange()
        }
    }

    // MARK: Profiles

    public var profileRows: [SettingsProfileRow] {
        let workspace = shell.workspace
        return workspace.liveProfilesOldestFirst.enumerated().map { index, profile in
            SettingsProfileRow(
                id: profile.id,
                name: profile.name,
                spaceCount: workspace.spaces(inProfile: profile.id).count,
                isDefault: index == 0
            )
        }
    }

    /// The profile the Profiles pane edits: the selection, else the profile of the browser window
    /// used last.
    public var editedProfileID: UUID? {
        if let id = selectedProfileID, shell.workspace.profiles[id]?.meta.isTombstone == false { return id }
        return shell.controller.currentProfileID ?? profileRows.first?.id
    }

    /// "+" under the profile list. Creates "Profile N" through the sidebar (TreeOps) and selects it.
    @discardableResult
    public func addProfile() -> UUID {
        let id = shell.sidebar.createProfile(name: "Profile \(profileRows.count + 1)")
        selectedProfileID = id
        return id
    }

    /// "Profile Settings…" in General jumps to the Profiles pane. [03 §General] observed.
    public func openProfileSettings() {
        selectedPane = .profiles
    }

    /// Why the "−" button is disabled for the edited profile, or nil when it can be deleted.
    /// [03 §Profiles] observed: "The Default Profile cannot be deleted."; the in-use rule is
    /// inferred (`TreeOps.deleteProfile`).
    public var profileDeletionBlockedReason: String? {
        guard let id = editedProfileID else { return "Select a Profile." }
        switch TreeOps.profileDeletionBlocker(shell.workspace, id: id) {
        case nil: return nil
        case .defaultProfileNotDeletable?: return "The Default Profile cannot be deleted."
        case .profileHasSpaces(let count)?:
            let spaces = count == 1 ? "1 Space uses" : "\(count) Spaces use"
            return "\(spaces) this Profile. Move them to another Profile or delete them first."
        case .some: return "This Profile cannot be deleted."
        }
    }

    public var canDeleteEditedProfile: Bool { profileDeletionBlockedReason == nil }

    /// "−" under the profile list. Deletes the edited profile through TreeOps and selects the
    /// Default profile. Returns false when refused.
    @discardableResult
    public func deleteEditedProfile() -> Bool {
        guard let id = editedProfileID, canDeleteEditedProfile else { return false }
        objectWillChange.send()
        guard shell.sidebar.deleteProfile(id) else { return false }
        selectedProfileID = nil
        return true
    }

    /// The edited profile's synced settings.
    public var editedProfileSettings: ProfileSettings {
        guard let id = editedProfileID, let profile = shell.workspace.profiles[id] else { return .default }
        return profile.settings
    }

    private func updateEditedProfileSettings(_ change: (inout ProfileSettings) -> Void) {
        guard let id = editedProfileID else { return }
        var settings = editedProfileSettings
        change(&settings)
        objectWillChange.send()
        shell.sidebar.updateProfileSettings(id, settings)
    }

    public var searchEngine: SearchEngine {
        get { editedProfileSettings.searchEngine }
        set { updateEditedProfileSettings { $0.searchEngine = newValue } }
    }

    public var archiveLifetime: ArchiveLifetime {
        get { ArchiveLifetime.closest(to: editedProfileSettings.todayLifetime) }
        set { updateEditedProfileSettings { $0.todayLifetime = newValue.interval } }
    }

    // MARK: Shortcuts

    public var shortcutGroups: [ShortcutGroup] {
        ShortcutCatalog.filtered(ShortcutCatalog.groups, query: shortcutQuery)
    }

    // MARK: Links

    /// "Open links from other apps in Little Arc". [03 §Links] observed toggle; default off
    /// (inferred). Read by `DefaultExternalLinkRouter` on every external link. B24.
    public var opensExternalLinksInLittleArc: Bool {
        get { preferences.opensExternalLinksInLittleArc }
        set {
            objectWillChange.send()
            preferences.opensExternalLinksInLittleArc = newValue
        }
    }

    // MARK: Advanced

    /// Software update controls (D7), shared with the app menu.
    public var updates: UpdatesModel { shell.controller.updates }

    /// "When opening Arc, restore windows from previous session". [03 §Advanced] observed, off by
    /// default; a per-device app setting read at launch by `WorkspaceController`.
    public var restoresWindows: Bool {
        get { preferences.restoresWindowsFromPreviousSession }
        set {
            objectWillChange.send()
            preferences.restoresWindowsFromPreviousSession = newValue
        }
    }

    /// Creates the crash report folder if needed (so Finder has something to show) and reveals it.
    public func showCrashReports(base: URL = PersistenceDefaults.defaultDirectory) {
        let directory = CrashReportLocation.directory(in: base)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        revealInFinder(directory)
    }
}
