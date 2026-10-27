import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// Favorites grid, empty state, add / reorder / remove and the right-click menu actions (plan B55).
/// Spec: docs/arc-spec/06-flows.md §21 (E19): §21.1 per Profile, §21.2 empty state, §21.3 grid,
/// §21.4 add / reorder / remove, §21.5 menus, §21.6 Separate All Tabs.
@MainActor
final class SidebarFavoritesGridTests: XCTestCase {
    typealias Grid = SidebarFavoritesGrid

    // MARK: 06 §21.3 grid

    /// 06 §21.3 observed table: n → columns × rows and tile width.
    func testGridShapeAndTileWidthsMatchCapture() {
        let observed: [Int: (columns: Int, rows: Int, width: CGFloat)] = [
            1: (1, 1, 260), 2: (2, 1, 126), 3: (3, 1, 81.33), 4: (4, 1, 59), 5: (3, 2, 81.33),
            6: (3, 2, 81.33), 7: (4, 2, 59), 8: (4, 2, 59), 9: (3, 3, 81.33),
        ]
        for (n, expected) in observed {
            let shape = Grid.shape(count: n)
            XCTAssertEqual(shape.columns, expected.columns, "n = \(n)")
            XCTAssertEqual(shape.rows, expected.rows, "n = \(n)")
            XCTAssertEqual(Grid.tileWidth(columns: shape.columns), expected.width, accuracy: 0.5, "n = \(n)")
        }
        XCTAssertEqual(Grid.shape(count: 0).rows, 0)
        // 06 §21.8 unknown n ≥ 10; the rule gives 3 rows of 4 for 10.
        XCTAssertEqual(Grid.shape(count: 10).rows, 3)
        XCTAssertEqual(Grid.shape(count: 10).columns, 4)
    }

    /// 06 §21.3 observed: area height 8 + rows × 47 + (rows − 1) × 8 + 8 = 63 / 118 / 173;
    /// 06 §21.2 observed: 105 with the empty-state card.
    func testAreaHeights() {
        XCTAssertEqual(Grid.areaHeight(count: 1, showsEmptyCard: true), 63)
        XCTAssertEqual(Grid.areaHeight(count: 5, showsEmptyCard: true), 118)
        XCTAssertEqual(Grid.areaHeight(count: 9, showsEmptyCard: true), 173)
        XCTAssertEqual(Grid.areaHeight(count: 0, showsEmptyCard: true), 105)
        XCTAssertEqual(Grid.areaHeight(count: 0, showsEmptyCard: false), 63, "dismissed card: one empty row (inferred)")
    }

    /// 06 §21.3 observed: row pitch 55, 8 pt gaps, the last row left-aligned (5 → two tiles on the left).
    func testSlotFramesLeftAlignTheLastRow() {
        let five = Grid.slotFrames(count: 5, origin: CGPoint(x: 8, y: 90))
        XCTAssertEqual(five[0].minX, 8)
        XCTAssertEqual(five[2].maxX, 268, accuracy: 0.01)
        XCTAssertEqual(five[3].minY - five[0].minY, 55)
        XCTAssertEqual(five[3].minX, 8)
        XCTAssertEqual(five[4].minX - five[3].maxX, 8, accuracy: 0.01)
        XCTAssertEqual(five[1].minX - five[0].maxX, 8, accuracy: 0.01)
        XCTAssertTrue(five.allSatisfy { $0.height == 47 })
    }

