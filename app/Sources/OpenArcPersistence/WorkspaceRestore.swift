import Foundation
import OpenArcModel
import OpenArcSyncAPI

/// Help ▸ Restore Data (plan B117, decision Q18): turns the current workspace into one whose live
/// records are a backup's live records, made entirely of ordinary local edits so sync stays
/// consistent.
///
/// # Why not just load the backup file
/// Replacing the workspace with the backup value would carry the backup's old field-group stamps
/// and tombstone flags. Under `ConflictPolicy` (field-group last-writer-wins, delete wins) that
/// goes wrong both ways: other devices hold newer stamps, so they would win every group and undo
/// the restore; and a record deleted since the backup was taken has a tombstone on the server,
/// which always wins, so flipping it back to live locally would be silently reverted (or, worse,
/// leave devices disagreeing until the next merge). Records missing from the backup would simply
/// vanish locally without a deletion ever reaching the server.
///
/// # What we do instead
/// - A backup record whose id is **live now** is edited in place: every field group whose content
///   differs from the backup's is overwritten and stamped `now`. Those are newer than anything
///   another device has, so the restore wins the merge there too.
/// - A backup record whose id is **tombstoned now, or gone** (purged after a synced delete) is
///   re-created under a **new id** with fresh metadata (`now`). A tombstone is never undone; the
///   copy is a new record every device accepts. References to it (a tab's Space or folder, a
///   folder's parent, a Space's theme, a split's panes, an archive item's Space, an Easel element's
///   Easel, Easel links in tab URLs) are rewritten to the new id.
/// - Profiles are local-only (plan Q13, never synced), so they keep their ids and a tombstoned one
///   is simply made live again. This also keeps the engine's per-profile data (cookies, history),
///   which is keyed by profile id. A profile made after the backup is kept, not deleted: deleting
///   a profile is a separate, deliberate action with its own consequences for browsing data.
/// - A record live now but not live in the backup is tombstoned (`markDeleted(at: now)`), so the
///   deletion syncs like any other.
/// - A tab that is live now keeps its last-active time; a re-created tab is marked active `now`:
///   a backup is up to a week old, and its last-active times would let auto-archive clear the
///   restored Today tabs at once.
/// - Splits are repaired afterwards (`TreeOps.repairSplits`).
///
/// The result differs from `current` only through `SyncMetadata.stamp` / `markDeleted` and new
/// records, so `WorkspaceDiff.stampedChanges` (and so `WorkspaceStore.submit(changesFrom:to:)`)
/// sees every changed record and the sync store gets them as normal local changes.
public enum WorkspaceRestore {

    /// `current` with the live records of `backup`, as described above. Pure: the time and the new
    /// ids come from the caller (`makeID` is called once per re-created record, in a stable order).
    public static func restored(
        current: WorkspaceState,
        backup: WorkspaceState,
        now: Date,
        makeID: () -> UUID
    ) -> WorkspaceState {
        let maps = IDMaps(current: current, backup: backup, makeID: makeID)
        var s = current

        restore(&s.profiles, current.profiles, backup.profiles.values.map { maps.profile($0) }, now: now, localOnly: true,
                wrap: SyncRecord.profile) { if case .profile(let v) = $0 { return v } else { return nil } }
        restore(&s.themes, current.themes, backup.themes.values.map { maps.theme($0) }, now: now,
                wrap: SyncRecord.theme) { if case .theme(let v) = $0 { return v } else { return nil } }
        restore(&s.spaces, current.spaces, backup.spaces.values.map { maps.space($0) }, now: now,
                wrap: SyncRecord.space) { if case .space(let v) = $0 { return v } else { return nil } }
        restore(&s.folders, current.folders, backup.folders.values.map { maps.folder($0) }, now: now,
                wrap: SyncRecord.folder) { if case .folder(let v) = $0 { return v } else { return nil } }
        restore(&s.tabs, current.tabs, backup.tabs.values.map { maps.tab($0, current: current.tabs, now: now) }, now: now,
                wrap: SyncRecord.tab) { if case .tab(let v) = $0 { return v } else { return nil } }
        restore(&s.archive, current.archive, backup.archive.values.map { maps.archiveItem($0) }, now: now,
                wrap: SyncRecord.archiveItem) { if case .archiveItem(let v) = $0 { return v } else { return nil } }
        restore(&s.splits, current.splits, backup.splits.values.map { maps.split($0) }, now: now,
                wrap: SyncRecord.splitLayout) { if case .splitLayout(let v) = $0 { return v } else { return nil } }
        restore(&s.easels, current.easels, backup.easels.values.map { maps.easel($0) }, now: now,
                wrap: SyncRecord.easel) { if case .easel(let v) = $0 { return v } else { return nil } }
        restore(&s.easelElements, current.easelElements, backup.easelElements.values.map { maps.easelElement($0) }, now: now,
                wrap: SyncRecord.easelElement) { if case .easelElement(let v) = $0 { return v } else { return nil } }

        return TreeOps.repairSplits(s, now: now)
    }

