import XCTest
@testable import OpenArcModel

/// Tree operations behind the B77 context-menu items. Spec: docs/arc-spec/05-surfaces.md
/// §context menus; 06-flows.md §21.5 (Change Icon…, Edit Pinned Page ▸ Edit…, Turn “<folder>”
/// into Space, Export “<Space>” into Folder ▸, Move to ▸ Profile ▸, split row Rename…).
final class TreeOpsItemEditTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100)
    private let t1 = Date(timeIntervalSince1970: 200)
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// Profiles 1 (Default) and 2; Spaces 10, 11 in profile 1 and 12 in profile 2; theme 5 on 10.
    private func base() throws -> WorkspaceState {
        var s = WorkspaceState()
        s = TreeOps.createProfile(s, id: id(1), name: "Default", now: t0)
        s = TreeOps.createProfile(s, id: id(2), name: "Work", now: t0)
        s = TreeOps.createTheme(s, id: id(5), style: ThemeStyle(colors: [RGBAColor(hex: 0x6E5BD6)], grain: 0.3), now: t0)
        s = try TreeOps.createSpace(s, id: id(10), profileID: id(1), name: "Home", icon: "🏠", themeID: id(5), now: t0)
        s = try TreeOps.createSpace(s, id: id(11), profileID: id(1), name: "Side", afterSpaceID: id(10), now: t0)
        s = try TreeOps.createSpace(s, id: id(12), profileID: id(2), name: "Office", now: t0)
        return s
    }

    private func pinned(_ s: inout WorkspaceState, _ tab: UUID, space: UUID, folder: UUID? = nil, url: String = "https://x.example") throws {
        s = try TreeOps.openTab(s, id: tab, spaceID: space, url: URL(string: url), title: "t\(tab.uuidString.suffix(2))", now: t0)
        s = try TreeOps.moveTab(s, id: tab, to: .pinned(spaceID: space, folderID: folder), position: .last, now: t0)
    }

    // MARK: Change Icon…

    /// 06 §21.5 observed Change Icon… on tabs, favorites, folders and split rows: only `naming` is
    /// stamped; setting the same icon changes nothing; nil goes back to the default.
    func testSetIconsStampOnlyNaming() throws {
        var s = try base()
        try pinned(&s, id(20), space: id(10))
        s = try TreeOps.createFolder(s, id: id(30), spaceID: id(10), title: "F", now: t0)
        s = try TreeOps.openTab(s, id: id(21), spaceID: id(10), url: nil, title: "b", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: id(40), existingTabID: id(20), newTabID: id(21), now: t0)

        s = try TreeOps.setTabIcon(s, id: id(20), icon: "⭐️", now: t1)
        s = try TreeOps.setFolderIcon(s, id: id(30), icon: "book", now: t1)
        s = try TreeOps.setSplitIcon(s, layoutID: id(40), icon: "🔬", now: t1)
        let tab = s.tabs[id(20)]!, folder = s.folders[id(30)]!, split = s.splits[id(40)]!
        XCTAssertEqual(tab.icon, "⭐️")
        XCTAssertEqual(folder.icon, "book")
        XCTAssertEqual(split.icon, "🔬")
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.naming), t1)
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.content), t0)
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.placement), t0)
        XCTAssertEqual(folder.meta.modifiedAt(Folder.FieldGroup.naming), t1)
        XCTAssertEqual(folder.meta.modifiedAt(Folder.FieldGroup.placement), t0)
        XCTAssertEqual(split.meta.modifiedAt(SplitLayout.FieldGroup.naming), t1)
        XCTAssertEqual(split.meta.modifiedAt(SplitLayout.FieldGroup.layout), t0)

        XCTAssertEqual(try TreeOps.setTabIcon(s, id: id(20), icon: "⭐️", now: t1), s, "same icon: untouched")
        s = try TreeOps.setTabIcon(s, id: id(20), icon: nil, now: t1)
        XCTAssertNil(s.tabs[id(20)]!.icon)
        XCTAssertThrowsError(try TreeOps.setFolderIcon(s, id: id(99), icon: "x", now: t1))
    }

    /// 06 §21.5 observed split row Rename…: the row's own title; blank clears it. Only `naming`.
    func testRenameSplit() throws {
        var s = try base()
        s = try TreeOps.openTab(s, id: id(20), spaceID: id(10), url: nil, title: "a", now: t0)
        s = try TreeOps.openTab(s, id: id(21), spaceID: id(10), url: nil, title: "b", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: id(40), existingTabID: id(20), newTabID: id(21), now: t0)
        let root = s.splits[id(40)]!.root
        s = try TreeOps.renameSplit(s, layoutID: id(40), title: "  Research ", now: t1)
        XCTAssertEqual(s.splits[id(40)]!.title, "Research")
        XCTAssertEqual(s.splits[id(40)]!.root, root)
        XCTAssertEqual(s.splits[id(40)]!.meta.modifiedAt(SplitLayout.FieldGroup.naming), t1)
        XCTAssertEqual(s.splits[id(40)]!.meta.modifiedAt(SplitLayout.FieldGroup.layout), t0)
        s = try TreeOps.renameSplit(s, layoutID: id(40), title: "   ", now: t1)
        XCTAssertNil(s.splits[id(40)]!.title)
    }

    // MARK: Edit Pinned Page ▸ Edit…

    /// 05 §context menus / 06 §21.5 observed Edit Pinned Page ▸ Edit…: URL → `pin`, title →
    /// `naming`; the page's own title or a blank clears the custom title; Today tabs are refused.
    func testEditPinnedPage() throws {
        var s = try base()
        try pinned(&s, id(20), space: id(10), url: "https://old.example")
        let newURL = URL(string: "https://new.example/start")!
        s = try TreeOps.editPinnedPage(s, id: id(20), url: newURL, title: "Mine", now: t1)
        var tab = s.tabs[id(20)]!
        XCTAssertEqual(tab.pinnedURL, newURL)
        XCTAssertEqual(tab.customTitle, "Mine")
        XCTAssertEqual(tab.url, URL(string: "https://old.example"), "the current page is not touched")
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.pin), t1)
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.naming), t1)
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.content), t0)

        let t2 = Date(timeIntervalSince1970: 300)
        s = try TreeOps.editPinnedPage(s, id: id(20), url: newURL, title: tab.title, now: t2)
        tab = s.tabs[id(20)]!
        XCTAssertNil(tab.customTitle, "the page title clears the custom title")
        XCTAssertEqual(tab.meta.modifiedAt(TabNode.FieldGroup.pin), t1, "unchanged URL: `pin` not stamped")
        XCTAssertEqual(try TreeOps.editPinnedPage(s, id: id(20), url: newURL, title: "", now: t2), s, "no change")

        s = try TreeOps.openTab(s, id: id(22), spaceID: id(10), url: nil, title: "today", now: t0)
        XCTAssertThrowsError(try TreeOps.editPinnedPage(s, id: id(22), url: newURL, title: nil, now: t1)) {
            XCTAssertEqual($0 as? TreeError, .spaceMismatch)
        }
    }

    // MARK: Move to ▸ Profile ▸

    /// 05 §context menus observed Move to ▸ Profile ▸ on pinned tabs; 06 §21.5 on favorites. A
    /// pinned tab lands at the end of the profile's first Space's pinned area and leaves its split.
    func testMoveTabToProfile() throws {
        var s = try base()
        try pinned(&s, id(20), space: id(10))
        s = try TreeOps.openTab(s, id: id(21), spaceID: id(10), url: nil, title: "b", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: id(40), existingTabID: id(20), newTabID: id(21), now: t0)
        try pinned(&s, id(23), space: id(12))

        s = try TreeOps.moveTabToProfile(s, id: id(20), profileID: id(2), now: t1)
        XCTAssertEqual(s.tabs[id(20)]!.location, .pinned(spaceID: id(12), folderID: nil))
        XCTAssertEqual(s.pinnedChildren(spaceID: id(12), folderID: nil).map(\.id), [id(23), id(20)], "at the end")
        XCTAssertTrue(s.splits[id(40)]!.meta.isTombstone, "left its split (two panes → none)")
        XCTAssertEqual(try TreeOps.moveTabToProfile(s, id: id(20), profileID: id(2), now: t1), s, "already there")

        // A Today tab goes to the top of the target Today.
        s = try TreeOps.moveTabToProfile(s, id: id(21), profileID: id(2), now: t1)
        XCTAssertEqual(s.today(spaceID: id(12)).first?.id, id(21))

        // Favorites move between profiles' favorites.
        s = try TreeOps.moveTab(s, id: id(23), to: .favorite(profileID: id(2)), position: .last, now: t0)
        s = try TreeOps.moveTabToProfile(s, id: id(23), profileID: id(1), now: t1)
        XCTAssertEqual(s.favorites(profileID: id(1)).map(\.id), [id(23)])

        // A profile without a Space cannot take a pinned tab.
        s = TreeOps.createProfile(s, id: id(3), name: "Empty", now: t0)
        XCTAssertThrowsError(try TreeOps.moveTabToProfile(s, id: id(20), profileID: id(3), now: t1)) {
            XCTAssertEqual($0 as? TreeError, .notFound(id(3)))
        }
    }

    /// B73: profiles are local. A Space whose profile is unknown here counts as the Default
    /// profile's, so its pinned tab is already "in" Default and moving it there changes nothing.
    func testMoveTabToProfileUsesLocalProfiles() throws {
        var s = try base()
        s = try TreeOps.createSpace(s, id: id(13), profileID: id(1), name: "Remote", now: t0)
        s.spaces[id(13)]?.profileID = id(77) // written by another device's profile
        try pinned(&s, id(20), space: id(13))
        XCTAssertEqual(try TreeOps.moveTabToProfile(s, id: id(20), profileID: id(1), now: t1), s)
    }

    // MARK: Turn “<folder>” into Space

    /// 06 §21.5 observed "Turn “<name>” into Space": a new Space after the folder's Space (same
    /// profile, folder name + icon, a copy of the theme), the folder's children become its
    /// top-level pinned items in order (nested folders keep their contents), the folder is
    /// tombstoned, and a split whose tabs all moved follows them.
    func testTurnFolderIntoSpace() throws {
        var s = try base()
        s = try TreeOps.createFolder(s, id: id(30), spaceID: id(10), title: "Reading", now: t0)
        s = try TreeOps.setFolderIcon(s, id: id(30), icon: "📚", now: t0)
        try pinned(&s, id(20), space: id(10), folder: id(30))
        s = try TreeOps.createFolder(s, id: id(31), spaceID: id(10), parentFolderID: id(30), title: "Inner", now: t0)
        s = try TreeOps.moveFolder(s, id: id(31), toSpace: id(10), parentFolderID: id(30), position: .last, now: t0)
        try pinned(&s, id(21), space: id(10), folder: id(31))
        try pinned(&s, id(22), space: id(10), folder: id(30))
        try pinned(&s, id(23), space: id(10)) // stays behind
        s = try TreeOps.addSplitPane(s, layoutID: id(40), existingTabID: id(20), newTabID: id(22), now: t0)

        s = try TreeOps.turnFolderIntoSpace(s, folderID: id(30), newSpaceID: id(50), newThemeID: id(51), now: t1)
        let space = try XCTUnwrap(s.spaces[id(50)])
        XCTAssertEqual(space.name, "Reading")
        XCTAssertEqual(space.icon, "📚")
        XCTAssertEqual(space.profileID, id(1))
        XCTAssertEqual(s.spaces(inProfile: id(1)).map(\.id), [id(10), id(50), id(11)], "right after the source Space")
        XCTAssertEqual(space.themeID, id(51))
        XCTAssertEqual(s.themes[id(51)]?.style, s.themes[id(5)]?.style, "a copy of the theme")
        XCTAssertEqual(s.pinnedChildren(spaceID: id(50), folderID: nil).map(\.id), [id(20), id(31), id(22)])
        XCTAssertEqual(s.tabs[id(21)]!.location, .pinned(spaceID: id(50), folderID: id(31)))
        XCTAssertEqual(s.folders[id(31)]!.spaceID, id(50))
        XCTAssertTrue(s.folders[id(30)]!.meta.isTombstone)
        XCTAssertEqual(s.pinnedChildren(spaceID: id(10), folderID: nil).map(\.id), [id(23)])
        XCTAssertEqual(s.splits[id(40)]!.spaceID, id(50), "the split follows its tabs")
        XCTAssertFalse(s.splits[id(40)]!.meta.isTombstone)
        XCTAssertThrowsError(try TreeOps.turnFolderIntoSpace(s, folderID: id(30), newSpaceID: id(52), newThemeID: id(53), now: t1))
    }

    /// A split with a member outside the folder loses the members that moved; a Space without a
    /// theme gives a new Space without one.
    func testTurnFolderIntoSpaceSplitsAndNoTheme() throws {
        var s = try base()
        s = try TreeOps.createFolder(s, id: id(30), spaceID: id(11), title: "Mixed", now: t0)
        try pinned(&s, id(20), space: id(11), folder: id(30))
        try pinned(&s, id(21), space: id(11))
        s = try TreeOps.addSplitPane(s, layoutID: id(40), existingTabID: id(20), newTabID: id(21), now: t0)
        s = try TreeOps.turnFolderIntoSpace(s, folderID: id(30), newSpaceID: id(50), newThemeID: id(51), now: t1)
        XCTAssertNil(s.spaces[id(50)]!.themeID)
        XCTAssertNil(s.themes[id(51)])
        XCTAssertTrue(s.splits[id(40)]!.meta.isTombstone, "two panes, one moved: the split ends")
        XCTAssertEqual(s.tabs[id(21)]!.location, .pinned(spaceID: id(11), folderID: nil))
    }

    // MARK: Export “<Space>” into Folder ▸

    /// 05 §context menus / 06 §21.5 observed "Export “<name>” into Folder ▸ <other Space>": a new
    /// folder named after the Space at the top of the other Space's pinned area, with a copy of the
    /// pinned area (pinned URLs, custom titles, icons, folder nesting and expanded state). The
    /// source is untouched; Today tabs are not copied.
    func testExportSpaceIntoFolder() throws {
        var s = try base()
        try pinned(&s, id(20), space: id(10), url: "https://a.example")
        s = try TreeOps.renameTab(s, id: id(20), customTitle: "A", now: t0)
        s = try TreeOps.setTabIcon(s, id: id(20), icon: "⭐️", now: t0)
        s = try TreeOps.updateTabContent(s, id: id(20), url: URL(string: "https://a.example/elsewhere"), title: "x", faviconURL: nil, now: t0)
        s = try TreeOps.createFolder(s, id: id(30), spaceID: id(10), title: "Docs", now: t0)
        s = try TreeOps.moveFolder(s, id: id(30), toSpace: id(10), parentFolderID: nil, position: .last, now: t0)
        s = try TreeOps.setFolderExpanded(s, id: id(30), isExpanded: false, now: t0)
        try pinned(&s, id(21), space: id(10), folder: id(30), url: "https://b.example")
        s = try TreeOps.openTab(s, id: id(22), spaceID: id(10), url: nil, title: "today", now: t0)
        try pinned(&s, id(23), space: id(11)) // already in the target
        let source = s.allTabs(inSpace: id(10)).map(\.id)
        let sourceFolders = s.folders

        var counter = 100
        s = try TreeOps.exportSpaceIntoFolder(s, spaceID: id(10), intoSpaceID: id(11), folderID: id(60),
                                              newID: { _ in counter += 1; return self.id(counter) }, now: t1)
        let folder = try XCTUnwrap(s.folders[id(60)])
        XCTAssertEqual(folder.title, "Home")
        XCTAssertEqual(folder.icon, "🏠")
        XCTAssertEqual(s.pinnedChildren(spaceID: id(11), folderID: nil).map(\.id), [id(60), id(23)], "at the top")
        let copies = s.pinnedChildren(spaceID: id(11), folderID: id(60))
        XCTAssertEqual(copies.count, 2)
        guard case .tab(let tabCopy) = copies[0], case .folder(let folderCopy) = copies[1] else { return XCTFail("order") }
        XCTAssertEqual(tabCopy.url, URL(string: "https://a.example"), "the pinned URL")
        XCTAssertEqual(tabCopy.customTitle, "A")
        XCTAssertEqual(tabCopy.icon, "⭐️")
        XCTAssertEqual(folderCopy.title, "Docs")
        XCTAssertFalse(folderCopy.isExpanded)
        XCTAssertEqual(s.pinnedChildren(spaceID: id(11), folderID: folderCopy.id).count, 1)
        XCTAssertEqual(s.allTabs(inSpace: id(10)).map(\.id), source, "source untouched")
        XCTAssertEqual(s.folders[id(30)], sourceFolders[id(30)])
        XCTAssertFalse(s.today(spaceID: id(11)).contains { $0.title == "today" }, "Today is not exported")
        XCTAssertThrowsError(try TreeOps.exportSpaceIntoFolder(s, spaceID: id(10), intoSpaceID: id(10), folderID: id(61),
                                                               newID: { _ in UUID() }, now: t1)) {
            XCTAssertEqual($0 as? TreeError, .spaceMismatch)
        }
    }
}
