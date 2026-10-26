import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// A sync store that records every call and reports a scripted list of statuses (then finishes,
/// so tests that read the status stream stay bounded).
private actor RecordingSyncStore: SyncStore {
    enum Call: Equatable {
        case start, stop, enqueue([PendingChange]), syncNow, reset
    }

    struct Failure: Error, LocalizedError {
        var errorDescription: String? { "offline" }
    }

    private(set) var calls: [Call] = []
    private var startFails = false
    private var syncNowFails = false
    nonisolated let scripted: [SyncStatus]

    init(statuses: [SyncStatus] = [SyncStatus(phase: .idle)]) {
        scripted = statuses
    }

    func failStart(_ fails: Bool) { startFails = fails }
    func failSyncNow(_ fails: Bool) { syncNowFails = fails }

    func start(database: any SyncLocalDatabase) async throws {
        calls.append(.start)
        if startFails { throw Failure() }
    }
    func stop() async { calls.append(.stop) }
    func enqueue(_ changes: [PendingChange]) async { calls.append(.enqueue(changes)) }
    func syncNow() async throws {
        calls.append(.syncNow)
        if syncNowFails { throw Failure() }
    }
    func resetLocalSyncState() async { calls.append(.reset) }
    func currentStatus() async -> SyncStatus { scripted.last ?? .disabled }
    nonisolated func statusUpdates() -> AsyncStream<SyncStatus> {
        let statuses = scripted
        return AsyncStream { continuation in
            statuses.forEach { continuation.yield($0) }
            continuation.finish()
        }
    }

    /// Calls other than `enqueue`, to check start/stop order.
    var lifecycle: [Call] {
        calls.filter { if case .enqueue = $0 { return false } else { return true } }
    }

    var enqueued: [PendingChange] {
        calls.flatMap { call -> [PendingChange] in
            if case .enqueue(let changes) = call { return changes } else { return [] }
        }
    }
}

/// A local database that holds nothing (the controller only passes it to `start`).
private actor NullDatabase: SyncLocalDatabase {
    func record(for id: SyncRecordID) async -> SyncRecord? { nil }
    func apply(_ batch: RemoteChangeBatch) async throws {}
    func loadSyncState() async -> Data? { nil }
    func saveSyncState(_ data: Data?) async {}
}