    // MARK: - One record type

    /// Writes `targets` (backup records, ids and references already mapped; tombstones in the
    /// backup are skipped) into `records`, and tombstones every live record of `current` that is
    /// not among them.
    private static func restore<T: SyncableEntity & Hashable>(
        _ records: inout [UUID: T],
        _ current: [UUID: T],
        _ targets: [T?],
        now: Date,
        localOnly: Bool = false,
        wrap: (T) -> SyncRecord,
        unwrap: (SyncRecord) -> T?
    ) {
        var kept = Set<UUID>()
        for case let target? in targets {
            kept.insert(target.id)
            if let existing = current[target.id], localOnly || !existing.meta.isTombstone {
                records[target.id] = restoreInPlace(existing, to: target, now: now, wrap: wrap, unwrap: unwrap)
            } else {
                // A new record (`IDMaps` gave every non-live synced record a new id).
                var fresh = target
                fresh.meta = .new(at: now, groups: T.FieldGroup.self)
                records[target.id] = fresh
            }
        }
        // Local-only records (Profiles) made after the backup are kept (see the type comment).
        for (id, record) in current where !localOnly && !record.meta.isTombstone && !kept.contains(id) {
            records[id]?.meta.markDeleted(at: now)
        }
    }

    /// `existing` with the content of `target` in every field group where they differ; only those
    /// groups are stamped `now`. A tombstone (local-only types only) is made live again with every
    /// group stamped.
    ///
    /// The per-group field copy is `RecordMerge`'s (the one place that knows which fields form a
    /// group): merging a copy of `target` whose chosen groups carry the latest possible time over
    /// `existing` yields `existing` with exactly those groups taken from `target`.
    private static func restoreInPlace<T: SyncableEntity & Hashable>(
        _ existing: T,
        to target: T,
        now: Date,
        wrap: (T) -> SyncRecord,
        unwrap: (SyncRecord) -> T?
    ) -> T {
        func content(_ value: T) -> T {
            var v = value
            v.meta = existing.meta
            return v
        }
        func taking(_ groups: Set<String>) -> T {
            guard !groups.isEmpty else { return existing }
            var local = target
            var server = existing
            local.meta = existing.meta
            local.meta.isTombstone = false
            server.meta.isTombstone = false
            for group in T.FieldGroup.allCases {
                local.meta.fieldGroupModifiedAt[group.rawValue] = groups.contains(group.rawValue) ? .distantFuture : .distantPast
                server.meta.fieldGroupModifiedAt[group.rawValue] = Date(timeIntervalSinceReferenceDate: 0)
            }
            guard let outcome = RecordMerge.merge(local: wrap(local), server: wrap(server)),
                  let merged = unwrap(outcome.merged)
            else { return existing }
            return content(merged)
        }

        let base = content(existing)
        let changed = T.FieldGroup.allCases.filter { taking([$0.rawValue]) != base }
        var result = taking(Set(changed.map(\.rawValue)))
        result.meta = existing.meta
        if result.meta.isTombstone {
            result.meta.isTombstone = false
            result.meta.deletedAt = nil
            result.meta.stamp(Array(T.FieldGroup.allCases), at: now)
        } else if !changed.isEmpty {
            result.meta.stamp(changed, at: now)
        }
        return result
    }
}

// MARK: - Id mapping

/// Old (backup) id → id in the restored workspace, per record type. A backup record keeps its id
/// when that id is live now (for Profiles: whenever it exists); otherwise it gets a new one.
/// Tombstones in the backup are not restored and get no entry.
private struct IDMaps {
    var profiles: [UUID: UUID] = [:]
    var themes: [UUID: UUID] = [:]
    var spaces: [UUID: UUID] = [:]
    var folders: [UUID: UUID] = [:]
    var tabs: [UUID: UUID] = [:]
    var archive: [UUID: UUID] = [:]
    var splits: [UUID: UUID] = [:]
    var easels: [UUID: UUID] = [:]
    var easelElements: [UUID: UUID] = [:]

    init(current: WorkspaceState, backup: WorkspaceState, makeID: () -> UUID) {
        func map<T: SyncableEntity>(_ backup: [UUID: T], _ current: [UUID: T], localOnly: Bool = false) -> [UUID: UUID] {
            var result: [UUID: UUID] = [:]
            // Sorted, so `makeID` is called in a stable order.
            for record in backup.values.sorted(by: { $0.id.uuidString < $1.id.uuidString }) where !record.meta.isTombstone {
                let keeps = localOnly ? true : current[record.id].map { !$0.meta.isTombstone } ?? false
                result[record.id] = keeps ? record.id : makeID()
            }
            return result
        }
        profiles = map(backup.profiles, current.profiles, localOnly: true)
        themes = map(backup.themes, current.themes)
        spaces = map(backup.spaces, current.spaces)
        folders = map(backup.folders, current.folders)
        tabs = map(backup.tabs, current.tabs)
        archive = map(backup.archive, current.archive)
        splits = map(backup.splits, current.splits)
        easels = map(backup.easels, current.easels)
        easelElements = map(backup.easelElements, current.easelElements)
    }

