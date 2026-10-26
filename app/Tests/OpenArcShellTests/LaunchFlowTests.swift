import Foundation
import AppKit
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Collects autosave work; tests fire it by hand (or never) instead of sleeping.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class HeldSaveScheduler: AutosaveScheduling, @unchecked Sendable {
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

/// A sync store that records what it is asked to enqueue.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class RecordingSyncStore: SyncStore, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[PendingChange]] = []

    var enqueued: [PendingChange] { lock.withLock { batches.flatMap { $0 } } }

    func start(database: any SyncLocalDatabase) async throws {}
    func stop() async {}
    func enqueue(_ changes: [PendingChange]) async { lock.withLock { batches.append(changes) } }
    func syncNow() async throws {}
    func resetLocalSyncState() async {}
    func currentStatus() async -> SyncStatus { .disabled }
    func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { $0.yield(.disabled); $0.finish() }
    }
}

/// B2 launch flow: first launch, relaunch restore, read-only refusal, sync forwarding and the
/// termination flush. The restore behavior is inferred (the spec records no launch behavior);
/// the default profile name is [03 §Profiles] observed.
@MainActor
final class LaunchFlowTests: XCTestCase {
    /// A unique directory under app/.build/b2-tmp, removed after each test.
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b2-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let clock = Date(timeIntervalSince1970: 1_000)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var workspaceFile: URL { directory.appendingPathComponent(PersistenceDefaults.workspaceFileName) }
    private var uiStateFile: URL { UIStateFile.url(in: directory) }

    private func makeStore(_ scheduler: HeldSaveScheduler = HeldSaveScheduler()) -> WorkspaceStore {
        WorkspaceStore(directory: directory, scheduler: scheduler, now: { [clock] in clock })
    }

    private func makeModel(
        _ store: WorkspaceStore,
        sync: any SyncStore = DisabledSyncStore(),
        workspace: WorkspaceState? = nil,
        center: NotificationCenter = NotificationCenter()
    ) -> ShellModel {
        // These tests check change forwarding, not the one-time full upload of a first sync start
        // (covered in SyncUITests), so the full upload is marked as done.
        let preferences = AppPreferences.inMemory()
        preferences.needsFullSyncUpload = false
        let deps = AppDependencies(engine: FakeEngine(), sync: sync, persistence: store, preferences: preferences)
        let now = clock
        let model = ShellModel(
            dependencies: deps,
            workspace: workspace ?? .firstLaunch(now: now),
            now: { now },
            notificationCenter: center
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    // MARK: Data directory

    func testDataDirectoryDefaultsToApplicationSupport() {
        XCTAssertEqual(AppDataLocation.directory(environment: [:]), PersistenceDefaults.defaultDirectory)
        XCTAssertEqual(AppDataLocation.directory(environment: ["OPENARC_DATA_DIR": "  "]), PersistenceDefaults.defaultDirectory)
    }

    func testDataDirectoryEnvironmentOverride() {
        let url = AppDataLocation.directory(environment: ["OPENARC_DATA_DIR": "/tmp/openarc-dev"])
        XCTAssertEqual(url.path, "/tmp/openarc-dev")
        let home = AppDataLocation.directory(environment: ["OPENARC_DATA_DIR": "~/oa"])
        XCTAssertEqual(home.path, (NSHomeDirectory() as NSString).appendingPathComponent("oa"))
    }

    // MARK: First launch

    /// [03 §Profiles] observed: the built-in profile is "Default". One Space, a theme, no tabs.
    func testFirstLaunchWorkspaceShape() {
        let ws = WorkspaceState.firstLaunch(now: clock)
        XCTAssertEqual(ws.profiles.values.map(\.name), ["Default"])
        XCTAssertEqual(ws.allLiveSpaces.count, 1)
        let space = ws.allLiveSpaces[0]
        XCTAssertEqual(space.profileID, ws.profiles.keys.first)
        XCTAssertNotNil(space.themeID.flatMap { ws.themes[$0] }, "the Space has a default theme")
        XCTAssertTrue(ws.tabs.isEmpty)
        XCTAssertTrue(ws.folders.isEmpty)
    }

    func testFirstLaunchCreatesDefaultProfileAndSpaceAndWritesFile() async throws {
        let scheduler = HeldSaveScheduler()
        let store = makeStore(scheduler)
        XCTAssertEqual(store.loadResult.outcome, .noFile)
        let model = makeModel(store)
        XCTAssertEqual(model.workspace.profiles.values.map(\.name), ["Default"])
        XCTAssertEqual(model.workspace.allLiveSpaces.count, 1)
        XCTAssertEqual(model.selectedSpaceID, model.workspace.allLiveSpaces.first?.id)
        XCTAssertNil(model.selectedTabID)
        XCTAssertNil(model.launchNotice)

        let expected = model.workspace
        await eventually { await store.workspace == expected }
        await scheduler.fireAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceFile.path))
        XCTAssertEqual(makeStore().loadResult.workspace, expected)
    }

