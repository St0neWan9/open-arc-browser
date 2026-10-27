import Foundation
import OpenArcModel

// Menu actions and favorites state for the sidebar's right-click menus and the favorites grid
// (plan B55). Spec: docs/arc-spec/06-flows.md §21.1–§21.5 (E19 capture).

extension SidebarViewModel {

    // MARK: Plumbing

    /// Applies a pure workspace change made by a menu item. Returns whether it was accepted.
    @discardableResult
    func menuMutate(_ body: (WorkspaceState) throws -> WorkspaceState) -> Bool {
        do {
            try controller.mutate(origin: self, body)
            onWorkspaceChange?(workspace)
            return true
        } catch {
            return false
        }
    }

    // MARK: Favorites

    /// Live profiles in the order the menus list them (oldest first: Default on top). inferred.
    var menuProfiles: [Profile] { workspace.liveProfilesOldestFirst }

    /// Index of the favorite being dragged (reordering), nil for any other drag. [06 §21.4] B55.
    var draggedFavoriteIndex: Int? {
        guard case .tab(let id)? = draggingItem else { return nil }
        return snapshot.favorites.firstIndex { $0.id == id }
    }

    /// Whether a drag that would add a new tile hovers the favorites (the grid then shows one more
    /// slot, which may add a row). [06 §21.4] observed: the tiles give way while dragging.
    var favoritesPreviewCount: Int {
        let count = snapshot.favorites.count
        guard case .favoriteGap = dropTarget, draggedFavoriteIndex == nil else { return count }
        return count + 1
    }

    /// The empty-state card shows while the profile has no favorites and it was not dismissed.
    /// [06 §21.2] observed card; dismissal per device (inferred).
    /// It stays while a drag hovers it, so the drop block keeps its size (inferred).
    var showsFavoritesEmptyCard: Bool {
        !isIncognito && snapshot.favorites.isEmpty
            && !controller.dependencies.preferences.isFavoritesEmptyCardDismissed
    }

    /// ✕ ("Dismiss") on the empty-state card. [06 §21.2] observed button; its effect is not
    /// captured: inferred, the card goes away for good on this device and an empty drop block
    /// (one tile row) stays in its place.
    func dismissFavoritesEmptyCard() {
        controller.dependencies.preferences.isFavoritesEmptyCardDismissed = true
        controller.objectWillChange.send()
    }

    /// Height of the favorites tiles block for the layout (grid rows, the empty card, or one row).
    /// With no favorites the block keeps its empty size (card or one row) while a drag hovers it.
    var favoritesTilesHeight: CGFloat {
        let count = snapshot.favorites.isEmpty ? 0 : favoritesPreviewCount
        return SidebarFavoritesGrid.tilesHeight(count: count, showsEmptyCard: showsFavoritesEmptyCard)
    }

    /// Favorite ▸ Move to ▸ Profile ▸ <Profile>: the favorite moves to the end of that profile's
    /// favorites. [06 §21.5] observed item; the position is inferred (like adding, [06 §21.4]).
    func moveFavorite(_ id: UUID, toProfile profileID: UUID) {
        guard let tab = workspace.tabs[id], case .favorite(let current) = tab.location, current != profileID else { return }
        menuMutate { try TreeOps.moveTab($0, id: id, to: .favorite(profileID: profileID), position: .last, now: controller.now()) }
    }

    /// Edit Pinned Page ▸ Replace Pinned URL with Current is disabled while the page was not
    /// navigated away from its pinned URL. [06 §21.5] observed.
    func canReplacePinnedURL(_ id: UUID) -> Bool {
        guard let tab = workspace.tabs[id], let current = liveState(for: id)?.url ?? tab.url else { return false }
        return current != tab.pinnedURL
    }

    // MARK: Spaces

    /// Space menu ▸ Set Profile ▸ <Profile>. The favorites block switches to that profile's
    /// favorites at once. [06 §21.1] observed.
    func setSpaceProfile(_ spaceID: UUID, profileID: UUID) {
        menuMutate { try TreeOps.setSpaceProfile($0, id: spaceID, profileID: profileID, now: controller.now()) }
    }

    /// Spaces a "Move to ▸" menu lists, in dock order (the current one is checked). [06 §21.5] observed.
    var menuSpaces: [Space] { dockSpaces }

    // MARK: Folders

