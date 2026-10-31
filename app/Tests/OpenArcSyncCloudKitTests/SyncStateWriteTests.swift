import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// B151: the sync state is written only when it changed, coalesced, and compressed. A macOS
/// disk-writes report showed the state (7.6 MB, mostly cached system fields) rewritten on every
/// engine event: 2.15 GB in 7 h. Acceptance: an hour of idle sync writes less than 50 MB.
final class SyncStateWriteTests: XCTestCase {

    /// Records in the simulated workspace. The user's workspace has about this many synced
    /// records: a 7.6 MB state at about 2.2 KB of base64 system fields per record.
    private let recordCount = 3_500
    private let tabID = SyncRecordID(type: .tab, uuid: Fx.uuid(5))

    // MARK: - Harness

    /// A state as a long-used device has it: engine state, zone saved, cached system fields of
    /// every record.
    private func seasonedState() -> PersistedSyncState {
        var state = PersistedSyncState()
        state.engineState = Data(repeating: 7, count: 4_000)
        state.zoneSaved = true
        state.zonePollToken = Data("token-0".utf8)
        for n in 0..<recordCount {
            let id = SyncRecordID(type: .tab, uuid: Fx.uuid(100_000 + n))
            state.systemFields[id.recordName] = Fx.systemFields(for: id, tag: "srv-\(n)")
        }
        return state
    }

    private struct Rig {
        let store: CloudKitSyncStore
        let storage: InMemoryStateStorage
        let clock: VirtualClock
        let saves: VirtualTimeScheduler
        let retries: FakeRetryScheduler
        let drivers: FakeDriverFactory

        var driver: FakeDriver { get throws { try XCTUnwrap(drivers.current) } }

        /// Moves virtual time forward, running every coalesced write that falls due.
        func advance(by seconds: TimeInterval) async {
            await saves.advance(by: seconds)
        }
    }

    private func makeRig(seed: PersistedSyncState?, records: [SyncRecord] = []) async throws -> Rig {
        let storage = InMemoryStateStorage()
        if let seed { try await storage.saveState(seed.encoded()) }
        let clock = VirtualClock()
        let saves = VirtualTimeScheduler(clock: clock)
        let retries = FakeRetryScheduler()
        let drivers = FakeDriverFactory()
        let store = CloudKitSyncStore(
            configuration: CloudKitSyncStore.Configuration(),
            stateStorage: storage,
            driverFactory: drivers.factory,
            clock: { clock.now },
            retryScheduler: retries,
            saveScheduler: saves,
            savePolicy: .standard
        )
        try await store.start(database: FakeDatabase(records))
        return Rig(store: store, storage: storage, clock: clock, saves: saves, retries: retries, drivers: drivers)
    }

    // MARK: - An idle hour

    /// One hour of an idle app with sync on, at the event rate the engine and the app produce:
    /// - every minute a fetch the app asks for (activation / push; `SyncFetchThrottle` allows one
    ///   a minute) with a fresh zone poll token, and `lastSyncedAt` moving;
    /// - twice a minute an engine state update (CKSyncEngine reports one after each internal
    ///   operation), every fifth minute with new content (its change tokens moved);
    /// - every five minutes an automatic engine cycle.
    /// Before B151 each of these events rewrote the whole state (measured with this harness: 540
    /// writes, 4.37 GB for the hour). Now caches are written at most every `lazyDelay` (300 s),
    /// compressed: at most 13 writes and well under the 50 MB acceptance limit.
    func testIdleHourWritesStayBelowLimit() async throws {
        let rig = try await makeRig(seed: seasonedState())
        while await rig.retries.runNext() {}
        let driver = try rig.driver
        let pollCount = Counter()
        driver.zonePollHandler = { _ in DriverZoneChanges(token: Data("token-\(pollCount.next())".utf8)) }
        let writesBefore = await rig.storage.writeCount
        let bytesBefore = await rig.storage.bytesWritten

        var engine = Data(repeating: 7, count: 4_000)
        for minute in 0..<60 {
            await driver.emit(.stateUpdate(engine))
            if minute % 5 == 0 {
                engine[minute % engine.count] &+= 1
                await driver.emitAutomaticCycle(fetchEvents: [.stateUpdate(engine)])
                while await rig.retries.runNext() {}
            }
            try await rig.store.syncNow()
            await rig.advance(by: 30)
            await driver.emit(.stateUpdate(engine))
            await rig.advance(by: 30)
        }

        let writes = await rig.storage.writeCount - writesBefore
        let bytes = await rig.storage.bytesWritten - bytesBefore
        let stateSize = await rig.storage.data?.count ?? 0
        print("B151 idle hour: \(writes) state writes, \(bytes) bytes; state \(stateSize) bytes for \(recordCount) records")
        XCTAssertLessThanOrEqual(writes, 13, "caches are written at most every lazyDelay")
        XCTAssertLessThan(bytes, 50_000_000, "plan B151 acceptance: < 50 MB per idle hour")
        XCTAssertLessThan(bytes, 5_000_000, "compressed state: a few MB at most")
    }

