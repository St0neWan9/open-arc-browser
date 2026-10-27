import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// Plan D10 (encrypted fields and their migration), D11 (sync schema version guard) and D12
/// ("Delete iCloud Data…"). docs/arc-spec/03-settings.md §账号卡: "Arc Sync is end-to-end
/// encrypted" (observed); an older build does not overwrite data written by a newer one, and the
/// synced data can be wiped (both inferred (analysis)). Field split, version rule and wording are ours.
final class SchemaEvolutionTests: XCTestCase {

    private let mapper = Fx.mapper
    private let tabID = SyncRecordID(type: .tab, uuid: Fx.uuid(5))
    private let folderID = SyncRecordID(type: .folder, uuid: Fx.uuid(4))
    private var tabCKID: CKRecord.ID { Fx.mapper.recordID(for: tabID) }

    /// The CKRecord a build from before D10 wrote: the migrated fields under their plain keys.
    private func preMigrationRecord(_ record: SyncRecord) -> CKRecord {
        let ck = mapper.makeCKRecord(record, systemFields: nil)
        for spec in RecordSchema.contentFields(of: record.id.type) {
            guard let legacyKey = spec.legacyKey else { continue }
            ck.setObject(ck.encryptedValues.object(forKey: spec.key), forKey: legacyKey)
            ck.encryptedValues.setObject(nil, forKey: spec.key)
        }
        ck[MetaFields.schemaVersion.key] = nil as Int64?
        return ck
    }

    /// A server copy written by a newer build (schema version 99).
    private func newerServerCK(_ record: SyncRecord, tag: String) -> CKRecord {
        let ck = Fx.serverCK(record, tag: tag)
        ck[MetaFields.schemaVersion.key] = RecordSchema.currentVersion + 97
        return ck
    }

    // MARK: - D10: field split and migration

    /// [03 §账号卡] "end-to-end encrypted" observed; Arc encrypts the whole sidebar payload,
    /// inferred (analysis). D10 moves a theme's style and an easel element's frame and style.
    func testMigratedFieldsAreEncryptedAndTheirPlainKeysCleared() throws {
        let migrated: [SyncRecordType: [String]] = [
            .theme: ["style_appearance", "style_colors", "style_grain", "style_brightness"],
            .easelElement: ["geometry_frame", "style_style"],
        ]
        for record in Fx.fullRecords() {
            let type = record.id.type
            let legacy = RecordSchema.legacyFields(of: type).map(\.key)
            XCTAssertEqual(legacy, migrated[type] ?? [], "\(type)")
            let ck = mapper.makeCKRecord(record, systemFields: nil)
            for spec in RecordSchema.contentFields(of: type) where spec.legacyKey != nil {
                XCTAssertTrue(spec.encrypted, "\(type).\(spec.key)")
                XCTAssertEqual(spec.key, spec.legacyKey! + "Enc", "\(type).\(spec.key)")
                XCTAssertNotNil(ck.encryptedValues.object(forKey: spec.key), "\(type).\(spec.key)")
                XCTAssertNil(ck.object(forKey: spec.legacyKey!), "\(type).\(spec.legacyKey!) must not be written")
            }
        }
        // Only tree structure and timestamps stay plain on the migrated types.
        XCTAssertEqual(RecordSchema.contentFields(of: .theme).filter { !$0.encrypted }.map(\.key), [])
        XCTAssertEqual(RecordSchema.contentFields(of: .easelElement).filter { !$0.encrypted }.map(\.key),
                       ["placement_easelID", "placement_zKey"])
    }

    /// A record written before D10 (plain keys only) still decodes, and the next save from a
    /// record rebuilt out of its system fields clears the plain copy on the server.
    func testPreMigrationRecordsDecodeAndTheNextSaveClearsThePlainKeys() throws {
        for record in [SyncRecord.theme(Fx.theme()), .easelElement(Fx.easelElement())] {
            let old = preMigrationRecord(record)
            XCTAssertEqual(RecordMapper.schemaVersion(of: old), 1)
            XCTAssertEqual(try mapper.decode(old).withoutSystemFields, record, "\(record.id.type)")

            let server = Fx.serverCK(record, tag: "t1")
            let outgoing = mapper.makeCKRecord(record, systemFields: RecordMapper.encodeSystemFields(of: server))
            for legacy in RecordSchema.legacyFields(of: record.id.type) {
                XCTAssertTrue(outgoing.changedKeys().contains(legacy.key), "\(legacy.key) is cleared on the server")
                XCTAssertNil(outgoing[legacy.key])
            }
        }
    }

