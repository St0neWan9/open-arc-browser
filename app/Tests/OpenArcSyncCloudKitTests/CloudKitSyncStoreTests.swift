import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// End-to-end tests of `CloudKitSyncStore` against `FakeDriver` (no CloudKit, no network, no
/// sleeps). Status values follow docs/arc-spec/03-settings.md ("Sync Sidebar", "Last synced",
/// observed); merge rules follow OpenArcSyncAPI/ConflictPolicy.swift.
final class CloudKitSyncStoreTests: XCTestCase {

    private let tabID = SyncRecordID(type: .tab, uuid: Fx.uuid(5))
    private let folderID = SyncRecordID(type: .folder, uuid: Fx.uuid(4))
    private let archiveID = SyncRecordID(type: .archiveItem, uuid: Fx.uuid(6))
    private var tabCKID: CKRecord.ID { Fx.mapper.recordID(for: tabID) }

    /// A send handler that fails every save of the first `failures` sends with `error`, then
    /// behaves like a healthy server.
    private func failingSaves(_ driver: FakeDriver, times failures: Int, _ error: @escaping @Sendable (CKRecord) -> CKError) -> FakeDriver.SendHandler {
        let calls = Counter()
        return { [weak driver] batch in
            if calls.next() <= failures {
                return DriverSentRecordChanges(failedSaves: batch.recordsToSave.map { DriverFailedSave(record: $0, error: error($0)) })
            }
            return DriverSentRecordChanges(
                savedRecords: batch.recordsToSave.map { driver?.saved($0) ?? $0 },
                deletedRecordIDs: batch.recordIDsToDelete
            )
        }
    }

    private func tag(_ batch: DriverBatch?, _ id: SyncRecordID) -> String? {
        batch?.recordsToSave.first { $0.recordID.recordName == id.recordName }?.recordChangeTag
    }

    // MARK: - Start-up and account status

    func testStartWithAvailableAccountIsIdleAndQueuesZoneCreation() async throws {
        let h = StoreHarness()
        try await h.start()
        let status = await h.store.currentStatus()
        XCTAssertEqual(status.phase, .idle)
        XCTAssertTrue(try h.driver.zoneSavePending)
    }

