import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// The B77 context-menu items, through the sidebar view model and the shell.
/// Spec: docs/arc-spec/05-surfaces.md §context menus; 06-flows.md §12 (favorite hover tip),
/// §20.2 (Share), §21.5 (menus: Change Icon…, Edit Pinned Page ▸ Edit…, Turn “<folder>” into Space,
/// Export “<Space>” into Folder ▸, Move to ▸ Profile ▸ / New Space…, split row Rename…).
@MainActor
final class SidebarItemEditTests: XCTestCase {

    // MARK: 06 §21.5 Change Icon…

    /// 06 §21.5 observed Change Icon… on a favorite, a Today tab, a folder and a split row: the icon
    /// picker opens for that item and the chosen icon is stored; "Use Default Icon" clears it.
    func testChangeIconForEveryKindOfRow() throws {
        var f = SidebarFixture()
        let layoutID = SidebarFixture.id(80)
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today1, newTabID: f.today2, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        for (item, icon) in [(f.fav1, "⭐️"), (f.today3, "book"), (f.folderA, "📚"), (layoutID, "🔬")] {
            vm.beginChangeIcon(item)
            XCTAssertEqual(vm.iconPickerItemID, item)
            vm.chooseIcon(icon)
            XCTAssertNil(vm.iconPickerItemID)
            XCTAssertEqual(vm.customIcon(of: item), icon)
        }
        vm.beginChangeIcon(f.folderA)
        vm.chooseIcon(nil)
        XCTAssertNil(vm.workspace.folders[f.folderA]?.icon)
        vm.beginChangeIcon(f.fav1)
        vm.cancelChangeIcon()
        XCTAssertEqual(vm.workspace.tabs[f.fav1]?.icon, "⭐️", "cancel keeps the icon")
        vm.stop()
    }

    // MARK: 06 §21.5 Edit Pinned Page ▸ Edit…

