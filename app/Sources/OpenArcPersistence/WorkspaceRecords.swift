import Foundation
import OpenArcModel
import OpenArcSyncAPI

// Mapping between the flat `WorkspaceState` and `SyncRecord`s. Every record type of the
// workspace maps one-to-one onto a `SyncRecordType`.

extension WorkspaceState {
    /// The record with this id, tombstones included.
    public func record(for id: SyncRecordID) -> SyncRecord? {
        switch id.type {
        case .profile: return profiles[id.uuid].map(SyncRecord.profile)
        case .theme: return themes[id.uuid].map(SyncRecord.theme)
        case .space: return spaces[id.uuid].map(SyncRecord.space)
        case .folder: return folders[id.uuid].map(SyncRecord.folder)
        case .tab: return tabs[id.uuid].map(SyncRecord.tab)
        case .archiveItem: return archive[id.uuid].map(SyncRecord.archiveItem)
        case .splitLayout: return splits[id.uuid].map(SyncRecord.splitLayout)
        case .easel: return easels[id.uuid].map(SyncRecord.easel)
        case .easelElement: return easelElements[id.uuid].map(SyncRecord.easelElement)
        }
    }

    /// Inserts or overwrites a record.
    public mutating func setRecord(_ record: SyncRecord) {
        switch record {
        case .profile(let v): profiles[v.id] = v
        case .theme(let v): themes[v.id] = v
        case .space(let v): spaces[v.id] = v
        case .folder(let v): folders[v.id] = v
        case .tab(let v): tabs[v.id] = v
        case .archiveItem(let v): archive[v.id] = v
        case .splitLayout(let v): splits[v.id] = v
        case .easel(let v): easels[v.id] = v
        case .easelElement(let v): easelElements[v.id] = v
        }
    }

    /// Removes a record completely (a purge, not a tombstone).
    public mutating func removeRecord(_ id: SyncRecordID) {
        switch id.type {
        case .profile: profiles[id.uuid] = nil
        case .theme: themes[id.uuid] = nil
        case .space: spaces[id.uuid] = nil
        case .folder: folders[id.uuid] = nil
        case .tab: tabs[id.uuid] = nil
        case .archiveItem: archive[id.uuid] = nil
        case .splitLayout: splits[id.uuid] = nil
        case .easel: easels[id.uuid] = nil
        case .easelElement: easelElements[id.uuid] = nil
        }
    }

    /// Ids of every record, tombstones included, sorted by record name.
    public var allRecordIDs: [SyncRecordID] {
        var ids: [SyncRecordID] = []
        ids += profiles.keys.map { SyncRecordID(type: .profile, uuid: $0) }
        ids += themes.keys.map { SyncRecordID(type: .theme, uuid: $0) }
        ids += spaces.keys.map { SyncRecordID(type: .space, uuid: $0) }
        ids += folders.keys.map { SyncRecordID(type: .folder, uuid: $0) }
        ids += tabs.keys.map { SyncRecordID(type: .tab, uuid: $0) }
        ids += archive.keys.map { SyncRecordID(type: .archiveItem, uuid: $0) }
        ids += splits.keys.map { SyncRecordID(type: .splitLayout, uuid: $0) }
        ids += easels.keys.map { SyncRecordID(type: .easel, uuid: $0) }
        ids += easelElements.keys.map { SyncRecordID(type: .easelElement, uuid: $0) }
        return ids.sorted { $0.recordName < $1.recordName }
    }

    /// Ids of every record that syncs (`allRecordIDs` without local-only types), for a full upload.
    public var allSyncedRecordIDs: [SyncRecordID] {
        allRecordIDs.filter(\.isSynced)
    }
}

extension SyncRecordID {
    /// False for local-only record types (`SyncRecordType.isLocalOnly`).
    var isSynced: Bool { !type.isLocalOnly }
}

/// Which records differ between two workspace values. This is how callers learn which local
/// records changed so they can enqueue `PendingChange`s with the sync store.
public enum WorkspaceDiff {

    /// The result of comparing two workspaces.
    public struct Changes: Hashable, Sendable {
        /// Records created or changed, including records that became tombstones.
        public var saved: [SyncRecordID]
        /// Records present before and gone now (purged).
        public var removed: [SyncRecordID]

        public init(saved: [SyncRecordID] = [], removed: [SyncRecordID] = []) {
            self.saved = saved
            self.removed = removed
        }

        public var isEmpty: Bool { saved.isEmpty && removed.isEmpty }

