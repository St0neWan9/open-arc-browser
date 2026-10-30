import Foundation
import AppKit
import Combine
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
    ///   - deleteError: why the last "Delete iCloud Data…" failed, if it did (D12).
    ///   - formatDate: formats `lastSyncedAt`; the app passes a relative format with its clock.
    public static func make(
        status: SyncStatus,
        backendAvailable: Bool,
        isSyncOn: Bool = true,
        actionError: String? = nil,
        deleteError: String? = nil,
        formatDate: (Date) -> String = SyncCardState.defaultDateFormat
    ) -> SyncCardState {
        guard backendAvailable else {
            return SyncCardState(isToggleEnabled: false, statusLine: "iCloud sync is not available in this version.", isWarning: false)
        }
        if let deleteError {
            // "Delete iCloud Data…" (D12) failed; nothing was changed.
            return warning("Deleting iCloud data failed: \(deleteError)")
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
        case _ where status.needsAppUpdate:
            // D11: a newer version wrote some records; this build reads but does not overwrite
            // them. [03 §账号卡] inferred (analysis); the wording is ours.
            return warning("Some items were synced by a newer version of \(AppIdentity.displayName). Update \(AppIdentity.displayName) to sync your changes to them. \(lastSynced)")
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

    /// "Delete iCloud Data…" on the account card and its confirmation (plan D12; [03 §账号卡]
    /// inferred (analysis): Arc has a way to wipe its synced data, entry point unknown). Our own
    /// wording.
    public enum DeleteServerData {
        public static let buttonTitle = "Delete iCloud Data…"
        public static let confirmTitle = "Delete your sidebar from iCloud?"
        public static let confirmMessage = "This removes everything \(AppIdentity.displayName) has synced to iCloud and turns off Sync Sidebar on this Mac. The sidebar on this Mac stays as it is. If you turn sync on again, this Mac uploads its sidebar again."
        public static let confirmButton = "Delete"
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

    /// "Not used" for a profile no Space uses. [06 §16.3] observed.
    public var detail: String {
        switch spaceCount {
        case 0: return "Not used"
        case 1: return "1 Space"
        default: return "\(spaceCount) Spaces"
        }
    }
}

/// Where crash reports are kept. Plan decision Q8: stored locally only, never uploaded. D8 points
/// Chromium's Crashpad database here (`ChromiumEngine(crashReportsDirectory:)`): `.dmp` minidumps
/// of the app (browser) process and every helper stay in its `pending/` subfolder (nothing
/// uploads them). The folder
/// may not exist before the engine first starts.
public enum CrashReportLocation {
    /// Persisted folder name; never rename.
    public static let folderName = "Crash Reports"

    /// `<app data dir>/Crash Reports`; the app data dir honours `OPENARC_DATA_DIR`.
    public static func directory(in base: URL = AppDataLocation.directory()) -> URL {
        base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Environment variable that shows the Debug ▸ Crash menu (plan D8 verification).
    public static let debugCrashEnvironmentKey = "OPENARC_DEBUG_CRASH"

    /// True only for the development build (`AppIdentity.developmentBundleIdentifier`) started
    /// with `OPENARC_DEBUG_CRASH=1`: the menu that crashes the app on purpose never shows in the
    /// release build.
    public static func isDebugCrashMenuEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String = AppIdentity.bundleIdentifier
    ) -> Bool {
        bundleIdentifier == AppIdentity.developmentBundleIdentifier
            && environment[debugCrashEnvironmentKey]?.trimmingCharacters(in: .whitespaces) == "1"
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
    /// Profile whose "Delete this Profile" confirmation is showing; nil when none. [06 §16.3].
    @Published public var profilePendingDeletion: UUID?
    /// Text typed into the Shortcuts pane search field.
    @Published public var shortcutQuery = ""
    /// Profile whose "Clear Browsing Data" sheet is showing; nil when none. B83.
    @Published public var profileClearingData: UUID?
    /// The engine is clearing data for the sheet. B83.
    @Published public internal(set) var isClearingBrowsingData = false
    /// Download folders as the engine reported (or was told) them, per profile; a missing entry
    /// shows the user's Downloads folder. B83.
    @Published var loadedDownloadDirectories: [UUID: URL] = [:]
    /// The Links pane's Air Traffic Control sheet is showing (B52; opened from the command bar, B61).
    @Published public var isAirTrafficControlShown = false
    private var airTrafficControlRequests: AnyCancellable?

    /// Opens a folder in Finder. Injectable so tests do not open Finder.
    var revealInFinder: (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Asks for a folder ("Download location" ▸ Other…), starting in the given one. Injectable so
    /// tests do not show an open panel.
    var pickFolder: (URL) -> URL? = { SettingsModel.runFolderPanel($0) }

    public init(shell: ShellModel) {
        self.shell = shell
        // The command bar's "Air Traffic Control" row: Links pane, sheet open (B61). A request made
        // before this model existed (it opened the Settings window) is still pending.
        let controller = shell.controller
        airTrafficControlRequests = controller.$airTrafficControlRequests.sink { [weak self, weak controller] count in
            guard let controller, count > controller.handledAirTrafficControlRequests else { return }
            controller.handledAirTrafficControlRequests = count
            self?.showAirTrafficControl()
        }
    }

    /// Shows the Links pane with the Air Traffic Control sheet.
    public func showAirTrafficControl() {
        selectedPane = .links
        isAirTrafficControlShown = true
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

    /// "Delete iCloud Data…" (D12), after the confirmation.
    public func deleteICloudData() {
        objectWillChange.send()
        sync.deleteServerData()
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

    /// Renames a profile through `TreeOps.renameProfile` (the profile list's edit button, B100).
    /// Blank names are ignored. Returns false if nothing changed.
    @discardableResult
    public func renameProfile(_ id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, shell.workspace.profiles[id]?.name != trimmed else { return false }
        let controller = shell.controller
        return (try? controller.mutate(origin: nil) { try TreeOps.renameProfile($0, id: id, name: trimmed, now: controller.now()) }) != nil
    }

    /// "Previews Settings…" in General jumps to the Links pane, where the Peek switches are.
    /// [03 §General] observed button; the target is inferred (Previews = Peek link previews,
    /// [03 §Links] observed Peek section). B84.
    public func openPreviewsSettings() {
        selectedPane = .links
    }

    /// "Profile Settings…" in General jumps to the Profiles pane. [03 §General] observed.
    public func openProfileSettings() {
        selectedPane = .profiles
    }

    /// Why the "−" button is disabled for the edited profile, or nil when it can be deleted.
    /// [06 §16.3] observed: the button is disabled for the Default profile ("The Default Profile
    /// cannot be deleted.") and for a profile any Space uses ("Only Profiles not assigned to any
    /// Spaces can be deleted."). Arc does not move or delete those Spaces.
    public var profileDeletionBlockedReason: String? {
        guard let id = editedProfileID else { return "Select a Profile." }
        switch TreeOps.profileDeletionBlocker(shell.workspace, id: id) {
        case nil: return nil
        case .defaultProfileNotDeletable?: return "The Default Profile cannot be deleted."
        case .profileHasSpaces?: return "Only Profiles not assigned to any Spaces can be deleted."
        case .some: return "This Profile cannot be deleted."
        }
    }

    public var canDeleteEditedProfile: Bool { profileDeletionBlockedReason == nil }

    /// "−" under the profile list: opens the "Delete this Profile" confirmation for the edited
    /// profile. [06 §16.3] observed. Returns false when the profile cannot be deleted.
    @discardableResult
    public func requestDeleteEditedProfile() -> Bool {
        guard let id = editedProfileID, canDeleteEditedProfile else { return false }
        profilePendingDeletion = id
        return true
    }

    /// Name of the profile awaiting confirmation; the user must type it exactly.
    public var profilePendingDeletionName: String? {
        profilePendingDeletion.flatMap { shell.workspace.profiles[$0]?.name }
    }

    /// Body of the confirmation. [06 §16.3] observed text.
    public static func profileDeletionMessage(name: String) -> String {
        "Deleting \(name) will permanently remove any cookies, history, preferences, and logins that belong to this Profile.\nTo continue, please type the name of this Profile:"
    }

    /// The red "Delete" button is enabled only once the typed text equals the profile's name.
    /// [06 §16.3] observed (a prefix keeps it disabled; case and whitespace handling: inferred exact).
    public func canConfirmProfileDeletion(typed: String) -> Bool {
        guard let name = profilePendingDeletionName else { return false }
        return typed == name
    }

    public func cancelProfileDeletion() { profilePendingDeletion = nil }

    /// "Delete" in the confirmation: deletes the profile through TreeOps (its engine data is
    /// removed too) and selects the Default profile. Returns false when refused.
    @discardableResult
    public func confirmProfileDeletion(typed: String) -> Bool {
        guard let id = profilePendingDeletion, canConfirmProfileDeletion(typed: typed) else { return false }
        profilePendingDeletion = nil
        guard TreeOps.profileDeletionBlocker(shell.workspace, id: id) == nil else { return false }
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

    /// "Include search engine suggestions" ([03 §Profiles] observed toggle), per profile. B66.
    public var includesSearchSuggestions: Bool {
        get { editedProfileSettings.includesSearchSuggestions }
        set { updateEditedProfileSettings { $0.includesSearchSuggestions = newValue } }
    }

    public var archiveLifetime: ArchiveLifetime {
        get { ArchiveLifetime.closest(to: editedProfileSettings.todayLifetime) }
        set { updateEditedProfileSettings { $0.todayLifetime = newValue.interval } }
    }

    // MARK: Shortcuts

    /// The pane's rows, the Space jumps named after the app's Spaces in dock order ([02] header
    /// note observed, F5-22), filtered by the search field.
    public var shortcutGroups: [ShortcutGroup] {
        let names = shell.controller.workspace.allLiveSpaces.map(\.name)
        return ShortcutCatalog.filtered(ShortcutCatalog.groups(spaceNames: names), query: shortcutQuery)
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

    // MARK: General

    /// "Warn before quitting". [03 §General] observed, on by default; a per-device app setting
    /// read when the user quits (B68).
    public var warnsBeforeQuitting: Bool {
        get { preferences.warnsBeforeQuitting }
        set {
            objectWillChange.send()
            preferences.warnsBeforeQuitting = newValue
        }
    }

    // MARK: Advanced

    /// "Haptic feedback when reordering tabs". [03 §Advanced] observed, on by default; a
    /// per-device app setting read by the sidebar drag (B68).
    public var playsReorderHaptics: Bool {
        get { preferences.playsReorderHaptics }
        set {
            objectWillChange.send()
            preferences.playsReorderHaptics = newValue
        }
    }

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

    /// "Enable Picture in Picture when you leave a video tab". [03 §Advanced] observed, on by
    /// default; a per-device app setting (plan C15).
    public var entersPictureInPictureOnLeavingVideoTab: Bool {
        get { preferences.entersPictureInPictureOnLeavingVideoTab }
        set {
            objectWillChange.send()
            preferences.entersPictureInPictureOnLeavingVideoTab = newValue
        }
    }

    // MARK: Ad blocking (plan C16)

    /// The engine's ad blocker; nil until `loadAdBlocking()` found a ruleset (then the row shows).
    @Published public private(set) var adBlockingRulesetVersion: String?
    /// "Block ads and trackers" (inferred label, see `SettingsCatalog`). The engine stores it
    /// (Chromium's Local State), so it is per device and survives restarts.
    @Published public private(set) var isAdBlockingOn = true

    /// Reads the switch and the ruleset version from the engine. The view runs it in `.task`.
    public func loadAdBlocking() async {
        let blocker = shell.controller.dependencies.engine.adBlocking
        let version = await blocker.rulesetVersion()
        let on = await blocker.isEnabled()
        adBlockingRulesetVersion = version
        isAdBlockingOn = on
    }

    /// Keeps `adBlockingRulesetVersion` current while the caller's task runs: a filter-list update
    /// from our static host (plan C19) replaces the ruleset without a restart, and Settings shows
    /// the new version at once. Subscribes before re-reading, so an update in between is not lost.
    /// Ends when the task is cancelled (the view's `.task`) or the engine's stream ends.
    public func followAdBlockingRulesetVersion() async {
        let blocker = shell.controller.dependencies.engine.adBlocking
        let changes = blocker.rulesetVersionChanges()
        adBlockingRulesetVersion = await blocker.rulesetVersion()
        for await version in changes {
            adBlockingRulesetVersion = version
        }
    }

    /// Sets the global switch. Open tabs follow at their next page load.
    public func setAdBlocking(_ isOn: Bool) async {
        isAdBlockingOn = isOn
        let blocker = shell.controller.dependencies.engine.adBlocking
        await blocker.setEnabled(isOn)
        isAdBlockingOn = await blocker.isEnabled()
    }

    /// Settings ▸ Advanced "Reset Translated-site Prompts" ([03 §Advanced] observed button; its
    /// effect is [06 §19.6] unknown). Advanced settings are app-wide, so every profile's translation
    /// decisions are forgotten: never-translate sites and languages, always-translate languages
    /// (inferred from the label and the engine's prompt memory). Plan B47.
    public func resetTranslatedSitePrompts() async {
        let translation = shell.controller.dependencies.engine.translation
        let live = shell.controller.workspace.profiles.values.filter { !$0.meta.isTombstone }.map(\.id)
        for profileID in live.sorted(by: { $0.uuidString < $1.uuidString }) {
            await translation.resetDecisions(profileID: profileID)
        }
    }

    /// Sound, haptic and window-drag switches (B84), shared with every window.
    public var advancedBehavior: AdvancedBehaviorSettings { shell.controller.feedback.settings }

    /// The Icon pane's state (B84).
    public var appIcon: AppIconSettings { shell.controller.appIcon }

    /// Result of the last Export Data, shown under the button. nil before any export.
    @Published public private(set) var exportStatus: String?

    /// "Export Data" ([03 §Advanced] observed button; Arc's format is unknown). Asks where to save,
    /// then writes our own JSON export of the workspace (`WorkspaceExport`). Returns the written
    /// file, or nil when cancelled or failed (the status line says which). B84.
    @discardableResult
    public func exportData() async -> URL? {
        let stamp = shell.controller.now()
        let name = WorkspaceExport.suggestedFileName(at: stamp)
        guard let url = await shell.dependencies.exportPicker.chooseDestination(suggestedName: name) else { return nil }
        do {
            let data = try WorkspaceExport.make(shell.workspace, exportedAt: stamp).encoded()
            try data.write(to: url, options: .atomic)
            exportStatus = "Exported to \(url.lastPathComponent)."
            return url
        } catch {
            exportStatus = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    /// Creates the crash report folder if needed (so Finder has something to show) and reveals it.
    public func showCrashReports(base: URL = AppDataLocation.directory()) {
        let directory = CrashReportLocation.directory(in: base)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        revealInFinder(directory)
    }
}
