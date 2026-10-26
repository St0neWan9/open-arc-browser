import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// View model intents. Spec: [06 §13] new tab, [06 §12] drag results, [06 §3] folders,
/// [06 §11] delete space, [06 §5] split view, [02] shortcuts, [05] context menus.
@MainActor
final class SidebarViewModelTests: XCTestCase {

    /// [06 §13] observed: a new tab is inserted at the top of Today and becomes selected.
    func testNewTabInsertsAtTopOfToday() async {
        let f = SidebarFixture()
        let (vm, ids) = makeSidebarViewModel(f)
        let id = vm.newTab(url: URL(string: "https://new.example.com"))
        XCTAssertNotNil(id)
        XCTAssertEqual(vm.snapshot.today.first?.id, id)
        XCTAssertEqual(vm.selectedTabID, id)
        XCTAssertEqual(vm.snapshot.today.count, 4)
        _ = ids
        await vm.settleEngineWork()
        XCTAssertNotNil(vm.liveState(for: id!))
        vm.stop()
    }

    /// [06 §13] "+ New Tab" row asks the shell for the command bar when attached; otherwise it
    /// creates a blank tab.
    func testNewTabRowOpensCommandBarWhenAttached() {
        let (vm, _) = makeSidebarViewModel()
        var requests: [SidebarRequest] = []
        vm.requestHandler = { requests.append($0) }
        let before = vm.snapshot.today.count
        vm.newTabRowClicked()
        XCTAssertEqual(requests, [.openCommandBar(.newTab)])
        XCTAssertEqual(vm.snapshot.today.count, before)
        vm.requestHandler = nil
        vm.newTabRowClicked()
        XCTAssertEqual(vm.snapshot.today.count, before + 1)
        vm.stop()
    }

    /// [05 §window hierarchy] observed: the URL box opens the command bar instead of editing.
    func testUrlBoxClickRequestsCommandBar() {
        let (vm, _) = makeSidebarViewModel()
        var requests: [SidebarRequest] = []
        vm.requestHandler = { requests.append($0) }
        vm.openCommandBar(.currentTab)
        XCTAssertEqual(requests, [.openCommandBar(.currentTab)])
    }

