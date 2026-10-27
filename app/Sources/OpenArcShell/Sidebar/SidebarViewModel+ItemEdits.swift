import Foundation
import OpenArcModel

// Context-menu items that edit or move sidebar items (plan B77): Change Icon…, Edit Pinned Page ▸
// Edit…, Show Unread Badge, Turn “<folder>” into Space, Export “<Space>” into Folder ▸, Move to ▸
// Profile ▸ / New Space…, split-row Rename… and the tab Share request.
// Spec: docs/arc-spec/05-surfaces.md §context menus; 06-flows.md §12 (favorite hover tip), §20.2,
// §21.5 (menus). Workspace changes go through the pure functions in `TreeOps+SidebarMenus.swift`.

/// A pending system share picker for a tab's link.
struct SidebarShareRequest: Equatable {
    let serial: Int
    let tabID: UUID
    let url: URL
}

extension SidebarViewModel {

    // MARK: Change Icon…

    /// The icon an item shows instead of its favicon / folder glyph, nil for the default.
    func customIcon(of itemID: UUID) -> String? {
        if let tab = workspace.tabs[itemID] { return tab.icon }
        if let folder = workspace.folders[itemID] { return folder.icon }
        return workspace.splits[itemID]?.icon
    }

    /// Change Icon… on a tab, favorite, folder or split row opens the icon picker (the Space icon
    /// picker, B77). [06 §21.5] observed item.
    func beginChangeIcon(_ itemID: UUID) {
        guard workspace.tabs[itemID] != nil || workspace.folders[itemID] != nil || workspace.splits[itemID] != nil else { return }
        hoverEnded(itemID)
        iconPickerItemID = itemID
    }

    func cancelChangeIcon() { iconPickerItemID = nil }

    /// Applies the picked icon (nil = back to the default) and closes the picker.
    func chooseIcon(_ icon: String?) {
        guard let id = iconPickerItemID else { return }
        iconPickerItemID = nil
        let stamp = controller.now()
        if workspace.tabs[id] != nil {
            menuMutate { try TreeOps.setTabIcon($0, id: id, icon: icon, now: stamp) }
        } else if workspace.folders[id] != nil {
            menuMutate { try TreeOps.setFolderIcon($0, id: id, icon: icon, now: stamp) }
        } else if workspace.splits[id] != nil {
            menuMutate { try TreeOps.setSplitIcon($0, layoutID: id, icon: icon, now: stamp) }
        }
    }

    // MARK: Edit Pinned Page ▸ Edit…

    /// Opens the Edit… sheet (URL + title) for a pinned tab or a favorite. [06 §21.5] observed item.
    func beginEditPinnedPage(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone, !isToday(tab) else { return }
        pinnedPageEditorTabID = id
    }

    func cancelEditPinnedPage() { pinnedPageEditorTabID = nil }

    /// The URL a pinned-page field text stands for (typed like the command bar: `example.com`
    /// gets https), nil when it is not a URL. inferred.
    static func pinnedPageURL(from text: String) -> URL? {
        if case .url(let url) = CommandBarInputClassifier.classify(text) { return url }
        return nil
    }

    /// Saves the sheet: the pinned URL and the title (blank = the page title). When the page was
    /// still at its old pinned URL it goes to the new one (inferred: the pinned page *is* that
    /// URL until the user navigates away). Returns false when the URL is not valid.
    @discardableResult
    func commitEditPinnedPage(urlText: String, title: String) -> Bool {
        guard let id = pinnedPageEditorTabID, let tab = workspace.tabs[id], let url = Self.pinnedPageURL(from: urlText) else { return false }
        let current = liveState(for: id)?.url ?? tab.url
        let wasAtPinnedPage = current == nil || current == tab.pinnedURL
        pinnedPageEditorTabID = nil
        let stamp = controller.now()
        guard menuMutate({ try TreeOps.editPinnedPage($0, id: id, url: url, title: title, now: stamp) }) else { return false }
        if wasAtPinnedPage, url != current { resetTabToPinnedURL(id) }
        return true
    }

    // MARK: Show Unread Badge (favorites)

    /// Favorite ▸ Show Unread Badge is on for this favorite. Per device (inferred: a display
    /// choice, like the dismissed empty card). [05 §context menus] observed item.
    func showsUnreadBadge(_ id: UUID) -> Bool {
        controller.dependencies.preferences.unreadBadgeTabIDs.contains(id)
    }

    func toggleUnreadBadge(_ id: UUID) {
        guard let tab = workspace.tabs[id], case .favorite = tab.location else { return }
        var ids = controller.dependencies.preferences.unreadBadgeTabIDs
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        controller.dependencies.preferences.unreadBadgeTabIDs = ids
        controller.objectWillChange.send()
    }

    /// The count a favorite's badge shows: the unread count in its page title ("Inbox (3)").
    /// nil when the badge is off. Badge source inferred (plan B77).
    func unreadCount(_ id: UUID) -> Int? {
        guard showsUnreadBadge(id), let tab = workspace.tabs[id] else { return nil }
        let title = liveState(for: id)?.title ?? tab.title
        return UnreadBadge.count(inTitle: title.isEmpty ? tab.title : title)
    }

    /// The favorite hover tip while its badge is on. [06 §12] observed ("No unread emails, you can
    /// exhale! 🌿" on a tile without unread items); the text with unread items is inferred.
    func favoriteHoverTip(_ id: UUID) -> String? {
        guard let count = unreadCount(id) else { return nil }
        return UnreadBadge.tip(count: count)
    }

    // MARK: Move to ▸ Profile ▸

