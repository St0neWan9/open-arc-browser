import XCTest
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// Drag and drop in the sidebar: pure hit-testing (point -> target), the planner/TreeOps chain,
/// cross-Space moves, external link drops and drag cancel.
/// Spec: [06 §12] "Hover and drag results", [06 §15] drag-and-drop details (E9: bands, split
/// preview, folder-first, dead zone, Space-name row, dock and edge switching, payload, Esc),
/// [06 §3] folders, [04 §sidebar] row pitch 41 pt, [05 §window hierarchy] dock and favorites.
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
        regions[.spaceName] = CGRect(x: 0, y: CGFloat(Metrics.Sidebar.spaceHeaderTop), width: layout.width, height: CGFloat(Metrics.Sidebar.spaceHeaderHeight))
        let dockIDs = [f.home, f.work]
        for (id, frame) in zip(dockIDs, layout.dockItemFrames(count: dockIDs.count)) { regions[.dock(id)] = frame }
        let g = SidebarDropGeometry.make(snapshot: snap, dockSpaceIDs: dockIDs, rowFrames: rowFrames, regions: regions, width: layout.width)
        return (g, snap)
    }

    private func rowFrame(_ id: UUID, in g: SidebarDropGeometry) -> CGRect {
        g.entry(forRow: id)!.frame
    }

    private func hit(_ x: CGFloat, _ y: CGFloat, _ g: SidebarDropGeometry, allowsSplit: Bool = true) -> SidebarDropTarget? {
        SidebarDropHitTester.target(at: CGPoint(x: x, y: y), in: g, allowsSplit: allowsSplit)
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

    /// [06 §15.2] observed: on a tab row only ≈ 21 pt around each boundary inserts (≈ 10 pt on each
    /// side); the middle ≈ 20 pt is the split band, on the pointer's half of the row.
    func testTabRowInsertAndSplitBands() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let row = rowFrame(f.today2, in: g)
        // Upper band: the slot between today3 and today2 (one slot, reported on the upper row).
        XCTAssertEqual(hit(listX, row.minY + 2, g), .row(f.today3, .below))
        XCTAssertEqual(hit(listX, row.minY + 10, g), .row(f.today3, .below))
        // Middle ≈ 20 pt: split preview, side by x.
        XCTAssertEqual(hit(listX, row.minY + 11, g), .row(f.today2, .split(.leading)))
        XCTAssertEqual(hit(listX, row.midY, g), .row(f.today2, .split(.leading)))
        XCTAssertEqual(hit(layout.width - 30, row.midY, g), .row(f.today2, .split(.trailing)))
        XCTAssertEqual(hit(listX, row.maxY - 11, g), .row(f.today2, .split(.leading)))
        // Lower band.
        XCTAssertEqual(hit(listX, row.maxY - 10, g), .row(f.today2, .below))
        XCTAssertEqual(hit(listX, row.maxY - 1, g), .row(f.today2, .below))
        // Band sizes: ≈ 20 pt split band, ≈ 21 pt insertion slot per boundary.
        let splitBand = row.height - SidebarLocalTokens.tabRowAboveBand - SidebarLocalTokens.tabRowBelowBand
        XCTAssertEqual(splitBand, 20, accuracy: 1)
        XCTAssertEqual(SidebarLocalTokens.tabRowAboveBand + SidebarLocalTokens.tabRowBelowBand, 21, accuracy: 1)
    }

    /// The first Today row's top band is the top of Today; folders and groups have no split band, so
    /// a tab row splits in half for them (`allowsSplit` false).
    func testTabRowWithoutSplitSplitsInHalves() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let row = rowFrame(f.today2, in: g)
        XCTAssertEqual(hit(listX, row.midY - 1, g, allowsSplit: false), .row(f.today3, .below))
        XCTAssertEqual(hit(listX, row.midY + 1, g, allowsSplit: false), .row(f.today2, .below))
    }

    /// [06 §15.3] observed: a collapsed (or empty) folder row has ≈ 11 pt above, a middle "into"
    /// band and ≈ 8 pt below; an expanded folder with children has no "into" band: upper half =
    /// before the folder, lower half = the folder's first slot.
    func testFolderRowBands() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        // folderC is empty (expanded, no children): into band.
        let c = rowFrame(f.folderC, in: g)
        // Its top ≈ 11 pt is the slot above it (after folder A's last child, see below).
        XCTAssertEqual(hit(listX, c.minY + 10, g), .row(f.inFolderTab, .below))
        XCTAssertEqual(hit(listX, c.minY + 12, g), .row(f.folderC, .into))
        XCTAssertEqual(hit(listX, c.maxY - 9, g), .row(f.folderC, .into))
        XCTAssertEqual(hit(listX, c.maxY - 7, g), .row(f.folderC, .below))
        XCTAssertEqual(g.entry(forRow: f.folderC)?.kind, .row(f.folderC, style: .folder))

        // folderA is expanded with children: halves, lower half = first child slot (indented line).
        let a = rowFrame(f.folderA, in: g)
        XCTAssertEqual(g.entry(forRow: f.folderA)?.kind, .row(f.folderA, style: .halves))
        XCTAssertEqual(hit(listX, a.midY - 1, g), .row(f.folderA, .above))
        XCTAssertEqual(hit(listX, a.midY + 1, g), .row(f.folderA, .below))
        XCTAssertEqual(g.entry(forRow: f.folderA)?.depthBelow, 1)

        // A collapsed folder with children also has the into band.
        var collapsed = f
        collapsed.ws = try! TreeOps.setFolderExpanded(f.ws, id: f.folderA, isExpanded: false, now: f.now)
        let (g2, _) = geometry(collapsed)
        XCTAssertEqual(hit(listX, rowFrame(f.folderA, in: g2).midY, g2), .row(f.folderA, .into))
    }

    /// [06 §15.2] observed: the insertion line is centered in the gap between two rows, starts at
    /// x ≈ 16 (+ 16 per folder level) and runs to the content edge.
    func testIndicatorLineGeometry() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let trailing: CGFloat = 265
        let between = SidebarDropIndicatorLine.make(for: .row(f.today3, .below), in: g, contentTrailing: trailing)!
        let row3 = rowFrame(f.today3, in: g)
        XCTAssertEqual(between.y, row3.maxY - 0.5, accuracy: 0.01)
        XCTAssertEqual(between.leading, 16)
        XCTAssertEqual(between.trailing, 265)
        // Below an expanded folder with children: first child slot, one level in (x ≈ 32).
        XCTAssertEqual(SidebarDropIndicatorLine.make(for: .row(f.folderA, .below), in: g, contentTrailing: trailing)?.leading, 32)
        // Inside folder B (depth 2): its child deepTab's line is at 16 + 2 × 16.
        XCTAssertEqual(SidebarDropIndicatorLine.make(for: .row(f.deepTab, .above), in: g, contentTrailing: trailing)?.leading, 48)
        // Into, split, Space-name row: no line.
        XCTAssertNil(SidebarDropIndicatorLine.make(for: .row(f.folderC, .into), in: g, contentTrailing: trailing))
        XCTAssertNil(SidebarDropIndicatorLine.make(for: .row(f.today2, .split(.leading)), in: g, contentTrailing: trailing))
        XCTAssertNil(SidebarDropIndicatorLine.make(for: .pinnedAreaTop, in: g, contentTrailing: trailing))
        XCTAssertNil(SidebarDropIndicatorLine.make(for: nil, in: g, contentTrailing: trailing))
    }

    /// [06 §15.3] observed: below the last child of a folder only the indented line shows: the
    /// boundary between the last child and the next top-level row is ONE slot, inside the folder.
    func testBoundaryAfterFolderChildrenIsInsideTheFolder() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        // folderA's last visible child is inFolderTab (depth 1); the next row is folderC (depth 0).
        let c = rowFrame(f.folderC, in: g)
        XCTAssertEqual(hit(listX, c.minY + 2, g), .row(f.inFolderTab, .below))
        XCTAssertEqual(SidebarDropIndicatorLine.make(for: .row(f.inFolderTab, .below), in: g, contentTrailing: 265)?.leading, 32)
    }

    /// [06 §15.2] observed: no gap between rows is dead; every point between the first row and the
    /// divider maps to some target.
    func testNoDeadStripBetweenRows() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        let first = g.entries.first!.frame.minY
        let divider = g.entries.first { $0.kind == .divider }!.frame
        var y = first
        while y < divider.midY {
            XCTAssertNotNil(hit(listX, y, g), "y \(y)")
            y += 0.5
        }
    }

    /// [06 §15.4] observed: the Space-name row is a drop target (first pinned item); the gap above
    /// the first pinned row means "above the first pinned row" (same result).
    func testSpaceNameRowAndTopOfPinnedArea() {
        let f = SidebarFixture()
        let (g, snap) = geometry(f)
        XCTAssertEqual(hit(listX, layout.spaceNameRowFrame.midY, g), .pinnedAreaTop)
        XCTAssertEqual(hit(layout.width - 5, CGFloat(Metrics.Sidebar.spaceHeaderTop) + 1, g), .pinnedAreaTop, "full width")
        let first = snap.pinned[0].id
        XCTAssertEqual(first, f.folderA)
        XCTAssertEqual(hit(listX, rowFrame(first, in: g).minY - 2, g), .row(first, .above))
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

    /// [03 §Advanced] "Haptic feedback when reordering tabs" (observed, on by default; B68): one tap
    /// per new drop position of an in-app drag, none while the pointer stays, none when off.
    func testReorderHapticFollowsTheSetting() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        var taps = 0
        vm.playReorderHaptic = { taps += 1 }
        vm.beginDrag(.tab(f.today1))
        let y = rowFrame(f.today2, in: g).minY + 3
        vm.updateDropTarget(at: CGPoint(x: listX, y: y), in: g)
        vm.updateDropTarget(at: CGPoint(x: listX, y: y + 1), in: g)
        XCTAssertEqual(taps, 1)
        vm.updateDropTarget(at: CGPoint(x: listX, y: rowFrame(f.today3, in: g).minY + 3), in: g)
        XCTAssertEqual(taps, 2)
        vm.endDrag()

        vm.controller.dependencies.preferences.playsReorderHaptics = false
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: CGPoint(x: listX, y: y), in: g)
        XCTAssertEqual(taps, 2, "off: no haptic")
        vm.endDrag()
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

    /// [06 §15.4] observed: the divider (upper half) is the end of the pinned area; from the
    /// divider's lower half to the upper half of "+ New Tab" (≈ 29 pt) there is NO target; the lower
    /// half of "+ New Tab" is the top of Today. [06 §15.2] observed: below the last row = end of Today.
    func testDividerDeadZoneNewTabAndEndOfList() {
        let f = SidebarFixture()
        let (g, snap) = geometry(f)
        let divider = g.entries.first { $0.kind == .divider }!.frame
        let newTab = g.entries.first { $0.kind == .newTabRow }!.frame
        // Divider upper half: after the last pinned row (pinnedTab, top level).
        XCTAssertEqual(hit(listX, divider.minY + 2, g), .row(f.pinnedTab, .below))
        // Dead zone.
        var y = divider.midY
        while y < newTab.midY {
            XCTAssertNil(hit(listX, y, g), "dead zone at y \(y)")
            y += 0.5
        }
        XCTAssertEqual(newTab.midY - divider.midY, 29, accuracy: 1, "≈ 29 pt dead zone")
        // Lower half of "+ New Tab": top of Today (line above the first Today tab).
        XCTAssertEqual(hit(listX, newTab.midY + 1, g), .row(snap.today[0].id, .above))
        XCTAssertEqual(SidebarDropIndicatorLine.make(for: .row(snap.today[0].id, .above), in: g, contentTrailing: 265)?.y,
                       newTab.maxY - 0.5)
        // Below the last row: after the last Today row (the end of Today).
        let last = g.entries.last!
        guard case .row(let lastID, _) = last.kind else { return XCTFail("last entry is a row") }
        XCTAssertEqual(hit(listX, last.frame.maxY + 60, g), .row(lastID, .below))
    }

    /// [06 §15.4] observed: at the divider with an expanded last folder, the line is indented under
    /// the folder's last child (the item becomes its last child, inferred).
    func testDividerAfterExpandedLastFolderGoesInsideIt() throws {
        var f = SidebarFixture()
        // Move pinnedTab into folder C, so C (expanded) is last and has a child.
        f.ws = try TreeOps.moveTab(f.ws, id: f.pinnedTab, to: .pinned(spaceID: f.home, folderID: f.folderC), position: .last, now: f.now)
        let (g, _) = geometry(f)
        let divider = g.entries.first { $0.kind == .divider }!.frame
        XCTAssertEqual(hit(listX, divider.minY + 2, g), .row(f.pinnedTab, .below))
        XCTAssertEqual(SidebarDropIndicatorLine.make(for: .row(f.pinnedTab, .below), in: g, contentTrailing: 265)?.leading, 32)
        let p = SidebarDropPlanner.plan(item: .tab(f.today1), target: .row(f.pinnedTab, .below), workspace: f.ws, spaceID: f.home, profileID: f.profile)
        XCTAssertEqual(p?.action, .moveTab(id: f.today1, to: .pinned(spaceID: f.home, folderID: f.folderC), position: .after(f.pinnedTab)))
    }

    /// An empty Today: the lower half of "+ New Tab" and the space below it are the end of Today.
    func testEmptyTodayTargets() throws {
        var f = SidebarFixture()
        for id in [f.today1, f.today2, f.today3] {
            f.ws = try TreeOps.moveTab(f.ws, id: id, to: .pinned(spaceID: f.home, folderID: nil), position: .last, now: f.now)
        }
        let (g, snap) = geometry(f)
        XCTAssertFalse(snap.showsDivider)
        let newTab = g.entries.first { $0.kind == .newTabRow }!.frame
        XCTAssertNil(hit(listX, newTab.minY + 2, g), "upper half of + New Tab")
        XCTAssertEqual(hit(listX, newTab.maxY - 2, g), .todayAreaEnd)
        XCTAssertEqual(hit(listX, newTab.maxY + 40, g), .todayAreaEnd)
    }

    /// Points over other chrome (top bar, URL box) hit nothing.
    func testPointsOutsideDropRegionsHitNothing() {
        let f = SidebarFixture()
        let (g, _) = geometry(f)
        XCTAssertNil(hit(listX, 12, g), "toolbar row")
        XCTAssertNil(hit(listX, layout.urlBoxFrame.midY, g), "URL box")
    }

    /// An empty list (no entries yet) appends to Today.
    func testEmptyListTargetsEndOfToday() {
        let g = SidebarDropGeometry(
            list: CGRect(x: 0, y: 190, width: 260, height: 500), entries: [],
            favorites: .null, favoriteCount: 0, dockItems: []
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
                    let allowsSplit: Bool = if case .tab(let id) = item, case .favorite? = f.ws.tabs[id]?.location { false } else if case .tab = item { true } else { false }
                    guard let target = hit(x, y, g, allowsSplit: allowsSplit) else { continue }
                    guard let plan = SidebarDropPlanner.plan(item: item, target: target, workspace: f.ws, spaceID: f.home, profileID: f.profile) else { continue }
                    accepted += 1
                    switch target {
                    case .row(_, let zone): seen.insert("row.\(zone)")
                        if zone == .split(.leading) { XCTAssertTrue(allowsSplit) }
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
                    default:
                        XCTAssertNoThrow(try SidebarDropPlanner.apply(plan, to: f.ws, newTabID: plan.action.needsCopyID ? SidebarFixture.id(7_000) : nil, layoutID: SidebarFixture.id(7_001), now: f.now), "\(item) at (\(x), \(y)) -> \(target)")
                    }
                    XCTAssertNoThrow(try SidebarDropPlanner.apply(plan, to: f.ws, newTabID: plan.action.needsCopyID ? SidebarFixture.id(7_000) : nil, layoutID: SidebarFixture.id(7_001), now: f.now))
                }
                y += 3
            }
        }
        XCTAssertGreaterThan(accepted, 500)
        for kind in ["row.above", "row.into", "row.below", "row.split(OpenArcModel.SplitSide.leading)", "pinnedTop", "fav", "dock"] {
            XCTAssertTrue(seen.contains(kind), "sweep never produced \(kind)")
        }
    }

    // MARK: Cross-Space

    /// [06 §15.6] observed: dropped on a Space dot, the tab moves to that Space's Today; the window
    /// stays on that Space and the moved tab is not selected.
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
        XCTAssertEqual(vm.selectedSpaceID, f.work, "the window shows the target Space")
        XCTAssertNotEqual(vm.selectedTabID, f.today1, "the moved tab is not selected")
    }

    /// The same when the dragged tab was the selected one (mouse-down selects it, [06 §15.1]).
    func testDropSelectedTabOnDockIconLeavesItUnselected() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.pressSelect(.tab(f.today1))
        XCTAssertEqual(vm.selectedTabID, f.today1)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.performDrop(on: .dockSpace(f.work)))
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        XCTAssertNotEqual(vm.selectedTabID, f.today1)
        vm.stop()
    }

    /// [06 §15.6] observed: hovering a Space dot during a drag switches to that Space within 1 s,
    /// and the drag continues: the item can then be placed inside the new Space's list.
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

    /// [06 §15.6] observed: hovering a dot switches the Space even when dropping there would change
    /// nothing (the dragged item already lives in that Space).
    func testDockHoverSwitchesEvenWithoutAcceptedDrop() async throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.moveTab(f.ws, id: f.today1, to: .today(spaceID: f.work), position: .first, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        vm.dockSwitchDelay = 0.03
        vm.beginDrag(.tab(f.today1))
        XCTAssertFalse(vm.updateDropTarget(.dockSpace(f.work)), "a drop there changes nothing")
        let switched = await waitUntil { vm.selectedSpaceID == f.work }
        XCTAssertTrue(switched)
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

    /// [06 §15.7] observed: the drag pasteboard holds only an app-private item type, no URL and no
    /// text, so a tab dragged out of the window gives nothing (changed from the earlier URL offer).
    func testPayloadIsPrivateOnlyWithoutURL() {
        let tabProvider = SidebarDragPayload.makeProvider(item: .tab(SidebarFixture.id(1)))
        XCTAssertEqual(tabProvider.registeredTypeIdentifiers, [SidebarDragPayload.itemType.identifier])
        let folderProvider = SidebarDragPayload.makeProvider(item: .folder(SidebarFixture.id(2)))
        XCTAssertEqual(folderProvider.registeredTypeIdentifiers, [SidebarDragPayload.itemType.identifier])

        let pasteboardItem = SidebarDragPayload.makePasteboardItem(.tab(SidebarFixture.id(1)))
        XCTAssertEqual(pasteboardItem.types.map(\.rawValue), [SidebarDragPayload.itemType.identifier])
        XCTAssertNil(pasteboardItem.string(forType: .URL))
        XCTAssertNil(pasteboardItem.string(forType: .string))
    }

    func testPayloadRoundTrip() {
        for item in [SidebarDragItem.tab(SidebarFixture.id(7)), .folder(SidebarFixture.id(8))] {
            XCTAssertEqual(SidebarDragPayload.decode(SidebarDragPayload.encode(item)), item)
        }
        XCTAssertNil(SidebarDragPayload.decode(Data("junk".utf8)))
        XCTAssertNil(SidebarDragPayload.decode(Data("tab:not-a-uuid".utf8)))
    }

    // MARK: [06 §15] details

    /// [06 §15.1] observed: a drag starts at ≥ 4 pt vertically or ≥ 5 pt horizontally, per axis;
    /// 1–3 pt vertically, 1–4 pt horizontally and (3, 3) do not start one.
    func testDragStartThresholdPerAxis() {
        for dy in [1, 2, 3] as [CGFloat] { XCTAssertFalse(SidebarDragThreshold.isExceeded(dx: 0, dy: dy)) }
        for dy in [4, -4, 6] as [CGFloat] { XCTAssertTrue(SidebarDragThreshold.isExceeded(dx: 0, dy: dy)) }
        for dx in [1, 2, 3, 4] as [CGFloat] { XCTAssertFalse(SidebarDragThreshold.isExceeded(dx: dx, dy: 0)) }
        for dx in [5, -5] as [CGFloat] { XCTAssertTrue(SidebarDragThreshold.isExceeded(dx: dx, dy: 0)) }
        XCTAssertFalse(SidebarDragThreshold.isExceeded(dx: 3, dy: 3), "diagonal (3, 3)")
        XCTAssertFalse(SidebarDragThreshold.isExceeded(dx: 4, dy: 3))
    }

    /// [06 §15.1] observed: mouse-down selects the tab (before any movement). Folders only act on
    /// click; a press on a split group selects its focused pane.
    func testPressSelectsTab() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.pressSelect(.tab(f.today2))
        XCTAssertEqual(vm.selectedTabID, f.today2)
        vm.pressSelect(.folder(f.folderA))
        XCTAssertEqual(vm.selectedTabID, f.today2)
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.isExpanded, true, "a press does not toggle a folder")
        vm.beginDrag(.tab(f.today2))
        vm.pressSelect(.tab(f.today3))
        XCTAssertEqual(vm.selectedTabID, f.today2, "no selection change during a drag")
        vm.stop()
    }

    /// The press targets: favorite slots and visible rows; the row's trailing ✕ / — area never
    /// selects on press (it acts on click); folders never select.
    func testDragSourceItems() {
        let f = SidebarFixture()
        let (g, snap) = geometry(f)
        var frames: [UUID: CGRect] = [:]
        for entry in g.entries { if case .row(let id, _) = entry.kind { frames[id] = entry.frame } }
        let items = SidebarDragSourceItem.make(
            snapshot: snap, rowFrames: frames, listViewport: g.list,
            favoriteSlots: layout.favoriteSlotFrames(count: 2), accessoryWidth: 38
        )
        XCTAssertEqual(items.count, 2 + snap.pinned.count + snap.today.count)
        let row = rowFrame(f.today2, in: g)
        let hit = SidebarDragSourceItem.item(at: CGPoint(x: 40, y: row.midY), in: items)
        XCTAssertEqual(hit?.item, .tab(f.today2))
        XCTAssertEqual(hit?.selectRect?.contains(CGPoint(x: 40, y: row.midY)), true)
        XCTAssertEqual(hit?.selectRect?.contains(CGPoint(x: row.maxX - 10, y: row.midY)), false, "✕ area")
        let folder = SidebarDragSourceItem.item(at: CGPoint(x: 40, y: rowFrame(f.folderA, in: g).midY), in: items)
        XCTAssertEqual(folder?.item, .folder(f.folderA))
        XCTAssertNil(folder?.selectRect)
        let fav = SidebarDragSourceItem.item(at: CGPoint(x: layout.favoritesFrame.minX + 5, y: layout.favoritesFrame.midY), in: items)
        XCTAssertEqual(fav?.item, .tab(f.fav1))
        // Rows scrolled out of the list viewport cannot be picked.
        let clipped = SidebarDragSourceItem.make(snapshot: snap, rowFrames: frames, listViewport: CGRect(x: 0, y: row.minY, width: 276, height: 41),
                                                 favoriteSlots: [], accessoryWidth: 38)
        XCTAssertEqual(clipped.map(\.item), [.tab(f.today2)])
    }

    /// [06 §15.2] observed: releasing on the split preview makes the two tabs one split, shown as
    /// one row with two cells; the dropped tab is on the pointer's side and becomes the focused pane.
    func testDropOnMiddleBandCreatesSplit() {
        let f = SidebarFixture()
        let (vm, ids) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let row = rowFrame(f.today3, in: g)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: row.midY), in: g))
        XCTAssertEqual(vm.dropTarget, .row(f.today3, .split(.leading)))
        XCTAssertEqual(vm.splitPreviewSide(for: f.today3), .leading)
        XCTAssertNil(vm.splitPreviewSide(for: f.today2))
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        let layoutID = SidebarFixture.id(1_001)
        _ = ids
        XCTAssertEqual(vm.workspace.splits[layoutID]?.root.tabIDs, [f.today1, f.today3], "dropped tab on the left")
        XCTAssertEqual(vm.selectedTabID, f.today1, "the dropped tab is the focused pane")
        let group = vm.snapshot.splitGroup(layoutID: layoutID)
        XCTAssertNotNil(group, "one row with two cells")
        XCTAssertEqual(vm.snapshot.today.map(\.id), [layoutID, f.today2])

        // Right half → the dropped tab goes right.
        let (vm2, _) = makeSidebarViewModel(f)
        vm2.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm2.updateDropTarget(at: CGPoint(x: layout.width - 20, y: row.midY), in: g))
        XCTAssertEqual(vm2.dropTarget, .row(f.today3, .split(.trailing)))
        XCTAssertTrue(vm2.performDrop(on: vm2.dropTarget!))
        XCTAssertEqual(vm2.workspace.splits.values.first?.root.tabIDs, [f.today3, f.pinnedTab])
        XCTAssertEqual(vm2.workspace.tabs[f.pinnedTab]?.location, .today(spaceID: f.home), "moves next to the target")
        vm.stop()
        vm2.stop()
    }

    /// Folders and split groups have no split band; favorites cannot form a split from a row; a tab
    /// onto itself is refused.
    func testSplitBandOnlyForSingleTabs() {
        let f = SidebarFixture()
        func plan(_ item: SidebarDragItem, _ target: SidebarDropTarget) -> SidebarDropPlan? {
            SidebarDropPlanner.plan(item: item, target: target, workspace: f.ws, spaceID: f.home, profileID: f.profile)
        }
        XCTAssertEqual(plan(.tab(f.today1), .row(f.today2, .split(.trailing)))?.action,
                       .splitTab(id: f.today1, target: f.today2, side: .trailing, moveNextToTarget: true))
        XCTAssertNil(plan(.folder(f.folderC), .row(f.today2, .split(.leading))))
        XCTAssertNil(plan(.tab(f.fav1), .row(f.today2, .split(.leading))))
        XCTAssertNil(plan(.tab(f.today2), .row(f.today2, .split(.leading))))
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.folder(f.folderC))
        XCTAssertFalse(vm.dragAllowsSplit)
        vm.beginDrag(.tab(f.fav1))
        XCTAssertFalse(vm.dragAllowsSplit)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.dragAllowsSplit)
        vm.stop()
    }

    /// [06 §15.7] observed: a link from outside over a row's middle band shows the same split
    /// preview; dropping there opens the link as a tab in a split with that row (inferred result).
    func testExternalLinkOnMiddleBandOpensInSplit() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.beginExternalDrag()
        XCTAssertTrue(vm.dragAllowsSplit)
        XCTAssertTrue(vm.updateDropTarget(.row(f.today2, .split(.trailing))))
        let id = vm.performURLDrop(URL(string: "https://link.example.com")!, on: .row(f.today2, .split(.trailing)))
        XCTAssertNotNil(id)
        let layout = vm.workspace.splits.values.first { !$0.meta.isTombstone }
        XCTAssertEqual(layout?.root.tabIDs, [f.today2, id!])
        vm.stop()
    }

    /// [06 §15.3] observed: dropping on a collapsed folder makes the tab its FIRST child and expands
    /// the folder (hovering alone never expands it).
    func testDropIntoCollapsedFolderInsertsFirstAndExpands() async throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.setFolderExpanded(f.ws, id: f.folderA, isExpanded: false, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: rowFrame(f.folderA, in: g).midY), in: g))
        XCTAssertEqual(vm.dropTarget, .row(f.folderA, .into))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.isExpanded, false, "no spring-loading")
        XCTAssertTrue(vm.performDrop(on: vm.dropTarget!))
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.home, folderID: f.folderA).first?.id, f.today1)
        XCTAssertEqual(vm.workspace.folders[f.folderA]?.isExpanded, true)
        vm.stop()
    }

    /// [06 §15.4] observed: dropped on the Space-name row, the tab becomes the first pinned item.
    func testDropOnSpaceNameRowPinsFirst() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        vm.beginDrag(.tab(f.today2))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: 100, y: layout.spaceNameRowFrame.midY), in: g))
        XCTAssertEqual(vm.dropTarget, .pinnedAreaTop)
        XCTAssertTrue(vm.performDrop(on: .pinnedAreaTop))
        XCTAssertEqual(vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).first?.id, f.today2)
        vm.stop()
    }

    /// [06 §15.4] observed: the dead zone between the divider and "+ New Tab" shows no indicator,
    /// and a release there changes nothing (inferred).
    func testDeadZoneShowsNothingAndDropsNothing() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let divider = g.entries.first { $0.kind == .divider }!.frame
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: divider.minY + 2), in: g))
        XCTAssertNotNil(vm.dropTarget)
        XCTAssertFalse(vm.updateDropTarget(at: CGPoint(x: listX, y: divider.maxY + 4), in: g))
        XCTAssertNil(vm.dropTarget, "the indicator disappears in the dead zone")
        vm.stop()
    }

    /// [06 §15.9] observed: Esc during a drag removes the indicator at once, and the release after
    /// it changes nothing, even on a valid target.
    func testEscapeCancelsDrag() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let before = vm.workspace
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: listX, y: rowFrame(f.today3, in: g).minY + 2), in: g))
        XCTAssertNotNil(vm.dropTarget)
        vm.dragSessionEnded() // Esc ends the AppKit session
        XCTAssertNil(vm.dropTarget)
        XCTAssertNil(vm.draggingItem)
        XCTAssertFalse(vm.performDrop(on: .row(f.today3, .above)), "a later release does nothing")
        XCTAssertEqual(vm.workspace, before)
        vm.stop()
    }

    /// [06 §15.6] observed: x < ≈ 20 pt is the left edge (22 pt does not trigger, 18 pt does); the
    /// right edge triggers at 4 pt from the edge but not at 20 pt.
    func testEdgeSwitchBands() {
        let w = layout.width
        XCTAssertEqual(SidebarEdgeSwitch.direction(x: 18, sidebarWidth: w), -1)
        XCTAssertNil(SidebarEdgeSwitch.direction(x: 22, sidebarWidth: w))
        XCTAssertEqual(SidebarEdgeSwitch.direction(x: w - 4, sidebarWidth: w), 1)
        XCTAssertNil(SidebarEdgeSwitch.direction(x: w - 20, sidebarWidth: w))
        XCTAssertNil(SidebarEdgeSwitch.direction(x: w / 2, sidebarWidth: w))
        XCTAssertNil(SidebarEdgeSwitch.direction(x: 5, sidebarWidth: 0), "unknown width")
        XCTAssertGreaterThanOrEqual(SidebarLocalTokens.edgeSwitchLeftDelay, 0.5)
        XCTAssertLessThanOrEqual(SidebarLocalTokens.edgeSwitchLeftDelay, 1.5)
        XCTAssertEqual(SidebarLocalTokens.edgeSwitchRightDelay, 0.8, accuracy: 0.05)
        XCTAssertLessThanOrEqual(SidebarLocalTokens.dockSwitchDelay, 1, "[06 §15.6] dot hover within 1 s")
    }

    /// [06 §15.6] observed: resting at the right edge switches to the next Space, at the left edge to
    /// the previous one; leaving the edge first cancels; Esc afterwards does not switch back.
    func testEdgeSwitchChangesSpaceDuringDrag() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        vm.edgeSwitchRightDelay = 0.03
        vm.edgeSwitchLeftDelay = 0.03
        vm.beginDrag(.tab(f.today1))
        let y = rowFrame(f.today2, in: g).midY
        vm.updateDropTarget(at: CGPoint(x: layout.width - 3, y: y), in: g)
        XCTAssertEqual(vm.edgeSwitchDirection, 1)
        XCTAssertEqual(vm.selectedSpaceID, f.home, "not before the delay")
        let switched = await waitUntil { vm.selectedSpaceID == f.work }
        XCTAssertTrue(switched)
        XCTAssertEqual(vm.draggingItem, .tab(f.today1), "the drag continues")
        // Left edge: back to the previous Space.
        vm.updateDropTarget(at: CGPoint(x: 5, y: y), in: g)
        let back = await waitUntil { vm.selectedSpaceID == f.home }
        XCTAssertTrue(back)
        // Leaving the edge before the delay cancels.
        vm.edgeSwitchRightDelay = 0.1
        vm.updateDropTarget(at: CGPoint(x: layout.width - 3, y: y), in: g)
        vm.updateDropTarget(at: CGPoint(x: 100, y: y), in: g)
        XCTAssertNil(vm.edgeSwitchDirection)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        // Switch, then Esc: the Space stays.
        vm.edgeSwitchRightDelay = 0.02
        vm.updateDropTarget(at: CGPoint(x: layout.width - 3, y: y), in: g)
        _ = await waitUntil { vm.selectedSpaceID == f.work }
        vm.dragSessionEnded()
        XCTAssertEqual(vm.selectedSpaceID, f.work, "Esc does not switch back")
        vm.stop()
    }

    /// [06 §15.7] observed: a Today tab dropped on the web panel forms a split with the tab shown
    /// there, on the pointer's side; a pinned tab stays and a new split row appears in Today.
    func testWebPanelDropCreatesSplit() throws {
        let f = SidebarFixture()
        let panel = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SidebarWebPanelDrop.target(at: CGPoint(x: 100, y: 10), panes: [.init(tabID: f.today3, frame: panel)])?.side, .leading)
        XCTAssertEqual(SidebarWebPanelDrop.target(at: CGPoint(x: 900, y: 10), panes: [.init(tabID: f.today3, frame: panel)])?.side, .trailing)
        XCTAssertNil(SidebarWebPanelDrop.target(at: CGPoint(x: 1100, y: 10), panes: [.init(tabID: f.today3, frame: panel)]))

        // Today tab onto the page of today3, left half.
        var (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today3)
        vm.beginDrag(.tab(f.today1))
        XCTAssertTrue(vm.performWebPanelDrop(onTab: f.today3, side: .leading))
        let layout1 = try XCTUnwrap(vm.workspace.splits.values.first { !$0.meta.isTombstone })
        XCTAssertEqual(layout1.root.tabIDs, [f.today1, f.today3])
        XCTAssertEqual(vm.selectedTabID, f.today1)
        XCTAssertNil(vm.draggingItem)
        vm.stop()

        // Pinned tab onto the page of today3, right half: the pinned tab stays; a copy joins.
        (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today3)
        vm.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm.performWebPanelDrop(onTab: f.today3, side: .trailing))
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.location, .pinned(spaceID: f.home, folderID: nil), "pinned original stays")
        let layout2 = try XCTUnwrap(vm.workspace.splits.values.first { !$0.meta.isTombstone })
        XCTAssertEqual(layout2.root.tabIDs.first, f.today3)
        let copy = try XCTUnwrap(layout2.root.tabIDs.last)
        XCTAssertNotEqual(copy, f.pinnedTab)
        XCTAssertEqual(vm.workspace.tabs[copy]?.location, .today(spaceID: f.home))
        XCTAssertEqual(vm.workspace.tabs[copy]?.url, vm.workspace.tabs[f.pinnedTab]?.url)
        XCTAssertNotNil(vm.snapshot.splitGroup(layoutID: layout2.id), "a split row in Today")
        XCTAssertEqual(vm.selectedTabID, copy)

        // Onto its own page, or without a tab drag: nothing.
        vm.beginDrag(.tab(f.today2))
        XCTAssertFalse(vm.performWebPanelDrop(onTab: f.today2, side: .leading))
        vm.beginDrag(.folder(f.folderA))
        XCTAssertFalse(vm.performWebPanelDrop(onTab: f.today2, side: .leading))
        vm.stop()
    }

    /// B19, real mouse: the press that starts the drag selects the dragged tab ([06 §15.1]), so the
    /// single panel shows that tab when the drop lands. The drop still pairs with the page that was
    /// current before the press ([06 §15.7] observed), instead of being refused.
    func testWebPanelDropAfterPressSelectPairsWithPreviousPage() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today3)
        vm.pressSelect(.tab(f.today1))
        XCTAssertEqual(vm.selectedTabID, f.today1, "mouse-down selects")
        vm.beginDrag(.tab(f.today1))
        // The panel now shows today1 itself.
        let partner = try XCTUnwrap(vm.webPanelDropPartner(forPane: f.today1))
        XCTAssertEqual(partner, f.today3)
        XCTAssertTrue(vm.performWebPanelDrop(onTab: partner, side: .trailing))
        let layout = try XCTUnwrap(vm.workspace.splits.values.first { !$0.meta.isTombstone })
        XCTAssertEqual(layout.root.tabIDs, [f.today3, f.today1])
        XCTAssertEqual(vm.selectedTabID, f.today1)

        // Without a previous page (the press did not change the selection) the drop is refused.
        vm.pressSelect(.tab(f.today2))
        vm.pressSelect(.tab(f.today2))
        vm.beginDrag(.tab(f.today2))
        XCTAssertNil(vm.webPanelDropPartner(forPane: f.today2))
        vm.endDrag()
        vm.stop()
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