    /// A loaded file wins over the first-launch default: no second "Default" profile appears.
    func testRelaunchDoesNotCreateASecondDefaultWorkspace() async throws {
        let first = makeModel(makeStore())
        try await first.flushPersistence()
        let saved = first.workspace
        let relaunched = makeModel(makeStore())
        XCTAssertEqual(relaunched.workspace, saved)
        XCTAssertEqual(relaunched.workspace.profiles.count, 1)
    }

    // MARK: Relaunch restore

    func testRelaunchRestoresWorkspaceSelectionAndSidebarVisibility() async throws {
        let f = SidebarFixture()
        let first = makeModel(makeStore(), workspace: f.ws)
        first.selectSpace(f.work)
        first.sidebar.selectTab(f.workTab)
        await first.sidebar.settleEngineWork()
        first.toggleSidebar()
        XCTAssertFalse(first.isSidebarVisible)
        try await first.flushPersistence()
        let saved = first.workspace
        XCTAssertTrue(FileManager.default.fileExists(atPath: uiStateFile.path))

        // The default passed in is ignored because the file loads. (Restoring the tab selects it,
        // which stamps its activity, so compare what was loaded, not the live value.)
        let store = makeStore()
        XCTAssertEqual(store.loadResult.workspace, saved)
        let relaunched = makeModel(store, workspace: .firstLaunch(now: clock))
        XCTAssertEqual(Set(relaunched.workspace.tabs.keys), Set(saved.tabs.keys))
        XCTAssertNil(relaunched.workspace.profiles.values.first { $0.id != f.profile })
        XCTAssertEqual(relaunched.selectedSpaceID, f.work)
        XCTAssertEqual(relaunched.selectedTabID, f.workTab)
        XCTAssertFalse(relaunched.isSidebarVisible)
    }

    /// The UI state is per device: it never becomes a sync record.
    func testUIStateIsNotPartOfTheSyncedWorkspace() async throws {
        let f = SidebarFixture()
        let recorder = RecordingSyncStore()
        let model = makeModel(makeStore(), sync: recorder, workspace: f.ws)
        let before = model.workspace
        model.toggleSidebar()
        try await model.flushPersistence()
        XCTAssertEqual(model.workspace, before, "hiding the sidebar does not touch the workspace")
        let envelope = try String(contentsOf: workspaceFile, encoding: .utf8)
        XCTAssertFalse(envelope.contains("isSidebarVisible"))
    }

    func testStaleSelectionIDsAreIgnored() async throws {
        let f = SidebarFixture()
        let first = makeModel(makeStore(), workspace: f.ws)
        try await first.flushPersistence()
        try UIStateFile.save(UIState(selectedSpaceID: UUID(), selectedTabID: UUID(), isSidebarVisible: true), to: directory)

        let relaunched = makeModel(makeStore())
        XCTAssertEqual(relaunched.selectedSpaceID, relaunched.workspace.allLiveSpaces.first?.id)
        XCTAssertNil(relaunched.selectedTabID)
    }

    /// An archived tab, or a tab in another Space than the restored one, is not selected.
    func testArchivedOrForeignTabIsNotRestored() async throws {
        let f = SidebarFixture()
        var ws = f.ws
        ws = try TreeOps.archiveTab(ws, id: f.today1, now: clock)
        let first = makeModel(makeStore(), workspace: ws)
        try await first.flushPersistence()

        try UIStateFile.save(UIState(selectedSpaceID: f.home, selectedTabID: f.today1), to: directory)
        let archived = makeModel(makeStore())
        XCTAssertEqual(archived.selectedSpaceID, f.home)
        XCTAssertNil(archived.selectedTabID)

        try UIStateFile.save(UIState(selectedSpaceID: f.home, selectedTabID: f.workTab), to: directory)
        let foreign = makeModel(makeStore())
        XCTAssertEqual(foreign.selectedSpaceID, f.home)
        XCTAssertNil(foreign.selectedTabID)
    }

    // MARK: Read-only store

    func testNewerSchemaShowsNoticeOnceAndNeverWrites() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data(#"{"schemaVersion": 999, "savedAt": 0, "workspace": {}}"#.utf8)
        try original.write(to: workspaceFile)

        let store = makeStore()
        XCTAssertTrue(store.isReadOnly)
        let recorder = RecordingSyncStore()
        let model = makeModel(store, sync: recorder)
        let notice = try XCTUnwrap(model.launchNotice)
        XCTAssertTrue(notice.message.contains("newer version"))
        XCTAssertTrue(notice.message.contains("will not be saved"))
        // The app still runs on the first-launch workspace, in memory.
        XCTAssertEqual(model.workspace.profiles.values.map(\.name), ["Default"])
        XCTAssertNotNil(model.selectedSpaceID)

        model.dismissLaunchNotice()
        XCTAssertNil(model.launchNotice)

        _ = model.sidebar.createFolder(title: "Unsaved")
        model.flushForTermination()
        XCTAssertEqual(try Data(contentsOf: workspaceFile), original, "the newer file is never overwritten")
        XCTAssertFalse(FileManager.default.fileExists(atPath: uiStateFile.path))
        XCTAssertTrue(recorder.enqueued.isEmpty, "nothing from a read-only store is sent to sync")
    }

