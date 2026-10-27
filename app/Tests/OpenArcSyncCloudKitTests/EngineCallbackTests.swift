import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// B86 (D4 blockers): CKSyncEngine traps when a task running inside one of its delegate callbacks
/// awaits a call into the engine, and remote changes must be fetched at database level. Our own
/// design rules for CloudKit, not from docs/arc-spec (the spec has no sync internals); inferred.
final class EngineCallbackTests: XCTestCase {

    private let tabID = SyncRecordID(type: .tab, uuid: Fx.uuid(5))

    // MARK: - Detached scheduling

    /// The production scheduler must not hand the callback's task-local context to its work.
    func testTaskRetrySchedulerDoesNotInheritCallbackContext() async {
        let seen = expectation(description: "work ran")
        let observed = Flag()
        EngineCallbackContext.$isActive.withValue(true) {
            XCTAssertTrue(EngineCallbackContext.isActive)
            TaskRetryScheduler().schedule(after: 0) {
                observed.set(EngineCallbackContext.isActive)
                seen.fulfill()
            }
        }
        await fulfillment(of: [seen], timeout: 2)
        XCTAssertEqual(observed.value, false, "scheduled work runs outside the delegate callback")
    }

    /// The check above can fail: a plain `Task {}` (the B63 code) does inherit the marker.
    func testPlainTaskInheritsCallbackContext() async {
        let seen = expectation(description: "work ran")
        let observed = Flag()
        EngineCallbackContext.$isActive.withValue(true) {
            InheritingScheduler().schedule(after: 0) {
                observed.set(EngineCallbackContext.isActive)
                seen.fulfill()
            }
        }
        await fulfillment(of: [seen], timeout: 2)
        XCTAssertEqual(observed.value, true)
    }

    /// D4 crash path: the engine's first automatic cycle ends inside `handleEvent`, the store
    /// queues B63's confirming `syncNow`, and that sync awaits `fetchChanges`. With the real
    /// scheduler the engine is never called from inside a callback.
    func testConfirmingSyncAfterAutomaticCycleRunsOutsideCallback() async throws {
        let (store, drivers) = makeStore(scheduler: TaskRetryScheduler())
        try await store.start(database: FakeDatabase([.tab(Fx.tab())]))
        let driver = try XCTUnwrap(drivers.current)
        await store.enqueue([.save(tabID)])

        await driver.emitAutomaticCycle()
        try await waitUntil { await store.currentStatus().lastSyncedAt != nil }

        XCTAssertEqual(driver.fetchScopes, [.allZones], "the confirmation fetched once")
        XCTAssertEqual(driver.callsInsideCallback, [], "no engine call from inside a delegate callback")
        XCTAssertEqual(driver.sentBatches.count, 1)
    }

    /// The fake catches the D4 bug: with the B63 scheduler the confirming fetch is made from
    /// inside the callback that ended the automatic cycle.
    func testInheritingSchedulerIsCaughtByFakeDriver() async throws {
        let (store, drivers) = makeStore(scheduler: InheritingScheduler())
        try await store.start(database: FakeDatabase([.tab(Fx.tab())]))
        let driver = try XCTUnwrap(drivers.current)

        await driver.emitAutomaticCycle()
        try await waitUntil { !driver.fetchScopes.isEmpty }
        try await waitUntil { await store.currentStatus().lastSyncedAt != nil }

        XCTAssertEqual(driver.callsInsideCallback.first, "fetchChanges")
    }

    // MARK: - Database-level fetch

    /// Activation, push and Sync Now all reach the store as `syncNow` (B65; covered in
    /// `SyncLiveUpdateTests`). The fetch it makes is database level, never limited to our zone,
    /// so zones changed by other devices are found through the database change feed.
    func testSyncNowFetchesAtDatabaseScope() async throws {
        let h = StoreHarness()
        try await h.start()
        try await h.store.syncNow()
        try await h.store.syncNow()
        XCTAssertEqual(try h.driver.fetchScopes, [.allZones, .allZones])
        XCTAssertEqual(try h.driver.callsInsideCallback, [])
    }

    func testAllZonesMapsToEngineDefaultScope() {
        XCTAssertEqual(CKSyncEngineDriver.fetchOptions(for: .allZones).scope, .all)
        XCTAssertEqual(CKSyncEngine.FetchChangesOptions().scope, .all, "the engine default is database level too")
        XCTAssertEqual(CKSyncEngineDriver.fetchOptions(for: .zones([Fx.zoneID])).scope, .zoneIDs([Fx.zoneID]))
    }

    /// A relaunch with saved engine state catches up with a database-level fetch, run outside
    /// `start` (detached) and not waiting for the throttled activation fetch.
    func testRelaunchWithSavedEngineStateFetchesAtDatabaseScope() async throws {
        let storage = InMemoryStateStorage()
        var saved = PersistedSyncState()
        saved.engineState = Data("engine".utf8)
        try await storage.saveState(saved.encoded())

        let h = StoreHarness(storage: storage)
        try await h.start()
        let driver = try h.driver
        XCTAssertEqual(driver.engineState, Data("engine".utf8))
        XCTAssertEqual(driver.fetchScopes, [], "start does not wait for the network")
        XCTAssertEqual(h.scheduler.delays, [0], "catch-up fetch queued at once")

        await h.scheduler.runNext()
        XCTAssertEqual(driver.fetchScopes, [.allZones])
        let status = await h.store.currentStatus()
        XCTAssertEqual(status.lastSyncedAt, Fx.t(1000))
    }

    /// A fresh engine fetches everything on its own (D4); no extra fetch is queued.
    func testFreshStartQueuesNoCatchUpFetch() async throws {
        let h = StoreHarness()
        try await h.start()
        XCTAssertEqual(h.scheduler.delays, [])
        XCTAssertEqual(try h.driver.fetchScopes, [])
    }

    // MARK: - Helpers

    private func makeStore(scheduler: any RetryScheduling) -> (CloudKitSyncStore, FakeDriverFactory) {
        let drivers = FakeDriverFactory()
        let store = CloudKitSyncStore(
            configuration: CloudKitSyncStore.Configuration(),
            stateStorage: InMemoryStateStorage(),
            driverFactory: drivers.factory,
            clock: { Fx.t(1000) },
            retryScheduler: scheduler
        )
        return (store, drivers)
    }

    /// Polls `condition` until it holds; fails after `timeout` (only a guard against a hang).
    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @Sendable () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else {
                XCTFail("condition not met within \(timeout) s", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// The B63 scheduler: a plain `Task {}` that inherits the caller's task-local context.
private struct InheritingScheduler: RetryScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        Task { await work() }
    }
}

/// Thread-safe optional Bool.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Bool?

    func set(_ value: Bool) { lock.withLock { _value = value } }
    var value: Bool? { lock.withLock { _value } }
}