    /// A build from before D10 edits a record a newer build wrote: it sets the plain key and
    /// leaves the encrypted one alone, so the plain value is the newer one and wins.
    func testPlainValueFromAnOlderBuildWinsOverTheEncryptedOne() throws {
        let ck = mapper.makeCKRecord(.theme(Fx.theme(variant: 0)), systemFields: nil)
        ck["style_grain"] = 0.9
        ck["style_appearance"] = "light"
        guard case .theme(let decoded) = try mapper.decode(ck) else { return XCTFail("wrong type") }
        XCTAssertEqual(decoded.grain, 0.9)
        XCTAssertEqual(decoded.appearance, .light)
        XCTAssertEqual(decoded.colors, Fx.theme(variant: 0).colors, "untouched fields read the encrypted key")
    }

    // MARK: - D11: schema version guard

    func testEveryRecordCarriesTheWritersSchemaVersion() {
        for record in Fx.fullRecords() + Fx.sparseRecords() {
            let ck = mapper.makeCKRecord(record, systemFields: nil)
            XCTAssertEqual(ck[MetaFields.schemaVersion.key] as? Int64, RecordSchema.currentVersion, "\(record.id)")
            XCTAssertEqual(RecordMapper.schemaVersion(of: ck), RecordSchema.currentVersion)
        }
        XCTAssertEqual(RecordSchema.currentVersion, 2)
    }

    /// [03 §账号卡] inferred (analysis): an older build reads newer records but never overwrites
    /// them. The fetched copy is applied, a local edit stays queued without an upload, and the
    /// status asks for an app update. Records from older builds still decode and upload.
    func testNewerRecordIsReadButNeverOverwritten() async throws {
        var local = Fx.tab()
        local.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(1))
        let h = StoreHarness(records: [.tab(local), .folder(Fx.folder())])
        try await h.start()
        let driver = try h.driver

