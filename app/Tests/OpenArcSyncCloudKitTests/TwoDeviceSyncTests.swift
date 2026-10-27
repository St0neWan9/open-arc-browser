import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// An in-memory stand-in for the private CloudKit zone, shared by several `FakeDriver`s:
/// - a save whose change tag does not match the stored copy fails with `serverRecordChanged`
///   (carrying the stored copy), like CloudKit's `ifServerRecordUnchanged` policy;
/// - a save with a change tag for a record the server does not have fails with `unknownItem`;
/// - every accepted save gets a fresh change tag and lands in a change log;
/// - each device fetches the log from its own cursor (its own writes included, as a zone change
///   fetch returns them), collapsed to the latest change per record;
/// - the store's zone poll (`fetchZoneChanges`) reads the same log from the token it passes, so
///   by default every change reaches a device twice (engine fetch and poll), as on CloudKit;
/// - `engineSkipsFetch` makes the engine fetch return nothing, like CKSyncEngine when no push
///   told it a zone changed ("no zone IDs needing to be fetched", D4); then only the poll sees changes.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class FakeServer: @unchecked Sendable {
    private enum Change {
        case saved(String)
        case deleted(String, type: String)
    }

    private let lock = NSLock()
    private var records: [String: CKRecord] = [:]
    private var log: [Change] = []
    private var cursors: [String: Int] = [:]
    private var tagCounter = 0
    private var _uploadCount = 0
    private var _conflictCount = 0
    private var _holdFetches = false
    private var _engineSkipsFetch = false

    /// Every record save or delete a device sent, accepted or not.
    var uploadCount: Int { lock.withLock { _uploadCount } }
    /// Saves rejected with `serverRecordChanged`.
    var conflictCount: Int { lock.withLock { _conflictCount } }
    /// While true, fetches return nothing (the devices miss each other's writes and conflict on send).
    var holdFetches: Bool {
        get { lock.withLock { _holdFetches } }
        set { lock.withLock { _holdFetches = newValue } }
    }

    /// While true, engine fetches return nothing; only the store's zone poll sees changes.
    var engineSkipsFetch: Bool {
        get { lock.withLock { _engineSkipsFetch } }
        set { lock.withLock { _engineSkipsFetch = newValue } }
    }

    /// The server's copy of a record, decoded.
    func record(_ id: SyncRecordID) -> SyncRecord? {
        let ck = lock.withLock { records[id.recordName] }
        return ck.flatMap { try? Fx.mapper.decode($0) }
    }

    /// Wires `driver` to this server as device `device`.
    func connect(_ driver: FakeDriver, as device: String) {
        driver.sendHandler = { [weak self] batch in
            self?.send(batch) ?? DriverSentRecordChanges()
        }
        driver.fetchHandler = { [weak self] in
            self?.fetch(for: device) ?? []
        }
        driver.zonePollHandler = { [weak self] token in
            self?.poll(since: token) ?? DriverZoneChanges(token: token)
        }
    }

    /// The zone poll: the log after `token` (a log position), collapsed per record.
    private func poll(since token: Data?) -> DriverZoneChanges {
        lock.withLock {
            let start = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
            let end = log.count
            let token = Data(String(end).utf8)
            guard !_holdFetches else { return DriverZoneChanges(token: Data(String(start).utf8)) }
            let (modified, deleted) = changes(in: start..<end)
            return DriverZoneChanges(modified: modified, deleted: deleted, token: token)
        }
    }

    /// Latest state per record of the log entries in `range`, in first-seen order. Call under `lock`.
    private func changes(in range: Range<Int>) -> ([CKRecord], [DriverFetchedDeletion]) {
        var latest: [String: Change] = [:]
        var order: [String] = []
        for change in log[range] {
            let name: String
            switch change {
            case .saved(let n), .deleted(let n, _): name = n
            }
            if latest[name] == nil { order.append(name) }
            latest[name] = change
        }
        var modified: [CKRecord] = []
        var deleted: [DriverFetchedDeletion] = []
        for name in order {
            switch latest[name] {
            case .saved:
                if let ck = records[name] { modified.append(ck) }
            case .deleted(_, let type):
                deleted.append(DriverFetchedDeletion(recordID: CKRecord.ID(recordName: name, zoneID: Fx.zoneID), recordType: type))
            case nil:
                break
            }
        }
        return (modified, deleted)
    }

    private func send(_ batch: DriverBatch) -> DriverSentRecordChanges {
        lock.withLock {
            var result = DriverSentRecordChanges()
            for ck in batch.recordsToSave {
                _uploadCount += 1
                let name = ck.recordID.recordName
                if let current = records[name] {
                    guard ck.recordChangeTag == current.recordChangeTag else {
                        _conflictCount += 1
                        result.failedSaves.append(DriverFailedSave(record: ck, error: ckError(.serverRecordChanged, serverRecord: current)))
                        continue
                    }
                } else if ck.recordChangeTag != nil {
                    result.failedSaves.append(DriverFailedSave(record: ck, error: ckError(.unknownItem)))
                    continue
                }
                guard let decoded = try? Fx.mapper.decode(ck) else { continue }
                tagCounter += 1
                let stored = Fx.serverCK(decoded, tag: "s-\(tagCounter)")
                records[name] = stored
                log.append(.saved(name))
                result.savedRecords.append(stored)
            }
            for id in batch.recordIDsToDelete {
                _uploadCount += 1
                if let removed = records.removeValue(forKey: id.recordName) {
                    log.append(.deleted(id.recordName, type: removed.recordType))
                }
                result.deletedRecordIDs.append(id)
            }
            return result
        }
    }

    private func fetch(for device: String) -> [SyncDriverEvent] {
        lock.withLock {
            guard !_holdFetches, !_engineSkipsFetch else { return [] }
            let start = cursors[device] ?? 0
            cursors[device] = log.count
            let (modified, deleted) = changes(in: start..<log.count)
            guard !modified.isEmpty || !deleted.isEmpty else { return [] }
            return [.fetchedRecordChanges(modified: modified, deleted: deleted)]
        }
    }
}

