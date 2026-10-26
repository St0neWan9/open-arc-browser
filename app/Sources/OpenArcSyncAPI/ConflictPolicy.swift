import Foundation
import OpenArcModel

/// # Conflict policy: field-group last-writer-wins, delete wins
///
/// Every record type splits its fields into **field groups** (`SyncableEntity.FieldGroup`).
/// Fields in one group are always written together, e.g. a tab's `placement` group is
/// location + sort key, so a move is atomic. `SyncMetadata.fieldGroupModifiedAt` stores one
/// timestamp per group, and every model operation stamps only the groups it changed.
///
/// When the server copy and the local copy of a record conflict:
/// 1. **Delete wins.** If either side is a tombstone, the result is a tombstone. Archiving is a
///    delete of the tab plus a new `ArchiveItem`, so nothing is lost as long as ArchiveItems sync
///    too (see the open question in SyncStore.swift).
/// 2. Otherwise, **for each field group**, the side with the later group timestamp wins.
/// 3. **Ties go to the server** copy. Every device makes the same choice, so all devices converge.
///
/// ## Why not whole-record last-writer-wins
/// Common concurrent edits touch different parts of the same record. For example, one device
/// renames a pinned tab while another navigates it (url/title change), or one device moves a tab
/// while another renames it. Whole-record LWW would silently drop one of those edits.
///
/// Per-field LWW without groups would allow torn states, such as the location from one device
/// combined with a sort key computed for a different container. Field groups keep each logical
/// edit atomic and lose only true same-group conflicts.
///
/// Fractional sort keys (`SortKey`) mean a move rewrites only the moved record, so reordering
/// on two devices rarely conflicts at all.
///
/// ## Known limitations
/// - Timestamps are device wall-clock times. Clock skew between devices can make an older edit
///   win; acceptable for sidebar data. A hybrid logical clock could replace `Date` later without
///   changing this API.
/// - Structural invariants are not checked by the merge (a tab may point at a folder deleted on
///   another device). After applying remote changes, the app must repair: orphaned pinned tabs go
///   to the top level of their space's pinned area; orphaned folders go to the top level.
public enum ConflictPolicy {

    /// Which copy wins a field group.
    public enum Side: Hashable, Sendable {
        case local
        case server
    }

    /// Outcome of resolving one record.
    public struct Resolution<Group: SyncFieldGroup>: Hashable, Sendable {
        /// True if the merged record is a tombstone; `winners` is then irrelevant.
        public var isDeleted: Bool
        /// Winning side for each field group (empty for a deletion).
        public var winners: [Group: Side]
        /// True if the local copy is a tombstone and the server copy is not: the delete wins, but
        /// the server has not seen it yet.
        public var localDeleteNotOnServer: Bool
        /// Metadata for the merged record. When the server wins everything (`needsUpload` is
        /// false) this is exactly the server's metadata, version included.
        public var mergedMeta: SyncMetadata

        /// The groups the local copy won. Empty for a deletion.
        public var localWonGroups: Set<Group> {
            isDeleted ? [] : Set(winners.filter { $0.value == .local }.keys)
        }

        /// True if the merged record holds something the server does not have yet (a group the
        /// local copy won, or a local delete), so it must be uploaded again. False means the
        /// server copy wins everything: adopt it as it is and upload nothing.
        public var needsUpload: Bool {
            localDeleteNotOnServer || !localWonGroups.isEmpty
        }
    }

    /// Decides the merge of two copies of one record. Pure; the sync implementation then copies
    /// each group's fields from the winning side.
    ///
    /// `version` is a per-record change counter that only advances when the local side makes a
    /// change that must be uploaded. A merge the server wins entirely adopts the server's metadata
    /// (and so its version); a merge the local side contributes to gets `max(local, server) + 1`.
    /// Bumping the version on every merge made a server-won merge look like a local change, which
    /// was uploaded and echoed back by the other device forever. [A20]
    public static func resolve<Group: SyncFieldGroup>(
        local: SyncMetadata,
        server: SyncMetadata,
        groups: Group.Type
    ) -> Resolution<Group> {
        // A delete the server already has wins as the server wrote it.
        if server.isTombstone {
            return Resolution(isDeleted: true, winners: [:], localDeleteNotOnServer: false, mergedMeta: server)
        }

        var merged = server
        // The server's system fields are newer by definition (they come with the server copy).
        merged.backendSystemFields = server.backendSystemFields

        if local.isTombstone {
            merged.isTombstone = true
            merged.deletedAt = local.deletedAt
            merged.modifiedAt = max(local.modifiedAt, server.modifiedAt)
            merged.version = max(local.version, server.version) + 1
            return Resolution(isDeleted: true, winners: [:], localDeleteNotOnServer: true, mergedMeta: merged)
        }

        var winners: [Group: Side] = [:]
        for group in Group.allCases {
            let localTime = local.modifiedAt(group)
            let serverTime = server.modifiedAt(group)
            let side: Side = localTime > serverTime ? .local : .server
            winners[group] = side
            merged.fieldGroupModifiedAt[group.rawValue] = max(localTime, serverTime)
        }
        guard winners.values.contains(.local) else {
            // The server wins every group: its copy is the result, metadata included.
            return Resolution(isDeleted: false, winners: winners, localDeleteNotOnServer: false, mergedMeta: server)
        }
        merged.createdAt = min(local.createdAt, server.createdAt)
        merged.modifiedAt = max(local.modifiedAt, server.modifiedAt)
        merged.version = max(local.version, server.version) + 1
        return Resolution(isDeleted: false, winners: winners, localDeleteNotOnServer: false, mergedMeta: merged)
    }
}
