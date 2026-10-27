import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// RecordMapper: model <-> CKRecord. The encrypted groups come from
/// docs/arc-spec/03-settings.md ("Arc Sync is end-to-end encrypted", observed); the per-field
/// split is our own decision (RecordSchema.swift).
final class RecordMapperTests: XCTestCase {
    private let mapper = Fx.mapper

    /// Gives a record non-default metadata so the round trip covers every meta field.
    private func withRichMeta(_ record: SyncRecord) -> SyncRecord {
        record.mapMeta { meta in
            meta.modifiedAt = Fx.t(50)
            meta.version = 7
            for (index, group) in RecordSchema.groups(of: record.id.type).enumerated() {
                meta.fieldGroupModifiedAt[group] = Fx.t(Double(10 + index))
            }
        }
    }

    // MARK: Round trip

    func testRoundTripEveryEntityTypeWithAllFieldsSet() throws {
        let records = Fx.fullRecords().map(withRichMeta)
        XCTAssertEqual(Set(records.map(\.id.type)), Set(SyncRecordType.allCases), "fixture must cover every type")
        for record in records {
            let ck = mapper.makeCKRecord(record, systemFields: nil)
            let decoded = try mapper.decode(ck)
            XCTAssertEqual(decoded.withoutSystemFields, record, "\(record.id.type)")
            XCTAssertNotNil(decoded.meta.backendSystemFields, "decode must attach system fields")
        }
    }

    func testRoundTripWithOptionalFieldsEmptyAndEveryTabLocation() throws {
        for record in Fx.sparseRecords() {
            let decoded = try mapper.decode(mapper.makeCKRecord(record, systemFields: nil))
            XCTAssertEqual(decoded.withoutSystemFields, record, "\(record.id)")
        }
        let favorite = SyncRecord.tab(Fx.tab(variant: 1))
        XCTAssertEqual(try mapper.decode(mapper.makeCKRecord(favorite, systemFields: nil)).withoutSystemFields, favorite)
    }

    /// `Theme.brightness` (the [06 §2] ring knob, inferred) syncs as the plain `style_brightness`
    /// key in the `style` group. A record saved before the key existed decodes with the default.
    func testThemeBrightnessSyncsAndOldRecordsDecodeWithDefault() throws {
        let theme = Fx.theme(variant: 1)
        let ck = mapper.makeCKRecord(.theme(theme), systemFields: nil)
        XCTAssertEqual(ck[ThemeFields.brightness.key] as? Double, 0.8)
        XCTAssertFalse(ThemeFields.brightness.encrypted)
        XCTAssertEqual(ThemeFields.brightness.group, Theme.FieldGroup.style.rawValue)

        ck[ThemeFields.brightness.key] = nil
        guard case .theme(let decoded) = try mapper.decode(ck) else { return XCTFail("wrong type") }
        XCTAssertEqual(decoded.brightness, Theme.defaultBrightness)
        XCTAssertEqual(decoded.grain, theme.grain)
    }

    /// `Profile.settings` ([03 §Profiles] observed: search engine, "Archive tabs after") syncs as
    /// plain `settings_*` keys in the `settings` group. A record saved before the keys existed,
    /// or one carrying an unknown engine, decodes with the defaults.
    func testProfileSettingsSyncAndOldRecordsDecodeWithDefaults() throws {
        let profile = Fx.profile(variant: 1)
        let ck = mapper.makeCKRecord(.profile(profile), systemFields: nil)
        XCTAssertEqual(ck[ProfileFields.searchEngine.key] as? String, "ecosia")
        XCTAssertEqual(ck[ProfileFields.todayLifetime.key] as? Double, 7 * 24 * 3600)
        // B66: "Include search engine suggestions" ([03 §Profiles] observed toggle) as 0/1.
        XCTAssertEqual(ck[ProfileFields.includesSearchSuggestions.key] as? Int64, 0)
        for field in [ProfileFields.searchEngine, ProfileFields.todayLifetime, ProfileFields.includesSearchSuggestions] {
            XCTAssertFalse(field.encrypted)
            XCTAssertEqual(field.group, Profile.FieldGroup.settings.rawValue)
        }
        XCTAssertNotNil(ck[MetaFields.groupTime(Profile.FieldGroup.settings.rawValue).key])
        guard case .profile(let decoded) = try mapper.decode(ck) else { return XCTFail("wrong type") }
        XCTAssertEqual(decoded.settings, profile.settings)

        ck[ProfileFields.searchEngine.key] = nil
        ck[ProfileFields.todayLifetime.key] = nil
        ck[ProfileFields.includesSearchSuggestions.key] = nil
        ck[MetaFields.groupTime(Profile.FieldGroup.settings.rawValue).key] = nil
        guard case .profile(let old) = try mapper.decode(ck) else { return XCTFail("wrong type") }
        XCTAssertEqual(old.settings, .default)
        XCTAssertEqual(old.name, profile.name)

        ck[ProfileFields.searchEngine.key] = "someFutureEngine"
        guard case .profile(let future) = try mapper.decode(ck) else { return XCTFail("wrong type") }
        XCTAssertEqual(future.settings.searchEngine, .google)
    }

