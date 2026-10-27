import Foundation

// Tree operations behind the sidebar's right-click menus (plan B55). Same rules as `TreeOps`:
// pure, `now` comes from the caller, only the changed field groups are stamped, deletion
// tombstones. Spec: docs/arc-spec/06-flows.md §21.1 (favorites per Profile), §21.5 (menus).

extension TreeOps {

    /// Space menu ▸ Set Profile ▸ <Profile>: the Space now belongs to `profileID`. Stamps only the
    /// Space's `profile` group. The sidebar then shows that profile's favorites, since favorites
    /// live per profile and every Space of a profile shares them. [06 §21.1] observed. The dock
    /// order is kept as it is (inferred).
    public static func setSpaceProfile(_ state: WorkspaceState, id: UUID, profileID: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        var space = try liveValue(s.spaces, id)
        _ = try liveValue(s.profiles, profileID)
        guard space.profileID != profileID else { return s }
        space.profileID = profileID
        space.meta.stamp([Space.FieldGroup.profile], at: now)
        s.spaces[id] = space
        return s
    }

    /// Folder menu ▸ Delete: archives every live tab inside the folder (nested folders included)
    /// and tombstones the folder and its nested folders. [06 §21.5] observed the item; what it does
    /// is inferred from Delete Space ([06 §11] observed: "archive all the tabs and folders inside
    /// it"). The tabs are archived as closed by the user, so Restore Last Closed Tab can bring them
    /// back one by one (inferred).
    public static func deleteFolder(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        let folder = try liveValue(state.folders, id)
        var s = state
        let tabs = s.tabs.values.filter { tab in
            guard !tab.meta.isTombstone, case .pinned(let spaceID, let folderID?) = tab.location else { return false }
            return spaceID == folder.spaceID && s.folder(folderID, isWithin: id)
        }
        for tab in tabs.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            s = try archiveTab(s, id: tab.id, reason: .closed, now: now)
        }
        for other in s.folders.values where !other.meta.isTombstone && s.folder(other.id, isWithin: id) {
            s.folders[other.id]?.meta.markDeleted(at: now)
        }
        return s
    }

    /// Split row menu ▸ Separate All Tabs: the split ends and each tab becomes its own row again,
    /// where it already is. [06 §21.6] observed ("两格各自变成 Today 里的一行,分屏结束").
    /// Tombstones the layout; the tabs are not touched.
    public static func separateSplit(_ state: WorkspaceState, layoutID: UUID, now: Date) throws -> WorkspaceState {
        _ = try liveValue(state.splits, layoutID)
        var s = state
        s.splits[layoutID]?.meta.markDeleted(at: now)
        return s
    }

    /// Split row menu ▸ Convert to Vertical Split View: the top-level split stacks its panes
    /// (`.vertical`), or goes back to side by side. Fractions are kept. Stamps the `layout` group.
    /// [06 §21.5] observed the item; converting back is inferred.
    public static func setSplitAxis(_ state: WorkspaceState, layoutID: UUID, axis: SplitAxis, now: Date) throws -> WorkspaceState {
        var layout = try liveValue(state.splits, layoutID)
        guard case .split(let current, let children) = layout.root, current != axis else { return state }
        var s = state
        layout.root = .split(axis: axis, children: children)
        layout.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
        s.splits[layoutID] = layout
        return s
    }

    /// A live record or the matching error (the private `live` helper is not visible here).
    private static func liveValue<T: SyncableEntity>(_ table: [UUID: T], _ id: UUID) throws -> T {
        guard let value = table[id] else { throw TreeError.notFound(id) }
        guard !value.meta.isTombstone else { throw TreeError.tombstoned(id) }
        return value
    }
}