/// A20: two devices syncing through one server converge, and a merge the server wins never sends
/// the record back up (no ping-pong). Merge rules: `OpenArcSyncAPI/ConflictPolicy.swift`
/// (field-group last-writer-wins, delete wins, ties go to the server). Delete wins follows from
/// archiving being a delete (docs/arc-spec/05-surfaces.md, ⌘W archives, observed); the sync
/// behavior itself is our own design (inferred).
final class TwoDeviceSyncTests: XCTestCase {

    private let tabID = SyncRecordID(type: .tab, uuid: Fx.uuid(5))
    private let folderID = SyncRecordID(type: .folder, uuid: Fx.uuid(4))

    private struct Devices {
        let server: FakeServer
        let a: StoreHarness
        let b: StoreHarness

        var both: [StoreHarness] { [a, b] }
    }

    /// Device A creates `records` and uploads them; device B starts empty and fetches them.
    private func makeDevices(_ records: [SyncRecord]) async throws -> Devices {
        let server = FakeServer()
        let a = StoreHarness(records: records) { server.connect($0, as: "A") }
        let b = StoreHarness { server.connect($0, as: "B") }
        try await a.start()
        try await b.start()
        await a.store.enqueue(records.map { .save($0.id) })
        let devices = Devices(server: server, a: a, b: b)
        try await sync(devices, rounds: 2)
        for record in records {
            let onB = await b.database.record(for: record.id)
            XCTAssertEqual(onB?.withoutSystemFields, record.withoutSystemFields, "B received \(record.id.recordName)")
        }
        return devices
    }

    private func sync(_ devices: Devices, rounds: Int) async throws {
        for _ in 0..<rounds {
            try await devices.a.store.syncNow()
            try await devices.b.store.syncNow()
        }
    }

    /// A local edit as the app makes it: change the record, then announce it.
    private func edit(_ device: StoreHarness, _ id: SyncRecordID, _ change: (inout SyncRecord) -> Void) async throws {
        var record = try await XCTUnwrapAsync(await device.database.record(for: id))
        change(&record)
        await device.database.put(record)
        await device.store.enqueue([.save(id)])
    }

    private func editTab(_ device: StoreHarness, at time: TimeInterval, _ change: (inout TabNode, Date) -> Void) async throws {
        try await edit(device, tabID) { record in
            guard case .tab(var tab) = record else { return }
            change(&tab, Fx.t(time))
            record = .tab(tab)
        }
    }

