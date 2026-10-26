import XCTest
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Drag and drop in the sidebar: pure hit-testing (point -> target), the planner/TreeOps chain,
/// cross-Space moves, external link drops and drag cancel.
/// Spec: [06 §12] "Hover and drag results" (observed: Today tab above the first pinned row pins it;
/// pinned tab onto a folder row goes inside and expands it; real press-move-release needed),
/// [06 §3] folders (top of the pinned area), [06 §4] tab states, [04 §sidebar] row pitch 41 pt,
/// [05 §window hierarchy] dock and favorites block. Band sizes, indicator looks, cross-Space drops
/// and external link drops are inferred/unknown there.
@MainActor
final class SidebarDragTests: XCTestCase {

    private let layout = SidebarLayout()

    // MARK: Geometry helpers

    /// Geometry built from the real layout numbers: rows at the 41 pt pitch, favorites block, dock.
    private func geometry(_ f: SidebarFixture, snapshot: SidebarSnapshot? = nil) -> (SidebarDropGeometry, SidebarSnapshot) {
        let snap = snapshot ?? SidebarSnapshot.make(workspace: f.ws, spaceID: f.home, profileID: f.profile)
        let frames = layout.listItemFrames(snap.listKinds)
        var rowFrames: [UUID: CGRect] = [:]
        var regions: [SidebarDropRegion: CGRect] = [:]
        var index = 0
        for item in snap.pinned { rowFrames[item.id] = frames[index]; index += 1 }
        if snap.showsDivider { regions[.divider] = frames[index]; index += 1 }
        regions[.newTabRow] = frames[index]; index += 1
        for item in snap.today { rowFrames[item.id] = frames[index]; index += 1 }
        regions[.list] = CGRect(
            x: 0, y: layout.listTop,
            width: layout.contentWidth, height: layout.dockFrame.minY - (layout.listTop)
        )
        regions[.favorites] = layout.favoritesFrame
        let dockIDs = [f.home, f.work]
        for (id, frame) in zip(dockIDs, layout.dockItemFrames(count: dockIDs.count)) { regions[.dock(id)] = frame }
        let g = SidebarDropGeometry.make(snapshot: snap, dockSpaceIDs: dockIDs, rowFrames: rowFrames, regions: regions, rowSpacing: layout.rowSpacing)
        return (g, snap)
    }

    private func rowFrame(_ id: UUID, in g: SidebarDropGeometry) -> CGRect {
        g.entries.first { if case .row(let rid, _) = $0.kind { return rid == id } else { return false } }!.frame
    }

    private func hit(_ x: CGFloat, _ y: CGFloat, _ g: SidebarDropGeometry) -> SidebarDropTarget? {
        SidebarDropHitTester.target(at: CGPoint(x: x, y: y), in: g)
    }

    private var listX: CGFloat { layout.horizontalInset + 20 }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: Hit-testing (pure)

    /// [06 §12] folder rows have a middle band (drop inside) and edge bands (before / after);
    /// the band size (`dropEdgeBand`) is unknown. Tab rows split in half.
    func testRowEdgeAndMiddleBands() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let folder = rowFrame(f.folderC, in: g)
        let band = SidebarLocalTokens.dropEdgeBand * folder.height
        XCTAssertEqual(hit(listX, folder.minY + band / 2, g), .row(f.folderC, .above))
        XCTAssertEqual(hit(listX, folder.midY, g), .row(f.folderC, .into))
        XCTAssertEqual(hit(listX, folder.maxY - band / 2, g), .row(f.folderC, .below))