    /// Engine events that leave the state as it is write nothing, however many there are.
    func testRepeatedUnchangedEventsWriteNothing() async throws {
        let seed = seasonedState()
        let rig = try await makeRig(seed: seed)
        while await rig.retries.runNext() {}
        let driver = try rig.driver
        await rig.advance(by: 600)
        let writesBefore = await rig.storage.writeCount
        for _ in 0..<1_000 {
            await driver.emit(.stateUpdate(try XCTUnwrap(seed.engineState)))
            await driver.emit(.willFetchChanges)
            await driver.emit(.didFetchChanges(.manual))
        }
        await rig.advance(by: 3_600)
        let writes = await rig.storage.writeCount
        XCTAssertEqual(writes, writesBefore)
    }

    // MARK: - Real changes still reach disk

    /// A local change queued for upload is written within `promptDelay`, not before, and once
    /// for a burst of edits.
    func testQueuedLocalChangeIsSavedWithinPromptWindow() async throws {
        let rig = try await makeRig(seed: seasonedState(), records: [.tab(Fx.tab())])
        while await rig.retries.runNext() {}
        let writesBefore = await rig.storage.writeCount
        for _ in 0..<20 { await rig.store.enqueue([.save(tabID)]) }

        var onDisk = await rig.storage.decoded
        XCTAssertNil(onDisk.pending.entry(for: tabID), "coalesced: not written at once")
        await rig.advance(by: StateSavePolicy.standard.promptDelay)
        onDisk = await rig.storage.decoded
        XCTAssertEqual(onDisk.pending.entry(for: tabID)?.operation, .save)
        let writes = await rig.storage.writeCount
        XCTAssertEqual(writes, writesBefore + 1, "one write for the burst")
    }

    /// `stop` (turning sync off) and `flushState` (quitting) write what is pending at once,
    /// lazy changes included.
    func testStopAndFlushWritePendingChanges() async throws {
        let rig = try await makeRig(seed: seasonedState(), records: [.tab(Fx.tab())])
        while await rig.retries.runNext() {}
        let driver = try rig.driver
        await rig.store.enqueue([.save(tabID)])
        await rig.store.flushState()
        var onDisk = await rig.storage.decoded
        XCTAssertNotNil(onDisk.pending.entry(for: tabID), "flushState writes the queue")

        await driver.emit(.stateUpdate(Data("new engine".utf8)))
        onDisk = await rig.storage.decoded
        XCTAssertNotEqual(onDisk.engineState, Data("new engine".utf8), "a cache change waits")
        await rig.store.stop()
        onDisk = await rig.storage.decoded
        XCTAssertEqual(onDisk.engineState, Data("new engine".utf8), "stop writes it")

        // A write scheduled before the stop does nothing afterwards.
        let writes = await rig.storage.writeCount
        await rig.advance(by: 3_600)
        let after = await rig.storage.writeCount
        XCTAssertEqual(after, writes)
    }

    /// A cache-only change (new engine state) is written once `lazyDelay` has passed.
    func testCacheChangeIsSavedWithinLazyWindow() async throws {
        let rig = try await makeRig(seed: seasonedState())
        while await rig.retries.runNext() {}
        let driver = try rig.driver
        await driver.emit(.stateUpdate(Data("moved".utf8)))
        await rig.advance(by: StateSavePolicy.standard.lazyDelay - 1)
        var onDisk = await rig.storage.decoded
        XCTAssertNotEqual(onDisk.engineState, Data("moved".utf8))
        await rig.advance(by: 1)
        onDisk = await rig.storage.decoded
        XCTAssertEqual(onDisk.engineState, Data("moved".utf8))
    }

    /// A prompt change arriving while a lazy write waits is written at the prompt delay, and
    /// carries the cache change with it.
    func testPromptChangeOvertakesWaitingLazyWrite() async throws {
        let rig = try await makeRig(seed: seasonedState(), records: [.tab(Fx.tab())])
        while await rig.retries.runNext() {}
        let driver = try rig.driver
        await driver.emit(.stateUpdate(Data("moved".utf8)))
        await rig.advance(by: 10)
        await rig.store.enqueue([.save(tabID)])
        await rig.advance(by: StateSavePolicy.standard.promptDelay)
        let onDisk = await rig.storage.decoded
        XCTAssertNotNil(onDisk.pending.entry(for: tabID))
        XCTAssertEqual(onDisk.engineState, Data("moved".utf8))
    }