    /// 06 §21.3: more favorite rows push the Space header and the list down by 55 per row.
    func testLayoutMovesHeaderAndListWithRows() {
        let one = SidebarLayout(favoritesTilesHeight: Grid.tilesHeight(count: 3, showsEmptyCard: true))
        let two = SidebarLayout(favoritesTilesHeight: Grid.tilesHeight(count: 6, showsEmptyCard: true))
        let three = SidebarLayout(favoritesTilesHeight: Grid.tilesHeight(count: 9, showsEmptyCard: true))
        XCTAssertEqual(one.listTop, 181)
        XCTAssertEqual(two.listTop, 236)
        XCTAssertEqual(three.listTop, 291)
        XCTAssertEqual(three.spaceNameRowFrame.minY - one.spaceNameRowFrame.minY, 110)
        XCTAssertEqual(three.favoriteSlotFrames(count: 9).last?.maxY, 90 + 3 * 47 + 2 * 8)
        // The favorites tile drag zone grows with the grid, starting at the same top.
        XCTAssertEqual(SidebarDragImageGeometry.favoritesBand(three).minY, SidebarDragImageGeometry.favoritesBand(one).minY)
        XCTAssertEqual(SidebarDragImageGeometry.favoritesBand(three).maxY, three.spaceNameRowFrame.minY - 5)
    }

    /// 06 §21.4: a new tile opens at the grid slot under the pointer, row by row.
    func testDropGapFollowsTheGridSlot() {
        let width = Grid.tilesWidth
        // 4 favorites + 1 new = 5 slots in 3 × 2; pointer over row 2, first slot → gap 3.
        XCTAssertEqual(Grid.dropGap(at: CGPoint(x: 10, y: 60), favoriteCount: 4, draggedIndex: nil, width: width), 3)
        XCTAssertEqual(Grid.dropGap(at: CGPoint(x: 250, y: 60), favoriteCount: 4, draggedIndex: nil, width: width), 4)
        XCTAssertEqual(Grid.dropGap(at: CGPoint(x: 10, y: 10), favoriteCount: 4, draggedIndex: nil, width: width), 0)
        // Reorder (06 §21.4 observed): the 4th tile dragged onto the 1st slot becomes the first.
        let gap = Grid.dropGap(at: CGPoint(x: 10, y: 10), favoriteCount: 4, draggedIndex: 3, width: width)
        XCTAssertEqual(gap, 0)
        XCTAssertEqual(Grid.targetIndex(gap: gap, draggedIndex: 3), 0)
        // The first tile dragged onto the last slot.
        let last = Grid.dropGap(at: CGPoint(x: 250, y: 10), favoriteCount: 4, draggedIndex: 0, width: width)
        XCTAssertEqual(last, 4)
        XCTAssertEqual(Grid.targetIndex(gap: last, draggedIndex: 0), 3)
    }