    /// 06 §21.5 observed Edit Pinned Page ▸ Edit…: a sheet with the URL and the title; saving
    /// stores the pinned URL and title, and a page still at its pinned URL goes to the new one.
    func testEditPinnedPageSheet() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginEditPinnedPage(f.today1)
        XCTAssertNil(vm.pinnedPageEditorTabID, "Today tabs have no pinned page")
        vm.beginEditPinnedPage(f.pinnedTab)
        XCTAssertEqual(vm.pinnedPageEditorTabID, f.pinnedTab)
        XCTAssertFalse(vm.commitEditPinnedPage(urlText: "not a url", title: ""))
        XCTAssertTrue(vm.commitEditPinnedPage(urlText: "news.example.org/today", title: "News"))
        XCTAssertNil(vm.pinnedPageEditorTabID)
        let tab = try XCTUnwrap(vm.workspace.tabs[f.pinnedTab])
        XCTAssertEqual(tab.pinnedURL, URL(string: "https://news.example.org/today"))
        XCTAssertEqual(tab.url, URL(string: "https://news.example.org/today"), "was at the pinned page: follows it")
        XCTAssertEqual(tab.displayTitle, "News")
        vm.stop()
    }

    // MARK: 05 §context menus Show Unread Badge, 06 §12 hover tip

    /// 05 §context menus observed "Show Unread Badge" (favorites only); 06 §12 observed the hover
    /// tip "No unread emails, you can exhale! 🌿". The count comes from the page title (inferred).
    func testUnreadBadgeAndHoverTip() throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.updateTabContent(f.ws, id: f.fav1, url: URL(string: "https://fav1.example.com"),
                                            title: "Inbox (3) - Mail", faviconURL: nil, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertFalse(vm.showsUnreadBadge(f.fav1))
        XCTAssertNil(vm.unreadCount(f.fav1))
        XCTAssertNil(vm.favoriteHoverTip(f.fav1))
        vm.toggleUnreadBadge(f.today1)
        XCTAssertFalse(vm.showsUnreadBadge(f.today1), "favorites only")

        vm.toggleUnreadBadge(f.fav1)
        XCTAssertTrue(vm.showsUnreadBadge(f.fav1))
        XCTAssertEqual(vm.unreadCount(f.fav1), 3)
        XCTAssertEqual(vm.favoriteHoverTip(f.fav1), "3 unread items")
        vm.toggleUnreadBadge(f.fav2)
        XCTAssertEqual(vm.unreadCount(f.fav2), 0)
        XCTAssertEqual(vm.favoriteHoverTip(f.fav2), "No unread emails, you can exhale! 🌿")
        vm.toggleUnreadBadge(f.fav1)
        XCTAssertFalse(vm.showsUnreadBadge(f.fav1))
        vm.stop()
    }

    /// Unread count parsing (inferred source: the page title).
    func testUnreadCountFromTitle() {
        XCTAssertEqual(UnreadBadge.count(inTitle: "Inbox (12) - Mail"), 12)
        XCTAssertEqual(UnreadBadge.count(inTitle: "(4) Chat"), 4)
        XCTAssertEqual(UnreadBadge.count(inTitle: "Release (beta) notes (99+)"), 99)
        XCTAssertEqual(UnreadBadge.count(inTitle: "Plain title"), 0)
        XCTAssertEqual(UnreadBadge.label(count: 120), "99+")
    }

    // MARK: 06 §21.5 Turn “<folder>” into Space, Export “<Space>” into Folder ▸

    /// 06 §21.5 observed "Turn “<name>” into Space": the folder becomes a Space and the sidebar
    /// shows it.
    func testTurnFolderIntoSpaceSelectsTheNewSpace() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let spaceID = try XCTUnwrap(vm.turnFolderIntoSpace(f.folderA))
        XCTAssertEqual(vm.selectedSpaceID, spaceID)
        XCTAssertEqual(vm.workspace.spaces[spaceID]?.name, "A")
        XCTAssertEqual(vm.dockSpaces.map(\.id), [f.home, spaceID, f.work])
        XCTAssertEqual(vm.workspace.tabs[f.inFolderTab]?.location, .pinned(spaceID: spaceID, folderID: nil))
        XCTAssertEqual(vm.workspace.tabs[f.deepTab]?.location, .pinned(spaceID: spaceID, folderID: f.folderB))
        vm.stop()
    }

    /// 06 §21.5 observed "Export “<name>” into Folder ▸ <other Space>".
    func testExportSpaceIntoFolder() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let folderID = try XCTUnwrap(vm.exportSpace(f.home, intoSpace: f.work))
        XCTAssertEqual(vm.workspace.folders[folderID]?.title, "Home")
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.work, folderID: nil).map(\.id), [folderID])
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.work, folderID: folderID).count,
                       vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).count)
        XCTAssertNil(vm.exportSpace(f.home, intoSpace: f.home))
        vm.stop()
    }

    // MARK: 05 §context menus Move to ▸ Profile ▸ (pinned tabs)

    /// 05 §context menus observed Move to ▸ Profile ▸ on pinned tabs: the tab goes to the profile's
    /// first Space; a profile without a Space is offered disabled.
    func testMovePinnedTabToProfile() throws {
        var f = SidebarFixture()
        let other = SidebarFixture.id(70), otherSpace = SidebarFixture.id(71), empty = SidebarFixture.id(72)
        f.ws = TreeOps.createProfile(f.ws, id: other, name: "Other", now: f.now)
        f.ws = TreeOps.createProfile(f.ws, id: empty, name: "Empty", now: f.now)
        f.ws = try TreeOps.createSpace(f.ws, id: otherSpace, profileID: other, name: "Elsewhere", now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertEqual(vm.profileID(ofTab: f.pinnedTab), f.profile)
        XCTAssertTrue(vm.canMoveTab(f.pinnedTab, toProfile: other))
        XCTAssertFalse(vm.canMoveTab(f.pinnedTab, toProfile: empty))
        XCTAssertTrue(vm.canMoveTab(f.fav1, toProfile: empty), "favorites need no Space")
        vm.moveTabToProfile(f.pinnedTab, profileID: other)
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.location, .pinned(spaceID: otherSpace, folderID: nil))
        vm.stop()
    }

    // MARK: 06 §21.5 Move to ▸ New Space…

    /// 06 §21.5 observed Move to ▸ New Space…: after "Create Space" the item is in the new Space;
    /// Cancel leaves it where it was.
    func testMoveToNewSpaceMovesTheItemAfterCreation() throws {
        let f = SidebarFixture()
        var counter = 5_000
        let model = ShellModel(dependencies: .fake(), workspace: f.ws, now: { f.now },
                               makeID: { counter += 1; return SidebarFixture.id(counter) })
        model.selectSpace(f.home)
        model.sidebar.requestNewSpace(moving: f.folderC)
        XCTAssertTrue(model.spaceFlow.isCreating)
        model.spaceFlow.cancelCreate()
        XCTAssertEqual(model.workspace.folders[f.folderC]?.spaceID, f.home, "cancel: not moved")

        model.sidebar.requestNewSpace(moving: f.today1)
        model.spaceFlow.draftName = "Fresh"
        let spaceID = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertEqual(model.workspace.tabs[f.today1]?.location, .today(spaceID: spaceID))
        XCTAssertEqual(model.selectedSpaceID, spaceID)

        // A plain New Space moves nothing.
        model.sidebar.requestFromMenu(.newSpace)
        model.spaceFlow.draftName = "Empty"
        let empty = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertTrue(model.workspace.allTabs(inSpace: empty).isEmpty)
        model.stop()
    }

    // MARK: 06 §21.5 split row Rename…

    /// 06 §21.5 observed split row Rename…: inline rename stores the row's own title; a blank
    /// title goes back to the members' titles.
    func testSplitRowRename() throws {
        var f = SidebarFixture()
        let layoutID = SidebarFixture.id(80)
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today1, newTabID: f.today2, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginRename(layoutID)
        XCTAssertEqual(vm.renamingItemID, layoutID)
        vm.commitRename(layoutID, text: "Compare")
        XCTAssertNil(vm.renamingItemID)
        XCTAssertEqual(vm.splitLayout(layoutID)?.title, "Compare")
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.customTitle, nil, "members are not renamed")
        vm.commitRename(layoutID, text: " ")
        XCTAssertNil(vm.splitLayout(layoutID)?.title)
        vm.stop()
    }

    // MARK: 06 §20.2 / §21.5 Share

    /// 06 §20.2 observed the tab menu's Share; before B77 `ShellModel.handle` dropped `.share`.
    /// It now asks for the system share picker with the tab's link.
    func testShareRequestOpensThePicker() throws {
        let f = SidebarFixture()
        let model = ShellModel(dependencies: .fake(), workspace: f.ws, now: { f.now })
        model.selectSpace(f.home)
        model.sidebar.requestFromMenu(.share(tabID: f.today1))
        let request = try XCTUnwrap(model.sidebar.shareRequest)
        XCTAssertEqual(request.url, URL(string: "https://today1.example.com"))
        model.sidebar.finishShare(serial: request.serial)
        XCTAssertNil(model.sidebar.shareRequest)
        model.stop()
    }

    /// The other requests the menus send are handled too (Change Icon…, Edit…, Export, Move to
    /// Profile).
    func testShellHandlesItemEditRequests() throws {
        var f = SidebarFixture()
        let other = SidebarFixture.id(70)
        f.ws = TreeOps.createProfile(f.ws, id: other, name: "Other", now: f.now)
        let model = ShellModel(dependencies: .fake(), workspace: f.ws, now: { f.now })
        model.selectSpace(f.home)
        model.sidebar.requestFromMenu(.changeIcon(tabID: f.today1))
        XCTAssertEqual(model.sidebar.iconPickerItemID, f.today1)
        model.sidebar.requestFromMenu(.editPinnedPage(tabID: f.fav1))
        XCTAssertEqual(model.sidebar.pinnedPageEditorTabID, f.fav1)
        model.sidebar.requestFromMenu(.toggleUnreadBadge(tabID: f.fav1))
        XCTAssertTrue(model.sidebar.showsUnreadBadge(f.fav1))
        model.sidebar.requestFromMenu(.moveTab(tabID: f.fav2, toProfile: other))
        XCTAssertEqual(model.workspace.favorites(profileID: other).map(\.id), [f.fav2])
        let before = model.workspace.folders.count
        model.sidebar.requestFromMenu(.exportSpace(spaceID: f.home, intoSpaceID: f.work))
        XCTAssertGreaterThan(model.workspace.folders.count, before)
        model.stop()
    }
}