/// D5: the sync UI. [03 §账号卡] observed: the "Sync Sidebar" toggle and the
/// "Last synced: <time>" line; launch and toggle behavior, the other card states and the relative
/// time format are inferred.
@MainActor
final class SyncUITests: XCTestCase {
    private let clock = Date(timeIntervalSince1970: 1_000_000)
    private let recordA = SyncRecordID(type: .folder, uuid: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
    private let recordB = SyncRecordID(type: .tab, uuid: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)

    /// A unique directory under app/.build/d5-tmp, removed after each test.
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/d5-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(
        _ store: any SyncStore,
        preferences: AppPreferences = .inMemory(),
        database: (any SyncLocalDatabase)? = NullDatabase(),
        now: Date? = nil
    ) -> SidebarSyncController {
        let ids = [recordA, recordB]
        let fixed = now ?? clock
        return SidebarSyncController(
            store: store, database: database, preferences: preferences,
            allRecordIDs: { ids }, now: { fixed }
        )
    }

    // MARK: Launch reads "Sync Sidebar"

    func testLaunchStartsStoreWhenSyncSidebarIsOn() async {
        let store = RecordingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        let lifecycle = await store.lifecycle
        XCTAssertEqual(lifecycle, [.start])
        XCTAssertTrue(sync.isRunning)
    }

    func testLaunchDoesNotStartWhenSyncSidebarIsOff() async {
        let store = RecordingSyncStore()
        let preferences = AppPreferences.inMemory()
        preferences.isSidebarSyncEnabled = false
        let sync = makeController(store, preferences: preferences)
        sync.launch()
        await sync.settle()
        let calls = await store.calls
        XCTAssertEqual(calls, [])
        XCTAssertFalse(sync.isRunning)
        XCTAssertEqual(sync.card.statusLine, "Sync is off.")
    }

    /// Without a database (no on-disk store, or a read-only one) there is nothing to sync.
    func testLaunchWithoutDatabaseDoesNotStart() async {
        let store = RecordingSyncStore()
        let sync = makeController(store, database: nil)
        sync.launch()
        await sync.settle()
        let calls = await store.calls
        XCTAssertEqual(calls, [])
    }

    /// The app's launch path: the controller reads the preference and starts against the store.
    func testWorkspaceControllerLaunchRespectsPreference() async throws {
        for isOn in [true, false] {
            let store = RecordingSyncStore()
            let preferences = AppPreferences.inMemory()
            preferences.isSidebarSyncEnabled = isOn
            let persistence = WorkspaceStore(directory: directory.appendingPathComponent("\(isOn)"))
            let deps = AppDependencies(engine: FakeEngine(), sync: store, persistence: persistence, preferences: preferences)
            let now = clock
            let controller = WorkspaceController(dependencies: deps, workspace: .firstLaunch(now: now), now: { now }, notificationCenter: NotificationCenter())
            await controller.sidebarSync.settle()
            let lifecycle = await store.lifecycle
            XCTAssertEqual(lifecycle, isOn ? [.start] : [], "Sync Sidebar \(isOn)")
            controller.stop()
        }
    }

    /// With `DisabledSyncStore` nothing happens: no start, the toggle does nothing.
    func testDisabledStoreNeverStarts() async {
        let preferences = AppPreferences.inMemory()
        let sync = makeController(DisabledSyncStore(), preferences: preferences)
        sync.launch()
        sync.setEnabled(false)
        await sync.settle()
        XCTAssertFalse(sync.isRunning)
        XCTAssertFalse(sync.isEnabled)
        XCTAssertTrue(preferences.isSidebarSyncEnabled, "the choice is not stored without a backend")
        XCTAssertEqual(sync.card, SyncCardState(isToggleEnabled: false, statusLine: "iCloud sync is not available in this version.", isWarning: false))
    }

    // MARK: Toggle at runtime

    /// A start still queued when the toggle goes off does nothing.
    func testToggleOffBeforeQueuedStartSkipsIt() async {
        let store = RecordingSyncStore()
        let sync = makeController(store)
        sync.launch()
        sync.setEnabled(false)
        await sync.settle()
        let lifecycle = await store.lifecycle
        XCTAssertEqual(lifecycle, [.stop])
        XCTAssertFalse(sync.isRunning)
    }

    func testToggleOffStopsAndOnStartsAgain() async {
        let store = RecordingSyncStore()
        let preferences = AppPreferences.inMemory()
        let sync = makeController(store, preferences: preferences)
        sync.launch()
        sync.setEnabled(false)
        XCTAssertFalse(preferences.isSidebarSyncEnabled)
        sync.setEnabled(true)
        await sync.settle()
        let lifecycle = await store.lifecycle
        XCTAssertEqual(lifecycle, [.start, .stop, .start], "calls keep their order")
        XCTAssertTrue(preferences.isSidebarSyncEnabled)
        XCTAssertTrue(sync.isRunning)
    }

    /// Settings' toggle goes through the same controller.
    func testSettingsToggleStopsAndStartsStore() async {
        let store = RecordingSyncStore()
        let persistence = WorkspaceStore(directory: directory)
        let deps = AppDependencies(engine: FakeEngine(), sync: store, persistence: persistence)
        let now = clock
        let shell = ShellModel(dependencies: deps, workspace: .firstLaunch(now: now), now: { now }, notificationCenter: NotificationCenter())
        defer { shell.stop() }
        let settings = SettingsModel(shell: shell)
        XCTAssertTrue(settings.isSidebarSyncOn)
        settings.setSidebarSync(false)
        XCTAssertFalse(settings.isSidebarSyncOn)
        settings.setSidebarSync(true)
        await settings.sync.settle()
        let lifecycle = await store.lifecycle
        XCTAssertEqual(lifecycle, [.start, .stop, .start])
    }

    /// Changes are forwarded only while sync runs; the changes missed while it was off are
    /// covered by one full upload at the next start.
    func testChangesWhileOffAreUploadedOnceAfterRestart() async {
        let store = RecordingSyncStore()
        let preferences = AppPreferences.inMemory()
        preferences.needsFullSyncUpload = false
        let sync = makeController(store, preferences: preferences)
        sync.launch()
        sync.forward([.save(recordA)])
        await sync.settle()
        sync.setEnabled(false)
        sync.forward([.save(recordB)])
        await sync.settle()
        var enqueued = await store.enqueued
        XCTAssertEqual(enqueued, [.save(recordA)], "nothing reaches a stopped store")
        XCTAssertTrue(preferences.needsFullSyncUpload)

        sync.setEnabled(true)
        await sync.settle()
        enqueued = await store.enqueued
        XCTAssertEqual(enqueued, [.save(recordA), .save(recordA), .save(recordB)])
        XCTAssertFalse(preferences.needsFullSyncUpload)
    }

    /// The first start on a device uploads every record (the preference defaults to true).
    func testFirstStartUploadsEveryRecord() async {
        let store = RecordingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        let enqueued = await store.enqueued
        XCTAssertEqual(enqueued, [.save(recordA), .save(recordB)])
    }

    // MARK: Sync Now

    /// [03 §账号卡]: no "Sync Now" item is listed in `01` or `03`; the card offers it after a
    /// failure (inferred) and it calls `syncNow`.
    func testSyncNowCallsStore() async {
        let store = RecordingSyncStore()
        let sync = makeController(store)
        sync.syncNow()
        await sync.settle()
        let calls = await store.calls
        XCTAssertEqual(calls, [.syncNow])
        XCTAssertNil(sync.actionError)
    }

    func testSettingsCardButtonCallsSyncNow() async {
        let store = RecordingSyncStore(statuses: [SyncStatus(phase: .failed(message: "offline"))])
        let deps = AppDependencies(engine: FakeEngine(), sync: store)
        let now = clock
        let shell = ShellModel(dependencies: deps, workspace: .demo(now: now), now: { now })
        defer { shell.stop() }
        let settings = SettingsModel(shell: shell)
        await settings.observeSync()
        XCTAssertEqual(settings.syncCard.action, .syncNow)
        settings.performSyncAction(.syncNow)
        await settings.sync.settle()
        let calls = await store.calls
        XCTAssertEqual(calls, [.syncNow])
    }

    func testFailedSyncNowShowsErrorAndRetryButton() async {
        let store = RecordingSyncStore()
        await store.failSyncNow(true)
        let sync = makeController(store)
        await sync.observeStatus()  // idle
        sync.syncNow()
        await sync.settle()
        XCTAssertEqual(sync.actionError, "offline")
        XCTAssertEqual(sync.card.action, .syncNow)
        XCTAssertTrue(sync.card.isWarning)
        XCTAssertEqual(sync.card.statusLine, "Sync failed: offline. Not synced yet")

        await store.failSyncNow(false)
        sync.syncNow()
        await sync.settle()
        XCTAssertNil(sync.actionError)
        XCTAssertEqual(sync.card.statusLine, "Not synced yet")
    }

    func testStartFailureShowsErrorAndKeepsFullUpload() async {
        let store = RecordingSyncStore(statuses: [])
        await store.failStart(true)
        let preferences = AppPreferences.inMemory()
        preferences.needsFullSyncUpload = false
        let sync = makeController(store, preferences: preferences)
        sync.launch()
        await sync.settle()
        XCTAssertFalse(sync.isRunning)
        XCTAssertTrue(preferences.needsFullSyncUpload)
        XCTAssertEqual(sync.card.action, .syncNow)
        XCTAssertEqual(sync.card.statusLine, "Sync failed: offline. Not synced yet")
    }

    /// After an account switch the card offers to sync with the new account: reset, then upload all.
    func testUseNewAccountResetsAndUploadsEverything() async {
        let store = RecordingSyncStore(statuses: [SyncStatus(phase: .unavailable(.accountChanged))])
        let sync = makeController(store)
        await sync.observeStatus()
        XCTAssertEqual(sync.card.action, .useNewAccount)
        sync.resumeAfterAccountChange()
        await sync.settle()
        let calls = await store.calls
        XCTAssertEqual(calls, [.reset, .enqueue([.save(recordA), .save(recordB)])])
    }

    // MARK: Card states [03 §账号卡]

    func testEveryCardStateText() {
        let make = { (status: SyncStatus, isOn: Bool) in
            SyncCardState.make(status: status, backendAvailable: true, isSyncOn: isOn, formatDate: { _ in "5 minutes ago" })
        }
        let synced = clock
        let cases: [(SyncStatus, Bool, SyncCardState)] = [
            (SyncStatus(phase: .idle), false,
             SyncCardState(isToggleEnabled: true, statusLine: "Sync is off.", isWarning: false)),
            (SyncStatus(phase: .unavailable(.noAccount)), true,
             SyncCardState(isToggleEnabled: true, statusLine: "Sign in to iCloud in System Settings to sync your sidebar.", isWarning: true)),
            (SyncStatus(phase: .unavailable(.restricted)), true,
             SyncCardState(isToggleEnabled: false, statusLine: "iCloud is restricted on this Mac.", isWarning: true)),
            (SyncStatus(phase: .unavailable(.accountChanged)), true,
             SyncCardState(isToggleEnabled: true, statusLine: "The iCloud account changed. Sync is paused.", isWarning: true, action: .useNewAccount)),
            (SyncStatus(phase: .unavailable(.temporarilyUnavailable), lastSyncedAt: synced), true,
             SyncCardState(isToggleEnabled: true, statusLine: "iCloud is temporarily unavailable. Last synced: 5 minutes ago", isWarning: true)),
            (SyncStatus(phase: .unavailable(.notConfigured)), true,
             SyncCardState(isToggleEnabled: true, statusLine: "This build of Open Arc is not set up for iCloud.", isWarning: true)),
            (SyncStatus(phase: .syncing), true,
             SyncCardState(isToggleEnabled: true, statusLine: "Syncing…", isWarning: false)),
            (SyncStatus(phase: .idle, lastSyncedAt: synced), true,
             SyncCardState(isToggleEnabled: true, statusLine: "Last synced: 5 minutes ago", isWarning: false)),
            (SyncStatus(phase: .idle), true,
             SyncCardState(isToggleEnabled: true, statusLine: "Not synced yet", isWarning: false)),
            (SyncStatus(phase: .failed(message: "CloudKit error 4"), lastSyncedAt: synced), true,
             SyncCardState(isToggleEnabled: true, statusLine: "Sync failed: CloudKit error 4. Last synced: 5 minutes ago", isWarning: true, action: .syncNow)),
            (.disabled, true,
             SyncCardState(isToggleEnabled: true, statusLine: "Starting sync…", isWarning: false)),
        ]
        for (status, isOn, expected) in cases {
            XCTAssertEqual(make(status, isOn), expected, "\(status.phase) on=\(isOn)")
        }
        XCTAssertEqual(SyncCardState.Action.syncNow.title, "Sync Now")
    }

    /// The card follows the status stream and formats "Last synced" relative to the injected clock.
    func testCardFollowsStatusWithRelativeTime() async {
        let synced = clock.addingTimeInterval(-2 * 3600)
        let store = RecordingSyncStore(statuses: [SyncStatus(phase: .syncing), SyncStatus(phase: .idle, lastSyncedAt: synced)])
        let sync = makeController(store)
        await sync.observeStatus()
        XCTAssertEqual(sync.status.phase, .idle)
        XCTAssertEqual(sync.card.statusLine, "Last synced: 2 hours ago")
    }

    // MARK: Relative time

    func testRelativeTimeWithFixedClock() {
        let now = clock
        let absolute: (Date) -> String = { _ in "ABS" }
        func text(_ secondsAgo: TimeInterval) -> String {
            SyncTimeFormat.relative(now.addingTimeInterval(-secondsAgo), now: now, absolute: absolute)
        }
        XCTAssertEqual(text(0), "just now")
        XCTAssertEqual(text(59), "just now")
        XCTAssertEqual(text(-30), "just now", "a time in the future (clock skew)")
        XCTAssertEqual(text(60), "1 minute ago")
        XCTAssertEqual(text(5 * 60 + 10), "5 minutes ago")
        XCTAssertEqual(text(3600), "1 hour ago")
        XCTAssertEqual(text(23 * 3600), "23 hours ago")
        XCTAssertEqual(text(86_400), "1 day ago")
        XCTAssertEqual(text(6 * 86_400), "6 days ago")
        XCTAssertEqual(text(7 * 86_400), "ABS")
    }

    // MARK: Backend choice

    func testSyncBackendSwitch() {
        XCTAssertEqual(SyncBackendChoice.from(environment: [:]), .disabled)
        XCTAssertEqual(SyncBackendChoice.from(environment: ["OPENARC_SYNC": "off"]), .disabled)
        XCTAssertEqual(SyncBackendChoice.from(environment: ["OPENARC_SYNC": " CloudKit "]), .cloudKit)

        let recording = RecordingSyncStore()
        XCTAssertTrue(AppDependencies.syncStore(environment: [:], makeCloudKitStore: { recording }) is DisabledSyncStore)
        XCTAssertTrue(AppDependencies.syncStore(environment: ["OPENARC_SYNC": "cloudkit"], makeCloudKitStore: { recording }) === recording)
        XCTAssertTrue(AppDependencies.syncStore(environment: ["OPENARC_SYNC": "cloudkit"], makeCloudKitStore: nil) is DisabledSyncStore)
    }

    // MARK: Remote changes

    /// A batch the sync store applies to the persistence store shows up in the workspace.
    func testRemoteBatchReachesWorkspace() async throws {
        let store = RecordingSyncStore()
        let persistence = WorkspaceStore(directory: directory)
        let deps = AppDependencies(engine: FakeEngine(), sync: store, persistence: persistence)
        let now = clock
        let controller = WorkspaceController(dependencies: deps, workspace: .firstLaunch(now: now), now: { now }, notificationCenter: NotificationCenter())
        defer { controller.stop() }
        let spaceID = try XCTUnwrap(controller.workspace.allLiveSpaces.first?.id)
        let folderID = UUID()
        let remote = try TreeOps.createFolder(controller.workspace, id: folderID, spaceID: spaceID, title: "From another Mac", now: now)
        let folder = try XCTUnwrap(remote.folders[folderID])
        // Let the forwarding task subscribe before the batch is applied.
        await controller.sidebarSync.settle()
        for _ in 0..<200 { await Task.yield() }
        try await persistence.apply(RemoteChangeBatch(upserts: [.folder(folder)]))
        for _ in 0..<2_000 where controller.workspace.folders[folderID] == nil { await Task.yield() }
        XCTAssertEqual(controller.workspace.folders[folderID]?.title, "From another Mac")
    }
}