    /// Runs rounds until the server's upload count stops growing, then checks that it stays put
    /// for several more rounds and that both devices hold the server's copy of `ids`.
    @discardableResult
    private func assertConverges(_ devices: Devices, ids: [SyncRecordID], file: StaticString = #filePath, line: UInt = #line) async throws -> Int {
        var previous = devices.server.uploadCount
        var settled = false
        for _ in 0..<6 {
            try await sync(devices, rounds: 1)
            let now = devices.server.uploadCount
            if now == previous { settled = true; break }
            previous = now
        }
        XCTAssertTrue(settled, "uploads keep growing: sync ping-pong", file: file, line: line)
        try await sync(devices, rounds: 4)
        XCTAssertEqual(devices.server.uploadCount, previous, "no uploads once converged", file: file, line: line)

        for device in devices.both {
            let pending = await device.persisted.pending
            XCTAssertTrue(pending.isEmpty, "nothing left to upload", file: file, line: line)
            XCTAssertTrue(try device.driver.pendingChanges.isEmpty, file: file, line: line)
            for id in ids {
                let local = await device.database.record(for: id)
                XCTAssertEqual(local?.withoutSystemFields, devices.server.record(id)?.withoutSystemFields, "\(id.recordName) matches the server", file: file, line: line)
            }
        }
        return previous
    }

    // MARK: - Edits

    /// Concurrent edits of different field groups: both survive on both devices, the merged record
    /// goes up once, and the device that only had to adopt it uploads nothing.
    func testDifferentGroupsConvergeWithoutPingPong() async throws {
        let d = try await makeDevices([.tab(Fx.tab())])
        let baseline = d.server.uploadCount

        try await editTab(d.a, at: 10) { tab, now in
            tab.customTitle = "Renamed on A"
            tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
        }
        try await editTab(d.b, at: 20) { tab, now in
            tab.url = URL(string: "https://navigated-on-b.example/")
            tab.title = "Navigated on B"
            tab.meta.stamp([TabNode.FieldGroup.content], at: now)
        }

        let uploads = try await assertConverges(d, ids: [tabID])
        let tab = try XCTUnwrap(d.server.record(tabID)?.tab)
        XCTAssertEqual(tab.customTitle, "Renamed on A")
        XCTAssertEqual(tab.title, "Navigated on B")
        // A's edit, B's merged record (B won content, A won naming): two uploads, nothing echoed.
        XCTAssertEqual(uploads - baseline, 2)
    }

    /// Concurrent edits of the same group: the later write wins everywhere; the losing device
    /// adopts the server copy and uploads nothing.
    func testSameGroupLaterWriteWinsWithoutPingPong() async throws {
        let d = try await makeDevices([.tab(Fx.tab())])
        let baseline = d.server.uploadCount

        try await editTab(d.a, at: 30) { tab, now in
            tab.customTitle = "Later on A"
            tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
        }
        try await editTab(d.b, at: 20) { tab, now in
            tab.customTitle = "Earlier on B"
            tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
        }

        let uploads = try await assertConverges(d, ids: [tabID])
        XCTAssertEqual(d.server.record(tabID)?.tab?.customTitle, "Later on A")
        // A uploads its edit; B's pending save is superseded by the server copy it fetches first.
        XCTAssertEqual(uploads - baseline, 1)
        let onB = await d.b.database.record(for: tabID)
        XCTAssertEqual(onB?.meta.version, d.server.record(tabID)?.meta.version, "B took the server's version as it is")
    }

    /// The same edits, but each device sends before seeing the other's write, so the second send
    /// fails with `serverRecordChanged` and goes through conflict resolution.
    func testConflictsOnSendConvergeWithoutPingPong() async throws {
        let d = try await makeDevices([.tab(Fx.tab()), .folder(Fx.folder())])
        let baseline = d.server.uploadCount

        // Tab: different groups (mixed merge). Folder: same group, A's write is later (B loses all).
        try await editTab(d.a, at: 10) { tab, now in
            tab.customTitle = "A name"
            tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
        }
        try await editTab(d.b, at: 20) { tab, now in
            tab.sortKey = Fx.key("z")
            tab.meta.stamp([TabNode.FieldGroup.placement], at: now)
        }
        try await edit(d.a, folderID) { record in
            guard case .folder(var folder) = record else { return }
            folder.title = "A title"
            folder.meta.stamp([Folder.FieldGroup.naming], at: Fx.t(40))
            record = .folder(folder)
        }
        try await edit(d.b, folderID) { record in
            guard case .folder(var folder) = record else { return }
            folder.title = "B title"
            folder.meta.stamp([Folder.FieldGroup.naming], at: Fx.t(30))
            record = .folder(folder)
        }

        d.server.holdFetches = true
        try await sync(d, rounds: 1)
        XCTAssertEqual(d.server.conflictCount, 2, "B's two saves hit A's writes")
        d.server.holdFetches = false

        let uploads = try await assertConverges(d, ids: [tabID, folderID])
        let tab = try XCTUnwrap(d.server.record(tabID)?.tab)
        XCTAssertEqual(tab.customTitle, "A name")
        XCTAssertEqual(tab.sortKey, Fx.key("z"))
        guard case .folder(let folder) = try XCTUnwrap(d.server.record(folderID)) else { return XCTFail("wrong type") }
        XCTAssertEqual(folder.title, "A title")
        // A: tab + folder; B: two rejected saves, then only the mixed tab goes up again.
        XCTAssertEqual(uploads - baseline, 5)
        XCTAssertEqual(d.server.conflictCount, 2)
    }