    /// Folder ▸ Move to ▸ <Space>: the folder and everything in it go to the end of that Space's
    /// pinned area (like dropping it on the Space's dock icon). inferred.
    func moveFolder(_ id: UUID, toSpace spaceID: UUID) {
        guard let folder = workspace.folders[id], folder.spaceID != spaceID else { return }
        menuMutate {
            try TreeOps.moveFolder($0, id: id, toSpace: spaceID, parentFolderID: nil, position: .last, now: controller.now())
        }
    }

    /// Folder ▸ Delete: archives the folder's tabs (nested ones too) and removes the folder. No
    /// confirmation (inferred: none recorded). The tabs leave like ⌘W, one by one, so the selection
    /// moves to a neighbor row; then the folders are tombstoned.
    func deleteFolder(_ id: UUID) {
        guard let folder = workspace.folders[id], !folder.meta.isTombstone else { return }
        let tabs = workspace.allTabs(inSpace: folder.spaceID).filter { tab in
            guard case .pinned(_, let folderID?) = tab.location else { return false }
            return workspace.folder(folderID, isWithin: id)
        }
        for tab in tabs { closeTab(tab.id) }
        menuMutate { try TreeOps.deleteFolder($0, id: id, now: controller.now()) }
    }

    // MARK: Split rows

    /// The split layout behind a split-group row.
    func splitLayout(_ layoutID: UUID) -> SplitLayout? {
        workspace.splits[layoutID].flatMap { $0.meta.isTombstone ? nil : $0 }
    }

    /// Split row ▸ Separate All Tabs. [06 §21.6] observed: each pane becomes its own row, the split ends.
    func separateAllTabs(_ layoutID: UUID) {
        menuMutate { try TreeOps.separateSplit($0, layoutID: layoutID, now: controller.now()) }
    }

    /// Split row ▸ Add Tab…: a new pane next to the group's focused pane, with the command bar in
    /// it, like Add Split View on that pane. [06 §21.5] observed item; [06 §5] Add Split View.
    func addTabToSplit(_ layoutID: UUID) {
        selectSplitGroup(layoutID)
        addSplitView()
    }

    /// Split row ▸ Convert to Vertical Split View (and back). [06 §21.5] observed item.
    func toggleSplitAxis(_ layoutID: UUID) {
        guard let layout = splitLayout(layoutID), case .split(let axis, _) = layout.root else { return }
        let next: SplitAxis = axis == .horizontal ? .vertical : .horizontal
        menuMutate { try TreeOps.setSplitAxis($0, layoutID: layoutID, axis: next, now: controller.now()) }
    }

    /// Whether the group's top-level split is side by side (the menu offers "Convert to Vertical").
    func isHorizontalSplit(_ layoutID: UUID) -> Bool {
        guard let layout = splitLayout(layoutID), case .split(let axis, _) = layout.root else { return true }
        return axis == .horizontal
    }

    /// Split row ▸ Move to ▸ <Space>: the group moves as a unit to the top of that Space's Today,
    /// like dropping it on the Space's dock icon. inferred.
    func moveSplitGroup(_ layoutID: UUID, toSpace spaceID: UUID) {
        guard let layout = splitLayout(layoutID), layout.spaceID != spaceID else { return }
        menuMutate {
            try TreeOps.moveSplitLayout($0, layoutID: layoutID, toSpaceID: spaceID, position: .first, now: controller.now())
        }
    }

    /// Today tabs above and below a split group's row (members excluded), for the group's
    /// "Archive Other Tabs / Below / Above". A group outside Today has every Today tab as "other"
    /// and nothing above or below. inferred.
    func todayTabs(aroundGroup group: SidebarSplitGroup) -> (above: [UUID], below: [UUID]) {
        guard let spaceID = selectedSpaceID else { return ([], []) }
        let order = workspace.today(spaceID: spaceID).map(\.id)
        let others = order.filter { !group.contains($0) }
        guard let first = order.firstIndex(where: group.contains) else { return (others, []) }
        let above = order[..<first].filter { !group.contains($0) }
        let below = order[first...].filter { !group.contains($0) }
        return (Array(above), Array(below))
    }