    /// Server changes whose local apply failed are kept for retry: written promptly, as they
    /// exist nowhere else once the engine's token moved on.
    func testDeferredRemoteChangesAreSavedPromptly() async throws {
        let database = FakeDatabase()
        await database.failNextApplies(1)
        let storage = InMemoryStateStorage()
        let clock = VirtualClock()
        let saves = VirtualTimeScheduler(clock: clock)
        let drivers = FakeDriverFactory()
        let store = CloudKitSyncStore(
            configuration: CloudKitSyncStore.Configuration(), stateStorage: storage,
            driverFactory: drivers.factory, clock: { clock.now }, retryScheduler: FakeRetryScheduler(),
            saveScheduler: saves
        )
        try await store.start(database: database)
        await saves.advance(by: 600)
        let driver = try XCTUnwrap(drivers.current)
        await driver.emit(.fetchedRecordChanges(modified: [Fx.serverCK(.tab(Fx.tab()), tag: "s1")], deleted: []))
        await saves.advance(by: StateSavePolicy.standard.promptDelay)
        let onDisk = await storage.decoded
        XCTAssertEqual(onDisk.deferredUpserts.map(\.id), [tabID])
    }

    // MARK: - Container

    /// The state is stored compressed; plain JSON from earlier builds still loads.
    func testStateIsCompressedAndLegacyJSONStillLoads() throws {
        let state = seasonedState()
        let plain = try JSONEncoder().encode(state)
        let stored = try XCTUnwrap(state.encoded())
        XCTAssertTrue(stored.starts(with: SyncStateContainer.tag))
        XCTAssertEqual(PersistedSyncState.decode(stored), state)
        XCTAssertEqual(PersistedSyncState.decode(plain), state, "a state written by an earlier build")
        print("B151 state for \(recordCount) records: JSON \(plain.count) bytes, stored \(stored.count) bytes")
        XCTAssertLessThan(stored.count * 10, plain.count, "at least 10:1")

        var unknown = stored
        unknown[SyncStateContainer.tag.count] = SyncStateContainer.version + 1
        XCTAssertEqual(PersistedSyncState.decode(unknown), PersistedSyncState(), "an unknown container is a fresh state")
    }

    /// Which differences are written promptly (lost data otherwise) and which wait.
    func testPromptSaveClassification() {
        let saved = seasonedState()
        var next = saved
        next.engineState = Data("x".utf8)
        next.zonePollToken = Data("y".utf8)
        next.systemFields["Tab/x"] = Data([1])
        next.lastSyncedAt = Fx.t(5)
        XCTAssertFalse(next.needsPromptSave(comparedTo: saved), "caches wait")
        XCTAssertFalse(next.differsOnlyInLastSyncedAt(from: saved))

        var synced = saved
        synced.lastSyncedAt = Fx.t(5)
        XCTAssertTrue(synced.differsOnlyInLastSyncedAt(from: saved))

        var queued = saved
        queued.pending.add(tabID, .save)
        XCTAssertTrue(queued.needsPromptSave(comparedTo: saved))
        var requeued = queued
        requeued.pending.add(tabID, .save)
        XCTAssertFalse(requeued.needsPromptSave(comparedTo: queued), "same change again: already on disk")
        var deleted = queued
        deleted.pending.add(tabID, .delete)
        XCTAssertTrue(deleted.needsPromptSave(comparedTo: queued))
        var confirmed = queued
        confirmed.pending.remove(tabID)
        XCTAssertFalse(confirmed.needsPromptSave(comparedTo: queued), "a shrinking queue waits")

        var flags = saved
        flags.awaitingAccountReset = true
        XCTAssertTrue(flags.needsPromptSave(comparedTo: saved))
        var deferred = saved
        deferred.deferredDeletions = [tabID]
        XCTAssertTrue(deferred.needsPromptSave(comparedTo: saved))
    }
}

// MARK: - Virtual time

/// A clock tests move by hand.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class VirtualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Fx.t(1000)

    var now: Date { lock.withLock { _now } }
    func set(_ date: Date) { lock.withLock { _now = date } }
}

/// Runs scheduled work when virtual time reaches it (`advance`), in due order; nothing sleeps.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class VirtualTimeScheduler: RetryScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private let clock: VirtualClock
    private var queue: [(due: Date, order: Int, work: @Sendable () async -> Void)] = []
    private var order = 0

    init(clock: VirtualClock) {
        self.clock = clock
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        let due = clock.now.addingTimeInterval(max(delay, 0))
        lock.withLock {
            order += 1
            queue.append((due, order, work))
        }
    }

    /// Moves the clock `seconds` forward, running every item that falls due on the way (also
    /// items scheduled by those items, when they fall due within the window).
    func advance(by seconds: TimeInterval) async {
        let end = clock.now.addingTimeInterval(seconds)
        while let next = popDue(by: end) {
            if next.due > clock.now { clock.set(next.due) }
            await next.work()
        }
        clock.set(end)
    }

    private func popDue(by end: Date) -> (due: Date, work: @Sendable () async -> Void)? {
        lock.withLock {
            guard let index = queue.indices.filter({ queue[$0].due <= end })
                .min(by: { (queue[$0].due, queue[$0].order) < (queue[$1].due, queue[$1].order) })
            else { return nil }
            let item = queue.remove(at: index)
            return (item.due, item.work)
        }
    }
}
