import CloudKit
import OpenArcModel
import OpenArcSyncAPI

/// Why a CloudKit record could not be turned into a model record.
enum RecordMappingError: Error, Equatable {
    case unknownRecordName(String)
    case recordTypeMismatch(expected: String, actual: String)
    case missingField(String)
    case invalidValue(field: String)
}

/// Converts between `SyncRecord` and `CKRecord`. Pure apart from CKRecord allocation; no network.
struct RecordMapper: Sendable {
    let zoneID: CKRecordZone.ID

    // MARK: - Identity

    /// CloudKit record id. The record name is `SyncRecordID.recordName` ("Tab/<UUID>"), which is
    /// stable and type-qualified (an ArchiveItem shares its UUID with the archived tab).
    func recordID(for id: SyncRecordID) -> CKRecord.ID {
        CKRecord.ID(recordName: id.recordName, zoneID: zoneID)
    }

    /// Parses a record name back into a `SyncRecordID`; nil for names we did not write.
    static func syncRecordID(fromRecordName name: String) -> SyncRecordID? {
        let parts = name.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2,
              let type = SyncRecordType(rawValue: String(parts[0])),
              let uuid = UUID(uuidString: String(parts[1]))
        else { return nil }
        // Reject non-canonical spellings so one record cannot appear under two names.
        let id = SyncRecordID(type: type, uuid: uuid)
        return id.recordName == name ? id : nil
    }

    func syncRecordID(from recordID: CKRecord.ID) -> SyncRecordID? {
        guard recordID.zoneID == zoneID else { return nil }
        return Self.syncRecordID(fromRecordName: recordID.recordName)
    }

    // MARK: - System fields

    /// Archives the CloudKit system fields (record id, change tag, ...) of a record.
    static func encodeSystemFields(of record: CKRecord) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// Rebuilds an empty record (system fields only) from archived system fields.
    static func decodeSystemFields(_ data: Data) -> CKRecord? {
        guard !data.isEmpty, let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = true
        defer { unarchiver.finishDecoding() }
        return CKRecord(coder: unarchiver)
    }

    // MARK: - Encoding

    /// Builds the CKRecord to upload. `systemFields` (when valid for this record) carries the
    /// server change tag so CloudKit can detect conflicting writes.
    func makeCKRecord(_ record: SyncRecord, systemFields: Data?) -> CKRecord {
        let id = record.id
        let ckID = recordID(for: id)
        let ck: CKRecord
        if let systemFields,
           let restored = Self.decodeSystemFields(systemFields),
           restored.recordID == ckID,
           restored.recordType == id.type.rawValue {
            ck = restored
        } else {
            ck = CKRecord(recordType: id.type.rawValue, recordID: ckID)
        }
        let w = FieldWriter(record: ck)
        switch record {
        case .profile(let v):
            w.set(ProfileFields.name, v.name)
            w.set(ProfileFields.searchEngine, v.settings.searchEngine.rawValue)
            w.set(ProfileFields.todayLifetime, v.settings.todayLifetime)
        case .theme(let v):
            w.set(ThemeFields.appearance, v.appearance.rawValue)
            w.set(ThemeFields.colors, Self.json(v.colors))
            w.set(ThemeFields.grain, v.grain)
            w.set(ThemeFields.brightness, v.brightness)
        case .space(let v):
            w.set(SpaceFields.name, v.name)
            w.set(SpaceFields.icon, v.icon)
            w.set(SpaceFields.themeID, v.themeID?.uuidString)
            w.set(SpaceFields.profileID, v.profileID.uuidString)
            w.set(SpaceFields.dockSortKey, v.dockSortKey.rawValue)
        case .folder(let v):
            w.set(FolderFields.spaceID, v.spaceID.uuidString)
            w.set(FolderFields.parentFolderID, v.parentFolderID?.uuidString)
            w.set(FolderFields.sortKey, v.sortKey.rawValue)
            w.set(FolderFields.title, v.title)
            w.set(FolderFields.isExpanded, Int64(v.isExpanded ? 1 : 0))
        case .tab(let v):
            let kind: String
            var profileID: UUID?
            var spaceID: UUID?
            var folderID: UUID?
            switch v.location {
            case .favorite(let p): kind = "favorite"; profileID = p
            case .pinned(let s, let f): kind = "pinned"; spaceID = s; folderID = f
            case .today(let s): kind = "today"; spaceID = s
            }
            w.set(TabFields.locationKind, kind)
            w.set(TabFields.profileID, profileID?.uuidString)
            w.set(TabFields.spaceID, spaceID?.uuidString)
            w.set(TabFields.folderID, folderID?.uuidString)
            w.set(TabFields.sortKey, v.sortKey.rawValue)
            w.set(TabFields.url, v.url?.absoluteString)
            w.set(TabFields.title, v.title)
            w.set(TabFields.faviconURL, v.faviconURL?.absoluteString)
            w.set(TabFields.customTitle, v.customTitle)
            w.set(TabFields.pinnedURL, v.pinnedURL?.absoluteString)
            w.set(TabFields.lastActiveAt, v.lastActiveAt)
        case .archiveItem(let v):
            w.set(ArchiveItemFields.url, v.url?.absoluteString)
            w.set(ArchiveItemFields.title, v.title)
            w.set(ArchiveItemFields.faviconURL, v.faviconURL?.absoluteString)
            w.set(ArchiveItemFields.folderPath, v.folderPath)
            w.set(ArchiveItemFields.spaceID, v.spaceID?.uuidString)
            w.set(ArchiveItemFields.reason, v.reason.rawValue)
            w.set(ArchiveItemFields.archivedAt, v.archivedAt)
        case .splitLayout(let v):
            w.set(SplitLayoutFields.spaceID, v.spaceID.uuidString)
            w.set(SplitLayoutFields.root, Self.json(v.root))
        }
        writeMeta(record.meta, type: id.type, to: w)
        return ck
    }