    func testRoundTripOfTombstone() throws {
        let tomb = SyncRecord.tab(Fx.tab()).mapMeta { $0.markDeleted(at: Fx.t(30)) }
        let decoded = try mapper.decode(mapper.makeCKRecord(tomb, systemFields: nil))
        XCTAssertTrue(decoded.meta.isTombstone)
        XCTAssertEqual(decoded.meta.deletedAt, Fx.t(30))
        XCTAssertEqual(decoded.withoutSystemFields, tomb)
    }

    /// Every send writes every key, including nils, so a record rebuilt from system fields
    /// clears values the server still holds (RecordSchema.swift layout rules).
    func testClearedOptionalOverwritesPreviousValue() throws {
        let tagged = Fx.serverCK(.tab(Fx.tab()), tag: "t1")
        var cleared = Fx.tab()
        cleared.customTitle = nil
        cleared.pinnedURL = nil
        let ck = mapper.makeCKRecord(.tab(cleared), systemFields: RecordMapper.encodeSystemFields(of: tagged))
        XCTAssertTrue(ck.changedKeys().contains(TabFields.customTitle.key))
        XCTAssertTrue(ck.changedKeys().contains(TabFields.pinnedURL.key))
        XCTAssertEqual(Set(ck.changedKeys()), Set(RecordSchema.fields(of: .tab).map(\.key)))
        XCTAssertEqual(try mapper.decode(ck).tab?.customTitle, nil)
    }

    // MARK: Identity

    func testRecordNamesAreStableAndTypeQualified() {
        let uuid = Fx.uuid(42)
        let tabID = SyncRecordID(type: .tab, uuid: uuid)
        let archiveID = SyncRecordID(type: .archiveItem, uuid: uuid)
        XCTAssertEqual(mapper.recordID(for: tabID).recordName, "Tab/00000000-0000-0000-0000-000000000042")
        XCTAssertEqual(mapper.recordID(for: archiveID).recordName, "ArchiveItem/00000000-0000-0000-0000-000000000042")
        XCTAssertEqual(mapper.recordID(for: tabID).zoneID, Fx.zoneID)
        XCTAssertEqual(mapper.recordID(for: tabID), mapper.recordID(for: tabID))

        for record in Fx.fullRecords() {
            let ck = mapper.makeCKRecord(record, systemFields: nil)
            XCTAssertEqual(ck.recordID.recordName, record.id.recordName)
            XCTAssertEqual(ck.recordType, record.id.type.rawValue)
            XCTAssertEqual(RecordMapper.syncRecordID(fromRecordName: ck.recordID.recordName), record.id)
        }
    }