    // MARK: Sync wiring

    func testLocalChangesReachSyncStoreEnqueue() async throws {
        let recorder = RecordingSyncStore()
        let model = makeModel(makeStore(), sync: recorder)
        let ws = model.workspace
        // First launch: the default records are announced too.
        let profileID = try XCTUnwrap(ws.profiles.keys.first)
        let spaceID = try XCTUnwrap(ws.allLiveSpaces.first?.id)
        await eventually {
            Set(recorder.enqueued).isSuperset(of: [
                .save(SyncRecordID(type: .profile, uuid: profileID)),
                .save(SyncRecordID(type: .space, uuid: spaceID)),
            ])
        }

        let folder = try XCTUnwrap(model.sidebar.createFolder(title: "Synced"))
        await eventually { recorder.enqueued.contains(.save(SyncRecordID(type: .folder, uuid: folder))) }
    }

    /// Nothing is announced for a relaunch that changes nothing.
    func testRelaunchWithoutChangesEnqueuesNothing() async throws {
        let first = makeModel(makeStore())
        try await first.flushPersistence()
        let recorder = RecordingSyncStore()
        let relaunched = makeModel(makeStore(), sync: recorder)
        let folder = try XCTUnwrap(relaunched.sidebar.createFolder(title: "Later"))
        await eventually { recorder.enqueued.contains(.save(SyncRecordID(type: .folder, uuid: folder))) }
        XCTAssertEqual(recorder.enqueued, [.save(SyncRecordID(type: .folder, uuid: folder))])
    }

    // MARK: Termination

    func testWillTerminateFlushesImmediately() async throws {
        let center = NotificationCenter()
        let scheduler = HeldSaveScheduler()
        let store = makeStore(scheduler)
        let model = makeModel(store, center: center)
        let folder = try XCTUnwrap(model.sidebar.createFolder(title: "Last edit"))
        model.toggleSidebar()

        // The autosave never fires; the notification alone must write.
        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertEqual(makeStore().loadResult.workspace.folders[folder]?.title, "Last edit")
        XCTAssertEqual(makeStore().loadResult.workspace, model.workspace)
        XCTAssertEqual(UIStateFile.load(from: directory)?.isSidebarVisible, false)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)
    }

    func testStoppedModelIgnoresWillTerminate() throws {
        let center = NotificationCenter()
        let model = makeModel(makeStore(), center: center)
        model.stop()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspaceFile.path))
    }

    private func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met", file: file, line: line)
    }
}

/// Engine selection at launch: Chromium is the default (user decision 2026-10-25) and gets
/// `<data dir>/Chromium` as its user data directory; `OPENARC_ENGINE=fake`, or a build without
/// Chromium, uses FakeEngine.
final class EngineChoiceTests: XCTestCase {
    func testEngineChoiceFromEnvironment() {
        XCTAssertEqual(EngineChoice.from(environment: [:]), .chromium)
        XCTAssertEqual(EngineChoice.from(environment: ["OPENARC_ENGINE": " Fake "]), .fake)
        XCTAssertEqual(EngineChoice.from(environment: ["OPENARC_ENGINE": " Chromium "]), .chromium)
    }

    func testChromiumFactoryGetsEngineDirectoryUnderDataDirectory() {
        let dataDirectory = URL(fileURLWithPath: "/tmp/openarc-engine-choice", isDirectory: true)
        let made = FakeEngine()
        var received: URL?
        let chosen = AppDependencies.engine(
            environment: ["OPENARC_ENGINE": "chromium"], dataDirectory: dataDirectory,
            makeChromiumEngine: { received = $0; return made }
        )
        XCTAssertTrue(chosen === made)
        XCTAssertEqual(received?.standardizedFileURL, dataDirectory.appendingPathComponent("Chromium", isDirectory: true).standardizedFileURL)

        XCTAssertTrue(
            AppDependencies.engine(environment: [:], dataDirectory: dataDirectory, makeChromiumEngine: { _ in made }) === made
        )
        XCTAssertFalse(
            AppDependencies.engine(environment: ["OPENARC_ENGINE": "fake"], dataDirectory: dataDirectory, makeChromiumEngine: { _ in made }) === made
        )
        XCTAssertTrue(
            AppDependencies.engine(environment: ["OPENARC_ENGINE": "chromium"], dataDirectory: dataDirectory, makeChromiumEngine: nil)
                is FakeEngine
        )
    }
}