    func testSyncNowBeforeStartThrowsNotStarted() async {
        let h = StoreHarness()
        do {
            try await h.store.syncNow()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncStoreError, .notStarted)
        }
    }

    func testAccountStatusAtStartSurfacesOnStatusUpdates() async throws {
        let h = StoreHarness { $0.accountStatusResult = .success(.noAccount) }
        let stream = h.store.statusUpdates()
        try await h.start()
        let seen = await collectStatuses(stream) { $0.phase == .unavailable(.noAccount) }
        XCTAssertEqual(seen.first?.phase, .disabled, "stream starts with the current value")
        XCTAssertEqual(seen.last?.phase, .unavailable(.noAccount))

        let restricted = StoreHarness { $0.accountStatusResult = .success(.restricted) }
        try await restricted.start()
        let restrictedPhase = await restricted.store.currentStatus().phase
        XCTAssertEqual(restrictedPhase, .unavailable(.restricted))

        let failing = StoreHarness { $0.accountStatusResult = .failure(.accountStatusFailed) }
        try await failing.start()
        let failingPhase = await failing.store.currentStatus().phase
        XCTAssertEqual(failingPhase, .unavailable(.temporarilyUnavailable))
    }

    func testAccountChangeEventsSurfaceOnStatusUpdates() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        let stream = h.store.statusUpdates()

        await driver.emit(.accountChange(.signOut))
        await driver.emit(.accountChange(.signIn))
        let seen = await takeStatuses(stream, count: 3)
        XCTAssertEqual(seen.map(\.phase), [.idle, .unavailable(.noAccount), .idle])
    }

    func testSignedOutKeepsChangesPendingUntilSignIn() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        try await h.store.syncNow()
        driver.accountStatusResult = .success(.noAccount)
        await driver.emit(.accountChange(.signOut))

        var persisted = await h.persisted
        XCTAssertFalse(persisted.zoneSaved, "zone belongs to the old account")
        XCTAssertTrue(persisted.systemFields.isEmpty)

        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertTrue(driver.sentBatches.isEmpty, "nothing is sent without an account")
        let blocked = await h.store.currentStatus()
        XCTAssertEqual(blocked.phase, .unavailable(.noAccount))
        XCTAssertEqual(blocked.pendingChangeCount, 1)

        driver.accountStatusResult = .success(.available)
        await driver.emit(.accountChange(.signIn))
        XCTAssertTrue(driver.zoneSavePending, "zone is created again for the new sign-in")
        try await h.store.syncNow()
        XCTAssertEqual(driver.sentBatches.count, 1)
        persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
        XCTAssertTrue(persisted.zoneSaved)
    }

    func testSwitchAccountsPausesUntilReset() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        await h.store.enqueue([.save(tabID)])
        let first = try h.driver
        await first.emit(.accountChange(.switchAccounts))

        XCTAssertTrue(first.isCancelled)
        let paused = await h.store.currentStatus()
        XCTAssertEqual(paused.phase, .unavailable(.accountChanged))
        XCTAssertEqual(paused.pendingChangeCount, 0, "old account's queue is dropped")
        do {
            try await h.store.syncNow()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncStoreError, .unavailable(.accountChanged))
        }
        let awaiting = await h.persisted.awaitingAccountReset
        XCTAssertTrue(awaiting)

        // A relaunch stays paused without creating a driver.
        let relaunched = StoreHarness(storage: h.storage)
        try await relaunched.start()
        XCTAssertNil(relaunched.drivers.current)
        let relaunchedPhase = await relaunched.store.currentStatus().phase
        XCTAssertEqual(relaunchedPhase, .unavailable(.accountChanged))

        // The app decides to reset: sync resumes with a fresh engine.
        await h.store.resetLocalSyncState()
        XCTAssertEqual(h.drivers.drivers.count, 2)
        let resumed = await h.store.currentStatus().phase
        XCTAssertEqual(resumed, .idle)
        let cleared = await h.persisted.awaitingAccountReset
        XCTAssertFalse(cleared)
    }

    // MARK: - Enqueue -> send -> confirm

    func testEnqueueSendConfirm() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver

        await h.store.enqueue([.save(tabID)])
        XCTAssertEqual(driver.pendingChanges, [.save(tabCKID)])
        var status = await h.store.currentStatus()
        XCTAssertEqual(status.pendingChangeCount, 1)
        let queued = await h.persisted.pending.entries.map(\.id)
        XCTAssertEqual(queued, [tabID], "queue is persisted on enqueue")

        try await h.store.syncNow()

        XCTAssertEqual(driver.sentBatches.count, 1)
        let sent = try XCTUnwrap(driver.sentBatches.first?.recordsToSave.first)
        XCTAssertEqual(sent.recordID, tabCKID)
        XCTAssertEqual(sent.recordType, "Tab")
        XCTAssertNil(sent.recordChangeTag, "first save has no server change tag")
        XCTAssertEqual(sent.encryptedValues[TabFields.title.key] as String?, "A page")
        XCTAssertTrue(driver.pendingChanges.isEmpty)

        let persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty, "confirmed change leaves the queue")
        XCTAssertTrue(persisted.zoneSaved)
        let cached = try XCTUnwrap(persisted.systemFields[tabID.recordName])
        XCTAssertEqual(RecordMapper.decodeSystemFields(cached)?.recordChangeTag, "srv-1")

        status = await h.store.currentStatus()
        XCTAssertEqual(status, SyncStatus(phase: .idle, lastSyncedAt: Fx.t(1000), pendingChangeCount: 0))

        // The next save of the same record carries the cached change tag.
        await h.database.put(.tab({ var t = Fx.tab(); t.customTitle = "Renamed"; return t }()))
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertEqual(driver.sentBatches.count, 2)
        XCTAssertEqual(tag(driver.sentBatches.last, tabID), "srv-1")
        XCTAssertEqual(driver.sentBatches.last?.recordsToSave.first?.encryptedValues[TabFields.customTitle.key] as String?, "Renamed")
    }

    func testDeleteIsSentAndConfirmed() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        await h.store.enqueue([.delete(tabID)])
        XCTAssertEqual(driver.pendingChanges, [.delete(tabCKID)])
        try await h.store.syncNow()
        XCTAssertEqual(driver.sentBatches.last?.recordIDsToDelete, [tabCKID])
        let persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
        XCTAssertNil(persisted.systemFields[tabID.recordName])
    }

    func testEditDuringSendStaysPending() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        let store = h.store
        let database = h.database
        let tabID = tabID
        // While the first save is in flight the user edits the tab again.
        driver.sendHandler = { [weak driver] batch in
            driver?.sendHandler = nil
            await database.put(.tab({ var t = Fx.tab(); t.customTitle = "Newer"; return t }()))
            await store.enqueue([.save(tabID)])
            return DriverSentRecordChanges(savedRecords: batch.recordsToSave.map { driver?.saved($0) ?? $0 })
        }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        var persisted = await h.persisted
        XCTAssertEqual(persisted.pending.entries.map(\.id), [tabID], "confirmation of the older send must not drop the newer edit")
        XCTAssertEqual(driver.pendingChanges, [.save(tabCKID)])

        try await h.store.syncNow()
        XCTAssertEqual(driver.sentBatches.last?.recordsToSave.first?.encryptedValues[TabFields.customTitle.key] as String?, "Newer")
        persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
    }

    func testPendingQueueSurvivesRestart() async throws {
        let storage = InMemoryStateStorage()
        let first = StoreHarness(records: [.tab(Fx.tab())], storage: storage)
        try await first.start()
        await first.store.enqueue([.save(tabID), .delete(folderID)])
        await first.store.stop()
        XCTAssertTrue(try first.driver.isCancelled)
        let stopped = await first.store.currentStatus().phase
        XCTAssertEqual(stopped, .disabled)

        let second = StoreHarness(records: [.tab(Fx.tab())], storage: storage)
        try await second.start()
        let driver = try second.driver
        XCTAssertEqual(driver.pendingChanges, [.save(tabCKID), .delete(Fx.mapper.recordID(for: folderID))])
        try await second.store.syncNow()
        let persisted = await second.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
    }

    func testRecordGoneLocallyIsDroppedFromQueue() async throws {
        let h = StoreHarness()
        try await h.start()
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertTrue(try h.driver.sentBatches.isEmpty)
        XCTAssertTrue(try h.driver.pendingChanges.isEmpty)
        let pending = await h.persisted.pending
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Scope

    /// Archive items are synced under the default scope (SyncScope.swift, pending product decision).
    func testArchiveItemsSyncByDefault() async throws {
        let h = StoreHarness(records: [.archiveItem(Fx.archiveItem())])
        try await h.start()
        await h.store.enqueue([.save(archiveID)])
        try await h.store.syncNow()
        XCTAssertEqual(try h.driver.sentBatches.first?.recordsToSave.first?.recordType, "ArchiveItem")
    }

    func testOutOfScopeSavesAreIgnoredAndLeftoversDeletedFromServer() async throws {
        var types = Set(SyncRecordType.allCases)
        types.remove(.archiveItem)
        let narrow = SyncScope(syncedTypes: types)

        let storage = InMemoryStateStorage()
        let wide = StoreHarness(records: [.archiveItem(Fx.archiveItem())], storage: storage)
        try await wide.start()
        await wide.store.enqueue([.save(archiveID)])
        await wide.store.stop()

        // Relaunch with a scope that no longer syncs archive items: the queued save becomes a delete.
        let h = StoreHarness(records: [.archiveItem(Fx.archiveItem())], scope: narrow, storage: storage)
        try await h.start()
        await h.store.enqueue([.save(SyncRecordID(type: .archiveItem, uuid: Fx.uuid(99)))])
        let pendingCount = await h.persisted.pending.count
        XCTAssertEqual(pendingCount, 1, "new out-of-scope saves are not queued")
        try await h.store.syncNow()
        let driver = try h.driver
        XCTAssertTrue(driver.sentBatches.allSatisfy { $0.recordsToSave.isEmpty })
        XCTAssertEqual(driver.sentBatches.first?.recordIDsToDelete, [Fx.mapper.recordID(for: archiveID)])
        let pending = await h.persisted.pending
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - Conflicts

    func testServerRecordChangedIsMergedAppliedAndResent() async throws {
        // Local: renamed at t30. Server: navigated at t20 (unknown to us).
        var local = Fx.tab()
        local.customTitle = "Local rename"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(30))
        var server = Fx.tab()
        server.url = URL(string: "https://server.example/")
        server.title = "Server nav"
        server.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(20))
        let serverCK = Fx.serverCK(.tab(server), tag: "server-7")

        let h = StoreHarness(records: [.tab(local)])
        try await h.start()
        let driver = try h.driver
        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.serverRecordChanged, serverRecord: serverCK) }

        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        // Merged copy applied locally: both edits survive.
        let mergedRecord = await h.database.record(for: tabID)
        let merged = try XCTUnwrap(mergedRecord?.tab)
        XCTAssertEqual(merged.customTitle, "Local rename")
        XCTAssertEqual(merged.url, URL(string: "https://server.example/"))
        XCTAssertEqual(merged.title, "Server nav")
        var persisted = await h.persisted
        XCTAssertEqual(persisted.pending.entries.map(\.id), [tabID], "local won a group: still pending")
        XCTAssertEqual(driver.pendingChanges, [.save(tabCKID)])
        XCTAssertEqual(RecordMapper.decodeSystemFields(try XCTUnwrap(persisted.systemFields[tabID.recordName]))?.recordChangeTag, "server-7")
        let phase = await h.store.currentStatus().phase
        XCTAssertEqual(phase, .idle, "a resolved conflict is not a failure")

        // Resend carries the server change tag and the merged values.
        try await h.store.syncNow()
        let resent = try XCTUnwrap(driver.sentBatches.last?.recordsToSave.first)
        XCTAssertEqual(resent.recordChangeTag, "server-7")
        XCTAssertEqual(resent.encryptedValues[TabFields.customTitle.key] as String?, "Local rename")
        XCTAssertEqual(resent.encryptedValues[TabFields.url.key] as String?, "https://server.example/")
        persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
    }

    func testConflictWonByServerIsAppliedWithoutResend() async throws {
        var local = Fx.tab()
        local.customTitle = "Old local"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(10))
        var server = Fx.tab()
        server.customTitle = "Newer server"
        server.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(20))
        let serverCK = Fx.serverCK(.tab(server), tag: "server-8")

        let h = StoreHarness(records: [.tab(local)])
        try await h.start()
        let driver = try h.driver
        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.serverRecordChanged, serverRecord: serverCK) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        let applied = await h.database.record(for: tabID)?.tab
        XCTAssertEqual(applied?.customTitle, "Newer server")
        XCTAssertTrue(driver.pendingChanges.isEmpty)
        let persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
        XCTAssertEqual(driver.sentBatches.count, 1)
    }

    func testLocalDeleteBeatsServerEditInConflictAndIsResent() async throws {
        var local = Fx.tab()
        local.meta.markDeleted(at: Fx.t(10))
        var server = Fx.tab()
        server.customTitle = "Server edit"
        server.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(50))
        let serverCK = Fx.serverCK(.tab(server), tag: "server-9")

        let h = StoreHarness(records: [.tab(local)])
        try await h.start()
        let driver = try h.driver
        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.serverRecordChanged, serverRecord: serverCK) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        let applied = await h.database.record(for: tabID)
        XCTAssertEqual(applied?.meta.isTombstone, true)
        try await h.store.syncNow()
        let resent = try XCTUnwrap(driver.sentBatches.last?.recordsToSave.first)
        XCTAssertEqual(resent[MetaFields.isTombstone.key] as? Int64, 1)
        XCTAssertEqual(resent.recordChangeTag, "server-9")
    }

    // MARK: - Fetched changes

    func testFetchedModificationsAndDeletionsAreApplied() async throws {
        // Local tab renamed at t30; server navigated it at t20. Server also has a new folder and
        // deleted our archive item.
        var local = Fx.tab()
        local.customTitle = "Local rename"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(30))
        var serverTab = Fx.tab()
        serverTab.title = "Server title"
        serverTab.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(20))
        let serverFolder = Fx.folder()

        let h = StoreHarness(records: [.tab(local), .archiveItem(Fx.archiveItem())])
        try await h.start()
        let driver = try h.driver
        driver.queueFetch([.fetchedRecordChanges(
            modified: [Fx.serverCK(.tab(serverTab), tag: "t-1"), Fx.serverCK(.folder(serverFolder), tag: "f-1")],
            deleted: [DriverFetchedDeletion(recordID: Fx.mapper.recordID(for: archiveID), recordType: "ArchiveItem")]
        )])
        try await h.store.syncNow()

        let batches = await h.database.appliedBatches
        XCTAssertEqual(batches.count, 1, "server changes are applied in one batch")
        XCTAssertEqual(batches.first?.deletions, [archiveID])

        let mergedRecord = await h.database.record(for: tabID)
        let mergedTab = try XCTUnwrap(mergedRecord?.tab)
        XCTAssertEqual(mergedTab.customTitle, "Local rename")
        XCTAssertEqual(mergedTab.title, "Server title")
        let folder = await h.database.record(for: folderID)
        XCTAssertEqual(folder?.withoutSystemFields, .folder(serverFolder))
        let archive = await h.database.record(for: archiveID)
        XCTAssertNil(archive)

        // The merged tab (local won `naming`) went back up in the same sync, with the server tag.
        XCTAssertEqual(tag(driver.sentBatches.last, tabID), "t-1")
        XCTAssertEqual(driver.sentBatches.last?.recordsToSave.count, 1)
        let persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
        XCTAssertNotNil(persisted.systemFields[folderID.recordName])
    }

    func testServerDeletionDropsPendingLocalEdit() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID)])
        driver.queueFetch([.fetchedRecordChanges(modified: [], deleted: [DriverFetchedDeletion(recordID: tabCKID, recordType: "Tab")])])
        try await h.store.syncNow()

        let record = await h.database.record(for: tabID)
        XCTAssertNil(record, "delete wins")
        XCTAssertTrue(driver.sentBatches.isEmpty)
        let persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
    }

    func testFetchedCopyIgnoredWhileLocalDeleteIsPending() async throws {
        let h = StoreHarness()
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.delete(tabID)])
        driver.queueFetch([.fetchedRecordChanges(modified: [Fx.serverCK(.tab(Fx.tab()), tag: "t")], deleted: [])])
        try await h.store.syncNow()
        let record = await h.database.record(for: tabID)
        XCTAssertNil(record, "pending local delete is not undone by a fetched copy")
        XCTAssertEqual(driver.sentBatches.last?.recordIDsToDelete, [tabCKID])
    }

    func testFetchedRecordOutsideScopeOrUndecodableIsIgnored() async throws {
        var types = Set(SyncRecordType.allCases)
        types.remove(.archiveItem)
        let h = StoreHarness(scope: SyncScope(syncedTypes: types))
        try await h.start()
        let broken = CKRecord(recordType: "Tab", recordID: CKRecord.ID(recordName: "garbage", zoneID: Fx.zoneID))
        try h.driver.queueFetch([.fetchedRecordChanges(
            modified: [Fx.serverCK(.archiveItem(Fx.archiveItem()), tag: "a"), broken, Fx.serverCK(.folder(Fx.folder()), tag: "f")],
            deleted: []
        )])
        try await h.store.syncNow()
        let archive = await h.database.record(for: archiveID)
        XCTAssertNil(archive)
        let folder = await h.database.record(for: folderID)
        XCTAssertNotNil(folder)
    }

    func testFailedApplyIsDeferredAndRetried() async throws {
        let h = StoreHarness()
        try await h.start()
        let driver = try h.driver
        await h.database.failNextApplies(1)
        driver.queueFetch([.fetchedRecordChanges(modified: [Fx.serverCK(.folder(Fx.folder()), tag: "f")], deleted: [])])
        try await h.store.syncNow()

        var folder = await h.database.record(for: folderID)
        XCTAssertNil(folder)
        // Staged remote changes keep the status at failed and do not advance lastSyncedAt,
        // even though the send in the same cycle succeeded (plan Q3).
        let deferred = await h.persisted.deferredUpserts.map(\.id)
        XCTAssertEqual(deferred, [folderID])
        let staged = await h.store.currentStatus()
        guard case .failed = staged.phase else { return XCTFail("expected failed, got \(staged.phase)") }
        XCTAssertNil(staged.lastSyncedAt)

        try await h.store.syncNow()
        folder = await h.database.record(for: folderID)
        XCTAssertNotNil(folder)
        let persisted = await h.persisted
        XCTAssertTrue(persisted.deferredUpserts.isEmpty)
        let recovered = await h.store.currentStatus().phase
        XCTAssertEqual(recovered, .idle)
    }

    // MARK: - Zones

    func testEncryptedDataResetReuploadsKnownRecords() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab()), .folder(Fx.folder())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID), .save(folderID)])
        try await h.store.syncNow()

        await driver.emit(.zonesDeleted([Fx.zoneID: .encryptedDataReset]))
        let persisted = await h.persisted
        XCTAssertEqual(Set(persisted.pending.entries.map(\.id)), [tabID, folderID])
        XCTAssertFalse(persisted.zoneSaved)
        XCTAssertTrue(persisted.systemFields.isEmpty)

        try await h.store.syncNow()
        let resent = try XCTUnwrap(driver.sentBatches.last)
        XCTAssertEqual(resent.recordsToSave.count, 2)
        XCTAssertTrue(resent.recordsToSave.allSatisfy { $0.recordChangeTag == nil }, "saved as new records")
    }

    func testPurgedZoneDropsQueueAndOtherZonesAreIgnored() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID)])

        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        await driver.emit(.zonesDeleted([otherZone: .purged]))
        var pending = await h.persisted.pending
        XCTAssertEqual(pending.count, 1)

        await driver.emit(.zonesDeleted([Fx.zoneID: .purged]))
        pending = await h.persisted.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(driver.pendingChanges.isEmpty)
        let record = await h.database.record(for: tabID)
        XCTAssertNotNil(record, "local data stays")
    }

    func testZoneNotFoundOnSaveRecreatesZoneAndResendsAsNew() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertFalse(driver.zoneSavePending)

        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.zoneNotFound) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertTrue(driver.zoneSavePending)
        var persisted = await h.persisted
        XCTAssertFalse(persisted.zoneSaved)
        XCTAssertEqual(persisted.pending.count, 1)

        try await h.store.syncNow()
        XCTAssertNil(tag(driver.sentBatches.last, tabID), "old change tag dropped with the zone")
        persisted = await h.persisted
        XCTAssertTrue(persisted.zoneSaved)
        XCTAssertTrue(persisted.pending.isEmpty)
    }

    // MARK: - Per-record failures

    func testUnknownItemResendsWithoutChangeTag() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        let cachedFields = await h.persisted.systemFields[tabID.recordName]
        XCTAssertNotNil(cachedFields)

        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.unknownItem) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertEqual(tag(driver.sentBatches.last, tabID), "srv-1", "first attempt still used the old tag")
        try await h.store.syncNow()
        XCTAssertNil(tag(driver.sentBatches.last, tabID), "resent as a new record")
        let pending = await h.persisted.pending
        XCTAssertTrue(pending.isEmpty)
    }

    func testPermanentErrorDiscardsChangeAndReportsFailure() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.invalidArguments) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        XCTAssertTrue(driver.pendingChanges.isEmpty)
        let status = await h.store.currentStatus()
        XCTAssertEqual(status.pendingChangeCount, 0, "queue must not stall")
        guard case .failed(let message) = status.phase else { return XCTFail("expected failed, got \(status.phase)") }
        XCTAssertTrue(message.contains(tabID.recordName))
        XCTAssertTrue(h.scheduler.delays.isEmpty, "permanent errors are not retried")
    }

    func testFailedDeleteOfMissingRecordCountsAsDone() async throws {
        let h = StoreHarness()
        try await h.start()
        let driver = try h.driver
        let unknownItem = ckError(.unknownItem)
        driver.sendHandler = { batch in
            DriverSentRecordChanges(failedDeletes: batch.recordIDsToDelete.map { DriverFailedDelete(recordID: $0, error: unknownItem) })
        }
        await h.store.enqueue([.delete(tabID)])
        try await h.store.syncNow()
        let pending = await h.persisted.pending
        XCTAssertTrue(pending.isEmpty)
        XCTAssertTrue(driver.pendingChanges.isEmpty)
    }

    func testAccountErrorOnSaveKeepsChangePending() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.notAuthenticated) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        let status = await h.store.currentStatus()
        XCTAssertEqual(status.phase, .unavailable(.noAccount))
        XCTAssertEqual(status.pendingChangeCount, 1)
        XCTAssertEqual(driver.pendingChanges, [.save(tabCKID)])
    }

    // MARK: - Retry scheduling (injected scheduler, no sleeps)

    func testOperationErrorSchedulesRetryWithServerDelay() async throws {
        let h = StoreHarness()
        try await h.start()
        let driver = try h.driver
        driver.failNextFetch(ckError(.requestRateLimited, retryAfter: 30))

        do {
            try await h.store.syncNow()
            XCTFail("expected the fetch error")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .requestRateLimited)
        }
        XCTAssertEqual(h.scheduler.delays, [30])
        let failed = await h.store.currentStatus().phase
        XCTAssertEqual(failed, .failed(message: "CloudKit error \(CKError.Code.requestRateLimited.rawValue)"))

        // Only one retry is scheduled at a time.
        driver.failNextFetch(ckError(.networkFailure))
        try? await h.store.syncNow()
        XCTAssertEqual(h.scheduler.delays, [30])

        let ran = await h.scheduler.runNext()
        XCTAssertTrue(ran)
        let recovered = await h.store.currentStatus().phase
        XCTAssertEqual(recovered, .idle, "the scheduled retry ran syncNow successfully")
    }

    func testBackoffGrowsAcrossFailedRetriesAndResetsAfterSuccess() async throws {
        let h = StoreHarness()
        try await h.start()
        let driver = try h.driver
        driver.failNextFetch(ckError(.networkFailure))
        driver.failNextSend(ckError(.serviceUnavailable))
        try? await h.store.syncNow()
        XCTAssertEqual(h.scheduler.delays, [2])

        // Retry 1: the fetch succeeds, the send fails again.
        await h.scheduler.runNext()
        XCTAssertEqual(h.scheduler.delays, [2, 4])

        // Retry 2 succeeds.
        await h.scheduler.runNext()
        XCTAssertEqual(h.scheduler.queuedCount, 0)
        let phase = await h.store.currentStatus().phase
        XCTAssertEqual(phase, .idle)

        // A later failure starts from the first step again.
        driver.failNextFetch(ckError(.networkFailure))
        try? await h.store.syncNow()
        XCTAssertEqual(h.scheduler.delays, [2, 4, 2])
    }

    func testTransientRecordErrorKeepsChangeAndRetries() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        driver.sendHandler = failingSaves(driver, times: 1) { _ in ckError(.zoneBusy, retryAfter: 5) }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()

        XCTAssertEqual(h.scheduler.delays, [5])
        XCTAssertEqual(driver.pendingChanges, [.save(tabCKID)])
        let failed = await h.store.currentStatus()
        guard case .failed = failed.phase else { return XCTFail("expected failed, got \(failed.phase)") }
        XCTAssertEqual(failed.pendingChangeCount, 1)

        await h.scheduler.runNext()
        XCTAssertEqual(driver.sentBatches.count, 2)
        let status = await h.store.currentStatus()
        XCTAssertEqual(status.phase, .idle)
        XCTAssertEqual(status.pendingChangeCount, 0)
    }

    func testScheduledRetryAfterStopDoesNothing() async throws {
        let h = StoreHarness()
        try await h.start()
        try h.driver.failNextFetch(ckError(.networkFailure))
        try? await h.store.syncNow()
        await h.store.stop()
        await h.scheduler.runNext()
        let phase = await h.store.currentStatus().phase
        XCTAssertEqual(phase, .disabled)
    }

    // MARK: - Status stream

    func testStatusStreamReportsSyncCycleAndPendingCount() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let stream = h.store.statusUpdates()
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        let seen = await collectStatuses(stream) { $0.phase == .idle && $0.pendingChangeCount == 0 && $0.lastSyncedAt != nil }
        XCTAssertEqual(seen.first, SyncStatus(phase: .idle))
        XCTAssertTrue(seen.contains(SyncStatus(phase: .idle, pendingChangeCount: 1)))
        XCTAssertTrue(seen.contains { $0.phase == .syncing })
        XCTAssertEqual(seen.last, SyncStatus(phase: .idle, lastSyncedAt: Fx.t(1000), pendingChangeCount: 0))
    }
}

/// Thread-safe call counter for send handlers.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// Increments and returns the new value (first call returns 1).
    func next() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}

/// Builds a CKError the way CloudKit reports it.
func ckError(_ code: CKError.Code, retryAfter: Double? = nil, serverRecord: CKRecord? = nil) -> CKError {
    var info: [String: Any] = [:]
    if let retryAfter { info[CKErrorRetryAfterKey] = NSNumber(value: retryAfter) }
    if let serverRecord { info[CKRecordChangedErrorServerRecordKey] = serverRecord }
    return CKError(code, userInfo: info)
}