        var server = Fx.tab()
        server.title = "From a newer build"
        server.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(20))
        let folderCK = preMigrationRecord(.folder(Fx.folder(variant: 1)))
        driver.queueFetch([.fetchedRecordChanges(modified: [newerServerCK(.tab(server), tag: "n1"), folderCK], deleted: [])])
        try await h.store.syncNow()

        // Read OK: the newer copy is applied locally, and the old-format folder decodes.
        let applied = await h.database.record(for: tabID)
        XCTAssertEqual(applied?.tab?.title, "From a newer build")
        let folder = await h.database.record(for: folderID)
        guard case .folder(let decodedFolder) = folder else { return XCTFail("folder not applied") }
        XCTAssertEqual(decodedFolder.title, "Docs")
        var status = await h.store.currentStatus()
        XCTAssertTrue(status.needsAppUpdate)
        XCTAssertEqual(status.phase, .idle, "reading newer records is not a failure")

        // A local edit to it is kept but never sent; a save and a delete alike.
        var edited = try XCTUnwrap(applied?.tab)
        edited.customTitle = "Local rename"
        edited.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(30))
        await h.database.put(.tab(edited))
        await h.store.enqueue([.save(tabID), .save(folderID)])
        XCTAssertEqual(driver.pendingChanges, [.save(Fx.mapper.recordID(for: folderID))], "held record never reaches the engine")
        try await h.store.syncNow()
        let sentNames = driver.sentBatches.flatMap { $0.recordsToSave.map(\.recordID.recordName) + $0.recordIDsToDelete.map(\.recordName) }
        XCTAssertFalse(sentNames.contains(tabID.recordName), "no upload over a newer record")
        XCTAssertTrue(sentNames.contains(folderID.recordName), "older-format records still upload")
        await h.store.enqueue([.delete(tabID)])
        try await h.store.syncNow()
        XCTAssertFalse(driver.sentBatches.flatMap(\.recordIDsToDelete).contains(tabCKID))

        let persisted = await h.persisted
        XCTAssertEqual(persisted.pending.entries.map(\.id), [tabID], "the edit waits in the queue")
        XCTAssertEqual(persisted.newerRecords[tabID.recordName], RecordSchema.currentVersion + 97)
        status = await h.store.currentStatus()
        XCTAssertEqual(status.pendingChangeCount, 1)
        XCTAssertTrue(status.needsAppUpdate)
    }

    /// A newer record that this build cannot even decode (a value it does not know) is still
    /// held: nothing this build has may replace it.
    func testUndecodableNewerRecordIsHeldToo() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        let ck = newerServerCK(.tab(Fx.tab()), tag: "n1")
        ck[TabFields.locationKind.key] = "someFutureLocation"
        driver.queueFetch([.fetchedRecordChanges(modified: [ck], deleted: [])])
        try await h.store.syncNow()

        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        XCTAssertTrue(driver.sentBatches.isEmpty)
        let status = await h.store.currentStatus()
        XCTAssertTrue(status.needsAppUpdate)
    }

    /// The save raced a newer build's write: the conflict returns its copy. The merge is applied
    /// locally, but nothing goes back up, even though the local copy won a group.
    func testConflictWithANewerRecordIsMergedLocallyAndNotResent() async throws {
        var local = Fx.tab()
        local.customTitle = "Local rename"
        local.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(30))
        var server = Fx.tab()
        server.title = "Server nav"
        server.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(20))
        let serverCK = newerServerCK(.tab(server), tag: "n7")

        let h = StoreHarness(records: [.tab(local)])
        try await h.start()
        let driver = try h.driver
        let calls = Counter()
        driver.sendHandler = { [weak driver] batch in
            if calls.next() == 1 {
                return DriverSentRecordChanges(failedSaves: batch.recordsToSave.map {
                    DriverFailedSave(record: $0, error: ckError(.serverRecordChanged, serverRecord: serverCK))
                })
            }
            return DriverSentRecordChanges(savedRecords: batch.recordsToSave.map { driver?.saved($0) ?? $0 })
        }
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        try await h.store.syncNow()

        let merged = await h.database.record(for: tabID)?.tab
        XCTAssertEqual(merged?.customTitle, "Local rename")
        XCTAssertEqual(merged?.title, "Server nav")
        XCTAssertEqual(driver.sentBatches.count, 1, "only the first, refused save")
        XCTAssertTrue(driver.pendingChanges.isEmpty)
        let status = await h.store.currentStatus()
        XCTAssertTrue(status.needsAppUpdate)
    }

    /// The hold ends when the record's server copy is no longer newer (the newer build's data was
    /// rewritten at this build's version, e.g. after a downgrade there) or when the app is updated:
    /// the queued edit then goes up.
    func testHoldEndsWhenTheServerCopyIsNoLongerNewer() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        let driver = try h.driver
        driver.queueFetch([.fetchedRecordChanges(modified: [newerServerCK(.tab(Fx.tab()), tag: "n1")], deleted: [])])
        try await h.store.syncNow()
        var edited = Fx.tab()
        edited.customTitle = "Local rename"
        edited.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(30))
        await h.database.put(.tab(edited))
        await h.store.enqueue([.save(tabID)])
        XCTAssertTrue(driver.pendingChanges.isEmpty)

        driver.queueFetch([.fetchedRecordChanges(modified: [Fx.serverCK(.tab(Fx.tab()), tag: "c2")], deleted: [])])
        try await h.store.syncNow()
        let sent = try XCTUnwrap(driver.sentBatches.last?.recordsToSave.first)
        XCTAssertEqual(sent.recordID, tabCKID)
        XCTAssertEqual(sent.encryptedValues[TabFields.customTitle.key] as String?, "Local rename")
        XCTAssertEqual(sent.recordChangeTag, "c2")
        let status = await h.store.currentStatus()
        XCTAssertFalse(status.needsAppUpdate)
        let persisted = await h.persisted
        XCTAssertTrue(persisted.pending.isEmpty)
        XCTAssertTrue(persisted.newerRecords.isEmpty)
    }

    /// The hold survives a relaunch: the restored queue does not hand the held change to the engine.
    func testHoldSurvivesRestart() async throws {
        let storage = InMemoryStateStorage()
        let first = StoreHarness(records: [.tab(Fx.tab())], storage: storage)
        try await first.start()
        try first.driver.queueFetch([.fetchedRecordChanges(modified: [newerServerCK(.tab(Fx.tab()), tag: "n1")], deleted: [])])
        try await first.store.syncNow()
        await first.store.enqueue([.save(tabID), .save(folderID)])
        await first.store.stop()

        let second = StoreHarness(records: [.tab(Fx.tab()), .folder(Fx.folder())], storage: storage)
        try await second.start()
        XCTAssertEqual(try second.driver.pendingChanges, [.save(Fx.mapper.recordID(for: folderID))])
        let status = await second.store.currentStatus()
        XCTAssertTrue(status.needsAppUpdate)
    }

    // MARK: - D12: Delete iCloud Data

    /// [03 §账号卡] inferred (analysis): the synced data can be wiped. Deletes our zone and the
    /// local sync state, leaves the workspace alone and the store stopped.
    func testDeleteServerDataDeletesZoneAndSyncStateButKeepsWorkspace() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab()), .folder(Fx.folder())])
        try await h.start()
        let driver = try h.driver
        await h.store.enqueue([.save(tabID), .save(folderID)])
        try await h.store.syncNow()
        await h.store.enqueue([.save(tabID)])

        try await h.store.deleteServerData(database: h.database)

        XCTAssertEqual(h.zoneDeleter.deleted, [Fx.zoneID])
        XCTAssertTrue(driver.isCancelled)
        let persisted = await h.persisted
        XCTAssertNil(persisted.engineState)
        XCTAssertTrue(persisted.pending.isEmpty)
        XCTAssertTrue(persisted.systemFields.isEmpty)
        XCTAssertFalse(persisted.zoneSaved)
        XCTAssertNil(persisted.lastSyncedAt)
        let status = await h.store.currentStatus()
        XCTAssertEqual(status, .disabled)
        // Workspace intact, and never written through `apply`.
        let tab = await h.database.record(for: tabID)
        let folder = await h.database.record(for: folderID)
        XCTAssertNotNil(tab)
        XCTAssertNotNil(folder)
        let applied = await h.database.appliedBatches
        XCTAssertTrue(applied.isEmpty)
        do {
            try await h.store.syncNow()
            XCTFail("the store is stopped")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncStoreError, .notStarted)
        }
    }

    /// Plan Q12: turning sync on again uploads everything, as new records into a new zone. The
    /// engine reporting the zone we deleted ourselves must not drop that upload.
    func testTurningSyncOnAgainReuploadsEverything() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab()), .folder(Fx.folder())])
        try await h.start()
        await h.store.enqueue([.save(tabID), .save(folderID)])
        try await h.store.syncNow()
        try await h.store.deleteServerData(database: h.database)

        // What `SidebarSyncController` does when "Sync Sidebar" is turned on again.
        try await h.start()
        let driver = try h.driver
        XCTAssertNil(driver.engineState, "a fresh engine")
        await h.store.enqueue([.save(tabID), .save(folderID)])
        await driver.emit(.zonesDeleted([Fx.zoneID: .deleted]))
        XCTAssertEqual(Set(driver.pendingChanges), [.save(tabCKID), .save(Fx.mapper.recordID(for: folderID))])
        try await h.store.syncNow()

        let resent = driver.sentBatches.flatMap(\.recordsToSave)
        XCTAssertEqual(Set(resent.map(\.recordID.recordName)), [tabID.recordName, folderID.recordName])
        XCTAssertTrue(resent.allSatisfy { $0.recordChangeTag == nil }, "saved as new records")
        let persisted = await h.persisted
        XCTAssertTrue(persisted.zoneSaved)
        XCTAssertNil(persisted.deletedOwnZone)
        XCTAssertTrue(persisted.pending.isEmpty)

        // Once the zone is back, a deletion reported later is another device's: the usual rule.
        await h.store.enqueue([.save(tabID)])
        await driver.emit(.zonesDeleted([Fx.zoneID: .deleted]))
        let pending = await h.persisted.pending
        XCTAssertTrue(pending.isEmpty)
    }

    /// While sync is off the store is not running; the deletion uses the database's sync state.
    func testDeleteServerDataWhileStopped() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        await h.store.stop()

        try await h.store.deleteServerData(database: h.database)
        XCTAssertEqual(h.zoneDeleter.deleted, [Fx.zoneID])
        XCTAssertEqual(h.drivers.drivers.count, 1, "no engine is started for the deletion")
        let persisted = await h.persisted
        XCTAssertNil(persisted.engineState)
        XCTAssertTrue(persisted.systemFields.isEmpty)
    }

    /// A failed deletion changes nothing: the error is thrown and a running store keeps running
    /// with the same state.
    func testFailedDeletionChangesNothing() async throws {
        let h = StoreHarness(records: [.tab(Fx.tab())])
        try await h.start()
        await h.store.enqueue([.save(tabID)])
        try await h.store.syncNow()
        let before = await h.persisted
        h.zoneDeleter.failNext(CKError(.networkUnavailable))

        do {
            try await h.store.deleteServerData(database: h.database)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? CKError)?.code, .networkUnavailable)
        }
        XCTAssertTrue(h.zoneDeleter.deleted.isEmpty)
        XCTAssertEqual(h.drivers.drivers.count, 2, "the engine is brought up again")
        let after = await h.persisted
        XCTAssertEqual(after.systemFields, before.systemFields)
        XCTAssertEqual(after.lastSyncedAt, before.lastSyncedAt)
        let phase = await h.store.currentStatus().phase
        XCTAssertEqual(phase, .idle)
        try await h.store.syncNow()
    }

    func testDeleteServerDataWithoutTheEntitlementThrows() async {
        let h = StoreHarness(isEntitled: false)
        do {
            try await h.store.deleteServerData(database: h.database)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncStoreError, .unavailable(.notConfigured))
        }
        XCTAssertTrue(h.zoneDeleter.deleted.isEmpty)
    }
}