    private func writeMeta(_ meta: SyncMetadata, type: SyncRecordType, to w: FieldWriter) {
        w.set(MetaFields.createdAt, meta.createdAt)
        w.set(MetaFields.modifiedAt, meta.modifiedAt)
        w.set(MetaFields.version, meta.version)
        w.set(MetaFields.isTombstone, Int64(meta.isTombstone ? 1 : 0))
        w.set(MetaFields.deletedAt, meta.deletedAt)
        for group in RecordSchema.groups(of: type) {
            w.set(MetaFields.groupTime(group), meta.fieldGroupModifiedAt[group])
        }
    }

    // MARK: - Decoding

    /// Decodes a server record. The result's `meta.backendSystemFields` holds the archived system
    /// fields of `ck`.
    func decode(_ ck: CKRecord) throws -> SyncRecord {
        guard let id = syncRecordID(from: ck.recordID) else {
            throw RecordMappingError.unknownRecordName(ck.recordID.recordName)
        }
        guard ck.recordType == id.type.rawValue else {
            throw RecordMappingError.recordTypeMismatch(expected: id.type.rawValue, actual: ck.recordType)
        }
        let r = FieldReader(record: ck)
        var meta = try readMeta(type: id.type, from: r)
        meta.backendSystemFields = Self.encodeSystemFields(of: ck)
        let now = meta.createdAt
        let uuid = id.uuid

        switch id.type {
        case .profile:
            // Records saved before the settings keys existed decode with the defaults; an unknown
            // engine (from a newer build) also falls back to the default.
            let settings = ProfileSettings(
                searchEngine: SearchEngine(lenient: r.optional(ProfileFields.searchEngine)),
                todayLifetime: ProfileSettings.validLifetime(r.optional(ProfileFields.todayLifetime))
            )
            var v = Profile(id: uuid, name: try r.required(ProfileFields.name), settings: settings, now: now)
            v.meta = meta
            return .profile(v)
        case .theme:
            let appearanceRaw: String = try r.required(ThemeFields.appearance)
            guard let appearance = ThemeAppearance(rawValue: appearanceRaw) else {
                throw RecordMappingError.invalidValue(field: ThemeFields.appearance.key)
            }
            let colors: [RGBAColor] = try r.json(ThemeFields.colors)
            var v = Theme(
                id: uuid, appearance: appearance, colors: colors, grain: try r.required(ThemeFields.grain),
                brightness: r.optional(ThemeFields.brightness) ?? Theme.defaultBrightness, now: now
            )
            v.meta = meta
            return .theme(v)
        case .space:
            var v = Space(
                id: uuid,
                profileID: try r.requiredUUID(SpaceFields.profileID),
                name: try r.required(SpaceFields.name),
                icon: r.optional(SpaceFields.icon),
                themeID: try r.optionalUUID(SpaceFields.themeID),
                dockSortKey: try r.sortKey(SpaceFields.dockSortKey),
                now: now
            )
            v.meta = meta
            return .space(v)
        case .folder:
            let expanded: Int64 = try r.required(FolderFields.isExpanded)
            var v = Folder(
                id: uuid,
                spaceID: try r.requiredUUID(FolderFields.spaceID),
                parentFolderID: try r.optionalUUID(FolderFields.parentFolderID),
                title: try r.required(FolderFields.title),
                isExpanded: expanded != 0,
                sortKey: try r.sortKey(FolderFields.sortKey),
                now: now
            )
            v.meta = meta
            return .folder(v)
        case .tab:
            let kind: String = try r.required(TabFields.locationKind)
            let location: TabLocation
            switch kind {
            case "favorite": location = .favorite(profileID: try r.requiredUUID(TabFields.profileID))
            case "pinned": location = .pinned(spaceID: try r.requiredUUID(TabFields.spaceID), folderID: try r.optionalUUID(TabFields.folderID))
            case "today": location = .today(spaceID: try r.requiredUUID(TabFields.spaceID))
            default: throw RecordMappingError.invalidValue(field: TabFields.locationKind.key)
            }
            var v = TabNode(
                id: uuid,
                location: location,
                sortKey: try r.sortKey(TabFields.sortKey),
                url: try r.optionalURL(TabFields.url),
                title: try r.required(TabFields.title),
                customTitle: r.optional(TabFields.customTitle),
                pinnedURL: try r.optionalURL(TabFields.pinnedURL),
                faviconURL: try r.optionalURL(TabFields.faviconURL),
                now: now
            )
            v.lastActiveAt = try r.required(TabFields.lastActiveAt)
            v.meta = meta
            return .tab(v)
        case .archiveItem:
            let reasonRaw: String = try r.required(ArchiveItemFields.reason)
            guard let reason = ArchiveReason(rawValue: reasonRaw) else {
                throw RecordMappingError.invalidValue(field: ArchiveItemFields.reason.key)
            }
            var v = ArchiveItem(
                id: uuid,
                url: try r.optionalURL(ArchiveItemFields.url),
                title: try r.required(ArchiveItemFields.title),
                faviconURL: try r.optionalURL(ArchiveItemFields.faviconURL),
                spaceID: try r.optionalUUID(ArchiveItemFields.spaceID),
                folderPath: r.optional(ArchiveItemFields.folderPath) ?? [],
                reason: reason,
                archivedAt: try r.required(ArchiveItemFields.archivedAt)
            )
            v.meta = meta
            return .archiveItem(v)
        case .splitLayout:
            var v = SplitLayout(
                id: uuid,
                spaceID: try r.requiredUUID(SplitLayoutFields.spaceID),
                root: try r.json(SplitLayoutFields.root),
                now: now
            )
            v.meta = meta
            return .splitLayout(v)
        }
    }