    // MARK: - Delete vs edit

    /// A deletes (tombstone) while B edits later: delete wins on both devices, whichever write
    /// reaches the server first, and nothing keeps bouncing. Then A purges and B removes it too.
    func testDeleteBeatsConcurrentEditAndConverges() async throws {
        for deleteFirst in [true, false] {
            let d = try await makeDevices([.tab(Fx.tab())])
            let baseline = d.server.uploadCount
            try await editTab(d.a, at: 10) { tab, now in tab.meta.markDeleted(at: now) }
            try await editTab(d.b, at: 50) { tab, now in
                tab.customTitle = "Edited after the delete"
                tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
            }

            d.server.holdFetches = true
            if deleteFirst {
                try await d.a.store.syncNow()
                try await d.b.store.syncNow()
            } else {
                try await d.b.store.syncNow()
                try await d.a.store.syncNow()
            }
            XCTAssertEqual(d.server.conflictCount, 1, "deleteFirst=\(deleteFirst)")
            d.server.holdFetches = false

            let uploads = try await assertConverges(d, ids: [tabID])
            XCTAssertEqual(d.server.record(tabID)?.meta.isTombstone, true, "deleteFirst=\(deleteFirst)")
            for device in d.both {
                let local = await device.database.record(for: tabID)
                XCTAssertEqual(local?.meta.isTombstone, true, "deleteFirst=\(deleteFirst)")
            }
            // Delete first: tombstone + B's rejected edit. Edit first: edit + A's rejected
            // tombstone + its resend (the server had not seen the delete).
            XCTAssertEqual(uploads - baseline, deleteFirst ? 2 : 3, "deleteFirst=\(deleteFirst)")

            // A purges the tombstone; B drops the record on the next fetch.
            await d.a.database.remove(tabID)
            await d.a.store.enqueue([.delete(tabID)])
            let afterPurge = try await assertConverges(d, ids: [tabID])
            XCTAssertEqual(afterPurge - uploads, 1)
            XCTAssertNil(d.server.record(tabID))
            let onB = await d.b.database.record(for: tabID)
            XCTAssertNil(onB)
        }
    }
}

/// B86 / D4 (2026-10-27): CKSyncEngine sends no fetch request when it does not know a zone
/// changed (no push arrived), so an already-synced or relaunched instance never saw a Space
/// another instance uploaded. The store's own zone poll in `syncNow` (launch catch-up,
/// activation, push, Sync Now; B65) must find it anyway. Our own sync design; inferred.
final class ZonePollTests: XCTestCase {

    private let spaceID = SyncRecordID(type: .space, uuid: Fx.uuid(3))

    func testChangeFromOtherDeviceArrivesWhenEngineSkipsFetch() async throws {
        let server = FakeServer()
        let a = StoreHarness(records: [.space(Fx.space())]) { server.connect($0, as: "A") }
        let b = StoreHarness { server.connect($0, as: "B") }
        try await b.start()
        try await b.store.syncNow()
        server.engineSkipsFetch = true

        try await a.start()
        await a.store.enqueue([.save(spaceID)])
        try await a.store.syncNow()
        XCTAssertNotNil(server.record(spaceID), "A uploaded the Space")

        try await b.store.syncNow()
        let onB = await b.database.record(for: spaceID)
        XCTAssertEqual(onB?.withoutSystemFields, SyncRecord.space(Fx.space()).withoutSystemFields, "B got A's Space without an engine fetch")
        let pending = await b.persisted.pending
        XCTAssertTrue(pending.isEmpty, "adopting the server copy uploads nothing")
    }

