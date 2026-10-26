import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// A sync store that records what it is asked to enqueue.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class EnqueueRecorder: SyncStore, @unchecked Sendable {
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

/// A19: regression tests for the bugs found in the review of the shared files (WorkspaceController,
/// ShellModel, the scene's window requests, WorkspaceStore submissions). Spec sections: sync
/// conflict policy (field-group LWW, delete wins; `OpenArcSyncAPI/ConflictPolicy.swift`), [03 §账号卡]
/// observed "Sync Sidebar", [03 §Profiles] observed per-profile search engine, [01 §File] observed
/// New Incognito Window. The behaviors checked here are inferred.
@MainActor
final class SharedFileReviewTests: XCTestCase {
    /// A unique directory under app/.build/a19-tmp, removed after each test.
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/a19-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(
        _ f: SidebarFixture,
        engine: FakeEngine = FakeEngine(),
        sync: any SyncStore = DisabledSyncStore(),
        store: WorkspaceStore? = nil,
        preferences: AppPreferences = .inMemory()
    ) -> WorkspaceController {
        let deps = AppDependencies(engine: engine, sync: sync, persistence: store, preferences: preferences)
        let fixed = f.now.addingTimeInterval(10)
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { fixed }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    /// Lets the forwarding task subscribe to the store and the sync controller start.
    private func letBackgroundWorkRun(_ controller: WorkspaceController) async {
        await controller.sidebarSync.settle()
        for _ in 0..<300 { await Task.yield() }
    }

    // MARK: Remote changes

    /// A remote edit the shown copy does not win must not come back as a local change: before
    /// A19 the merge bumped the version counter, the store saw a local change and the record was
    /// uploaded again (and echoed back by the other device, forever).
    func testRemoteChangeIsNotUploadedAgain() async throws {
        let f = SidebarFixture()
        let sync = EnqueueRecorder()
        let preferences = AppPreferences.inMemory()
        preferences.needsFullSyncUpload = false
        let store = WorkspaceStore(directory: directory)
        let controller = makeController(f, sync: sync, store: store, preferences: preferences)
        await letBackgroundWorkRun(controller)
        try await store.flush()
        await letBackgroundWorkRun(controller)
        let before = sync.enqueued.count

        let renamed = try TreeOps.renameSpace(controller.workspace, id: f.work, name: "Renamed elsewhere", now: f.now.addingTimeInterval(100))
        let server = try XCTUnwrap(renamed.spaces[f.work])
        try await store.apply(RemoteChangeBatch(upserts: [.space(server)]))
        for _ in 0..<2_000 where controller.workspace.spaces[f.work]?.name != "Renamed elsewhere" { await Task.yield() }
        XCTAssertEqual(controller.workspace.spaces[f.work]?.name, "Renamed elsewhere")

        try await store.flush()
        await letBackgroundWorkRun(controller)
        let spaceRecord = SyncRecordID(type: .space, uuid: f.work)
        let after = Array(sync.enqueued.dropFirst(before))
        XCTAssertFalse(after.contains(.save(spaceRecord)), "the server's own change is not sent back")
        let stored = await store.workspace
        XCTAssertEqual(stored.spaces[f.work], controller.workspace.spaces[f.work], "store and window agree")
    }

    /// A local commit made after a remote batch reached the store, but before the controller merged
    /// it, must not revert the remote records (before A19 the whole stale value was submitted).
    func testLocalCommitDoesNotRevertRemoteBatch() async throws {
        let f = SidebarFixture()
        let store = WorkspaceStore(directory: directory)
        let controller = makeController(f, store: store)
        await letBackgroundWorkRun(controller)
        // Stopping cancels the forwarding task, so the controller never merges the batch: this is
        // the window between `apply` and `mergeRemote`, held open.
        controller.stop()

        let remoteProfile = Profile(id: SidebarFixture.id(900), name: "From another Mac", now: f.now.addingTimeInterval(50))
        try await store.apply(RemoteChangeBatch(upserts: [.profile(remoteProfile)]))
        XCTAssertNil(controller.workspace.profiles[remoteProfile.id])

        var settings = ProfileSettings.default
        settings.searchEngine = .duckDuckGo
        XCTAssertTrue(controller.updateProfileSettings(f.profile, settings))
        try await store.flush()

        let saved = await store.workspace
        XCTAssertEqual(saved.profiles[remoteProfile.id], remoteProfile, "the remote record survives the local commit")
        XCTAssertEqual(saved.profiles[f.profile]?.settings.searchEngine, .duckDuckGo, "the local edit is saved")
    }

    /// A tab deleted on another device loses its engine tab here too.
    func testRemoteDeletionClosesTheEngineTab() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let store = WorkspaceStore(directory: directory)
        let controller = makeController(f, engine: engine, store: store)
        let window = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.home))
        addTeardownBlock { @MainActor in window.stop() }
        try await window.activate(tabID: f.today1)
        XCTAssertEqual(engine.tabIDs.count, 1)
        await letBackgroundWorkRun(controller)

        var tab = try XCTUnwrap(controller.workspace.tabs[f.today1])
        tab.meta.markDeleted(at: f.now.addingTimeInterval(100))
        try await store.apply(RemoteChangeBatch(upserts: [.tab(tab)]))
        for _ in 0..<2_000 where controller.workspace.tabs[f.today1]?.meta.isTombstone != true { await Task.yield() }
        await controller.settleEngineWork()

        XCTAssertEqual(controller.workspace.tabs[f.today1]?.meta.isTombstone, true)
        XCTAssertNil(window.selectedTabID)
        XCTAssertTrue(engine.tabIDs.isEmpty, "the engine tab of a remotely deleted tab is closed")
    }

    // MARK: Window requests

    /// File ▸ New Incognito Window (and the other menu items) must open what they say: the window
    /// root reopens the last session for any value this run did not record. [01 §File] observed.
    func testMenuWindowRequestsAreRecorded() {
        let f = SidebarFixture()
        let controller = makeController(f)
        let window = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.home))
        addTeardownBlock { @MainActor in window.stop() }
        for kind in [BrowserWindowRequest.Kind.incognito, .newWindow, .blank] {
            let fromWindow = window.issueMenuWindowRequest(kind, fromWindow: true)
            XCTAssertTrue(controller.wasIssued(fromWindow), "\(kind) from a window")
            let withoutWindow = controller.appHost().issueMenuWindowRequest(kind, fromWindow: false)
            XCTAssertTrue(controller.wasIssued(withoutWindow), "\(kind) with no window")
        }
        XCTAssertFalse(controller.wasIssued(BrowserWindowRequest(kind: .incognito)), "a value from elsewhere still restores")
    }

    /// Requests issued through an incognito window's controller are recorded where the scene
    /// checks them (the app's controller), and the installed opener does not keep the incognito
    /// controller alive after its window closed.
    func testIncognitoWindowOpenerRecordsOnParentAndDoesNotRetain() {
        let f = SidebarFixture()
        let controller = makeController(f)
        var opened: [BrowserWindowRequest] = []
        weak var released: WorkspaceController?
        do {
            let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
            incognito.controller.installWindowOpener { opened.append($0) }
            let request = BrowserWindowRequest(kind: .newWindow)
            incognito.controller.openBrowserWindow?(request)
            XCTAssertEqual(opened, [request])
            XCTAssertTrue(controller.wasIssued(request), "recorded on the app's controller")
            released = incognito.controller
            incognito.windowDidClose()
        }
        XCTAssertNil(released, "the closed incognito window's controller is released")
    }

    // MARK: Profile settings in incognito

    /// An incognito window searches with its profile's engine. [03 §Profiles] observed per-profile
    /// search engine; following it in incognito is inferred.
    func testIncognitoWindowUsesTheProfileSearchEngine() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let regular = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.home))
        addTeardownBlock { @MainActor in regular.stop() }
        var settings = ProfileSettings.default
        settings.searchEngine = .bing
        XCTAssertTrue(controller.updateProfileSettings(f.profile, settings))

        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        XCTAssertEqual(regular.searchURL(for: "q")?.host, "www.bing.com")
        XCTAssertEqual(incognito.searchURL(for: "q")?.host, "www.bing.com")
    }
}
