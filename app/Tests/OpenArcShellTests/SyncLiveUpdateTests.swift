import AppKit
import XCTest
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// A sync store that counts calls; its status is fixed (no stream needed here).
private actor CountingSyncStore: SyncStore {
    private(set) var starts = 0
    private(set) var syncNows = 0
    private var phase: SyncStatus.Phase = .idle

    func setPhase(_ phase: SyncStatus.Phase) { self.phase = phase }
    func start(database: any SyncLocalDatabase) async throws { starts += 1 }
    func stop() async {}
    func enqueue(_ changes: [PendingChange]) async {}
    func syncNow() async throws { syncNows += 1 }
    func resetLocalSyncState() async {}
    func currentStatus() async -> SyncStatus { SyncStatus(phase: phase) }
    nonisolated func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { $0.finish() }
    }
}

private actor EmptyDatabase: SyncLocalDatabase {
    func record(for id: SyncRecordID) async -> SyncRecord? { nil }
    func apply(_ batch: RemoteChangeBatch) async throws {}
    func loadSyncState() async -> Data? { nil }
    func saveSyncState(_ data: Data?) async {}
}

/// Main-actor clock the tests move by hand.
@MainActor
private final class ManualClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// Main-actor counter for the registration callback.
@MainActor
private final class Counter {
    var value = 0
}

/// B65: live sync while the app runs. Our own design (inferred): register for CloudKit pushes once
/// sync starts, fetch on a forwarded push, and fetch on activation at most once per 60 s.
@MainActor
final class SyncLiveUpdateTests: XCTestCase {
    private var center = NotificationCenter()
    private let clock = ManualClock()
    private let registrations = Counter()

    private func makeController(
        _ store: CountingSyncStore,
        isOn: Bool = true,
        registers: Bool = true
    ) -> SidebarSyncController {
        let preferences = AppPreferences.inMemory()
        preferences.isSidebarSyncEnabled = isOn
        let clock = self.clock, registrations = self.registrations
        let register: (@MainActor @Sendable () -> Void)? = registers ? { @MainActor in registrations.value += 1 } : nil
        return SidebarSyncController(
            store: store, database: EmptyDatabase(), preferences: preferences,
            allRecordIDs: { [] }, now: { clock.now },
            notificationCenter: center,
            registerForRemoteNotifications: register
        )
    }

    private func activate() { center.post(name: NSApplication.didBecomeActiveNotification, object: nil) }
    private func push() { center.post(name: SidebarSyncController.remoteChangeNotification, object: nil) }

    // MARK: Throttle

    func testThrottleAllowsFirstActivationAndPushesAlways() {
        let t0 = Date(timeIntervalSince1970: 0)
        var throttle = SyncFetchThrottle(minimumInterval: 60)
        XCTAssertTrue(throttle.allows(.activation, at: t0), "no fetch yet")
        throttle.noteFetch(at: t0)
        XCTAssertFalse(throttle.allows(.activation, at: t0.addingTimeInterval(59.9)))
        XCTAssertTrue(throttle.allows(.activation, at: t0.addingTimeInterval(60)))
        XCTAssertTrue(throttle.allows(.remoteNotification, at: t0.addingTimeInterval(1)), "pushes are not throttled")
        XCTAssertTrue(throttle.allows(.activation, at: t0.addingTimeInterval(-10)), "a clock set back does not block")
        XCTAssertEqual(SyncFetchThrottle.activationInterval, 60)
    }

    // MARK: Registration

    func testFirstStartRegistersForRemoteNotificationsOnce() async {
        let store = CountingSyncStore()
        let sync = makeController(store)
        XCTAssertEqual(registrations.value, 0, "nothing before the store starts")
        sync.launch()
        await sync.settle()
        XCTAssertEqual(registrations.value, 1)
        sync.setEnabled(false)
        sync.setEnabled(true)
        await sync.settle()
        let starts = await store.starts
        XCTAssertEqual(starts, 2)
        XCTAssertEqual(registrations.value, 1, "registered once per run")
    }

