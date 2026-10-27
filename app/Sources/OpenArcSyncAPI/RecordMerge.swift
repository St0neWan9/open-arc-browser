import Foundation
import OpenArcModel

/// Merges a local and a server copy of one record under `ConflictPolicy` (field-group
/// last-writer-wins, delete wins, ties go to the server). The policy decision itself stays in
/// `ConflictPolicy.resolve`; this type only copies the winning groups' fields.
///
/// This is the one shared implementation: the local store (OpenArcPersistence) and every sync
/// backend (OpenArcSyncCloudKit) call it, so both sides of a sync always merge the same way.
public enum RecordMerge {

    public struct Outcome: Hashable, Sendable {
        /// The merged record. It carries the server copy's backend system fields. Apply it locally.
        ///
        /// When the server wins everything this is the server copy as it is (version included),
        /// or the local copy if the two differ only in the local version counter.
        public var merged: SyncRecord
        /// True if the merged record is a tombstone.
        public var isDeleted: Bool
        /// Raw names of the field groups the local copy won (`SyncFieldGroup.rawValue`). Empty for
        /// a deletion and when the server wins everything.
        public var localWonGroups: Set<String>
        /// True if the merged record must be uploaded again: the local copy won at least one field
        /// group, or it is a tombstone the server has not seen (`Resolution.needsUpload`).
        ///
        /// Callers follow three cases:
        /// - remote wins everything (`false`): apply `merged` locally, enqueue nothing;
        /// - mixed (some groups each way): apply `merged` and upload it once;
        /// - local wins everything: apply (a no-op apart from system fields) and upload.
        public var needsUpload: Bool

        /// True if the server copy wins every field group (or holds the winning delete), so the
        /// merge adds nothing the server lacks.
        public var serverWinsAll: Bool { !needsUpload }

        public init(merged: SyncRecord, isDeleted: Bool, localWonGroups: Set<String> = [], needsUpload: Bool) {
            self.merged = merged
            self.isDeleted = isDeleted
            self.localWonGroups = localWonGroups
            self.needsUpload = needsUpload
        }
    }

    /// Merges two copies of the same record. Returns nil if they are different records (another
    /// UUID, or the same UUID with another record type).
    ///
    /// Idempotent: merging a record with itself, or with a copy that differs only in the local
    /// version counter, returns the local copy unchanged (`SyncLocalDatabase.apply` must be
    /// idempotent). The version only advances when the local copy contributes something the
    /// server lacks (see `ConflictPolicy.resolve`).
    public static func merge(local: SyncRecord, server: SyncRecord) -> Outcome? {
        guard local.id == server.id else { return nil }
        switch (local, server) {
        case (.profile(let l), .profile(let s)): return entity(l, s, copyProfile, SyncRecord.profile)
        case (.theme(let l), .theme(let s)): return entity(l, s, copyTheme, SyncRecord.theme)
        case (.space(let l), .space(let s)): return entity(l, s, copySpace, SyncRecord.space)
        case (.folder(let l), .folder(let s)): return entity(l, s, copyFolder, SyncRecord.folder)
        case (.tab(let l), .tab(let s)): return entity(l, s, copyTab, SyncRecord.tab)
        case (.archiveItem(let l), .archiveItem(let s)): return entity(l, s, copyArchiveItem, SyncRecord.archiveItem)
        case (.splitLayout(let l), .splitLayout(let s)): return entity(l, s, copySplitLayout, SyncRecord.splitLayout)
        case (.easel(let l), .easel(let s)): return entity(l, s, copyEasel, SyncRecord.easel)
        case (.easelElement(let l), .easelElement(let s)): return entity(l, s, copyEaselElement, SyncRecord.easelElement)
        default: return nil
        }
    }