    /// Markdown link of a tab, `[title](url)`, for "Copy link as Markdown". [06 §21.5] observed item;
    /// the format is inferred.
    func markdownLink(for id: UUID) -> String? {
        guard let url = linkURL(for: id) else { return nil }
        let title = workspace.tabs[id]?.displayTitle ?? ""
        let text = (title.isEmpty ? url.absoluteString : title)
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
        return "[\(text)](\(url.absoluteString))"
    }
}

// MARK: - Duplicate

extension SidebarViewModel {
    /// Folder ▸ Duplicate: a copy of the folder right below it, with copies of its tabs and nested
    /// folders in the same order. [06 §21.5] observed item; what is copied is inferred.
    func duplicateFolder(_ id: UUID) {
        guard let folder = workspace.folders[id], !folder.meta.isTombstone else { return }
        let stamp = controller.now()
        let makeID = controller.makeID
        menuMutate { state in
            var s = state
            let copyID = makeID()
            s = try TreeOps.createFolder(s, id: copyID, spaceID: folder.spaceID, parentFolderID: folder.parentFolderID,
                                         title: folder.title, now: stamp)
            s = try TreeOps.moveFolder(s, id: copyID, toSpace: folder.spaceID, parentFolderID: folder.parentFolderID,
                                       position: .after(id), now: stamp)
            if !folder.isExpanded { s = try TreeOps.setFolderExpanded(s, id: copyID, isExpanded: false, now: stamp) }
            return try Self.copyFolderContents(s, from: id, into: copyID, spaceID: folder.spaceID, now: stamp, makeID: makeID)
        }
    }

    /// Copies the children of `source` into the (empty) folder `target`, depth first.
    private static func copyFolderContents(
        _ state: WorkspaceState, from source: UUID, into target: UUID, spaceID: UUID,
        now: Date, makeID: () -> UUID
    ) throws -> WorkspaceState {
        var s = state
        for child in state.pinnedChildren(spaceID: spaceID, folderID: source) {
            switch child {
            case .tab(let tab):
                let copy = makeID()
                s = try TreeOps.openTab(s, id: copy, spaceID: spaceID, url: tab.pinnedURL ?? tab.url, title: tab.title, now: now)
                s = try TreeOps.moveTab(s, id: copy, to: .pinned(spaceID: spaceID, folderID: target), position: .last, now: now)
                if let custom = tab.customTitle { s = try TreeOps.renameTab(s, id: copy, customTitle: custom, now: now) }
            case .folder(let folder):
                let copy = makeID()
                s = try TreeOps.createFolder(s, id: copy, spaceID: spaceID, parentFolderID: target, title: folder.title, now: now)
                s = try TreeOps.moveFolder(s, id: copy, toSpace: spaceID, parentFolderID: target, position: .last, now: now)
                if !folder.isExpanded { s = try TreeOps.setFolderExpanded(s, id: copy, isExpanded: false, now: now) }
                s = try copyFolderContents(s, from: folder.id, into: copy, spaceID: spaceID, now: now, makeID: makeID)
            }
        }
        return s
    }

    /// Split row ▸ Duplicate: copies of the group's pages open at the top of Today as a new split
    /// with the same direction. [06 §21.5] observed item; the result is inferred (like Duplicate
    /// on a tab, which opens the copy at the top of Today).
    func duplicateSplitGroup(_ layoutID: UUID) {
        guard let layout = splitLayout(layoutID), case .split(let axis, _) = layout.root,
              let spaceID = selectedSpaceID else { return }
        let members = layout.root.tabIDs.compactMap { id in workspace.tabs[id].flatMap { $0.meta.isTombstone ? nil : $0 } }
        guard members.count > 1 else { return }
        let stamp = controller.now()
        let copies = members.map { _ in controller.makeID() }
        let newLayoutID = controller.makeID()
        let urls = members.map { liveState(for: $0.id)?.url ?? $0.url }
        menuMutate { state in
            var s = state
            // openTab puts each copy on top: open them in reverse so they keep the group's order.
            for (index, member) in members.enumerated().reversed() {
                s = try TreeOps.openTab(s, id: copies[index], spaceID: spaceID, url: urls[index], title: member.displayTitle, now: stamp)
            }
            for index in 1..<copies.count {
                s = try TreeOps.addSplitPane(s, layoutID: newLayoutID, existingTabID: copies[index - 1],
                                             newTabID: copies[index], axis: axis, now: stamp)
            }
            return s
        }
    }
}
