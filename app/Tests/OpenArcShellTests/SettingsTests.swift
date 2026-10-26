import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// A sync store that reports a fixed list of statuses and then finishes its stream.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class ScriptedSyncStore: SyncStore, @unchecked Sendable {
    let statuses: [SyncStatus]
    private let lock = NSLock()
    private var _stopCount = 0
    var stopCount: Int { lock.withLock { _stopCount } }

    init(_ statuses: [SyncStatus]) { self.statuses = statuses }

    func start(database: any SyncLocalDatabase) async throws {}
    func stop() async { lock.withLock { _stopCount += 1 } }
    func enqueue(_ changes: [PendingChange]) async {}
    func syncNow() async throws {}
    func resetLocalSyncState() async {}
    func currentStatus() async -> SyncStatus { statuses.last ?? .disabled }
    func statusUpdates() -> AsyncStream<SyncStatus> {
        let statuses = statuses
        return AsyncStream { continuation in
            statuses.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }
}

/// Settings window. Spec: docs/arc-spec/03-settings.md (whole file), 02-shortcuts.md, 01-menus.md.
@MainActor
final class SettingsTests: XCTestCase {
    private var suiteNames: [String] = []
    private let clock = Date(timeIntervalSince1970: 0)

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
    }

    private func makeSuite() -> String {
        let name = "org.openarc.tests.settings.\(UUID().uuidString)"
        suiteNames.append(name)
        return name
    }

    private func makeShell(
        sync: any SyncStore = DisabledSyncStore(),
        preferences: AppPreferences = .inMemory(),
        workspace: WorkspaceState? = nil
    ) -> ShellModel {
        let deps = AppDependencies(engine: FakeEngine(), sync: sync, preferences: preferences)
        let now = clock
        return ShellModel(dependencies: deps, workspace: workspace ?? .demo(now: now), now: { now })
    }

    // MARK: [03 §页签顺序]

    /// Pane order is the observed one minus Max (AI is out of scope).
    func testPaneListAndOrderWithoutMax() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title),
                       ["Account", "General", "Profiles", "Links", "Shortcuts", "Icon", "Advanced"])
        let everyLabel = SettingsPane.allCases.flatMap { SettingsCatalog.controls(in: $0).map(\.label) }
        XCTAssertFalse(everyLabel.contains { $0.localizedCaseInsensitiveContains("Max") })
        XCTAssertFalse(everyLabel.contains { $0.localizedCaseInsensitiveContains("ChatGPT") })
    }

    /// Control ids are unique, so views and tests can look them up.
    func testCatalogIDsAreUnique() {
        let ids = SettingsPane.allCases.flatMap { SettingsCatalog.controls(in: $0).map(\.id) }
        XCTAssertEqual(ids.count, Set(ids).count)
    }

    /// [03 §Profiles, §Advanced, §Links] observed labels, control types and defaults.
    func testCatalogMatchesObservedLabelsAndDefaults() {
        XCTAssertEqual(SettingsCatalog.control("profiles.searchEngine").kind, .picker(defaultValue: "Google"))
        XCTAssertEqual(SettingsCatalog.control("profiles.archiveTabsAfter").kind, .picker(defaultValue: "12 hours"))
        XCTAssertEqual(SettingsCatalog.control("links.archiveLittleArcsAfter").kind, .picker(defaultValue: "6 hours"))
        XCTAssertEqual(SettingsCatalog.control("general.warnBeforeQuitting").kind, .toggle(defaultValue: true))
        let advanced: [(String, Bool)] = [
            ("advanced.soundEffects", true), ("advanced.reorderHaptics", true),
            ("advanced.restoreWindows", false), ("advanced.windowDragging", true),
            ("advanced.showFullURL", false), ("advanced.pictureInPicture", true),
            ("advanced.themeData", true), ("advanced.boosts", true),
        ]
        for (id, value) in advanced {
            XCTAssertEqual(SettingsCatalog.control(id).kind, .toggle(defaultValue: value), id)
        }
        XCTAssertEqual(AdvancedPane.toggleIDs, advanced.map(\.0))
        for id in ["advanced.moreSettings", "advanced.resetTranslatePrompts", "advanced.exportData"] {
            XCTAssertEqual(SettingsCatalog.control(id).kind, .button, id)
        }
        let dataRows = ["Privacy and Security", "Passwords", "Credit Cards", "Notifications", "Autofill", "Clear Browsing Data"]
        let profileLabels = SettingsCatalog.controls(in: .profiles).filter { $0.kind == .navigationRow }.map(\.label)
        XCTAssertEqual(profileLabels, dataRows)
    }

    // MARK: [03 §Profiles] search engine

    /// Changing the profile's search engine changes the URL the command bar builds.
    func testSearchEngineChangeChangesSearchURL() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        XCTAssertEqual(settings.searchEngine, .google)
        XCTAssertEqual(shell.searchURL(for: "open arc")?.absoluteString, "https://www.google.com/search?q=open%20arc")
        settings.searchEngine = .duckDuckGo
        XCTAssertEqual(shell.searchURL(for: "open arc")?.absoluteString, "https://duckduckgo.com/?q=open%20arc")
        shell.stop()
    }

    /// The setting is per profile: switching to a Space of another profile applies that profile's
    /// engine, read from `Profile.settings` in the workspace.
    func testSearchEngineFollowsTheSelectedSpacesProfile() throws {
        let shell = makeShell()
        let firstSpace = try XCTUnwrap(shell.selectedSpaceID)
        let other = shell.sidebar.createProfile(name: "Work")
        XCTAssertTrue(shell.sidebar.updateProfileSettings(other, ProfileSettings(searchEngine: .bing)))
        let spaceID = UUID()
        shell.sidebar.replaceWorkspace(try TreeOps.createSpace(shell.workspace, id: spaceID, profileID: other, name: "Work", now: clock))
        shell.selectSpace(firstSpace)
        XCTAssertTrue(shell.searchURLTemplate.contains("google"))
        shell.selectSpace(spaceID)
        XCTAssertTrue(shell.searchURLTemplate.contains("bing"))
        shell.selectSpace(firstSpace)
        XCTAssertTrue(shell.searchURLTemplate.contains("google"))
        shell.stop()
    }

    /// A settings change that arrives with the workspace (another device, via sync) reaches the
    /// search URL without any local copy to refresh.
    func testSyncedSettingsChangeReachesSearchURL() throws {
        let shell = makeShell()
        let profileID = try XCTUnwrap(shell.sidebar.currentProfileID)
        let remote = try TreeOps.updateProfileSettings(
            shell.workspace, id: profileID, settings: ProfileSettings(searchEngine: .ecosia), now: clock.addingTimeInterval(5)
        )
        shell.sidebar.replaceWorkspace(remote)
        XCTAssertEqual(shell.searchURL(for: "x")?.absoluteString, "https://www.ecosia.org/search?q=x")
        shell.stop()
    }

    // MARK: [03 §Profiles] Archive tabs after

    /// Changing "Archive tabs after" writes the profile's settings through TreeOps (stamping only
    /// `settings`) and changes what auto-archive takes.
    func testArchiveLifetimeReachesAutoArchive() throws {
        var now = clock
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: .inMemory())
        let shell = ShellModel(dependencies: deps, workspace: .demo(now: clock), now: { now })
        let settings = SettingsModel(shell: shell)
        let profileID = try XCTUnwrap(settings.editedProfileID)
        let before = try XCTUnwrap(shell.workspace.profiles[profileID])
        XCTAssertEqual(settings.archiveLifetime, .twelveHours)

        now = clock.addingTimeInterval(60)
        settings.archiveLifetime = .twentyFourHours
        let after = try XCTUnwrap(shell.workspace.profiles[profileID])
        XCTAssertEqual(after.settings.todayLifetime, 24 * 3600)
        XCTAssertEqual(after.meta.modifiedAt(Profile.FieldGroup.settings), now)
        XCTAssertEqual(after.meta.modifiedAt(Profile.FieldGroup.naming), before.meta.modifiedAt(Profile.FieldGroup.naming))

        now = clock.addingTimeInterval(13 * 3600)
        XCTAssertTrue(shell.sidebar.runAutoArchive().isEmpty, "24 h lifetime keeps 13 h old tabs")
        settings.archiveLifetime = .twelveHours
        XCTAssertFalse(shell.sidebar.runAutoArchive().isEmpty)
        shell.stop()
    }

    // MARK: Migration from per-device preferences (B12 → A18)

    /// Values an older build stored per device move into the profile once, and the keys go away.
    func testLegacyPreferencesMigrateOnceIntoTheProfile() throws {
        let suite = makeSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let preferences = AppPreferences(defaults: defaults)
        let workspace = WorkspaceState.demo(now: clock)
        let profileID = try XCTUnwrap(workspace.defaultProfileID)
        preferences.setLegacyProfileSettings(searchEngine: .ecosia, archiveLifetime: .sevenDays, for: profileID)

        let shell = makeShell(preferences: preferences, workspace: workspace)
        let migrated = try XCTUnwrap(shell.workspace.profiles[profileID]?.settings)
        XCTAssertEqual(migrated, ProfileSettings(searchEngine: .ecosia, todayLifetime: 7 * 24 * 3600))
        XCTAssertTrue(shell.searchURLTemplate.contains("ecosia"))
        XCTAssertFalse(preferences.hasLegacyProfileSettings(for: profileID))
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.contains(profileID.uuidString) }.isEmpty)

        // Runs once: a later change in the profile is not overwritten at the next launch.
        let changed = try TreeOps.updateProfileSettings(
            shell.workspace, id: profileID, settings: ProfileSettings(searchEngine: .bing), now: clock.addingTimeInterval(1)
        )
        let relaunched = makeShell(preferences: AppPreferences(defaults: defaults), workspace: changed)
        XCTAssertEqual(relaunched.workspace.profiles[profileID]?.settings.searchEngine, .bing)
        shell.stop(); relaunched.stop()
    }

    /// Only the keys that exist are applied; a profile without legacy keys is not touched.
    func testPartialLegacyPreferencesKeepOtherDefaults() throws {
        let preferences = AppPreferences.inMemory()
        var workspace = WorkspaceState.demo(now: clock)
        let first = try XCTUnwrap(workspace.defaultProfileID)
        let second = UUID()
        workspace = TreeOps.createProfile(workspace, id: second, name: "Work", now: clock.addingTimeInterval(1))
        preferences.setLegacyProfileSettings(searchEngine: nil, archiveLifetime: .thirtyDays, for: first)

        let shell = makeShell(preferences: preferences, workspace: workspace)
        XCTAssertEqual(shell.workspace.profiles[first]?.settings, ProfileSettings(searchEngine: .google, todayLifetime: 30 * 24 * 3600))
        XCTAssertEqual(shell.workspace.profiles[second], workspace.profiles[second])
        shell.stop()
    }

    /// Profile settings no longer write per-device preferences.
    func testProfileSettingsDoNotWritePreferences() throws {
        let suite = makeSuite()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let shell = makeShell(preferences: AppPreferences(defaults: defaults))
        let settings = SettingsModel(shell: shell)
        settings.searchEngine = .ecosia
        settings.archiveLifetime = .twentyFourHours
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(AppPreferences.keyPrefix) }.isEmpty)
        XCTAssertEqual(shell.workspace.profiles[try XCTUnwrap(settings.editedProfileID)]?.settings,
                       ProfileSettings(searchEngine: .ecosia, todayLifetime: 24 * 3600))
        shell.stop()
    }

    /// The account-level "Sync Sidebar" choice still persists per device.
    func testSidebarSyncPreferencePersistsAcrossInstances() throws {
        let suite = makeSuite()
        let first = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(first.isSidebarSyncEnabled)
        first.isSidebarSyncEnabled = false
        let second = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertFalse(second.isSidebarSyncEnabled)
    }

    // MARK: [03 §Profiles] delete profile

    /// [06 §16.3] observed: "−" is disabled for the Default profile and for a profile any Space
    /// uses, with Arc's reasons; an unused profile shows "Not used", "−" asks for its name and only
    /// the exact name enables Delete; deleting removes it and its engine data.
    func testRemoveProfileButtonRules() async throws {
        // An advancing clock: "Default" is the oldest profile, so creation times must differ.
        var tick = clock
        let engine = FakeEngine()
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let shell = ShellModel(dependencies: deps, workspace: .demo(now: clock), now: {
            tick = tick.addingTimeInterval(1)
            return tick
        })
        let settings = SettingsModel(shell: shell)
        XCTAssertFalse(settings.canDeleteEditedProfile)
        XCTAssertEqual(settings.profileDeletionBlockedReason, "The Default Profile cannot be deleted.")
        XCTAssertFalse(settings.requestDeleteEditedProfile())
        XCTAssertNil(settings.profilePendingDeletion)

        let work = settings.addProfile()
        XCTAssertTrue(settings.canDeleteEditedProfile)
        XCTAssertEqual(settings.profileRows.first { $0.id == work }?.detail, "Not used")
        let spaceID = UUID()
        shell.sidebar.replaceWorkspace(try TreeOps.createSpace(shell.workspace, id: spaceID, profileID: work, name: "Work", now: clock))
        XCTAssertEqual(settings.profileRows.first { $0.id == work }?.detail, "1 Space")
        XCTAssertFalse(settings.canDeleteEditedProfile)
        XCTAssertEqual(settings.profileDeletionBlockedReason, "Only Profiles not assigned to any Spaces can be deleted.")
        XCTAssertFalse(settings.requestDeleteEditedProfile())

        shell.sidebar.replaceWorkspace(try TreeOps.deleteSpace(shell.workspace, id: spaceID, now: clock))
        XCTAssertTrue(settings.requestDeleteEditedProfile())
        XCTAssertEqual(settings.profilePendingDeletion, work)
        let name = try XCTUnwrap(settings.profilePendingDeletionName)
        XCTAssertEqual(SettingsModel.profileDeletionMessage(name: name),
                       "Deleting \(name) will permanently remove any cookies, history, preferences, and logins that belong to this Profile.\nTo continue, please type the name of this Profile:")
        XCTAssertFalse(settings.canConfirmProfileDeletion(typed: String(name.dropLast())))
        XCTAssertFalse(settings.confirmProfileDeletion(typed: String(name.dropLast())))
        XCTAssertEqual(shell.workspace.profiles[work]?.meta.isTombstone, false)
        XCTAssertTrue(settings.canConfirmProfileDeletion(typed: name))
        XCTAssertTrue(settings.confirmProfileDeletion(typed: name))
        XCTAssertNil(settings.profilePendingDeletion)
        XCTAssertEqual(shell.workspace.profiles[work]?.meta.isTombstone, true)
        XCTAssertEqual(settings.profileRows.map(\.name), ["Default"])
        XCTAssertNotEqual(settings.editedProfileID, work)
        await shell.sidebar.settleEngineWork()
        XCTAssertEqual(engine.deletedProfileIDs, [work])
        shell.stop()
    }

    /// [06 §16.3]: Cancel closes the confirmation and keeps the profile.
    func testCancelProfileDeletionKeepsProfile() {
        var tick = clock
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: .inMemory())
        let shell = ShellModel(dependencies: deps, workspace: .demo(now: clock), now: {
            tick = tick.addingTimeInterval(1)
            return tick
        })
        let settings = SettingsModel(shell: shell)
        let extra = settings.addProfile()
        XCTAssertTrue(settings.requestDeleteEditedProfile())
        settings.cancelProfileDeletion()
        XCTAssertNil(settings.profilePendingDeletion)
        XCTAssertEqual(shell.workspace.profiles[extra]?.meta.isTombstone, false)
        shell.stop()
    }

    // MARK: [03 §账号卡] iCloud sync card

    /// With `DisabledSyncStore` the card says sync is unavailable and the toggle is disabled.
    func testSyncCardWithoutBackendIsUnavailable() async {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        await settings.observeSync()
        XCTAssertFalse(settings.isSyncBackendAvailable)
        XCTAssertFalse(settings.syncCard.isToggleEnabled)
        XCTAssertFalse(settings.isSidebarSyncOn)
        XCTAssertTrue(settings.syncCard.statusLine.contains("not available"))
        shell.stop()
    }

    /// The card follows the store's status stream; idle shows "Last synced: <time>".
    func testSyncCardFollowsStatusUpdates() async {
        let last = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ScriptedSyncStore([.disabled, SyncStatus(phase: .syncing), SyncStatus(phase: .idle, lastSyncedAt: last)])
        let shell = makeShell(sync: store)
        let settings = SettingsModel(shell: shell)
        await settings.observeSync()  // the scripted stream finishes
        XCTAssertTrue(settings.isSyncBackendAvailable)
        XCTAssertEqual(settings.syncStatus.phase, .idle)
        let card = SyncCardState.make(status: settings.syncStatus, backendAvailable: true, formatDate: { _ in "T" })
        XCTAssertEqual(card, SyncCardState(isToggleEnabled: true, statusLine: "Last synced: T", isWarning: false))
        shell.stop()
    }

    func testSyncCardStates() {
        let make = { (status: SyncStatus) in SyncCardState.make(status: status, backendAvailable: true, formatDate: { _ in "T" }) }
        XCTAssertEqual(make(SyncStatus(phase: .syncing)).statusLine, "Syncing…")
        XCTAssertEqual(make(.disabled).statusLine, "Starting sync…")
        XCTAssertTrue(make(SyncStatus(phase: .unavailable(.noAccount))).isWarning)
        XCTAssertFalse(make(SyncStatus(phase: .unavailable(.restricted))).isToggleEnabled)
        let failed = make(SyncStatus(phase: .failed(message: "offline"), lastSyncedAt: clock))
        XCTAssertTrue(failed.isWarning)
        XCTAssertTrue(failed.statusLine.contains("Last synced: T"))
        XCTAssertEqual(make(SyncStatus(phase: .idle)).statusLine, "Not synced yet")
    }

    /// Turning "Sync Sidebar" off is stored and stops the store.
    func testSyncToggleStoresChoiceAndStopsStore() async {
        let store = ScriptedSyncStore([SyncStatus(phase: .idle)])
        let preferences = AppPreferences.inMemory()
        let shell = makeShell(sync: store, preferences: preferences)
        let settings = SettingsModel(shell: shell)
        XCTAssertTrue(settings.isSidebarSyncOn)
        settings.setSidebarSync(false)
        XCTAssertFalse(preferences.isSidebarSyncEnabled)
        XCTAssertFalse(settings.isSidebarSyncOn)
        for _ in 0..<100 where store.stopCount == 0 { await Task.yield() }
        XCTAssertEqual(store.stopCount, 1)
        shell.stop()
    }

    // MARK: Disabled controls

    /// Controls without a backing feature are disabled and name the plan task that enables them.
    func testControlsWithoutBackingAreDisabled() {
        let live: Set<String> = [
            "account.syncSidebar", "general.profileSettings", "profiles.list", "profiles.add", "profiles.remove",
            "profiles.searchEngine", "profiles.archiveTabsAfter", "shortcuts.search", "shortcuts.defaults",
            "icon.grid", "advanced.showCrashReports", "advanced.restoreWindows", "account.makeDefault",
            "links.littleArcExternal", "advanced.adBlocking",
        ]
        for pane in SettingsPane.allCases {
            for control in SettingsCatalog.controls(in: pane) {
                XCTAssertEqual(control.isEnabled, live.contains(control.id), control.id)
                if case .pending(let task) = control.backing { XCTAssertFalse(task.isEmpty, control.id) }
            }
        }
        // Shortcut customization is out of scope for now: read-only list. [02 §其他]
        XCTAssertFalse(SettingsCatalog.control("shortcuts.custom").isEnabled)
        XCTAssertFalse(SettingsCatalog.control("shortcuts.reset").isEnabled)
    }

    // MARK: [03 §Profiles] list

    /// The Default profile is first and flagged; each row counts its Spaces; "+" adds a profile.
    func testProfileRowsAndAdd() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        XCTAssertEqual(settings.profileRows.map(\.name), ["Default"])
        XCTAssertEqual(settings.profileRows.first?.detail, "1 Space")
        XCTAssertEqual(settings.profileRows.first?.isDefault, true)
        let id = settings.addProfile()
        XCTAssertEqual(settings.editedProfileID, id)
        XCTAssertEqual(settings.profileRows.count, 2)
        XCTAssertEqual(settings.profileRows.last?.isDefault, false)
        // Per-profile: the new profile still has the default engine.
        XCTAssertEqual(settings.searchEngine, .google)
        shell.stop()
    }

    /// "Profile Settings…" in General jumps to the Profiles pane. [03 §General]
    func testProfileSettingsButtonOpensProfilesPane() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        settings.selectedPane = .general
        settings.openProfileSettings()
        XCTAssertEqual(settings.selectedPane, .profiles)
        shell.stop()
    }

    // MARK: [02] Shortcuts pane

    /// The list follows the `02` groups and keys, and the search matches names and keys.
    func testShortcutListGroupsAndSearch() {
        XCTAssertEqual(ShortcutCatalog.groups.map(\.title),
                       ["Tabs and Sidebar", "Spaces", "Split View", "Page and Navigation", "Windows and App", "Developer"])
        let all = ShortcutCatalog.groups.flatMap(\.entries)
        XCTAssertEqual(all.first { $0.action == "Archive Tab" }?.keys, "⌘W")
        XCTAssertEqual(all.first { $0.action == "Settings…" }?.keys, "⌘,")
        XCTAssertEqual(ShortcutCatalog.filtered(ShortcutCatalog.groups, query: "split").flatMap(\.entries).count, 2)
        XCTAssertEqual(ShortcutCatalog.filtered(ShortcutCatalog.groups, query: "⇧⌘K").flatMap(\.entries).map(\.action),
                       ["Clear Unpinned Tabs"])
        XCTAssertTrue(ShortcutCatalog.filtered(ShortcutCatalog.groups, query: "zzz").isEmpty)
    }

    // MARK: [03 §Advanced] crash reports (plan Q8: local only)

    func testShowCrashReportsCreatesAndRevealsLocalFolder() throws {
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/settings-tmp/\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        var revealed: URL?
        settings.revealInFinder = { revealed = $0 }
        settings.showCrashReports(base: base)
        let expected = base.appendingPathComponent(CrashReportLocation.folderName, isDirectory: true)
        XCTAssertEqual(revealed, expected)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        shell.stop()
    }

    /// Plan D8: the crash folder follows the app data dir, so `OPENARC_DATA_DIR` isolates it too.
    func testCrashReportFolderFollowsDataDirectoryOverride() {
        let base = AppDataLocation.directory(environment: [AppDataLocation.environmentKey: "/tmp/d8-data"])
        XCTAssertEqual(CrashReportLocation.directory(in: base).path, "/tmp/d8-data/Crash Reports")
    }

    /// Plan D8: Debug ▸ Crash exists only in the development build started with
    /// `OPENARC_DEBUG_CRASH=1`.
    func testDebugCrashMenuOnlyInDevelopmentBuildWithSwitch() {
        let on = [CrashReportLocation.debugCrashEnvironmentKey: "1"]
        let dev = AppIdentity.developmentBundleIdentifier
        let release = AppIdentity.releaseBundleIdentifier
        XCTAssertTrue(CrashReportLocation.isDebugCrashMenuEnabled(environment: on, bundleIdentifier: dev))
        XCTAssertFalse(CrashReportLocation.isDebugCrashMenuEnabled(environment: on, bundleIdentifier: release))
        XCTAssertFalse(CrashReportLocation.isDebugCrashMenuEnabled(environment: [:], bundleIdentifier: dev))
        XCTAssertFalse(CrashReportLocation.isDebugCrashMenuEnabled(
            environment: [CrashReportLocation.debugCrashEnvironmentKey: "0"], bundleIdentifier: dev))
    }

    // MARK: Rendering

    /// Every pane builds and lays out.
    func testEveryPaneLaysOut() {
        let shell = makeShell()
        let settings = SettingsModel(shell: shell)
        for pane in SettingsPane.allCases {
            let host = NSHostingView(rootView: SettingsPaneView(pane: pane, model: settings).frame(width: SettingsTokens.windowWidth))
            host.frame = CGRect(x: 0, y: 0, width: SettingsTokens.windowWidth, height: 500)
            host.layoutSubtreeIfNeeded()
        }
        let window = NSHostingView(rootView: SettingsWindowView(model: settings))
        window.frame = CGRect(x: 0, y: 0, width: SettingsTokens.windowWidth, height: 500)
        window.layoutSubtreeIfNeeded()
        shell.stop()
    }
}