        /// `.save` for every created/changed/tombstoned record, `.delete` for every purged one
        /// (see `PendingChange`). Sorted by record name. Local-only records (Profile, plan Q13)
        /// are left out: they never go to the sync store.
        public var pendingChanges: [PendingChange] {
            (saved.filter(\.isSynced).map(PendingChange.save) + removed.filter(\.isSynced).map(PendingChange.delete))
                .sorted { Self.name($0) < Self.name($1) }
        }

        private static func name(_ change: PendingChange) -> String {
            switch change {
            case .save(let id), .delete(let id): return id.recordName
            }
        }
    }

    /// Compares two workspace values record by record.
    public static func changes(from old: WorkspaceState, to new: WorkspaceState) -> Changes {
        var result = Changes()
        compare(old.profiles, new.profiles, .profile, &result)
        compare(old.themes, new.themes, .theme, &result)
        compare(old.spaces, new.spaces, .space, &result)
        compare(old.folders, new.folders, .folder, &result)
        compare(old.tabs, new.tabs, .tab, &result)
        compare(old.archive, new.archive, .archiveItem, &result)
        compare(old.splits, new.splits, .splitLayout, &result)
        compare(old.easels, new.easels, .easel, &result)
        compare(old.easelElements, new.easelElements, .easelElement, &result)
        result.saved.sort { $0.recordName < $1.recordName }
        result.removed.sort { $0.recordName < $1.recordName }
        return result
    }

    /// Which records differ between two values whose changes were all made by `TreeOps`, decided
    /// from the sync metadata alone: a record differs when it was added or removed, or when its
    /// `meta.version` or tombstone flag changed. `TreeOps` bumps the version on every change it
    /// stamps (`SyncMetadata.stamp`, `markDeleted`), so this finds the same records as `changes`
    /// without comparing record contents: a few integer compares per record instead of a deep
    /// compare of every field (B102: a tab select on a 2000-tab workspace).
    ///
    /// Use it only for values one local change produced. A record whose content differs at the
    /// same version (a server copy taken in a merge, backend fields) is not reported: the caller
    /// compares candidates against its own copy where that matters (`WorkspaceStore`).
    public static func stampedChanges(from old: WorkspaceState, to new: WorkspaceState) -> Changes {
        var result = Changes()
        compareStamps(old.profiles, new.profiles, .profile, &result)
        compareStamps(old.themes, new.themes, .theme, &result)
        compareStamps(old.spaces, new.spaces, .space, &result)
        compareStamps(old.folders, new.folders, .folder, &result)
        compareStamps(old.tabs, new.tabs, .tab, &result)
        compareStamps(old.archive, new.archive, .archiveItem, &result)
        compareStamps(old.splits, new.splits, .splitLayout, &result)
        compareStamps(old.easels, new.easels, .easel, &result)
        compareStamps(old.easelElements, new.easelElements, .easelElement, &result)
        result.saved.sort { $0.recordName < $1.recordName }
        result.removed.sort { $0.recordName < $1.recordName }
        return result
    }

    /// Shortcut for `changes(from:to:).pendingChanges`.
    public static func pendingChanges(from old: WorkspaceState, to new: WorkspaceState) -> [PendingChange] {
        changes(from: old, to: new).pendingChanges
    }

    private static func compareStamps<T: SyncableEntity>(
        _ old: [UUID: T],
        _ new: [UUID: T],
        _ type: SyncRecordType,
        _ result: inout Changes
    ) {
        // Ids of `new` that `old` has too: when that is all of `old`, nothing was purged.
        var kept = 0
        for (id, value) in new {
            if let before = old[id] {
                kept += 1
                if before.meta.version == value.meta.version,
                   before.meta.isTombstone == value.meta.isTombstone { continue }
            }
            result.saved.append(SyncRecordID(type: type, uuid: id))
        }
        if old.count > kept {
            for id in old.keys where new[id] == nil {
                result.removed.append(SyncRecordID(type: type, uuid: id))
            }
        }
    }

    private static func compare<T: Equatable>(
        _ old: [UUID: T],
        _ new: [UUID: T],
        _ type: SyncRecordType,
        _ result: inout Changes
    ) {
        guard old != new else { return }
        for (id, value) in new where old[id] != value {
            result.saved.append(SyncRecordID(type: type, uuid: id))
        }
        for id in old.keys where new[id] == nil {
            result.removed.append(SyncRecordID(type: type, uuid: id))
        }
    }
}
