import Foundation
import AppKit
import XCTest
import OpenArcModel
import OpenArcDesign
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Collects autosave work; never fires it unless asked.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class HeldScheduler: AutosaveScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () async -> Void] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        lock.withLock { pending.append(work) }
    }

    func fireAll() async {
        let work = lock.withLock { () -> [@Sendable () async -> Void] in
            defer { pending = [] }
            return pending
        }
        for item in work { await item() }
    }
}

/// A sync store that records everything it is asked to enqueue.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class RecordingSync: SyncStore, @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [PendingChange] = []

    var enqueued: [PendingChange] { lock.withLock { changes } }

    func start(database: any SyncLocalDatabase) async throws {}
    func stop() async {}
    func enqueue(_ new: [PendingChange]) async { lock.withLock { changes.append(contentsOf: new) } }
    func syncNow() async throws {}
    func resetLocalSyncState() async {}
    func currentStatus() async -> SyncStatus { .disabled }
    func statusUpdates() -> AsyncStream<SyncStatus> { AsyncStream { $0.yield(.disabled); $0.finish() } }
}

/// B14: several browser windows on one `WorkspaceController`.
/// Observed: the File menu items New Window, Blank Window, New Incognito Window, Close Window
/// [01 §File] and their keys ⌘N, ⌃⌘N, ⇧⌘N, ⇧⌘W [02 §窗口与应用]; the "restore windows from
/// previous session" setting [03 §Advanced]. Inferred (the spec records no window behavior): shared
/// workspace, the one-window-per-tab rule (selecting a tab another window shows focuses that
/// window), New Window on the current Space, Blank Window without a tab, incognito isolation,
/// closing the last window keeps the app, restoring every window at launch.
@MainActor
final class MultiWindowTests: XCTestCase {
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b14-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(
        _ f: SidebarFixture = SidebarFixture(),
        engine: FakeEngine = FakeEngine(),
        sync: any SyncStore = DisabledSyncStore(),
        store: WorkspaceStore? = nil,
        preferences: AppPreferences = .inMemory(),
        now: (() -> Date)? = nil
    ) -> WorkspaceController {
        let deps = AppDependencies(engine: engine, sync: sync, persistence: store, preferences: preferences)
        let fixed = f.now.addingTimeInterval(10)
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: now ?? { fixed }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID? = nil, tab: UUID? = nil) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space, selectedTabID: tab))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func makeStore(_ scheduler: HeldScheduler = HeldScheduler()) -> WorkspaceStore {
        WorkspaceStore(directory: directory, scheduler: scheduler, now: { Date(timeIntervalSince1970: 1_000) })
    }

    // MARK: Shared workspace

    /// Every window shows the same workspace: an edit in one is seen by the other at once.
    func testTwoWindowsShareWorkspaceChanges() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.work)
        var redraws = 0
        let watch = b.sidebar.objectWillChange.sink { redraws += 1 }
        let folder = try XCTUnwrap(a.sidebar.createFolder(title: "Shared"))
        XCTAssertEqual(b.workspace.folders[folder]?.title, "Shared")
        XCTAssertGreaterThan(redraws, 0, "the other window redraws")
        b.sidebar.clearToday()
        XCTAssertTrue(a.workspace.today(spaceID: f.work).isEmpty, "B's Clear reached A's workspace")
        XCTAssertEqual(a.workspace, controller.workspace)
        watch.cancel()
    }

    /// Each window keeps its own selection, sidebar visibility and command bar.
    func testSelectionAndChromeArePerWindow() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.work)
        try await a.activate(tabID: f.today1)
        a.toggleSidebar()
        b.presentCommandBar(.newTab)
        XCTAssertEqual(a.selectedSpaceID, f.home)
        XCTAssertEqual(b.selectedSpaceID, f.work)
        XCTAssertNil(b.selectedTabID)
        XCTAssertFalse(a.isSidebarVisible)
        XCTAssertTrue(b.isSidebarVisible)
        XCTAssertFalse(a.isCommandBarPresented)
        XCTAssertTrue(b.isCommandBarPresented)
    }

    /// Archiving a tab in one window clears it from the other's selection (repair).
    func testArchivingInOneWindowRepairsTheOther() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.home)
        try await a.activate(tabID: f.today1)
        b.selectSpace(f.work)
        b.selectSpace(f.home)
        // B archives A's tab through the Library-free path: Clear Today in the same Space.
        b.sidebar.clearToday()
        XCTAssertNil(a.selectedTabID, "A's archived tab is no longer selected")
        await controller.settleEngineWork()
        XCTAssertNil(controller.liveTab(for: f.today1), "the engine tab closed once")
    }

    /// One engine tab per model tab, shared by the controller: selecting in two windows one after
    /// the other does not create a second engine tab.
    func testLiveTabsAreSharedNotDuplicated() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.home)
        try await a.activate(tabID: f.today1)
        a.sidebar.selectTab(f.today2)
        try await b.activate(tabID: f.today1)
        XCTAssertEqual(b.selectedTabID, f.today1)
        XCTAssertEqual(engine.tabIDs.count, 2, "today1 and today2, each once")
        XCTAssertTrue(a.selectedLiveTab === controller.liveTab(for: f.today2))
        XCTAssertTrue(b.selectedLiveTab === controller.liveTab(for: f.today1))
    }

    // MARK: One window per tab

    /// A tab shown in window A, selected in window B, brings A to the front; B's selection stays.
    func testSelectingATabShownInAnotherWindowFocusesThatWindow() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.home)
        var aFocused = 0
        a.focusWindow = { aFocused += 1 }
        try await a.activate(tabID: f.today1)
        try await b.activate(tabID: f.today2)

        b.sidebar.selectTab(f.today1)
        XCTAssertEqual(aFocused, 1)
        XCTAssertEqual(a.focusRequestCount, 1)
        XCTAssertEqual(b.selectedTabID, f.today2, "B keeps its own tab")
        XCTAssertEqual(a.selectedTabID, f.today1)

        // The command bar's Switch to Tab follows the same rule, and does not switch B's Space.
        b.selectSpace(f.work)
        b.perform(.switchToTab(tabID: f.today1))
        XCTAssertEqual(aFocused, 2)
        XCTAssertEqual(b.selectedSpaceID, f.work)

        // Once A shows something else, B may take the tab.
        a.sidebar.selectTab(f.today3)
        b.selectSpace(f.home)
        b.sidebar.selectTab(f.today1)
        XCTAssertEqual(b.selectedTabID, f.today1)
        XCTAssertEqual(aFocused, 2)
    }

    /// Split partners count as on screen too: a pane of A's split is not shown by B.
    func testSplitPaneOfAnotherWindowFocusesIt() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.home)
        try await a.activate(tabID: f.today1)
        a.sidebar.openInSplitView(f.today2)
        XCTAssertTrue(a.hasActiveSplit)
        b.sidebar.selectTab(f.today2)
        XCTAssertNil(b.selectedTabID)
        XCTAssertEqual(a.focusRequestCount, 1)
    }

    /// Switching to a Space whose remembered tab is on screen elsewhere selects nothing and does
    /// not steal focus.
    func testSpaceSwitchSkipsRememberedTabShownElsewhere() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.home)
        try await b.activate(tabID: f.today1)
        b.selectSpace(f.work)
        try await b.activate(tabID: f.workTab)
        try await a.activate(tabID: f.today1)
        XCTAssertEqual(a.selectedTabID, f.today1)
        b.selectSpace(f.home)
        XCTAssertNotEqual(b.selectedTabID, f.today1, "the remembered Home tab is on screen in A")
        XCTAssertEqual(a.focusRequestCount, 0)
    }

    // MARK: New, Blank and Close

    /// New Window opens on the active window's Space with its most recent tab that no window shows;
    /// Blank Window opens there with no tab.
    func testNewAndBlankWindowRequests() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        try await a.activate(tabID: f.today1)
        a.windowDidBecomeKey()

        let newWindow = ShellModel.window(for: a.windowRequest(.newWindow), on: controller)
        addTeardownBlock { @MainActor in newWindow.stop() }
        XCTAssertEqual(newWindow.selectedSpaceID, f.home)
        XCTAssertNotNil(newWindow.selectedTabID)
        XCTAssertNotEqual(newWindow.selectedTabID, f.today1, "A's tab stays in A")

        let blank = ShellModel.window(for: a.windowRequest(.blank), on: controller)
        addTeardownBlock { @MainActor in blank.stop() }
        XCTAssertEqual(blank.selectedSpaceID, f.home)
        XCTAssertNil(blank.selectedTabID)
        XCTAssertEqual(controller.browserWindows.count, 3)
    }

    /// Closing one window keeps the other working; closing the last one keeps the controller (the
    /// app stays open) and remembers that window for the next launch.
    func testClosingOneWindowKeepsTheOther() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.work)
        try await a.activate(tabID: f.today1)
        a.windowDidClose()
        XCTAssertEqual(controller.browserWindows.map(\.selectedSpaceID), [f.work])
        XCTAssertTrue(controller.activeWindow === b)
        XCTAssertNotNil(controller.liveTab(for: f.today1), "the page stays loaded for other windows")
        try await b.activate(tabID: f.workTab)
        let folder = try XCTUnwrap(b.sidebar.createFolder(title: "Still here"))
        XCTAssertNotNil(controller.workspace.folders[folder])
        // The closed window no longer holds its tab: B may show it.
        b.selectSpace(f.home)
        b.sidebar.selectTab(f.today1)
        XCTAssertEqual(b.selectedTabID, f.today1)

        b.windowDidClose()
        XCTAssertTrue(controller.browserWindows.isEmpty)
        XCTAssertNil(controller.activeWindow)
        XCTAssertEqual(controller.currentUIState.windows.map(\.selectedSpaceID), [f.home], "the last window is remembered")
        XCTAssertEqual(controller.reopenState().selectedTabID, f.today1)
        XCTAssertEqual(controller.workspace.folders[folder]?.title, "Still here")
    }

    /// Little Arc acts on the window used last; if that window closed meanwhile, "Open in Open Arc"
    /// goes to the next one, or opens a new window when none is left. [06 §7] inferred.
    func testLittleArcAdoptsIntoAnOpenWindow() throws {
        let f = SidebarFixture()
        // A clock that moves forward on every read, so the two adopted tabs get distinct activity
        // times; with a fixed clock "most recent tab" would tie and fall back to random tab ids.
        var tick: TimeInterval = 10
        let controller = makeController(f, now: {
            tick += 1
            return f.now.addingTimeInterval(tick)
        })
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.work)
        b.windowDidBecomeKey()
        XCTAssertTrue(controller.littleArcHost() === b)
        b.windowDidClose()
        let adopted = try XCTUnwrap(b.adoptLittleArcTab(url: URL(string: "https://little.example")!, title: "Little"))
        XCTAssertEqual(a.selectedTabID, adopted)
        XCTAssertEqual(controller.workspace.tabs[adopted]?.location.spaceID, f.home)

        a.windowDidClose()
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }
        let host = controller.littleArcHost()
        XCTAssertFalse(host.isBrowserWindow)
        let second = try XCTUnwrap(host.adoptLittleArcTab(url: URL(string: "https://again.example")!, title: "Again"))
        XCTAssertEqual(requests.map(\.kind), [.newWindow])
        let reopened = ShellModel.window(for: try XCTUnwrap(requests.first), on: controller)
        addTeardownBlock { @MainActor in reopened.stop() }
        XCTAssertEqual(reopened.selectedTabID, second, "the new window shows the adopted page")
    }

    // MARK: Incognito

    /// Incognito tabs are created off the record and never reach the store or sync; closing the
    /// window discards them.
    func testIncognitoTabsNeverReachStoreOrSync() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let sync = RecordingSync()
        let scheduler = HeldScheduler()
        let store = makeStore(scheduler)
        let controller = makeController(f, engine: engine, sync: sync, store: store)
        let regular = window(controller, space: f.home)
        try await regular.flushPersistence()
        let savedBefore = try Data(contentsOf: directory.appendingPathComponent(PersistenceDefaults.workspaceFileName))

        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        XCTAssertTrue(incognito.isIncognito)
        XCTAssertFalse(controller.browserWindows.contains { $0 === incognito }, "never saved in the UI state")
        let url = try XCTUnwrap(URL(string: "https://secret.example"))
        let opened = try await incognito.openNewTab(url: url)
        let tabID = try XCTUnwrap(opened)
        XCTAssertNil(controller.workspace.tabs[tabID], "not in the workspace")
        XCTAssertEqual(engine.offTheRecordTabIDs.count, 1)
        XCTAssertFalse(incognito.workspace.spaces.keys.contains(f.home), "no regular Spaces")
        XCTAssertTrue(incognito.sidebar.snapshot.favorites.isEmpty)
        incognito.sidebar.addFavorite(tabID)
        XCTAssertTrue(incognito.sidebar.snapshot.favorites.isEmpty, "no favorites in incognito")

        try await regular.flushPersistence()
        await scheduler.fireAll()
        let savedAfter = try Data(contentsOf: directory.appendingPathComponent(PersistenceDefaults.workspaceFileName))
        XCTAssertEqual(savedAfter, savedBefore, "nothing written")
        let file = try String(contentsOf: directory.appendingPathComponent(PersistenceDefaults.workspaceFileName), encoding: .utf8)
        XCTAssertFalse(file.contains("secret.example"))
        for _ in 0..<200 { await Task.yield() }
        XCTAssertFalse(sync.enqueued.contains { change in
            switch change {
            case .save(let id), .delete(let id): return id.uuid == tabID
            }
        }, "nothing sent to sync")
        let ui = try String(contentsOf: UIStateFile.url(in: directory), encoding: .utf8)
        XCTAssertFalse(ui.contains(tabID.uuidString))

        incognito.windowDidClose()
        await incognito.controller.settleEngineWork()
        XCTAssertTrue(engine.offTheRecordTabIDs.isEmpty, "closing the window discards its tabs")
        XCTAssertEqual(controller.browserWindows.count, 1)
    }

    /// The incognito window gets the fixed dark incognito colors (View ▸ Appearance Dark) and no
    /// Space commands. [06 §20.1] observed colors (B48); the Space commands inferred.
    func testIncognitoLookAndSpaceCommands() throws {
        let preferences = AppPreferences.inMemory()
        preferences.webAppearance = .dark
        let controller = makeController(preferences: preferences)
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        XCTAssertEqual(incognito.sidebar.palette.windowBackground, IncognitoTokens.windowBackground, "[06 §20.1] #0C0F14")
        XCTAssertLessThan(ThemeDerivation.luminance(incognito.sidebar.palette.windowBackground), 0.2, "a dark window")
        XCTAssertEqual(incognito.sidebar.palette.primaryText, RGBAColor(hex: 0xFFFFFF), "light text on the dark base")
        incognito.perform(.runCommand(.newSpace))
        XCTAssertFalse(incognito.spaceFlow.isCreating)
        XCTAssertEqual(incognito.lastUnhandledCommand, .newSpace)
        // A new window from an incognito window is a regular one on the app's active Space.
        XCTAssertNil(incognito.windowRequest(.newWindow).spaceID)
    }

    // MARK: UI state

    /// Two windows round-trip through `ui-state.json` and are restored at launch when the
    /// "restore windows" setting is on. [03 §Advanced] observed setting.
    func testLaunchRestoresTwoWindows() async throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.restoresWindowsFromPreviousSession = true
        do {
            let controller = makeController(f, store: makeStore(), preferences: preferences)
            let a = window(controller, space: f.home)
            let b = window(controller, space: f.work)
            try await a.activate(tabID: f.today2)
            try await b.activate(tabID: f.workTab)
            b.toggleSidebar()
            try await controller.flushPersistence()
            a.stop(); b.stop(); controller.stop()
        }
        let saved = try XCTUnwrap(UIStateFile.load(from: directory))
        XCTAssertEqual(saved.windows, [
            WindowUIState(selectedSpaceID: f.home, selectedTabID: f.today2, isSidebarVisible: true),
            WindowUIState(selectedSpaceID: f.work, selectedTabID: f.workTab, isSidebarVisible: false),
        ])

        let relaunched = makeController(store: makeStore(), preferences: preferences)
        let first = ShellModel.window(for: BrowserWindowRequest(kind: .restore), on: relaunched)
        addTeardownBlock { @MainActor in first.stop() }
        XCTAssertEqual(relaunched.takeAdditionalRestoreCount(), 1, "the scene opens one more window")
        let second = ShellModel.window(for: BrowserWindowRequest(kind: .restore), on: relaunched)
        addTeardownBlock { @MainActor in second.stop() }
        XCTAssertEqual(first.selectedSpaceID, f.home)
        XCTAssertEqual(first.selectedTabID, f.today2)
        XCTAssertEqual(second.selectedSpaceID, f.work)
        XCTAssertEqual(second.selectedTabID, f.workTab)
        XCTAssertFalse(second.isSidebarVisible)
        XCTAssertEqual(relaunched.takeAdditionalRestoreCount(), 0, "asked once")
    }

    /// The Advanced toggle is live and stores the per-device preference. [03 §Advanced] observed.
    func testRestoreWindowsSettingIsLive() {
        let controller = makeController()
        let settings = SettingsModel(shell: controller.appHost())
        XCTAssertTrue(SettingsCatalog.control("advanced.restoreWindows").isEnabled)
        XCTAssertFalse(settings.restoresWindows, "off by default")
        settings.restoresWindows = true
        XCTAssertTrue(controller.dependencies.preferences.restoresWindowsFromPreviousSession)
        XCTAssertFalse(controller.browserWindows.contains { $0 === controller.appHost() }, "the Settings host is not a window")
    }

    /// With the setting off (default, [03 §Advanced] observed), only the first window comes back.
    func testRestoreSettingOffBringsBackOneWindow() async throws {
        let f = SidebarFixture()
        try UIStateFile.save(UIState(windows: [
            WindowUIState(selectedSpaceID: f.work),
            WindowUIState(selectedSpaceID: f.home),
        ]), to: directory)
        let store = makeStore()
        await store.update(f.ws)
        try await store.flush()
        let controller = makeController(store: makeStore())
        let first = ShellModel.window(for: BrowserWindowRequest(kind: .restore), on: controller)
        addTeardownBlock { @MainActor in first.stop() }
        XCTAssertEqual(first.selectedSpaceID, f.work)
        XCTAssertEqual(controller.takeAdditionalRestoreCount(), 0)
        XCTAssertNil(controller.takePendingRestore())
    }

    /// Auto-archive starts with the first window and keeps every window's tab and the tab of a
    /// window still waiting to be restored.
    func testAutoArchiveSparesTabsOfAllWindows() throws {
        let f = SidebarFixture()
        let later = f.now.addingTimeInterval(13 * 3600)
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore())
        let controller = WorkspaceController(dependencies: deps, workspace: f.ws, now: { later }, autoArchiveTicker: ManualTicker())
        addTeardownBlock { @MainActor in controller.stop() }
        XCTAssertFalse(controller.isAutoArchiveRunning)
        let a = window(controller, space: f.home, tab: f.today1)
        let b = window(controller, space: f.work, tab: f.workTab)
        XCTAssertTrue(controller.isAutoArchiveRunning)
        // The first window's launch run kept only its own tab; run again with both windows open.
        controller.replaceWorkspace(f.ws)
        a.sidebar.selectTab(f.today1)
        b.sidebar.selectTab(f.workTab)
        let archived = Set(controller.runAutoArchive())
        XCTAssertFalse(archived.contains(f.today1))
        XCTAssertFalse(archived.contains(f.workTab))
        XCTAssertTrue(archived.contains(f.today2))
    }
}