    // References to records the backup does not restore (its own tombstones) keep their id.
    private func ref(_ id: UUID, _ map: [UUID: UUID]) -> UUID { map[id] ?? id }
    private func ref(_ id: UUID?, _ map: [UUID: UUID]) -> UUID? { id.map { ref($0, map) } }

    private func link(_ url: URL?) -> URL? {
        guard let easelID = EaselLink.easelID(from: url), let mapped = easels[easelID], mapped != easelID else { return url }
        return EaselLink.url(for: mapped)
    }

    private func location(_ location: TabLocation) -> TabLocation {
        switch location {
        case .favorite(let profileID): return .favorite(profileID: ref(profileID, profiles))
        case .pinned(let spaceID, let folderID): return .pinned(spaceID: ref(spaceID, spaces), folderID: ref(folderID, folders))
        case .today(let spaceID): return .today(spaceID: ref(spaceID, spaces))
        }
    }

    private func node(_ node: SplitNode) -> SplitNode {
        switch node {
        case .pane(let tabID): return .pane(tabID: ref(tabID, tabs))
        case .split(let axis, let children):
            return .split(axis: axis, children: children.map { SplitChild(node: self.node($0.node), fraction: $0.fraction) })
        }
    }

    // Each builder copies every stored property (the same list as `RecordMerge`'s group copies);
    // `meta` is the backup's and is replaced by `WorkspaceRestore`.

    func profile(_ v: Profile) -> Profile? {
        guard let id = profiles[v.id] else { return nil }
        var r = Profile(id: id, name: v.name, icon: v.icon, settings: v.settings, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }

    func theme(_ v: Theme) -> Theme? {
        guard let id = themes[v.id] else { return nil }
        var r = Theme(id: id, appearance: v.appearance, colors: v.colors, grain: v.grain, brightness: v.brightness, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }

    func space(_ v: Space) -> Space? {
        guard let id = spaces[v.id] else { return nil }
        var r = Space(id: id, profileID: ref(v.profileID, profiles), name: v.name, icon: v.icon,
                      themeID: ref(v.themeID, themes), dockSortKey: v.dockSortKey, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }

    func folder(_ v: Folder) -> Folder? {
        guard let id = folders[v.id] else { return nil }
        var r = Folder(id: id, spaceID: ref(v.spaceID, spaces), parentFolderID: ref(v.parentFolderID, folders), title: v.title,
                       icon: v.icon, isExpanded: v.isExpanded, sortKey: v.sortKey, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }

    /// The tab with the last-active time of its live copy in `current`, else `now` (see
    /// `WorkspaceRestore`).
    func tab(_ v: TabNode, current: [UUID: TabNode], now: Date) -> TabNode? {
        guard let id = tabs[v.id] else { return nil }
        var r = TabNode(id: id, location: location(v.location), sortKey: v.sortKey, url: link(v.url), title: v.title,
                        customTitle: v.customTitle, icon: v.icon, pinnedURL: link(v.pinnedURL), faviconURL: v.faviconURL, now: now)
        r.meta = v.meta
        if id == v.id, let live = current[id], !live.meta.isTombstone { r.lastActiveAt = live.lastActiveAt }
        return r
    }

    func archiveItem(_ v: ArchiveItem) -> ArchiveItem? {
        guard let id = archive[v.id] else { return nil }
        var r = ArchiveItem(id: id, url: link(v.url), title: v.title, faviconURL: v.faviconURL, spaceID: ref(v.spaceID, spaces),
                            folderPath: v.folderPath, reason: v.reason, archivedAt: v.archivedAt, isFromLittleArc: v.isFromLittleArc)
        r.meta = v.meta
        return r
    }

    func split(_ v: SplitLayout) -> SplitLayout? {
        guard let id = splits[v.id] else { return nil }
        var r = SplitLayout(id: id, spaceID: ref(v.spaceID, spaces), root: node(v.root), title: v.title, icon: v.icon, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }

    func easel(_ v: Easel) -> Easel? {
        guard let id = easels[v.id] else { return nil }
        var r = Easel(id: id, title: v.title, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }

    func easelElement(_ v: EaselElement) -> EaselElement? {
        guard let id = easelElements[v.id] else { return nil }
        var r = EaselElement(id: id, easelID: ref(v.easelID, easels), zKey: v.zKey, frame: v.frame, content: v.content,
                             style: v.style, now: v.meta.createdAt)
        r.meta = v.meta
        return r
    }
}