    private func readMeta(type: SyncRecordType, from r: FieldReader) throws -> SyncMetadata {
        let tombstone: Int64 = try r.required(MetaFields.isTombstone)
        var groupTimes: [String: Date] = [:]
        for group in RecordSchema.groups(of: type) {
            if let date: Date = r.optional(MetaFields.groupTime(group)) {
                groupTimes[group] = date
            }
        }
        return SyncMetadata(
            createdAt: try r.required(MetaFields.createdAt),
            modifiedAt: try r.required(MetaFields.modifiedAt),
            version: r.optional(MetaFields.version) ?? 1,
            isTombstone: tombstone != 0,
            deletedAt: r.optional(MetaFields.deletedAt),
            fieldGroupModifiedAt: groupTimes,
            backendSystemFields: nil
        )
    }

    // MARK: - JSON helpers

    static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding plain model values cannot fail; fall back to empty data defensively.
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// Writes one field to the plain or encrypted side of a record, as the schema says.
private struct FieldWriter {
    let record: CKRecord

    func set<T: CKRecordValueProtocol>(_ field: FieldSpec, _ value: T?) {
        if field.encrypted {
            record.encryptedValues[field.key] = value
        } else {
            record[field.key] = value
        }
    }
}

/// Reads one field from the plain or encrypted side of a record, as the schema says.
private struct FieldReader {
    let record: CKRecord

    func optional<T: CKRecordValueProtocol>(_ field: FieldSpec) -> T? {
        field.encrypted ? record.encryptedValues[field.key] : record[field.key]
    }

    func required<T: CKRecordValueProtocol>(_ field: FieldSpec) throws -> T {
        guard let value: T = optional(field) else { throw RecordMappingError.missingField(field.key) }
        return value
    }

    func requiredUUID(_ field: FieldSpec) throws -> UUID {
        let raw: String = try required(field)
        guard let uuid = UUID(uuidString: raw) else { throw RecordMappingError.invalidValue(field: field.key) }
        return uuid
    }

    func optionalUUID(_ field: FieldSpec) throws -> UUID? {
        guard let raw: String = optional(field) else { return nil }
        guard let uuid = UUID(uuidString: raw) else { throw RecordMappingError.invalidValue(field: field.key) }
        return uuid
    }

    func optionalURL(_ field: FieldSpec) throws -> URL? {
        guard let raw: String = optional(field) else { return nil }
        guard let url = URL(string: raw) else { throw RecordMappingError.invalidValue(field: field.key) }
        return url
    }

    func sortKey(_ field: FieldSpec) throws -> SortKey {
        let raw: String = try required(field)
        guard let key = SortKey(rawValue: raw) else { throw RecordMappingError.invalidValue(field: field.key) }
        return key
    }

    func json<T: Decodable>(_ field: FieldSpec) throws -> T {
        let data: Data = try required(field)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw RecordMappingError.invalidValue(field: field.key)
        }
    }
}
