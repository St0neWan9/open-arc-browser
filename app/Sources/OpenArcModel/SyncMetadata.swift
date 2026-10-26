import Foundation

/// Sync metadata carried by every syncable record.
///
/// Conflict policy (see OpenArcSyncAPI/ConflictPolicy.swift): **field-group last-writer-wins**,
/// and deletion (tombstone) always wins. That is why modification times are tracked per
/// field group rather than only per record.
///
/// - `backendSystemFields`: opaque data owned by the sync backend (e.g. archived CloudKit
///   system fields). The model only stores it and hands it back untouched. The name is
///   deliberately backend-neutral so a second backend can be added later.
public struct SyncMetadata: Codable, Hashable, Sendable {
    /// When the record was created.
    public var createdAt: Date
    /// Latest modification time of any field group.
    public var modifiedAt: Date
    /// Local edit counter, +1 on every change. Used for local change detection only,
    /// never compared across devices.
    public var version: Int64
    /// Tombstone: the record is deleted but kept until the sync layer has uploaded the deletion.
    public var isTombstone: Bool
    /// When the tombstone was set.
    public var deletedAt: Date?
    /// Field group name → last modification time of that group. Merges compare group by group.
    public var fieldGroupModifiedAt: [String: Date]
    /// Opaque data private to the sync backend. The model never parses it.
    public var backendSystemFields: Data?

    public init(
        createdAt: Date,
        modifiedAt: Date? = nil,
        version: Int64 = 1,
        isTombstone: Bool = false,
        deletedAt: Date? = nil,
        fieldGroupModifiedAt: [String: Date] = [:],
        backendSystemFields: Data? = nil
    ) {
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.version = version
        self.isTombstone = isTombstone
        self.deletedAt = deletedAt
        self.fieldGroupModifiedAt = fieldGroupModifiedAt
        self.backendSystemFields = backendSystemFields
    }

    /// Metadata for a new record: every field group is stamped with the creation time.
    public static func new<G: SyncFieldGroup>(at now: Date, groups: G.Type) -> SyncMetadata {
        var meta = SyncMetadata(createdAt: now)
        for group in G.allCases {
            meta.fieldGroupModifiedAt[group.rawValue] = now
        }
        return meta
    }

    /// Records one change: stamps only the field groups actually touched and bumps the version.
    public mutating func stamp<G: SyncFieldGroup>(_ groups: [G], at now: Date) {
        for group in groups {
            fieldGroupModifiedAt[group.rawValue] = now
        }
        modifiedAt = max(modifiedAt, now)
        version += 1
    }

    /// Marks the record as a tombstone. Deletion always wins a merge
    /// (edits to other field groups never resurrect it).
    public mutating func markDeleted(at now: Date) {
        guard !isTombstone else { return }
        isTombstone = true
        deletedAt = now
        modifiedAt = max(modifiedAt, now)
        version += 1
    }

    /// Modification time of a field group; falls back to the creation time if never stamped.
    public func modifiedAt<G: SyncFieldGroup>(_ group: G) -> Date {
        fieldGroupModifiedAt[group.rawValue] ?? createdAt
    }
}

/// The field groups of one record type. Fields in the same group are always changed and merged
/// together (e.g. the "placement" group = location + parent + sort key).
public protocol SyncFieldGroup: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {}

/// Common shape of every syncable entity.
public protocol SyncableEntity: Codable, Sendable, Identifiable where ID == UUID {
    associatedtype FieldGroup: SyncFieldGroup
    /// Record type name used by sync backends. Keep it stable; never rename.
    static var recordTypeName: String { get }
    var meta: SyncMetadata { get set }
}