    func testSyncOffNeverRegisters() async {
        let sync = makeController(CountingSyncStore(), isOn: false)
        sync.launch()
        await sync.settle()
        XCTAssertEqual(registrations.value, 0)
    }

    func testDependenciesWireRegistrationIntoWorkspaceController() async {
        let store = CountingSyncStore()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("b65-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var deps = AppDependencies(engine: FakeEngine(), sync: store, persistence: WorkspaceStore(directory: directory), preferences: .syncOn())
        let registrations = self.registrations
        deps.registerForRemoteNotifications = { registrations.value += 1 }
        let now = clock.now
        let controller = WorkspaceController(dependencies: deps, workspace: .firstLaunch(now: now), now: { now }, notificationCenter: center)
        defer { controller.stop() }
        await controller.sidebarSync.settle()
        XCTAssertEqual(registrations.value, 1)
        // The controller's sync observes the injected center.
        push()
        await controller.sidebarSync.settle()
        let syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 1)
    }

    // MARK: Push

    func testPushFetchesWhileRunning() async {
        let store = CountingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        push()
        await sync.settle()
        push()
        await sync.settle()
        let syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 2, "every push fetches, even right after start")
    }

    func testAppDelegateForwardsRemoteNotification() async {
        // The delegate posts on the default center; this controller listens there.
        center = .default
        let store = CountingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        OpenArcAppDelegate().application(NSApplication.shared, didReceiveRemoteNotification: ["ck": [String: Any]()])
        await sync.settle()
        let syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 1)
    }

    // MARK: Activation

    func testActivationFetchIsRateLimited() async {
        let store = CountingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        activate()
        await sync.settle()
        var syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 0, "the start just fetched")
        clock.advance(60)
        activate()
        await sync.settle()
        syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 1)
        clock.advance(30)
        activate()
        await sync.settle()
        syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 1, "30 s after the last fetch")
        clock.advance(30)
        activate()
        await sync.settle()
        syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 2)
    }

    func testPushAndSyncNowResetActivationSpacing() async {
        let store = CountingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        clock.advance(100)
        push()
        await sync.settle()
        clock.advance(10)
        activate()
        await sync.settle()
        var syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 1, "the push fetched 10 s ago")
        clock.advance(100)
        sync.syncNow()
        await sync.settle()
        clock.advance(10)
        activate()
        await sync.settle()
        syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 2, "Sync Now fetched 10 s ago")
    }

    func testNoFetchWhenNotRunningOrUnavailable() async {
        let off = CountingSyncStore()
        let offSync = makeController(off, isOn: false)
        offSync.launch()
        push()
        activate()
        await offSync.settle()
        var syncNows = await off.syncNows
        XCTAssertEqual(syncNows, 0, "sync off")

        let unavailable = CountingSyncStore()
        await unavailable.setPhase(.unavailable(.noAccount))
        let sync = makeController(unavailable)
        sync.launch()
        await sync.settle()
        clock.advance(120)
        push()
        activate()
        await sync.settle()
        syncNows = await unavailable.syncNows
        XCTAssertEqual(syncNows, 0, "no iCloud account")
    }

    func testDisabledStoreIgnoresActivation() async {
        let sync = SidebarSyncController(
            store: DisabledSyncStore(), database: EmptyDatabase(), preferences: .inMemory(),
            allRecordIDs: { [] }, notificationCenter: center,
            registerForRemoteNotifications: { [registrations] in registrations.value += 1 }
        )
        sync.launch()
        push()
        activate()
        await sync.settle()
        XCTAssertFalse(sync.isRunning)
        XCTAssertEqual(registrations.value, 0)
    }

    /// Activation and push arriving together queue one fetch, and the push wins the throttle.
    func testBurstQueuesOneFetch() async {
        let store = CountingSyncStore()
        let sync = makeController(store)
        sync.launch()
        await sync.settle()
        activate()
        push()
        activate()
        push()
        await sync.settle()
        let syncNows = await store.syncNows
        XCTAssertEqual(syncNows, 1)
    }
}
