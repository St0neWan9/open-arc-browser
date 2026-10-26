import OpenArcModel
import OpenArcSyncAPI

/// Which records go to iCloud. This is the single place to change the sync scope.
///
/// PRODUCT DECISION PENDING: the default syncs every record type, including archive items.
/// Syncing `ArchiveItem` means archiving a synced tab on one device leaves an archive entry on
/// the others instead of the tab silently disappearing (see the open question in
/// OpenArcSyncAPI/SyncStore.swift). To exclude a type, remove it from `syncedTypes`; to make some
/// records of a type local-only (e.g. Today tabs), extend `includes(_ record:)`. A record that
/// leaves the scope is deleted from the server on its next send.
public struct SyncScope: Hashable, Sendable {
    public var syncedTypes: Set<SyncRecordType>

    public init(syncedTypes: Set<SyncRecordType>) {
        self.syncedTypes = syncedTypes
    }

    /// Default scope: everything, archive items included (pending product decision, see above).
    public static let `default` = SyncScope(syncedTypes: Set(SyncRecordType.allCases))

    public func includes(_ type: SyncRecordType) -> Bool {
        syncedTypes.contains(type)
    }

    /// Record-level rule. Currently type-based only.
    public func includes(_ record: SyncRecord) -> Bool {
        includes(record.id.type)
    }
}
