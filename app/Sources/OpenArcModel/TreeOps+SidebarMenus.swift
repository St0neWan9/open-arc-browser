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

    // MARK: Change Icon… / Rename… (B77)

    /// Tab / favorite ▸ Change Icon…: sets (nil clears) the icon drawn instead of the favicon.
    /// Stamps only `naming` (custom title and icon share it), and only when the icon changes.
    /// [06 §21.5] observed item; the picker is our Space icon picker (B77).
    public static func setTabIcon(_ state: WorkspaceState, id: UUID, icon: String?, now: Date) throws -> WorkspaceState {
        var tab = try liveValue(state.tabs, id)
        guard tab.icon != icon else { return state }
        var s = state
        tab.icon = icon
        tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
        s.tabs[id] = tab
        return s
    }

    /// Folder ▸ Change Icon…: sets (nil clears) the icon drawn instead of the folder glyph. Stamps
    /// only `naming`. [06 §21.5] observed item.
    public static func setFolderIcon(_ state: WorkspaceState, id: UUID, icon: String?, now: Date) throws -> WorkspaceState {
        var folder = try liveValue(state.folders, id)
        guard folder.icon != icon else { return state }
        var s = state
        folder.icon = icon
        folder.meta.stamp([Folder.FieldGroup.naming], at: now)
        s.folders[id] = folder
        return s
    }

    /// Split row ▸ Change Icon…: the row's own icon. Stamps only the layout's `naming` group, so a
    /// concurrent divider drag (`layout`) on another device is kept. [06 §21.5] observed item.
    public static func setSplitIcon(_ state: WorkspaceState, layoutID: UUID, icon: String?, now: Date) throws -> WorkspaceState {
        var layout = try liveValue(state.splits, layoutID)
        guard layout.icon != icon else { return state }
        var s = state
        layout.icon = icon
        layout.meta.stamp([SplitLayout.FieldGroup.naming], at: now)
        s.splits[layoutID] = layout
        return s
    }

    /// Split row ▸ Rename…: the row's own title; nil (or blank) goes back to the members' titles.
    /// Stamps only the layout's `naming` group. [06 §21.5] observed item; the fallback is inferred.
    public static func renameSplit(_ state: WorkspaceState, layoutID: UUID, title: String?, now: Date) throws -> WorkspaceState {
        var layout = try liveValue(state.splits, layoutID)
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard layout.title != value else { return state }
        var s = state
        layout.title = value
        layout.meta.stamp([SplitLayout.FieldGroup.naming], at: now)
        s.splits[layoutID] = layout
        return s
    }

    // MARK: Edit Pinned Page ▸ Edit… (B77)

    /// Edit Pinned Page ▸ Edit…: the pinned (original) URL and the title of a pinned tab or a
    /// favorite. A blank title, or the page's own title, clears the custom title. Stamps `pin` when
    /// the URL changes and `naming` when the title changes; nothing else. Today tabs have no pinned
    /// page (`spaceMismatch`). [05 §context menus], [06 §21.5] observed items; the form (URL +
    /// title) is inferred ([06 §21.8] lists it as not captured).
    public static func editPinnedPage(_ state: WorkspaceState, id: UUID, url: URL, title: String?, now: Date) throws -> WorkspaceState {
        var tab = try liveValue(state.tabs, id)
        if case .today = tab.location { throw TreeError.spaceMismatch }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let customTitle: String? = trimmed.isEmpty || trimmed == tab.title ? nil : trimmed
        var groups: [TabNode.FieldGroup] = []
        if tab.pinnedURL != url {
            tab.pinnedURL = url
            groups.append(.pin)
        }
        if tab.customTitle != customTitle {
            tab.customTitle = customTitle
            groups.append(.naming)
        }
        guard !groups.isEmpty else { return state }
        var s = state
        tab.meta.stamp(groups, at: now)
        s.tabs[id] = tab
        return s
    }

    // MARK: Move to ▸ Profile ▸ (B77)

    /// Move to ▸ Profile ▸ <Profile>. A favorite goes to the end of that profile's favorites
    /// ([06 §21.5] observed). A pinned tab goes to the end of the top-level pinned area of the
    /// profile's first Space in dock order, a Today tab to the top of that Space's Today
    /// ([05 §context menus] observed Profile ▸ on the pinned menu; the landing place is inferred).
    /// Profiles are local (B73): `profileID` is a profile of this device, and Spaces are matched by
    /// their local profile (`spaces(inProfile:)`). A tab already in that profile is left as it is.
    /// A tab leaving its Space also leaves its split. Throws `notFound(profileID)` when the profile
    /// has no Space to receive a pinned or Today tab.
    public static func moveTabToProfile(_ state: WorkspaceState, id: UUID, profileID: UUID, now: Date) throws -> WorkspaceState {
        let tab = try liveValue(state.tabs, id)
        _ = try liveValue(state.profiles, profileID)
        switch tab.location {
        case .favorite(let current):
            guard state.localProfileID(for: current) != profileID else { return state }
            return try moveTab(state, id: id, to: .favorite(profileID: profileID), position: .last, now: now)
        case .pinned(let spaceID, _), .today(let spaceID):
            guard state.profileID(ofSpace: spaceID) != profileID else { return state }
            guard let target = state.spaces(inProfile: profileID).first else { throw TreeError.notFound(profileID) }
            var s = removeSplitPane(state, tabID: id, now: now)
            if tab.location.isPinned {
                s = try moveTab(s, id: id, to: .pinned(spaceID: target.id, folderID: nil), position: .last, now: now)
            } else {
                s = try moveTab(s, id: id, to: .today(spaceID: target.id), position: .first, now: now)
            }
            return s
        }
    }

    // MARK: Turn “<folder>” into Space (B77)

    /// Folder ▸ Turn “<name>” into Space: a new Space named after the folder (with its icon) is
    /// added right after the folder's Space, in the same (local) profile; the folder's children
    /// become the new Space's top-level pinned items in the same order, nested folders keep their
    /// contents, and the folder itself is tombstoned. [06 §21.5] observed item; the result is
    /// inferred from its title. The new Space gets a copy of the source Space's theme
    /// (`newThemeID`; inferred, so editing one theme never changes the other) or no theme when the
    /// source has none. Split layouts whose tabs all moved follow them; tabs that moved leave a
    /// split whose other tabs stayed.
    public static func turnFolderIntoSpace(
        _ state: WorkspaceState,
        folderID: UUID,
        newSpaceID: UUID,
        newThemeID: UUID,
        now: Date
    ) throws -> WorkspaceState {
        let folder = try liveValue(state.folders, folderID)
        let source = try liveValue(state.spaces, folder.spaceID)
        guard let profileID = state.localProfileID(for: source.profileID) else { throw TreeError.notFound(source.profileID) }
        var s = state
        var themeID: UUID?
        if let sourceTheme = source.themeID.flatMap({ state.themes[$0] }), !sourceTheme.meta.isTombstone {
            s = createTheme(s, id: newThemeID, style: sourceTheme.style, now: now)
            themeID = newThemeID
        }
        s = try createSpace(s, id: newSpaceID, profileID: profileID, name: folder.title, icon: folder.icon,
                            themeID: themeID, afterSpaceID: source.id, now: now)
        var movedTabs: Set<UUID> = []
        for child in s.pinnedChildren(spaceID: folder.spaceID, folderID: folderID) {
            switch child {
            case .tab(let tab):
                s = try moveTab(s, id: tab.id, to: .pinned(spaceID: newSpaceID, folderID: nil), position: .last, now: now)
            case .folder(let nested):
                s = try moveFolder(s, id: nested.id, toSpace: newSpaceID, parentFolderID: nil, position: .last, now: now)
            }
        }
        for tab in s.tabs.values where !tab.meta.isTombstone && tab.location.spaceID == newSpaceID {
            movedTabs.insert(tab.id)
        }
        s = rehomeSplits(s, movedTabs: movedTabs, from: folder.spaceID, to: newSpaceID, now: now)
        s.folders[folderID]?.meta.markDeleted(at: now)
        return s
    }

    /// Split layouts of `from` that name moved tabs: when every non-favorite member moved, the
    /// layout's space follows (`layout` stamped); otherwise the moved tabs leave it.
    private static func rehomeSplits(_ state: WorkspaceState, movedTabs: Set<UUID>, from: UUID, to: UUID, now: Date) -> WorkspaceState {
        var s = state
        for layout in state.splits.values where !layout.meta.isTombstone && layout.spaceID == from {
            let members = layout.root.tabIDs.filter { id in
                guard let tab = s.tabs[id], !tab.meta.isTombstone else { return false }
                if case .favorite = tab.location { return false }
                return true
            }
            let moved = members.filter(movedTabs.contains)
            guard !moved.isEmpty else { continue }
            if moved.count == members.count {
                s.splits[layout.id]?.spaceID = to
                s.splits[layout.id]?.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
            } else {
                for id in moved { s = removeSplitPane(s, tabID: id, now: now) }
            }
        }
        return s
    }

    // MARK: Export “<Space>” into Folder ▸ (B77)

    /// Space menu ▸ Export “<name>” into Folder ▸ <other Space>: a new folder named after the Space
    /// (with its icon) at the top of the other Space's pinned area, holding a copy of the Space's
    /// pinned area: folders (expanded state kept) and pinned tabs in the same order, each tab at
    /// its pinned URL with its custom title and icon. The exported Space is not changed, and Today
    /// tabs, favorites and splits are not copied. [05 §context menus], [06 §21.5] observed item
    /// ("Export … into Folder ▸ <other Spaces>"); copying (rather than moving) is our reading of
    /// "Export" (inferred). `newID` gives the id of the copy of each source record; it is called
    /// once per copied folder and tab. Throws `spaceMismatch` when both Spaces are the same.
    public static func exportSpaceIntoFolder(
        _ state: WorkspaceState,
        spaceID: UUID,
        intoSpaceID: UUID,
        folderID: UUID,
        newID: (UUID) -> UUID,
        now: Date
    ) throws -> WorkspaceState {
        guard spaceID != intoSpaceID else { throw TreeError.spaceMismatch }
        let space = try liveValue(state.spaces, spaceID)
        _ = try liveValue(state.spaces, intoSpaceID)
        var s = try createFolder(state, id: folderID, spaceID: intoSpaceID, title: space.name, now: now)
        // A record created at `now` has every group stamped at `now`: setting fields of the new
        // copies needs no further stamp.
        s.folders[folderID]?.icon = space.icon
        return try copyPinned(s, from: spaceID, folder: nil, into: intoSpaceID, folder: folderID, newID: newID, now: now)
    }

    /// Copies the pinned children of (`sourceSpace`, `sourceFolder`) to the end of the empty
    /// folder `targetFolder` in `targetSpace`, depth first.
    private static func copyPinned(
        _ state: WorkspaceState,
        from sourceSpace: UUID, folder sourceFolder: UUID?,
        into targetSpace: UUID, folder targetFolder: UUID,
        newID: (UUID) -> UUID, now: Date
    ) throws -> WorkspaceState {
        var s = state
        let container = TabLocation.pinned(spaceID: targetSpace, folderID: targetFolder)
        for child in state.pinnedChildren(spaceID: sourceSpace, folderID: sourceFolder) {
            switch child {
            case .tab(let tab):
                let copy = newID(tab.id)
                s = try openTab(s, id: copy, spaceID: targetSpace, url: tab.pinnedURL ?? tab.url, title: tab.title, now: now)
                s = try moveTab(s, id: copy, to: container, position: .last, now: now)
                s.tabs[copy]?.customTitle = tab.customTitle
                s.tabs[copy]?.icon = tab.icon
                s.tabs[copy]?.faviconURL = tab.faviconURL
            case .folder(let folder):
                let copy = newID(folder.id)
                s = try createFolder(s, id: copy, spaceID: targetSpace, parentFolderID: targetFolder, title: folder.title, now: now)
                s = try moveFolder(s, id: copy, toSpace: targetSpace, parentFolderID: targetFolder, position: .last, now: now)
                s.folders[copy]?.icon = folder.icon
                s.folders[copy]?.isExpanded = folder.isExpanded
                s = try copyPinned(s, from: sourceSpace, folder: folder.id, into: targetSpace, folder: copy, newID: newID, now: now)
            }
        }
        return s
    }

    /// A live record or the matching error (the private `live` helper is not visible here).
    private static func liveValue<T: SyncableEntity>(_ table: [UUID: T], _ id: UUID) throws -> T {
        guard let value = table[id] else { throw TreeError.notFound(id) }
        guard !value.meta.isTombstone else { throw TreeError.tombstoned(id) }
        return value
    }
}