    func testForeignRecordNamesAreRejected() {
        let uuid = Fx.uuid(1)
        let lettered = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
        XCTAssertNotNil(RecordMapper.syncRecordID(fromRecordName: "Tab/\(lettered.uuidString)"))
        XCTAssertNil(RecordMapper.syncRecordID(fromRecordName: "Tab/\(lettered.uuidString.lowercased())"), "non-canonical spelling")
        XCTAssertNil(RecordMapper.syncRecordID(fromRecordName: "Unknown/\(uuid.uuidString)"))
        XCTAssertNil(RecordMapper.syncRecordID(fromRecordName: "Tab"))
        XCTAssertNil(RecordMapper.syncRecordID(fromRecordName: "Tab/not-a-uuid"))
        let otherZone = CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName)
        XCTAssertNil(mapper.syncRecordID(from: CKRecord.ID(recordName: "Tab/\(uuid.uuidString)", zoneID: otherZone)))
    }

    func testDecodeErrors() {
        let id = SyncRecordID(type: .tab, uuid: Fx.uuid(5))
        let foreign = CKRecord(recordType: "Tab", recordID: CKRecord.ID(recordName: "foreign", zoneID: Fx.zoneID))
        XCTAssertThrowsError(try mapper.decode(foreign)) {
            XCTAssertEqual($0 as? RecordMappingError, .unknownRecordName("foreign"))
        }
        let wrongType = CKRecord(recordType: "Folder", recordID: mapper.recordID(for: id))
        XCTAssertThrowsError(try mapper.decode(wrongType)) {
            XCTAssertEqual($0 as? RecordMappingError, .recordTypeMismatch(expected: "Tab", actual: "Folder"))
        }
        let missing = mapper.makeCKRecord(.tab(Fx.tab()), systemFields: nil)
        missing.encryptedValues[TabFields.title.key] = nil as String?
        XCTAssertThrowsError(try mapper.decode(missing)) {
            XCTAssertEqual($0 as? RecordMappingError, .missingField(TabFields.title.key))
        }
        let badKind = mapper.makeCKRecord(.tab(Fx.tab()), systemFields: nil)
        badKind[TabFields.locationKind.key] = "sidebar"
        XCTAssertThrowsError(try mapper.decode(badKind)) {
            XCTAssertEqual($0 as? RecordMappingError, .invalidValue(field: TabFields.locationKind.key))
        }
        let badSortKey = mapper.makeCKRecord(.tab(Fx.tab()), systemFields: nil)
        badSortKey[TabFields.sortKey.key] = "i0"
        XCTAssertThrowsError(try mapper.decode(badSortKey)) {
            XCTAssertEqual($0 as? RecordMappingError, .invalidValue(field: TabFields.sortKey.key))
        }
    }

    // MARK: Encryption split

    /// [03 §Sync] observed: user content (titles, URLs, names) is end-to-end encrypted.
    func testUserContentIsEncryptedAndStructureStaysPlain() throws {
        for record in Fx.fullRecords() {
            let type = record.id.type
            let ck = mapper.makeCKRecord(record, systemFields: nil)
            // Note: `allKeys()` lists encrypted keys too, so plain presence is checked via subscript.
            let encryptedKeys = Set(ck.encryptedValues.allKeys())
            for field in RecordSchema.fields(of: type) {
                if field.encrypted {
                    XCTAssertTrue(encryptedKeys.contains(field.key), "\(type).\(field.key) must be encrypted")
                    XCTAssertNil(ck[field.key], "\(type).\(field.key) must not be plain")
                } else {
                    XCTAssertFalse(encryptedKeys.contains(field.key), "\(type).\(field.key) must be plain")
                }
            }
            // Encrypted fields belong exactly to the groups the API marks as encrypted.
            let encryptedGroups = Set(RecordSchema.contentFields(of: type).filter(\.encrypted).compactMap(\.group))
            XCTAssertEqual(encryptedGroups, type.encryptedFieldGroups, "\(type)")
        }
    }

    func testTabSensitiveValuesNeverAppearInPlainFields() throws {
        let tab = Fx.tab()
        let ck = mapper.makeCKRecord(.tab(tab), systemFields: nil)
        let plainStrings = ck.allKeys().compactMap { ck[$0] as? String }
        for secret in [tab.title, tab.customTitle!, tab.url!.absoluteString, tab.pinnedURL!.absoluteString, tab.faviconURL!.absoluteString] {
            XCTAssertFalse(plainStrings.contains(secret), "\(secret) leaked into a plain field")
        }
        XCTAssertEqual(ck.encryptedValues[TabFields.url.key] as String?, tab.url?.absoluteString)
        XCTAssertEqual(ck.encryptedValues[TabFields.title.key] as String?, tab.title)
        // Ids, sort keys, timestamps and tombstone flags stay plain and readable.
        XCTAssertEqual(ck[TabFields.spaceID.key] as? String, Fx.uuid(3).uuidString)
        XCTAssertEqual(ck[TabFields.folderID.key] as? String, Fx.uuid(4).uuidString)
        XCTAssertEqual(ck[TabFields.sortKey.key] as? String, "i")
        XCTAssertEqual(ck[TabFields.locationKind.key] as? String, "pinned")
        XCTAssertEqual(ck[TabFields.lastActiveAt.key] as? Date, Fx.t(1))
        XCTAssertEqual(ck[MetaFields.createdAt.key] as? Date, Fx.t0)
        XCTAssertEqual(ck[MetaFields.isTombstone.key] as? Int64, 0)
        XCTAssertEqual(ck[MetaFields.groupTime("placement").key] as? Date, Fx.t0)
    }

    func testArchiveAndSpaceContentEncrypted() {
        let archive = Fx.archiveItem()
        let ack = mapper.makeCKRecord(.archiveItem(archive), systemFields: nil)
        XCTAssertEqual(ack.encryptedValues[ArchiveItemFields.folderPath.key] as [String]?, ["Reading", "Later"])
        XCTAssertNil(ack[ArchiveItemFields.folderPath.key])
        XCTAssertEqual(ack[ArchiveItemFields.reason.key] as? String, "closed")
        XCTAssertEqual(ack[ArchiveItemFields.spaceID.key] as? String, Fx.uuid(3).uuidString)

        let sck = mapper.makeCKRecord(.space(Fx.space()), systemFields: nil)
        XCTAssertEqual(sck.encryptedValues[SpaceFields.name.key] as String?, "Home")
        XCTAssertEqual(sck.encryptedValues[SpaceFields.icon.key] as String?, "🏠")
        XCTAssertEqual(sck[SpaceFields.dockSortKey.key] as? String, "i")
    }

    // MARK: Schema sanity

    func testSchemaKeysAreUniqueAndPrefixedByGroup() {
        for type in SyncRecordType.allCases {
            let fields = RecordSchema.fields(of: type)
            XCTAssertEqual(Set(fields.map(\.key)).count, fields.count, "duplicate key in \(type)")
            for field in RecordSchema.contentFields(of: type) {
                let group = field.group ?? "<none>"
                XCTAssertTrue(field.key.hasPrefix("\(group)_"), "\(type).\(field.key)")
                XCTAssertTrue(RecordSchema.groups(of: type).contains(group), "\(type).\(field.key)")
            }
            // Every group has at least one field.
            let used = Set(RecordSchema.contentFields(of: type).compactMap(\.group))
            XCTAssertEqual(used, Set(RecordSchema.groups(of: type)), "\(type)")
        }
    }

    // MARK: System fields

    func testSystemFieldsArePreservedThroughEncodeAndMakeCKRecord() throws {
        let record = SyncRecord.tab(Fx.tab())
        let server = Fx.serverCK(record, tag: "tag-42")
        XCTAssertEqual(server.recordChangeTag, "tag-42")

        let archived = RecordMapper.encodeSystemFields(of: server)
        let restored = try XCTUnwrap(RecordMapper.decodeSystemFields(archived))
        XCTAssertEqual(restored.recordID, server.recordID)
        XCTAssertEqual(restored.recordType, "Tab")
        XCTAssertEqual(restored.recordChangeTag, "tag-42")
        XCTAssertTrue(restored.allKeys().isEmpty, "system fields carry no values")

        let outgoing = mapper.makeCKRecord(record, systemFields: archived)
        XCTAssertEqual(outgoing.recordChangeTag, "tag-42", "conflict detection needs the server change tag")
        XCTAssertEqual(try mapper.decode(outgoing).withoutSystemFields, record)
    }

    func testDecodeAttachesSystemFieldsOfServerRecord() throws {
        let server = Fx.serverCK(.folder(Fx.folder()), tag: "f-9")
        let decoded = try mapper.decode(server)
        let fields = try XCTUnwrap(decoded.meta.backendSystemFields)
        XCTAssertEqual(RecordMapper.decodeSystemFields(fields)?.recordChangeTag, "f-9")
        // Re-encoding the decoded model keeps the tag.
        XCTAssertEqual(mapper.makeCKRecord(decoded, systemFields: fields).recordChangeTag, "f-9")
    }

    func testInvalidOrMismatchedSystemFieldsStartAFreshRecord() {
        let record = SyncRecord.tab(Fx.tab())
        // Empty data means "the server forgot this record".
        XCTAssertNil(RecordMapper.decodeSystemFields(Data()))
        XCTAssertNil(mapper.makeCKRecord(record, systemFields: Data()).recordChangeTag)
        XCTAssertNil(mapper.makeCKRecord(record, systemFields: Data("garbage".utf8)).recordChangeTag)
        // System fields of a different record, type or zone are ignored.
        let otherRecord = Fx.systemFields(for: SyncRecordID(type: .tab, uuid: Fx.uuid(999)), tag: "x")
        XCTAssertNil(mapper.makeCKRecord(record, systemFields: otherRecord).recordChangeTag)
        let otherType = Fx.systemFields(for: SyncRecordID(type: .archiveItem, uuid: record.id.uuid), tag: "x")
        XCTAssertNil(mapper.makeCKRecord(record, systemFields: otherType).recordChangeTag)
        let otherZone = Fx.systemFields(for: record.id, tag: "x", zoneID: CKRecordZone.ID(zoneName: "Other", ownerName: CKCurrentUserDefaultName))
        let fresh = mapper.makeCKRecord(record, systemFields: otherZone)
        XCTAssertNil(fresh.recordChangeTag)
        XCTAssertEqual(fresh.recordID.zoneID, Fx.zoneID)
    }
}