    /// Pinned / favorite ▸ Move to ▸ Profile ▸ <Profile>. Profiles are local (B73). [05 §context
    /// menus] observed for pinned tabs, [06 §21.5] for favorites.
    func moveTabToProfile(_ id: UUID, profileID: UUID) {
        let stamp = controller.now()
        menuMutate { try TreeOps.moveTabToProfile($0, id: id, profileID: profileID, now: stamp) }
    }

    /// The local profile a tab belongs to (favorite: its profile; else its Space's).
    func profileID(ofTab id: UUID) -> UUID? {
        guard let tab = workspace.tabs[id] else { return nil }
        switch tab.location {
        case .favorite(let p): return workspace.localProfileID(for: p)
        case .pinned(let spaceID, _), .today(let spaceID): return workspace.profileID(ofSpace: spaceID)
        }
    }

    /// A pinned tab can only move to a profile that has a Space to receive it.
    func canMoveTab(_ id: UUID, toProfile profileID: UUID) -> Bool {
        guard let tab = workspace.tabs[id] else { return false }
        if case .favorite = tab.location { return true }
        return !workspace.spaces(inProfile: profileID).isEmpty
    }

    // MARK: Move to ▸ New Space…

    /// Move to ▸ New Space…: the shell opens New Space and moves the item there once it is
    /// created. [06 §21.5] observed item (B77).
    func requestNewSpace(moving itemID: UUID) {
        requestFromMenu(.newSpaceWithItem(itemID: itemID))
    }

    /// Moves a tab, folder or split row (by its layout id) to a Space, as Move to ▸ <Space> does.
    func moveItem(_ itemID: UUID, toSpace spaceID: UUID) {
        if workspace.tabs[itemID] != nil {
            moveTab(itemID, toSpace: spaceID)
        } else if workspace.folders[itemID] != nil {
            moveFolder(itemID, toSpace: spaceID)
        } else if workspace.splits[itemID] != nil {
            moveSplitGroup(itemID, toSpace: spaceID)
        }
    }

    // MARK: Turn “<folder>” into Space / Export “<Space>” into Folder ▸

    /// Folder ▸ Turn “<name>” into Space: the folder becomes a new Space after the current one, and
    /// the sidebar shows it (inferred). [06 §21.5] observed item. Returns the new Space id.
    @discardableResult
    func turnFolderIntoSpace(_ folderID: UUID) -> UUID? {
        guard let folder = workspace.folders[folderID], !folder.meta.isTombstone else { return nil }
        let spaceID = controller.makeID(), themeID = controller.makeID(), stamp = controller.now()
        guard menuMutate({ try TreeOps.turnFolderIntoSpace($0, folderID: folderID, newSpaceID: spaceID, newThemeID: themeID, now: stamp) })
        else { return nil }
        selectSpace(spaceID)
        return spaceID
    }

    /// Space ▸ Export “<name>” into Folder ▸ <other Space>: a copy of the pinned area as a folder
    /// at the top of the other Space. [05 §context menus], [06 §21.5] observed item. Returns the
    /// new folder id.
    @discardableResult
    func exportSpace(_ spaceID: UUID, intoSpace targetID: UUID) -> UUID? {
        let folderID = controller.makeID(), stamp = controller.now(), makeID = controller.makeID
        guard menuMutate({
            try TreeOps.exportSpaceIntoFolder($0, spaceID: spaceID, intoSpaceID: targetID, folderID: folderID,
                                              newID: { _ in makeID() }, now: stamp)
        }) else { return nil }
        return folderID
    }

    // MARK: Share

    /// Tab menu Share (the incognito menu's flat item and `SidebarRequest.share`): shows the system
    /// share picker for the tab's link. [06 §20.2], [06 §21.5] observed ("系统分享服务").
    func beginShare(_ tabID: UUID) {
        guard let url = linkURL(for: tabID) else { return }
        shareRequest = SidebarShareRequest(serial: (shareRequest?.serial ?? 0) + 1, tabID: tabID, url: url)
    }

    /// The picker closed (a service chosen or not).
    func finishShare(serial: Int) {
        guard shareRequest?.serial == serial else { return }
        shareRequest = nil
    }

    // MARK: Helpers

    private func isToday(_ tab: TabNode) -> Bool {
        if case .today = tab.location { return true }
        return false
    }
}

/// The favorite unread badge: the count comes from the page title, as mail and chat sites put it
/// there ("Inbox (3) – …", "(12) Chat"). inferred (plan B77; the spec does not record the source).
enum UnreadBadge {
    /// The first "(N)" in the title (N digits, optionally "N+"); 0 when there is none.
    static func count(inTitle title: String) -> Int {
        var rest = Substring(title)
        while let open = rest.firstIndex(of: "(") {
            let after = rest[rest.index(after: open)...]
            guard let close = after.firstIndex(of: ")") else { break }
            var inner = after[..<close]
            if inner.hasSuffix("+") { inner = inner.dropLast() }
            if !inner.isEmpty, inner.allSatisfy(\.isASCII), let value = Int(inner), value >= 0 { return value }
            rest = after[after.index(after: close)...]
        }
        return 0
    }

    /// Badge text: the count, capped at "99+". inferred.
    static func label(count: Int) -> String { count > 99 ? "99+" : String(count) }

    /// The hover tip. [06 §12] observed the zero text; the other is inferred.
    static func tip(count: Int) -> String {
        count == 0 ? "No unread emails, you can exhale! 🌿" : (count == 1 ? "1 unread item" : "\(label(count: count)) unread items")
    }
}
