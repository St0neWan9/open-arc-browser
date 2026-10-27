import OpenArcModel
import OpenArcSyncAPI

/// Which records go to iCloud. This is the single place to change the sync scope.
///
/// Local-only types (`SyncRecordType.isLocalOnly`, i.e. Profile since B73 / plan Q13) are never
/// in scope, whatever `syncedTypes` says, and are treated apart from types merely left out of the
/// scope: a type left out of `syncedTypes` is cleaned off the server (a queued save of it becomes
/// a delete), while a local-only type is never touched on the server at all. Profile records an
/// older build uploaded stay there, harmless; deleting them would make older builds on other
/// devices purge their local profile.
///
/// PRODUCT DECISION PENDING: the default syncs every other record type, including archive items.
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

    /// Default scope: every type that is not local-only, archive items included (pending product
    /// decision, see above).
    public static let `default` = SyncScope(syncedTypes: Set(SyncRecordType.syncedCases))

    public func includes(_ type: SyncRecordType) -> Bool {
        !type.isLocalOnly && syncedTypes.contains(type)
    }

    /// Record-level rule. Currently type-based only.
    public func includes(_ record: SyncRecord) -> Bool {
        includes(record.id.type)
    }
}