    /// Starts from the server copy, copies every group the local copy wins, and installs the merged
    /// metadata. A tombstone keeps the server's field values (content is irrelevant once deleted).
    private static func entity<T: SyncableEntity & Equatable>(
        _ local: T,
        _ server: T,
        _ copy: (inout T, T, T.FieldGroup) -> Void,
        _ wrap: (T) -> SyncRecord
    ) -> Outcome {
        if local == server {
            return Outcome(merged: wrap(local), isDeleted: local.meta.isTombstone, needsUpload: false)
        }
        let resolution = ConflictPolicy.resolve(local: local.meta, server: server.meta, groups: T.FieldGroup.self)
        let localWon = resolution.localWonGroups
        var merged = server
        for group in T.FieldGroup.allCases where localWon.contains(group) {
            copy(&merged, local, group)
        }
        merged.meta = resolution.mergedMeta
        // A merge that changes nothing but the local version counter keeps the local copy, so a
        // repeated apply is a no-op.
        var probe = merged
        probe.meta.version = local.meta.version
        if probe == local { merged = local }
        return Outcome(
            merged: wrap(merged),
            isDeleted: resolution.isDeleted,
            localWonGroups: Set(localWon.map(\.rawValue)),
            needsUpload: resolution.needsUpload
        )
    }

    // MARK: - Per-type group copies
    // Every stored property except `id` and `meta` must appear in exactly one case below (the same
    // split as the field groups in OpenArcModel/Entities.swift and every backend schema).

    static func copyProfile(_ m: inout Profile, _ l: Profile, _ g: Profile.FieldGroup) {
        switch g {
        case .naming: m.name = l.name
        case .settings: m.settings = l.settings
        }
    }

    static func copyTheme(_ m: inout Theme, _ l: Theme, _ g: Theme.FieldGroup) {
        switch g {
        case .style: m.style = l.style
        }
    }

    static func copySpace(_ m: inout Space, _ l: Space, _ g: Space.FieldGroup) {
        switch g {
        case .naming:
            m.name = l.name
            m.icon = l.icon
        case .theme: m.themeID = l.themeID
        case .profile: m.profileID = l.profileID
        case .placement: m.dockSortKey = l.dockSortKey
        }
    }

    static func copyFolder(_ m: inout Folder, _ l: Folder, _ g: Folder.FieldGroup) {
        switch g {
        case .placement:
            m.spaceID = l.spaceID
            m.parentFolderID = l.parentFolderID
            m.sortKey = l.sortKey
        case .naming: m.title = l.title
        case .display: m.isExpanded = l.isExpanded
        }
    }

    static func copyTab(_ m: inout TabNode, _ l: TabNode, _ g: TabNode.FieldGroup) {
        switch g {
        case .placement:
            m.location = l.location
            m.sortKey = l.sortKey
        case .content:
            m.url = l.url
            m.title = l.title
            m.faviconURL = l.faviconURL
        case .naming: m.customTitle = l.customTitle
        case .pin: m.pinnedURL = l.pinnedURL
        case .activity: m.lastActiveAt = l.lastActiveAt
        }
    }

    static func copyArchiveItem(_ m: inout ArchiveItem, _ l: ArchiveItem, _ g: ArchiveItem.FieldGroup) {
        switch g {
        case .content:
            m.url = l.url
            m.title = l.title
            m.faviconURL = l.faviconURL
            m.spaceID = l.spaceID
            m.folderPath = l.folderPath
            m.reason = l.reason
            m.archivedAt = l.archivedAt
        }
    }

    static func copySplitLayout(_ m: inout SplitLayout, _ l: SplitLayout, _ g: SplitLayout.FieldGroup) {
        switch g {
        case .layout:
            m.spaceID = l.spaceID
            m.root = l.root
        }
    }

    static func copyEasel(_ m: inout Easel, _ l: Easel, _ g: Easel.FieldGroup) {
        switch g {
        case .naming: m.title = l.title
        }
    }

    static func copyEaselElement(_ m: inout EaselElement, _ l: EaselElement, _ g: EaselElement.FieldGroup) {
        switch g {
        case .placement:
            m.easelID = l.easelID
            m.zKey = l.zKey
        case .geometry: m.frame = l.frame
        case .content: m.content = l.content
        case .style: m.style = l.style
        }
    }
}