    /// The relaunch case of D4: B quits, A uploads, B starts again from its saved state. The
    /// detached catch-up `syncNow` after `start` polls from the saved token.
    func testRelaunchedDeviceCatchesUpThroughZonePoll() async throws {
        let server = FakeServer()
        server.engineSkipsFetch = true
        let bStorage = InMemoryStateStorage()
        let b = StoreHarness(storage: bStorage) { server.connect($0, as: "B") }
        try await b.start()
        try await b.store.syncNow()
        await b.store.stop()
        let savedToken = await b.persisted.zonePollToken
        XCTAssertNotNil(savedToken, "the poll token is persisted")

        let a = StoreHarness(records: [.space(Fx.space())]) { server.connect($0, as: "A") }
        try await a.start()
        await a.store.enqueue([.save(spaceID)])
        try await a.store.syncNow()

        var saved = await bStorage.decoded
        saved.engineState = Data("engine".utf8)
        try await bStorage.saveState(saved.encoded())
        let relaunched = StoreHarness(storage: bStorage) { server.connect($0, as: "B") }
        try await relaunched.start()
        XCTAssertEqual(relaunched.scheduler.delays, [0], "catch-up sync queued")
        await relaunched.scheduler.runNext()
        XCTAssertEqual(try relaunched.driver.zonePollTokens, [savedToken], "polled from the saved token")
        let onB = await relaunched.database.record(for: spaceID)
        XCTAssertNotNil(onB)
    }

    /// Both the engine and the poll deliver the same change: it is applied once and nothing goes
    /// back up (ties go to the server, `ConflictPolicy`).
    func testDuplicateDeliveryFromEngineAndPollIsHarmless() async throws {
        let server = FakeServer()
        let a = StoreHarness(records: [.space(Fx.space())]) { server.connect($0, as: "A") }
        let b = StoreHarness { server.connect($0, as: "B") }
        try await a.start()
        try await b.start()
        await a.store.enqueue([.save(spaceID)])
        try await a.store.syncNow()
        let uploads = server.uploadCount

        for _ in 0..<3 {
            try await b.store.syncNow()
            try await a.store.syncNow()
        }
        XCTAssertEqual(server.uploadCount, uploads, "no echo uploads")
        let onB = await b.database.record(for: spaceID)
        XCTAssertNotNil(onB)
        let pending = await b.persisted.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testPollTokenAdvancesAndResetsOnSignOut() async throws {
        let h = StoreHarness()
        let driver = FakeDriverBox()
        try await h.start()
        let fake = try h.driver
        fake.zonePollHandler = { token in
            driver.calls += 1
            return DriverZoneChanges(token: Data("t\(driver.calls)".utf8))
        }
        try await h.store.syncNow()
        try await h.store.syncNow()
        XCTAssertEqual(fake.zonePollTokens, [nil, Data("t1".utf8)])
        let saved = await h.persisted.zonePollToken
        XCTAssertEqual(saved, Data("t2".utf8))

        await fake.emit(.accountChange(.signOut))
        let afterSignOut = await h.persisted.zonePollToken
        XCTAssertNil(afterSignOut, "a new account reads its zone from the start")
    }

    /// A failing poll fails the sync like a failed fetch: shown, retried with backoff, token kept.
    func testPollErrorIsReportedAndRetried() async throws {
        let h = StoreHarness()
        try await h.start()
        let fake = try h.driver
        fake.zonePollHandler = { _ in throw CKError(.networkFailure) }
        do {
            try await h.store.syncNow()
            XCTFail("expected the poll error")
        } catch {}
        let status = await h.store.currentStatus()
        guard case .failed = status.phase else { return XCTFail("phase \(status.phase)") }
        XCTAssertEqual(h.scheduler.delays.count, 1, "retry scheduled")
        let token = await h.persisted.zonePollToken
        XCTAssertNil(token)
    }
}

/// Mutable counter for a `@Sendable` closure.
// @unchecked: only touched from the one test task that runs the store calls sequentially.
private final class FakeDriverBox: @unchecked Sendable {
    var calls = 0
}

/// `XCTUnwrap` for a value produced by an `await` expression.
private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let resolved = try await value()
    return try XCTUnwrap(resolved, file: file, line: line)
}