    /// 06 §21.4 observed: dragging the 4th favorite onto the 1st makes it first, the others shift.
    func testReorderByDragMovesTheFourthToFirst() throws {
        var f = SidebarFixture()
        let extra = [SidebarFixture.id(60), SidebarFixture.id(61)]
        for id in extra {
            f.ws = try TreeOps.openTab(f.ws, id: id, spaceID: f.home, url: URL(string: "https://x.example"), title: "x", now: f.now)
            f.ws = try TreeOps.moveTab(f.ws, id: id, to: .favorite(profileID: f.profile), position: .last, now: f.now)
        }
        let (vm, _) = makeSidebarViewModel(f)
        let order = vm.snapshot.favorites.map(\.id)
        XCTAssertEqual(order.count, 4)
        let layout = SidebarLayout()
        let block = layout.favoritesTilesFrame
        let geometry = SidebarDropGeometry(list: .null, entries: [], favorites: block, favoriteCount: 4, dockItems: [],
                                           favoriteDraggedIndex: 3)
        vm.beginDrag(.tab(order[3]))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: block.minX + 5, y: block.midY), in: geometry))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.snapshot.favorites.map(\.id), [order[3], order[0], order[1], order[2]])
        vm.stop()
    }

    // MARK: 06 §21.1 / §21.2 / §21.4

    /// 06 §21.4 observed: Remove Favorite closes the page; it does not go back to Today.
    func testRemoveFavoriteClosesThePage() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.fav1)
        await vm.settleEngineWork()
        XCTAssertNotNil(vm.liveTab(for: f.fav1))
        let today = vm.snapshot.today.map(\.id)
        vm.removeFavorite(f.fav1)
        await vm.settleEngineWork()
        XCTAssertEqual(vm.snapshot.favorites.map(\.id), [f.fav2])
        XCTAssertEqual(vm.snapshot.today.map(\.id), today, "not moved back to Today")
        XCTAssertNil(vm.liveTab(for: f.fav1))
        XCTAssertNotEqual(vm.selectedTabID, f.fav1)
        vm.stop()
    }

    /// 06 §21.1 observed: Set Profile switches the favorites block to the new profile's (empty) set.
    func testSetProfileShowsThatProfilesFavorites() {
        var f = SidebarFixture()
        let other = SidebarFixture.id(70)
        f.ws = TreeOps.createProfile(f.ws, id: other, name: "Other", now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertEqual(vm.snapshot.favorites.count, 2)
        XCTAssertEqual(vm.menuProfiles.map(\.name), ["Default", "Other"])
        vm.setSpaceProfile(f.home, profileID: other)
        XCTAssertEqual(vm.workspace.spaces[f.home]?.profileID, other)
        XCTAssertTrue(vm.snapshot.favorites.isEmpty)
        // 06 §21.2: the empty-state card replaces the tiles; ✕ hides it (inferred: for good).
        XCTAssertTrue(vm.showsFavoritesEmptyCard)
        XCTAssertEqual(vm.favoritesTilesHeight, 89)
        vm.dismissFavoritesEmptyCard()
        XCTAssertFalse(vm.showsFavoritesEmptyCard)
        XCTAssertEqual(vm.favoritesTilesHeight, 47)
        vm.stop()
    }

    /// 06 §21.5 observed: a favorite's Move to ▸ Profile ▸ moves it to another profile's favorites.
    func testMoveFavoriteToProfile() {
        var f = SidebarFixture()
        let other = SidebarFixture.id(70)
        f.ws = TreeOps.createProfile(f.ws, id: other, name: "Other", now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        vm.moveFavorite(f.fav1, toProfile: other)
        XCTAssertEqual(vm.workspace.favorites(profileID: other).map(\.id), [f.fav1])
        XCTAssertEqual(vm.snapshot.favorites.map(\.id), [f.fav2])
        vm.stop()
    }

    /// 06 §21.4 observed: the command bar's "Favorite Tab" moves the current Today tab to the end
    /// of the favorites and out of Today; it is offered for Today tabs only.
    func testFavoriteTabCommand() async throws {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        let space = try XCTUnwrap(model.selectedSpaceID)
        let id = try XCTUnwrap(model.workspace.today(spaceID: space).first?.id)
        try await model.activate(tabID: id)
        XCTAssertTrue(CommandBarCommand.favoriteTab.isAvailable(in: model.commandBarCommandState))
        XCTAssertEqual(CommandBarCommand.favoriteTab.title, "Favorite Tab")
        model.perform(.runCommand(.favoriteTab))
        let profile = try XCTUnwrap(model.selectedSpace?.profileID)
        XCTAssertEqual(model.workspace.favorites(profileID: profile).last?.id, id)
        XCTAssertFalse(model.workspace.today(spaceID: space).contains { $0.id == id })
        XCTAssertFalse(CommandBarCommand.favoriteTab.isAvailable(in: model.commandBarCommandState), "already a favorite")
        model.stop()
    }

    // MARK: 06 §21.5 menus

    /// 06 §21.5 observed: "Replace Pinned URL with Current" is disabled until the page navigated.
    func testReplacePinnedURLDisabledUntilNavigated() throws {
        var f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertFalse(vm.canReplacePinnedURL(f.fav1))
        f.ws = try TreeOps.updateTabContent(vm.workspace, id: f.fav1, url: URL(string: "https://fav1.example.com/elsewhere"),
                                             title: "x", faviconURL: nil, now: f.now)
        vm.replaceWorkspace(f.ws)
        XCTAssertTrue(vm.canReplacePinnedURL(f.fav1))
        vm.stop()
    }

    /// 06 §21.5 observed Today tab items: Archive Other Tabs / Below / Above act on the neighbors.
    func testArchiveTabsBelowAndAbove() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let order = vm.workspace.today(spaceID: f.home).map(\.id)
        XCTAssertEqual(order.count, 3)
        let around = vm.todayTabs(around: order[1])
        XCTAssertEqual(around.above, [order[0]])
        XCTAssertEqual(around.below, [order[2]])
        vm.archiveTabs(around.below)
        XCTAssertEqual(vm.workspace.today(spaceID: f.home).map(\.id), [order[0], order[1]])
        vm.stop()
    }

    /// 06 §21.5 observed folder items: Move to ▸ <Space>, Duplicate, Delete.
    func testFolderMenuActions() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.duplicateFolder(f.folderA)
        let copies = vm.workspace.folders.values.filter { !$0.meta.isTombstone && $0.title == "A" && $0.id != f.folderA }
        XCTAssertEqual(copies.count, 1)
        let copy = copies[0]
        let top = vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).map(\.id)
        XCTAssertEqual(top.firstIndex(of: copy.id), top.firstIndex(of: f.folderA).map { $0 + 1 }, "right below the original")
        let copyChildren = vm.workspace.pinnedChildren(spaceID: f.home, folderID: copy.id)
        XCTAssertEqual(copyChildren.count, vm.workspace.pinnedChildren(spaceID: f.home, folderID: f.folderA).count)

        vm.moveFolder(f.folderC, toSpace: f.work)
        XCTAssertEqual(vm.workspace.folders[f.folderC]?.spaceID, f.work)

        vm.deleteFolder(f.folderA)
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.meta.isTombstone, true)
        XCTAssertEqual(vm.workspace.folders[f.folderB]?.meta.isTombstone, true)
        XCTAssertEqual(vm.workspace.tabs[f.inFolderTab]?.meta.isTombstone, true)
        XCTAssertEqual(vm.workspace.tabs[f.deepTab]?.meta.isTombstone, true)
        XCTAssertNotNil(vm.workspace.archive[f.deepTab])
        vm.stop()
    }

    /// 06 §21.5 / §21.6 observed split row items: Separate All Tabs, Convert to Vertical, Duplicate, Move to.
    func testSplitRowMenuActions() throws {
        var f = SidebarFixture()
        let layoutID = SidebarFixture.id(80)
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today1, newTabID: f.today2, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertNotNil(vm.snapshot.splitGroup(layoutID: layoutID))
        XCTAssertTrue(vm.isHorizontalSplit(layoutID))
        vm.toggleSplitAxis(layoutID)
        XCTAssertFalse(vm.isHorizontalSplit(layoutID))

        let group = try XCTUnwrap(vm.snapshot.splitGroup(layoutID: layoutID))
        let around = vm.todayTabs(aroundGroup: group)
        XCTAssertEqual(around.above + around.below, [f.today3])

        vm.duplicateSplitGroup(layoutID)
        let liveSplits = vm.workspace.splits.values.filter { !$0.meta.isTombstone }
        XCTAssertEqual(liveSplits.count, 2)
        let duplicate = try XCTUnwrap(liveSplits.first { $0.id != layoutID })
        guard case .split(let axis, _) = duplicate.root else { return XCTFail("not a split") }
        XCTAssertEqual(axis, .vertical, "same direction as the original")

        vm.separateAllTabs(layoutID)
        XCTAssertNil(vm.snapshot.splitGroup(layoutID: layoutID))
        XCTAssertTrue(vm.snapshot.today.contains { $0.id == f.today1 })
        XCTAssertTrue(vm.snapshot.today.contains { $0.id == f.today2 })

        vm.moveSplitGroup(duplicate.id, toSpace: f.work)
        XCTAssertEqual(vm.workspace.splits[duplicate.id]?.spaceID, f.work)
        vm.stop()
    }

    /// 06 §21.5 observed "Copy link as Markdown" (format inferred).
    func testMarkdownLink() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertEqual(vm.markdownLink(for: f.today1), "[today1](https://today1.example.com)")
        vm.stop()
    }
}