    /// [05 §window and app entry points] observed: closing archives, and selection moves to the
    /// tab below (else above).
    func testCloseArchivesAndSelectsNeighbor() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today2)
        await vm.settleEngineWork()
        vm.closeTab(f.today2)
        await vm.settleEngineWork()
        XCTAssertNil(vm.workspace.tabs[f.today2].flatMap { $0.meta.isTombstone ? nil : $0 })
        XCTAssertNotNil(vm.workspace.archive[f.today2])
        XCTAssertEqual(vm.selectedTabID, f.today1)
        vm.closeTab(f.today1)
        XCTAssertEqual(vm.selectedTabID, f.today3, "falls back to the tab above")
        vm.stop()
    }

    /// [05] "Clear" archives only Today tabs of the current space; pinned tabs stay.
    func testClearTodayKeepsPinned() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        vm.clearToday()
        XCTAssertTrue(vm.snapshot.today.isEmpty)
        XCTAssertNil(vm.selectedTabID)
        XCTAssertTrue(vm.snapshot.pinned.contains { $0.id == f.pinnedTab })
        XCTAssertEqual(SidebarSnapshot.make(workspace: vm.workspace, spaceID: f.work, profileID: f.profile).today.count, 1)
        vm.stop()
    }

    /// [06 §4] observed: pin (⌘D) moves the tab to the pinned area; toggling again unpins to Today.
    func testPinAndUnpin() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.togglePin(f.today1)
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .pinned(spaceID: f.home, folderID: nil))
        XCTAssertEqual(vm.snapshot.pinned.last?.id, f.today1)
        vm.togglePin(f.today1)
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .today(spaceID: f.home))
        XCTAssertEqual(vm.snapshot.today.first?.id, f.today1)
    }

    /// [06 §12] observed: dragging a Today tab above the first pinned row pins it before the folders.
    func testDropTodayTabAbovePinnedPinsBeforeFolders() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(.pinnedAreaTop))
        XCTAssertEqual(vm.dropTarget, .pinnedAreaTop)
        XCTAssertTrue(vm.performDrop(on: .pinnedAreaTop))
        XCTAssertEqual(vm.topLevelPinnedIDsForTest.first, f.today1)
        XCTAssertNil(vm.draggingItem)
        XCTAssertNil(vm.dropTarget)
    }

    /// [06 §12] observed: dropping a pinned tab on a folder moves it inside and expands the folder.
    func testDropPinnedTabOntoCollapsedFolderExpandsIt() throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.setFolderExpanded(f.ws, id: f.folderC, isExpanded: false, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm.performDrop(on: .row(f.folderC, .into)))
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.location, .pinned(spaceID: f.home, folderID: f.folderC))
        XCTAssertEqual(vm.workspace.folders[f.folderC]?.isExpanded, true)
        let row = vm.snapshot.pinned.first { $0.id == f.pinnedTab }
        XCTAssertEqual(row?.depth, 1)
    }

    /// [06 §12]: a folder cannot be dropped into itself; the workspace stays untouched and no
    /// indicator is shown.
    func testFolderDropIntoItselfIsRejected() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let before = vm.workspace
        vm.beginDrag(.folder(f.folderA))
        XCTAssertFalse(vm.updateDropTarget(.row(f.folderB, .into)))
        XCTAssertNil(vm.dropTarget)
        XCTAssertFalse(vm.performDrop(on: .row(f.folderB, .into)))
        XCTAssertEqual(vm.workspace, before)
    }

    /// [06 §3] observed: new folders are created at the top of the pinned area, expanded;
    /// blank names are refused.
    func testCreateFolder() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertNil(vm.createFolder(title: "   "))
        let id = vm.createFolder(title: "Projects")
        XCTAssertNotNil(id)
        XCTAssertEqual(vm.snapshot.pinned.first?.id, id)
        XCTAssertEqual(vm.workspace.folders[id!]?.isExpanded, true)
        XCTAssertFalse(vm.isNewFolderSheetPresented)
    }

    /// [06 §3, 02] folders expand and collapse; Collapse/Expand All Folders.
    func testToggleAndCollapseAll() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.toggleFolder(f.folderA)
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.isExpanded, false)
        vm.setAllFoldersExpanded(false)
        XCTAssertEqual(vm.snapshot.pinned.map(\.id), [f.folderA, f.folderC, f.pinnedTab])
        XCTAssertTrue(vm.workspace.folders.values.filter { $0.spaceID == f.home }.allSatisfy { !$0.isExpanded })
        vm.setAllFoldersExpanded(true)
        XCTAssertEqual(vm.snapshot.pinned.count, 6)
    }

    /// [06 §12] "Double-click to rename" / [05] Rename…: custom title for tabs, reset on empty.
    func testRename() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginRename(f.today1)
        XCTAssertEqual(vm.renamingItemID, f.today1)
        vm.commitRename(f.today1, text: "  My Tab ")
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.displayTitle, "My Tab")
        XCTAssertNil(vm.renamingItemID)
        vm.commitRename(f.today1, text: "")
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.displayTitle, "today1")
        vm.commitRename(f.folderA, text: "Renamed")
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.title, "Renamed")
        vm.commitRename(f.folderA, text: " ")
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.title, "Renamed")
    }

    /// [05 §context menus] Move to ▸ <Space>: pinned tabs stay pinned, Today tabs go to Today.
    func testMoveToSpace() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.moveTab(f.today1, toSpace: f.work)
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .today(spaceID: f.work))
        vm.moveTab(f.pinnedTab, toSpace: f.work)
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.location, .pinned(spaceID: f.work, folderID: nil))
    }

    /// [05 §context menus] Duplicate: a copy at the top of Today, selected.
    func testDuplicate() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let copy = vm.duplicateTab(f.pinnedTab)
        XCTAssertEqual(vm.snapshot.today.first?.id, copy)
        XCTAssertEqual(vm.workspace.tabs[copy!]?.url, vm.workspace.tabs[f.pinnedTab]?.url)
        vm.stop()
    }

    /// Favorites: add (Today -> favorites), remove (back to Today). [06 §12] observed shared.
    func testFavorites() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.addFavorite(f.today1)
        XCTAssertEqual(vm.snapshot.favorites.map(\.id), [f.fav1, f.fav2, f.today1])
        vm.removeFavorite(f.fav1)
        XCTAssertEqual(vm.snapshot.favorites.map(\.id), [f.fav2, f.today1])
        XCTAssertEqual(vm.snapshot.today.first?.id, f.fav1)
    }

    /// [01 §Spaces, 02 §Space] Next/Previous Space wrap; Go to Space N is 1-based; switching
    /// restores the tab last selected in that space.
    func testSpaceSwitching() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        vm.stepSpace(by: 1)
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        vm.stepSpace(by: 1)
        XCTAssertEqual(vm.selectedSpaceID, f.home, "wraps")
        XCTAssertEqual(vm.selectedTabID, f.today1, "restores the last tab")
        vm.stepSpace(by: -1)
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        vm.goToSpace(number: 1)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.goToSpace(number: 9)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.stop()
    }

    /// [06 §11] observed: deleting a space needs a confirmation, archives its tabs, and the
    /// window falls back to another space. The last space cannot be deleted (inferred).
    func testDeleteSpaceConfirmation() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.requestDeleteSpace(f.home)
        XCTAssertEqual(vm.pendingSpaceDeletionID, f.home)
        vm.cancelDeleteSpace()
        XCTAssertEqual(vm.workspace.spaces[f.home]?.meta.isTombstone, false)
        vm.requestDeleteSpace(f.home)
        vm.confirmDeleteSpace()
        XCTAssertEqual(vm.workspace.spaces[f.home]?.meta.isTombstone, true)
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        XCTAssertNotNil(vm.workspace.archive[f.today1])
        XCTAssertEqual(vm.snapshot.favorites.count, 2, "favorites survive")
        XCTAssertFalse(vm.canDeleteSpace)
        vm.requestDeleteSpace(f.work)
        XCTAssertNil(vm.pendingSpaceDeletionID)
    }

    /// [06 §5] observed: Add Split View keeps the current tab on the left, opens a new tab on
    /// the right and asks for the command bar inside that pane; the two tabs form one group.
    func testAddSplitView() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        var requests: [SidebarRequest] = []
        vm.requestHandler = { requests.append($0) }
        vm.addSplitView()
        XCTAssertTrue(requests.isEmpty, "no selected tab yet")
        vm.selectTab(f.today1)
        vm.addSplitView()
        XCTAssertEqual(requests, [.openCommandBar(.splitPane)])
        let layout = vm.workspace.splits.values.first
        XCTAssertEqual(layout?.root.tabIDs.first, f.today1)
        XCTAssertEqual(layout?.root.tabIDs.count, 2)
        XCTAssertTrue(vm.isInSplit(f.today1))
        XCTAssertEqual(vm.selectedTabID, layout?.root.tabIDs.last)
        await vm.settleEngineWork()
        vm.stop()
    }

    /// [06 §13] reload becomes stop while loading, and the engine is asked accordingly.
    func testReloadBecomesStopWhileLoading() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        await vm.settleEngineWork()
        XCTAssertEqual(vm.reloadMode, .reload)
        vm.apply(.loadStateChanged(LoadState(isLoading: true, progress: 0.3)), to: f.today1)
        XCTAssertEqual(vm.reloadMode, .stop)
        vm.apply(.loadStateChanged(.idle), to: f.today1)
        XCTAssertEqual(vm.reloadMode, .reload)
        vm.stop()
    }

    /// Engine content flows into the model (title/url/favicon); audio state comes from the engine.
    func testEngineContentSyncsToWorkspace() async {
        let f = SidebarFixture()
        let engine = FakeEngine(titleProvider: { _ in "Fake Title" })
        let (vm, _) = makeSidebarViewModel(f, engine: engine)
        vm.selectTab(f.today1)
        await vm.settleEngineWork()
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.title, "Fake Title")
        vm.apply(.audioStateChanged(AudioState(isAudible: true, isMuted: false)), to: f.today1)
        XCTAssertEqual(vm.liveState(for: f.today1)?.isAudible, true)
        XCTAssertEqual(vm.urlBoxContent, .domain("today1.example.com", isSecure: true))
        vm.stop()
    }

    /// [06 §12] observed: the hover card shows after the delay and not when the pointer left.
    func testHoverCardDelay() async throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.hoverDelay = 0.05
        vm.hoverBegan(f.today1)
        XCTAssertNil(vm.hoverCardTabID)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.hoverCardTabID, f.today1)
        vm.hoverEnded(f.today1)
        XCTAssertNil(vm.hoverCardTabID)
        vm.hoverBegan(f.today2)
        vm.hoverEnded(f.today2)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertNil(vm.hoverCardTabID)
        XCTAssertEqual(Motion.hoverCardDelay, 0.5)
    }

    /// Context menu items that need shell services stay disabled without a handler.
    func testRequestsNeedHandler() {
        let (vm, _) = makeSidebarViewModel()
        XCTAssertFalse(vm.canRequest)
        vm.requestHandler = { _ in }
        XCTAssertTrue(vm.canRequest)
    }
}

extension SidebarViewModel {
    /// Top-level pinned ids, for assertions.
    var topLevelPinnedIDsForTest: [UUID] {
        guard let space = selectedSpaceID else { return [] }
        return workspace.pinnedChildren(spaceID: space, folderID: nil).map(\.id)
    }
}