        let tab = rowFrame(f.pinnedTab, in: g)
        XCTAssertEqual(hit(listX, tab.minY + 2, g), .row(f.pinnedTab, .above))
        XCTAssertEqual(hit(listX, tab.midY - 1, g), .row(f.pinnedTab, .above))
        XCTAssertEqual(hit(listX, tab.midY + 1, g), .row(f.pinnedTab, .below))
        XCTAssertEqual(hit(listX, tab.maxY - 2, g), .row(f.pinnedTab, .below))
    }

    /// [04 §sidebar] observed pitch 41 pt with a 36 pt row: the 5 pt gap between two rows belongs to
    /// one of them (no dead strip), split at the middle of the gap.
    func testGapBetweenRowsHasNoDeadStrip() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let a = rowFrame(f.today3, in: g), b = rowFrame(f.today2, in: g)
        let gapMid = (a.maxY + b.minY) / 2
        XCTAssertEqual(hit(listX, gapMid - 0.5, g), .row(f.today3, .below))
        XCTAssertEqual(hit(listX, gapMid + 0.5, g), .row(f.today2, .above))
    }

    /// [06 §12] observed: the gap above the first pinned row means "above the first pinned row",
    /// which pins a Today tab before the folders.
    func testPointAboveFirstPinnedRowTargetsItsTop() {
        let f = SidebarFixture()
        let (g, snap) = geometry(f)
        let first = snap.pinned[0].id
        XCTAssertEqual(first, f.folderA)
        let y = rowFrame(first, in: g).minY - 2
        XCTAssertEqual(hit(listX, y, g), .row(first, .above))
    }

    /// [06 §12] observed: dropping a Today tab above the first pinned row pins it, placed before the folders.
    func testDragTodayTabAboveFirstPinnedRowPinsIt() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, snap) = geometry(f)
        // Inside the list's 3 pt top spacer ([07 §1] observed), above the first row.
        let y = rowFrame(snap.pinned[0].id, in: g).minY - 2
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: y), in: g))
        XCTAssertEqual(vm.dropTarget, .row(f.folderA, .above))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .pinned(spaceID: f.home, folderID: nil))
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).first?.id, f.today1)
        XCTAssertNil(vm.draggingItem)
    }

    /// [06 §12] observed: dragging a pinned tab onto a folder row moves it inside and expands the folder.
    func testDragPinnedTabOntoFolderRowMovesInside() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let folder = rowFrame(f.folderC, in: g)
        vm.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: folder.midY), in: g))
        XCTAssertEqual(vm.dropTarget, .row(f.folderC, .into))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.location, .pinned(spaceID: f.home, folderID: f.folderC))
        XCTAssertEqual(vm.workspace.folders[f.folderC]?.isExpanded, true)
    }

    /// Reorder inside Today: the tab moves between two Today rows (inferred; [06 §4] shows Today as a list).
    func testReorderInsideToday() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        // Today order is today3, today2, today1. Drop today1 on the upper half of today2.
        let y = rowFrame(f.today2, in: g).minY + 3
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: y), in: g))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.today(spaceID: f.home).map(\.id), [f.today3, f.today1, f.today2])
    }

    /// Reorder inside the pinned area: a pinned tab dropped on the lower half of a folder row's
    /// edge band goes after that folder (inferred), still at the top level.
    func testReorderInsidePinnedArea() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let folder = rowFrame(f.folderC, in: g)
        vm.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: folder.maxY - 2), in: g))
        XCTAssertEqual(vm.dropTarget, .row(f.folderC, .below))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).map(\.id), [f.folderA, f.folderC, f.pinnedTab])
    }

    /// [06 §3] folders live in the pinned area: a folder (with its contents) reorders at the top
    /// level and nests into another folder, but never into itself or a descendant.
    func testFolderDragReorderNestAndNeverIntoItself() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)

        // Reorder: C above A.
        var (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.folder(f.folderC))
        let a = rowFrame(f.folderA, in: g)
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: a.minY + 1), in: g))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).map(\.id).prefix(2), [f.folderC, f.folderA])

        // Nest: C into A; A's contents stay where they are.
        (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.folder(f.folderC))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: a.midY), in: g))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.folders[f.folderC]?.parentFolderID, f.folderA)

        // Never into itself or its own descendant: no indicator, no change.
        (vm, _) = makeSidebarViewModel(f)
        let before = vm.workspace
        vm.beginDrag(.folder(f.folderA))
        XCTAssertFalse(vm.updateDropTarget(at: CGPoint(x: listX, y: a.midY), in: g))
        XCTAssertNil(vm.dropTarget)
        let b = rowFrame(f.folderB, in: g)
        XCTAssertFalse(vm.updateDropTarget(at: CGPoint(x: listX, y: b.midY), in: g))
        XCTAssertFalse(vm.performDrop(on: .row(f.folderA, .into)))
        XCTAssertEqual(vm.workspace, before)
    }

    /// Favorites block: the x position picks the insertion gap; an empty block still takes drops at
    /// gap 0 (inferred). Dropping a Today tab there favorites it.
    func testFavoritesBlockTargetsAndFavoritesATab() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let block = layout.favoritesFrame
        XCTAssertEqual(hit(block.minX + 2, block.midY, g), .favoriteGap(0))
        XCTAssertEqual(hit(block.midX, block.midY, g), .favoriteGap(1))
        XCTAssertEqual(hit(block.maxX - 2, block.midY, g), .favoriteGap(2))

        let (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: block.maxX - 2, y: block.midY), in: g))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .favorite(profileID: f.profile))
        XCTAssertEqual(vm.workspace.favorites(profileID: f.profile).last?.id, f.today1)

        // Empty block.
        var empty = f.ws
        empty = try! TreeOps.moveTab(empty, id: f.fav1, to: .today(spaceID: f.home), position: .last, now: f.now)
        empty = try! TreeOps.moveTab(empty, id: f.fav2, to: .today(spaceID: f.home), position: .last, now: f.now)
        var f2 = f
        f2.ws = empty
        let (g2, _) = geometry(f2)
        XCTAssertEqual(hit(block.midX, block.midY, g2), .favoriteGap(0))
    }

    /// Dock icons are targets; the gap between icons is not.
    func testDockIconsAreTargets() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let frames = layout.dockItemFrames(count: 2)
        XCTAssertEqual(hit(frames[0].midX, frames[0].midY, g), .dockSpace(f.home))
        XCTAssertEqual(hit(frames[1].midX, frames[1].midY, g), .dockSpace(f.work))
        XCTAssertNil(hit(frames[1].maxX + 40, frames[1].midY, g), "empty dock area")
    }

    /// End of the list: everything below the last row means "end of Today"; the "+ New Tab" row,
    /// which sits at the top of Today right under the divider ([07 §4] observed), means "top of
    /// Today"; the divider's upper half is the end of the pinned area, its lower half the top of Today.
    func testEndOfListAndDividerTargets() {
        let f = SidebarFixture()
        let (g, snap) = geometry(f)
        let last = g.entries.last!.frame
        XCTAssertEqual(hit(listX, last.maxY + 60, g), .todayAreaEnd)
        let newTab = g.entries.first { $0.kind == .newTabRow }!.frame
        XCTAssertEqual(hit(listX, newTab.midY, g), .row(snap.today[0].id, .above))

        let divider = g.entries.first { $0.kind == .divider }!.frame
        XCTAssertEqual(hit(listX, divider.minY + 2, g), .pinnedAreaEnd)
        XCTAssertEqual(hit(listX, divider.maxY - 2, g), .row(snap.today[0].id, .above))
    }

    /// Points over other chrome (top bar, URL box, space name row) hit nothing.
    func testPointsOutsideDropRegionsHitNothing() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        XCTAssertNil(hit(listX, 12, g), "toolbar row")
        XCTAssertNil(hit(listX, layout.urlBoxFrame.midY, g), "URL box")
        XCTAssertNil(hit(listX, layout.spaceNameRowFrame.midY, g), "space name row")
    }

    /// An empty list (no entries yet) appends to Today.
    func testEmptyListTargetsEndOfToday() {
        let g = SidebarDropGeometry(
            list: CGRect(x: 0, y: 190, width: 260, height: 500), entries: [],
            favorites: .null, favoriteCount: 0, dockItems: [], rowSpacing: 5
        )
        XCTAssertEqual(hit(50, 300, g), .todayAreaEnd)
        XCTAssertNil(hit(50, 100, g))
    }

    // MARK: Every hit-tested target maps to a plan TreeOps accepts

    /// Sweeps pointer positions over the whole sidebar for every draggable item: whenever the hit-test
    /// yields a target with a plan, `TreeOps` must accept that plan (the UI shows no indicator
    /// otherwise, so a rejected plan would be a silent failed drop).
    func testEveryHitTargetMapsToAPlanTreeOpsAccepts() throws {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        var accepted = 0
        var seen = Set<String>()
        for item in f.allDraggables {
            var y: CGFloat = 0
            while y < layout.windowSize.height {
                for x in [listX, layout.favoritesFrame.minX + 3, layout.favoritesFrame.midX, layout.favoritesFrame.maxX - 3] + layout.dockItemFrames(count: 2).map(\.midX) {
                    guard let target = hit(x, y, g) else { continue }
                    guard let plan = SidebarDropPlanner.plan(item: item, target: target, workspace: f.ws, spaceID: f.home, profileID: f.profile) else { continue }
                    accepted += 1
                    switch target {
                    case .row(_, let zone): seen.insert("row.\(zone)")
                    case .pinnedAreaEnd: seen.insert("pinnedEnd")
                    case .todayAreaEnd: seen.insert("todayEnd")
                    case .favoriteGap: seen.insert("fav")
                    case .dockSpace: seen.insert("dock")
                    case .pinnedAreaTop: seen.insert("pinnedTop")
                    }
                    switch plan.action {
                    case .moveTab(let id, let loc, let pos):
                        XCTAssertNoThrow(try TreeOps.moveTab(f.ws, id: id, to: loc, position: pos, now: f.now), "\(item) at (\(x), \(y)) -> \(target)")
                    case .moveFolder(let id, let space, let parent, let pos):
                        XCTAssertNoThrow(try TreeOps.moveFolder(f.ws, id: id, toSpace: space, parentFolderID: parent, position: pos, now: f.now), "\(item) at (\(x), \(y)) -> \(target)")
                    case .moveTabs(let ids, let loc, let pos):
                        XCTAssertNoThrow(try SidebarDropPlanner.moveSteps(ids: ids, position: pos).reduce(f.ws) { try TreeOps.moveTab($0, id: $1.id, to: loc, position: $1.position, now: f.now) }, "\(item) at (\(x), \(y)) -> \(target)")
                    case .moveSplitLayout(let id, let space, let pos):
                        XCTAssertNoThrow(try TreeOps.moveSplitLayout(f.ws, layoutID: id, toSpaceID: space, position: pos, now: f.now), "\(item) at (\(x), \(y)) -> \(target)")
                    }
                }
                y += 3
            }
        }
        XCTAssertGreaterThan(accepted, 500)
        for kind in ["row.above", "row.into", "row.below", "pinnedEnd", "todayEnd", "fav", "dock"] {
            XCTAssertTrue(seen.contains(kind), "sweep never produced \(kind)")
        }
    }

    // MARK: Cross-Space

    /// Dropping on a dock icon moves the tab to that Space (inferred; [06 §12] lists it as untested).
    func testDropOnDockIconMovesTabToThatSpace() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let icon = layout.dockItemFrames(count: 2)[1]
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: icon.midX, y: icon.midY), in: g))
        XCTAssertEqual(vm.dropTarget, .dockSpace(f.work))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .today(spaceID: f.work))
        XCTAssertEqual(vm.workspace.today(spaceID: f.work).first?.id, f.today1)
        XCTAssertEqual(vm.selectedSpaceID, f.home, "a plain drop does not switch Space")
    }

    /// Hovering a dock icon during a drag switches to that Space after a delay (inferred), and the
    /// drag continues: the item can then be placed inside the new Space's list.
    func testHoverOverDockIconSwitchesSpaceThenDropPlaces() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.dockSwitchDelay = 0.03
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(.dockSpace(f.work)))
        XCTAssertEqual(vm.selectedSpaceID, f.home, "not before the delay")
        let switched = await waitUntil { vm.selectedSpaceID == f.work }
        XCTAssertTrue(switched)
        XCTAssertEqual(vm.draggingItem, .tab(f.today1), "the drag is still running")
        XCTAssertTrue(vm.performDrop(on: .todayAreaEnd))
        XCTAssertEqual(vm.workspace.today(spaceID: f.work).last?.id, f.today1)
        vm.stop()
    }

    /// Moving off the dock icon before the delay cancels the switch.
    func testLeavingDockIconCancelsSpaceSwitch() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.dockSwitchDelay = 0.05
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(.dockSpace(f.work)))
        XCTAssertTrue(vm.updateDropTarget(.todayAreaEnd))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.endDrag()
    }

    // MARK: External URL drops

    /// A link dragged in from another app opens a tab at the drop position (inferred): above the first
    /// pinned row it becomes a pinned tab before the folders; the tab is selected.
    func testExternalURLDropOpensTabAtPosition() {
        let f = SidebarFixture()
        let (vm, ids) = makeSidebarViewModel(f)
        let url = URL(string: "https://dropped.example.com/page")!
        vm.beginExternalDrag()
        XCTAssertTrue(vm.updateDropTarget(.row(f.folderA, .above)))
        let id = vm.performURLDrop(url, on: .row(f.folderA, .above))
        XCTAssertNotNil(id)
        XCTAssertEqual(id, SidebarFixture.id(1_001))
        _ = ids
        XCTAssertEqual(vm.workspace.tabs[id!]?.url, url)
        XCTAssertEqual(vm.workspace.tabs[id!]?.location, .pinned(spaceID: f.home, folderID: nil))
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).first?.id, id)
        XCTAssertEqual(vm.selectedTabID, id)
        XCTAssertFalse(vm.isDraggingExternalURL)
        vm.stop()
    }

    /// External link on a folder row goes inside and expands it; on the end of Today it is appended;
    /// on a dock icon it opens in that Space and the sidebar shows that Space.
    func testExternalURLDropOnFolderTodayEndAndDock() {
        let f = SidebarFixture()
        let url = URL(string: "https://dropped.example.com")!

        var (vm, _) = makeSidebarViewModel(f)
        vm.beginExternalDrag()
        var id = vm.performURLDrop(url, on: .row(f.folderC, .into))
        XCTAssertEqual(vm.workspace.tabs[id!]?.location, .pinned(spaceID: f.home, folderID: f.folderC))

        (vm, _) = makeSidebarViewModel(f)
        vm.beginExternalDrag()
        id = vm.performURLDrop(url, on: .todayAreaEnd)
        XCTAssertEqual(vm.workspace.today(spaceID: f.home).last?.id, id)

        (vm, _) = makeSidebarViewModel(f)
        vm.beginExternalDrag()
        id = vm.performURLDrop(url, on: .dockSpace(f.work))
        XCTAssertEqual(vm.workspace.tabs[id!]?.location, .today(spaceID: f.work))
        XCTAssertEqual(vm.selectedSpaceID, f.work)

        (vm, _) = makeSidebarViewModel(f)
        vm.beginExternalDrag()
        id = vm.performURLDrop(url, on: .favoriteGap(1))
        XCTAssertEqual(vm.workspace.tabs[id!]?.location, .favorite(profileID: f.profile))
    }

    /// A link on a target that accepts nothing (a favorite is not a row), or without an external drag
    /// in progress, changes nothing.
    func testExternalURLDropRejectedLeavesWorkspaceUnchanged() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let before = vm.workspace
        let url = URL(string: "https://dropped.example.com")!
        vm.beginExternalDrag()
        XCTAssertFalse(vm.updateDropTarget(.row(f.fav1, .above)))
        XCTAssertNil(vm.performURLDrop(url, on: .row(f.fav1, .above)))
        XCTAssertNil(vm.performURLDrop(url, on: .todayAreaEnd), "no external drag in progress")
        XCTAssertEqual(vm.workspace, before)
    }

    // MARK: Cancel

    /// A drag that ends without a drop (released outside any target, or Esc) leaves the workspace
    /// unchanged and clears all drag feedback; the watchdog notices the released mouse button.
    func testDragCancelLeavesWorkspaceUnchanged() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let before = vm.workspace
        vm.dragWatchInterval = 0.01
        // A main-actor box rather than a captured `var`: the watchdog closure is a Sendable
        // `@MainActor` closure, and both it and this test run on the main actor.
        let mouseDown = MouseButtonState()
        vm.beginDrag(.tab(f.today1), isSessionActive: { mouseDown.isDown })
        XCTAssertTrue(vm.updateDropTarget(.row(f.folderA, .above)))
        XCTAssertNotNil(vm.dropTarget)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNotNil(vm.draggingItem, "still dragging while the button is down")
        mouseDown.isDown = false
        let ended = await waitUntil { vm.draggingItem == nil }
        XCTAssertTrue(ended)
        XCTAssertNil(vm.dropTarget)
        XCTAssertEqual(vm.workspace, before)
        vm.stop()
    }

    /// Dropping on nothing (pointer over the toolbar) is a no-op that also ends the drag.
    func testDropOnNothingLeavesWorkspaceUnchanged() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let before = vm.workspace
        vm.beginDrag(.tab(f.today1))
        XCTAssertFalse(vm.updateDropTarget(at: CGPoint(x: listX, y: 12), in: g))
        XCTAssertNil(vm.dropTarget)
        vm.endDrag()
        XCTAssertNil(vm.draggingItem)
        XCTAssertEqual(vm.workspace, before)
    }

    // MARK: Payload

    /// In-app items use a private type; they are never offered as plain text, and a tab with a URL
    /// can be dragged out as a link.
    func testPayloadIsPrivateAndTabsDragOutAsURL() async throws {
        let url = URL(string: "https://out.example.com")!
        let tabProvider = SidebarDragPayload.makeProvider(item: .tab(SidebarFixture.id(1)), url: url)
        let ids = tabProvider.registeredTypeIdentifiers
        XCTAssertTrue(ids.contains(SidebarDragPayload.itemType.identifier))
        XCTAssertTrue(ids.contains(UTType.url.identifier))
        XCTAssertFalse(ids.contains(UTType.plainText.identifier))
        XCTAssertFalse(ids.contains(UTType.utf8PlainText.identifier))

        let folderProvider = SidebarDragPayload.makeProvider(item: .folder(SidebarFixture.id(2)), url: nil)
        XCTAssertEqual(folderProvider.registeredTypeIdentifiers, [SidebarDragPayload.itemType.identifier])
    }

    func testPayloadRoundTrip() {
        for item in [SidebarDragItem.tab(SidebarFixture.id(7)), .folder(SidebarFixture.id(8))] {
            XCTAssertEqual(SidebarDragPayload.decode(SidebarDragPayload.encode(item)), item)
        }
        XCTAssertNil(SidebarDragPayload.decode(Data("junk".utf8)))
        XCTAssertNil(SidebarDragPayload.decode(Data("tab:not-a-uuid".utf8)))
    }

    /// The view model reports the preview title for tabs and folders.
    func testDragTitle() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertEqual(vm.dragTitle(for: .tab(f.today1)), "today1")
        XCTAssertEqual(vm.dragTitle(for: .folder(f.folderA)), "A")
    }
}

/// Simulated primary mouse button state polled by the drag watchdog in tests.
@MainActor
private final class MouseButtonState {
    var isDown = true
}
