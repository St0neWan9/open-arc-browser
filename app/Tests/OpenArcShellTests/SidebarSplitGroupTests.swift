import XCTest
import OpenArcModel
@testable import OpenArcShell

/// The sidebar shows the tabs of a split as ONE grouped row.
/// Spec: [06 §5] observed: "the two split tabs are treated as one group in the sidebar". The spec
/// says nothing else about the group (look, position, close, drag), so position-of-first-member,
/// selection of the focused pane, close-all, drag-as-unit, drop-as-before/after and the keyboard
/// order are inferred; the tests pin those choices down. Row metrics: [04 §sidebar] observed.
@MainActor
final class SidebarSplitGroupTests: XCTestCase {

    private let layoutID = SidebarFixture.id(900)
    private let layout = SidebarLayout()

    /// Fixture with a split of `left` | `right` (`left` is the existing tab, as in [06 §5]).
    private func fixture(_ left: UUID, _ right: UUID, configure: (inout SidebarFixture) throws -> Void = { _ in }) -> SidebarFixture {
        var f = SidebarFixture()
        do {
            try configure(&f)
            f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: left, newTabID: right, now: f.now)
        } catch {
            fatalError("fixture is invalid: \(error)")
        }
        return f
    }

    /// Today order is today3, today2, today1; the split is today1 (left) | today2 (right).
    private func todaySplit() -> SidebarFixture { fixture(SidebarFixture().today1, SidebarFixture().today2) }

    private func snapshot(_ f: SidebarFixture) -> SidebarSnapshot {
        SidebarSnapshot.make(workspace: f.ws, spaceID: f.home, profileID: f.profile)
    }

    private func group(_ f: SidebarFixture) -> SidebarSplitGroup? { snapshot(f).splitGroup(layoutID: layoutID) }

    private func plan(_ f: SidebarFixture, _ item: SidebarDragItem, _ target: SidebarDropTarget) -> SidebarDropPlan? {
        SidebarDropPlanner.plan(item: item, target: target, workspace: f.ws, spaceID: f.home, profileID: f.profile)
    }

    // MARK: Snapshot [06 §5]

    /// The members share one row, placed where the first member (by sidebar order) was.
    func testSnapshotGroupsMembersIntoOneRowAtFirstMembersPosition() {
        let f = todaySplit()
        let snap = snapshot(f)
        // Plain Today order is today3, today2, today1; today2 comes first, so the row takes its slot.
        XCTAssertEqual(snap.today.map(\.id), [f.today3, layoutID])
        let g = snap.splitGroup(layoutID: layoutID)
        XCTAssertEqual(g?.sidebarOrder, [f.today2, f.today1])
        XCTAssertEqual(g?.anchorID, f.today2)
        // Pane order is the layout order: the existing tab left, the new one right.
        XCTAssertEqual(g?.members.map(\.id), [f.today1, f.today2])
        XCTAssertEqual(snap.pinned.map(\.id), snapshot(SidebarFixture()).pinned.map(\.id), "pinned area untouched")
        XCTAssertEqual(snap.listKinds.filter { $0 == .row }.count, snap.pinned.count + 2)
    }

    /// The group row replaces its members only: no member keeps a row of its own.
    func testMembersHaveNoSeparateRows() {
        let f = todaySplit()
        let ids = (snapshot(f).pinned + snapshot(f).today).map(\.id)
        XCTAssertFalse(ids.contains(f.today1))
        XCTAssertFalse(ids.contains(f.today2))
    }

    /// A group whose first member is pinned sits in the pinned area; its Today member leaves Today.
    func testGroupAcrossAreasTakesThePinnedPosition() {
        let f = fixture(SidebarFixture().pinnedTab, SidebarFixture().today1)
        let snap = snapshot(f)
        XCTAssertEqual(snap.pinned.last?.id, layoutID)
        XCTAssertEqual(snap.pinned.last?.area, .pinned)
        XCTAssertFalse(snap.today.contains { $0.id == f.today1 })
        XCTAssertEqual(snap.today.map(\.id), [f.today3, f.today2])
    }

    /// The row keeps the depth of the first member (a group inside a folder is indented).
    func testGroupKeepsDepthOfItsFirstMember() {
        let f = fixture(SidebarFixture().inFolderTab, SidebarFixture().deepTab)
        let item = snapshot(f).pinned.first { $0.id == layoutID }
        XCTAssertEqual(item?.depth, 2, "deepTab (inside folder B, depth 2) is listed before inFolderTab (depth 1)")
    }

    /// A layout with a single visible member (the other is a favorite) stays a plain row, and a
    /// tombstoned layout never groups.
    func testNoGroupWithoutTwoVisibleMembers() {
        let favSplit = fixture(SidebarFixture().today1, SidebarFixture().fav1)
        XCTAssertNil(group(favSplit))
        XCTAssertTrue(snapshot(favSplit).today.contains { $0.id == favSplit.today1 })
        XCTAssertEqual(snapshot(favSplit).favorites.count, 2, "favorites stay in the favorites block")

        var dead = todaySplit()
        dead.ws = TreeOps.removeSplitPane(dead.ws, tabID: dead.today1, now: dead.now)
        XCTAssertNil(group(dead))
        XCTAssertEqual(snapshot(dead).today.map(\.id), [dead.today3, dead.today2, dead.today1])
    }

    /// Three panes make one group of three; the order follows the panes.
    func testThreePaneGroup() throws {
        var f = todaySplit()
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: UUID(), existingTabID: f.today2, newTabID: f.today3, now: f.now)
        let g = group(f)
        XCTAssertEqual(g?.members.map(\.id), [f.today1, f.today2, f.today3])
        XCTAssertEqual(snapshot(f).today.map(\.id), [layoutID])
    }

    // MARK: Selection [06 §5]

    /// Selecting the row selects the focused pane tab; without any focus yet it is the first member
    /// by sidebar order, and a later selection of a pane is remembered.
    func testSelectingGroupSelectsFocusedPane() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectSplitGroup(layoutID)
        XCTAssertEqual(vm.selectedTabID, f.today2, "no focus yet: the first member by sidebar order")
        XCTAssertTrue(vm.isGroupSelected(vm.snapshot.splitGroup(layoutID: layoutID)!))

        vm.selectTab(f.today1)
        vm.selectTab(f.pinnedTab)
        XCTAssertFalse(vm.isGroupSelected(vm.snapshot.splitGroup(layoutID: layoutID)!))
        vm.selectSplitGroup(layoutID)
        XCTAssertEqual(vm.selectedTabID, f.today1, "returns to the pane that was focused last")
        vm.stop()
    }

    /// Either pane being selected highlights the one row; clicking it again keeps the focused pane.
    func testGroupRowStaysSelectedForEitherPane() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        let g = vm.snapshot.splitGroup(layoutID: layoutID)!
        vm.selectTab(f.today1)
        XCTAssertTrue(vm.isGroupSelected(g))
        vm.selectSplitGroup(layoutID)
        XCTAssertEqual(vm.selectedTabID, f.today1)
        vm.selectTab(f.today2)
        XCTAssertTrue(vm.isGroupSelected(g))
        vm.selectSplitGroup(layoutID)
        XCTAssertEqual(vm.selectedTabID, f.today2)
        vm.stop()
    }

    // MARK: Close [06 §5]

    /// ✕ on a Today group archives every member (inferred), tombstones the layout and moves the
    /// selection to the neighboring row.
    func testCloseGroupArchivesAllMembers() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        vm.closeSplitGroup(layoutID)
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.meta.isTombstone, true)
        XCTAssertEqual(vm.workspace.tabs[f.today2]?.meta.isTombstone, true)
        XCTAssertEqual(vm.workspace.splits[layoutID]?.meta.isTombstone, true)
        XCTAssertEqual(vm.workspace.archive.values.filter { !$0.meta.isTombstone }.count, 2)
        XCTAssertEqual(vm.snapshot.today.map(\.id), [f.today3])
        XCTAssertEqual(vm.selectedTabID, f.today3)
        vm.stop()
    }

    /// Closing a group that is not selected leaves the selection alone.
    func testCloseUnselectedGroupKeepsSelection() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.pinnedTab)
        vm.closeSplitGroup(layoutID)
        XCTAssertEqual(vm.selectedTabID, f.pinnedTab)
        XCTAssertNil(vm.snapshot.splitGroup(layoutID: layoutID))
        vm.stop()
    }

    /// Closing one pane of a group (⌃⇧-) hands focus to the sibling pane, as when the panes were
    /// separate rows; the row then turns back into a plain tab row.
    func testClosingOnePaneFocusesSiblingAndUngroups() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        vm.closeTab(f.today1)
        XCTAssertEqual(vm.selectedTabID, f.today2)
        XCTAssertNil(vm.snapshot.splitGroup(layoutID: layoutID))
        XCTAssertEqual(vm.snapshot.today.map(\.id), [f.today3, f.today2])
        vm.stop()
    }

    // MARK: Drag as a unit [06 §5], [06 §12]

    /// A group drags as a unit: the plan moves every member, keeping their sidebar order.
    func testGroupDragPlansMoveOfAllMembers() {
        let f = todaySplit()
        let pinnedTop = TabLocation.pinned(spaceID: f.home, folderID: nil)
        XCTAssertEqual(plan(f, .splitGroup(layoutID), .pinnedAreaTop)?.action,
                       .moveTabs(ids: [f.today2, f.today1], to: pinnedTop, position: .first))
        XCTAssertEqual(plan(f, .splitGroup(layoutID), .pinnedAreaEnd)?.action,
                       .moveTabs(ids: [f.today2, f.today1], to: pinnedTop, position: .last))
        XCTAssertEqual(plan(f, .splitGroup(layoutID), .row(f.pinnedTab, .below))?.action,
                       .moveTabs(ids: [f.today2, f.today1], to: pinnedTop, position: .after(f.pinnedTab)))
        let into = plan(f, .splitGroup(layoutID), .row(f.folderC, .into))
        XCTAssertEqual(into?.action, .moveTabs(ids: [f.today2, f.today1], to: .pinned(spaceID: f.home, folderID: f.folderC), position: .first))
        XCTAssertEqual(into?.expandFolderID, f.folderC)
    }

    /// Refused: onto itself, into favorites, onto its own Space's dock icon, an unknown layout.
    func testGroupDragRejections() {
        let f = todaySplit()
        XCTAssertNil(plan(f, .splitGroup(layoutID), .row(layoutID, .above)))
        XCTAssertNil(plan(f, .splitGroup(layoutID), .favoriteGap(0)))
        XCTAssertNil(plan(f, .splitGroup(layoutID), .dockSpace(f.home)))
        XCTAssertNil(plan(f, .splitGroup(UUID()), .pinnedAreaTop))
    }

    /// A group dropped on another Space's dock icon moves as a unit, layout included, to the top of
    /// that Space's Today area (inferred; [06 §5] observed the group is one unit, [06 §12] lists
    /// cross-Space drags as untested).
    func testGroupDropOnDockIconMovesWholeGroupToThatSpace() throws {
        let f = todaySplit()
        XCTAssertEqual(plan(f, .splitGroup(layoutID), .dockSpace(f.work))?.action,
                       .moveSplitLayout(id: layoutID, toSpace: f.work, position: .first))

        let (vm, _) = makeSidebarViewModel(f)
        var notifications = 0
        vm.onWorkspaceChange = { _ in notifications += 1 }
        vm.beginDrag(.splitGroup(layoutID))
        XCTAssertTrue(vm.performDrop(on: .dockSpace(f.work)))
        XCTAssertEqual(notifications, 1, "one mutation")
        XCTAssertEqual(vm.workspace.splits[layoutID]?.spaceID, f.work)
        let today = vm.workspace.today(spaceID: f.work).map(\.id)
        XCTAssertEqual(Array(today.prefix(2)), [f.today2, f.today1], "members land together, in sidebar order")
        XCTAssertFalse(vm.workspace.today(spaceID: f.home).map(\.id).contains(f.today1))
        let workSnapshot = SidebarSnapshot.make(workspace: vm.workspace, spaceID: f.work, profileID: f.profile)
        XCTAssertEqual(workSnapshot.today.first?.id, layoutID, "still one group row, now in the other Space")
        vm.stop()
    }

    /// The per-tab steps keep the members adjacent and in order for every position kind.
    func testMoveStepsKeepMembersTogetherInOrder() {
        let a = SidebarFixture.id(1), b = SidebarFixture.id(2), x = SidebarFixture.id(3)
        func steps(_ p: InsertPosition) -> [String] {
            SidebarDropPlanner.moveSteps(ids: [a, b], position: p).map { "\($0.id.uuidString.suffix(1)):\($0.position)" }
        }
        XCTAssertEqual(SidebarDropPlanner.moveSteps(ids: [a, b], position: .first).map(\.id), [b, a], "front inserts reverse")
        XCTAssertEqual(SidebarDropPlanner.moveSteps(ids: [a, b], position: .last).map(\.id), [a, b])
        XCTAssertEqual(SidebarDropPlanner.moveSteps(ids: [a, b], position: .before(x)).map(\.position), [.before(x), .before(x)])
        XCTAssertEqual(SidebarDropPlanner.moveSteps(ids: [a, b], position: .after(x)).map(\.position), [.after(x), .after(a)])
        XCTAssertEqual(steps(.last).count, 2)
    }

    /// Dropping a group moves every member in ONE mutation (one workspace notification), keeps them
    /// together and in order, and the group stays a group at the new place.
    func testPerformDropMovesGroupAsUnit() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        var notifications = 0
        vm.onWorkspaceChange = { _ in notifications += 1 }
        vm.beginDrag(.splitGroup(layoutID))
        XCTAssertTrue(vm.performDrop(on: .pinnedAreaTop))
        XCTAssertEqual(notifications, 1)
        let top = vm.workspace.pinnedChildren(spaceID: f.home, folderID: nil).map(\.id)
        XCTAssertEqual(Array(top.prefix(2)), [f.today2, f.today1])
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.location, .pinned(spaceID: f.home, folderID: nil))
        XCTAssertEqual(vm.snapshot.pinned.first?.id, layoutID, "one row, at the top of the pinned area")
        XCTAssertEqual(vm.snapshot.splitGroup(layoutID: layoutID)?.sidebarOrder, [f.today2, f.today1])
        XCTAssertNil(vm.draggingItem)

        // Back to the end of Today, after the other tab: order and grouping survive.
        vm.beginDrag(.splitGroup(layoutID))
        XCTAssertTrue(vm.performDrop(on: .todayAreaEnd))
        XCTAssertEqual(vm.workspace.today(spaceID: f.home).map(\.id), [f.today3, f.today2, f.today1])
        XCTAssertNotNil(vm.snapshot.splitGroup(layoutID: layoutID))
        vm.stop()
    }

    /// The drag preview names the members.
    func testDragTitleJoinsMemberTitles() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        XCTAssertEqual(vm.dragTitle(for: .splitGroup(layoutID)), "today1 | today2")
        vm.stop()
    }

    /// The pasteboard payload round-trips the group item.
    func testDragPayloadRoundTrip() {
        let item = SidebarDragItem.splitGroup(layoutID)
        XCTAssertEqual(SidebarDragPayload.decode(SidebarDragPayload.encode(item)), item)
    }

    // MARK: Drop onto a group [06 §5]

    /// A single tab dropped on a group row lands before or after the whole group, never between
    /// its members.
    func testDropTabOnGroupRowIsBeforeOrAfter() {
        let f = todaySplit()
        let today = TabLocation.today(spaceID: f.home)
        XCTAssertEqual(plan(f, .tab(f.pinnedTab), .row(layoutID, .above))?.action,
                       .moveTab(id: f.pinnedTab, to: today, position: .before(f.today2)))
        // Members today2, today1 are adjacent, so "after the group" anchors at the last of them.
        XCTAssertEqual(plan(f, .tab(f.pinnedTab), .row(layoutID, .below))?.action,
                       .moveTab(id: f.pinnedTab, to: today, position: .after(f.today1)))
        // No "into" semantics: a stray .into behaves like below.
        XCTAssertEqual(plan(f, .tab(f.pinnedTab), .row(layoutID, .into))?.action,
                       .moveTab(id: f.pinnedTab, to: today, position: .after(f.today1)))
    }

    /// Members that are not adjacent in the data order: "below the group" still lands right under
    /// the row (after the first member), and applying the drop keeps the group intact.
    func testDropBelowGroupWithSeparatedMembersStaysUnderTheRow() {
        let f = fixture(SidebarFixture().today3, SidebarFixture().today1)
        XCTAssertEqual(snapshot(f).today.map(\.id), [layoutID, f.today2], "today3 | today1 take today3's slot")
        let p = plan(f, .tab(f.pinnedTab), .row(layoutID, .below))
        XCTAssertEqual(p?.action, .moveTab(id: f.pinnedTab, to: .today(spaceID: f.home), position: .after(f.today3)))

        let (vm, _) = makeSidebarViewModel(f)
        vm.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm.performDrop(on: .row(layoutID, .below)))
        XCTAssertEqual(vm.snapshot.today.map(\.id), [layoutID, f.pinnedTab, f.today2])
        XCTAssertNotNil(vm.snapshot.splitGroup(layoutID: layoutID), "the group is still one row")
        vm.stop()
    }

    /// Dropping a tab right above/below a group and a folder dropped on a group follow the same rule;
    /// dropping a group onto another group row is before/after as well.
    func testFolderAndGroupOntoGroupRow() throws {
        var f = fixture(SidebarFixture().pinnedTab, SidebarFixture().today1)
        let otherLayout = SidebarFixture.id(901)
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: otherLayout, existingTabID: f.today2, newTabID: f.today3, now: f.now)
        let pinnedTop = TabLocation.pinned(spaceID: f.home, folderID: nil)
        // Folder C onto the pinned group's upper half: before the anchor, in the same container.
        XCTAssertEqual(plan(f, .folder(f.folderC), .row(layoutID, .above))?.action,
                       .moveFolder(id: f.folderC, toSpace: f.home, parent: nil, position: .before(f.pinnedTab)))
        // The Today group dropped on the pinned group's lower half.
        let g = snapshot(f).splitGroup(layoutID: otherLayout)!
        XCTAssertEqual(plan(f, .splitGroup(otherLayout), .row(layoutID, .below))?.action,
                       .moveTabs(ids: g.sidebarOrder, to: pinnedTop, position: .after(f.pinnedTab)))
        // Folders do not go into Today, with or without a group.
        XCTAssertNil(plan(f, .folder(f.folderC), .row(otherLayout, .above)))
    }

    // MARK: Hit testing [04 §sidebar]

    private func geometry(_ f: SidebarFixture) -> (SidebarDropGeometry, SidebarSnapshot) {
        let snap = snapshot(f)
        let frames = layout.listItemFrames(snap.listKinds)
        var rowFrames: [UUID: CGRect] = [:]
        var regions: [SidebarDropRegion: CGRect] = [:]
        var index = 0
        for item in snap.pinned { rowFrames[item.id] = frames[index]; index += 1 }
        if snap.showsDivider { regions[.divider] = frames[index]; index += 1 }
        regions[.newTabRow] = frames[index]; index += 1
        for item in snap.today { rowFrames[item.id] = frames[index]; index += 1 }
        let top = layout.listTop
        regions[.list] = CGRect(x: 0, y: top, width: layout.contentWidth, height: layout.dockFrame.minY - top)
        regions[.favorites] = layout.favoritesFrame
        return (SidebarDropGeometry.make(snapshot: snap, dockSpaceIDs: [], rowFrames: rowFrames, regions: regions, width: layout.width), snap)
    }

    /// The group row is one entry of the hit-test geometry: tab-style halves, no "into" band, and the
    /// hidden members have no entry of their own.
    func testHitTesterTreatsGroupAsOneTabStyleRow() {
        let f = todaySplit()
        let (g, _) = geometry(f)
        let rows: [UUID] = g.entries.compactMap { if case .row(let id, _) = $0.kind { return id } else { return nil } }
        XCTAssertTrue(rows.contains(layoutID))
        XCTAssertFalse(rows.contains(f.today1))
        XCTAssertFalse(rows.contains(f.today2))
        let entry = g.entries.first { $0.kind == .row(layoutID, style: .halves) }
        XCTAssertNotNil(entry, "no into band on a group row")
        let frame = entry!.frame
        let x = frame.minX + 20
        // Upper half: the slot above the group (reported as "below today3", the row above it).
        XCTAssertEqual(SidebarDropHitTester.target(at: CGPoint(x: x, y: frame.minY + 2), in: g), .row(f.today3, .below))
        XCTAssertEqual(SidebarDropHitTester.target(at: CGPoint(x: x, y: frame.midY), in: g), .row(layoutID, .below))
        XCTAssertEqual(SidebarDropHitTester.target(at: CGPoint(x: x, y: frame.maxY - 2), in: g), .row(layoutID, .below))
    }

    /// End to end: pointer over the group row, hover feedback only for accepted drops.
    func testUpdateDropTargetOverGroupRow() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        let (g, _) = geometry(f)
        let frame = g.entries.first { $0.kind == .row(layoutID, style: .halves) }!.frame
        vm.beginDrag(.tab(f.pinnedTab))
        XCTAssertTrue(vm.updateDropTarget(at: CGPoint(x: frame.minX + 20, y: frame.maxY - 3), in: g))
        XCTAssertEqual(vm.dropTarget, .row(layoutID, .below))
        vm.beginDrag(.splitGroup(layoutID))
        XCTAssertFalse(vm.updateDropTarget(at: CGPoint(x: frame.minX + 20, y: frame.maxY - 3), in: g), "onto itself")
        XCTAssertNil(vm.dropTarget)
        vm.stop()
    }

    // MARK: Keyboard order

    /// The group counts as ONE item in ⌘1–9 and Next/Previous Tab (inferred) and stands for its
    /// focused pane.
    func testKeyboardOrderCountsGroupOnce() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        // favorites, pinned rows (tabs only), then Today: today3, then the group.
        XCTAssertEqual(vm.keyboardTabOrder, [f.fav1, f.fav2, f.deepTab, f.inFolderTab, f.pinnedTab, f.today3, f.today2])
        vm.selectTab(f.today1)
        XCTAssertEqual(vm.keyboardTabOrder.last, f.today1, "the focused pane represents the group")
        XCTAssertEqual(vm.keyboardTabOrder.count, 7)
        vm.stop()
    }

    /// ⌘7 selects the group (the 7th item), ⌘9 the last item, and Next Tab steps over the group once.
    func testGoToItemAndStepTreatGroupAsOneItem() {
        let f = todaySplit()
        let (vm, _) = makeSidebarViewModel(f)
        vm.goToSidebarItem(number: 7)
        XCTAssertEqual(vm.selectedTabID, f.today2)
        vm.goToSidebarItem(number: 8)
        XCTAssertEqual(vm.selectedTabID, f.today2, "there is no 8th item: nothing changes")
        vm.selectTab(f.today3)
        vm.stepTab(by: 1)
        XCTAssertEqual(vm.selectedTabID, f.today2)
        vm.selectTab(f.today1)
        vm.stepTab(by: 1)
        XCTAssertEqual(vm.selectedTabID, f.fav1, "wraps over the single group item")
        vm.goToSidebarItem(number: 9)
        XCTAssertEqual(vm.selectedTabID, f.today1, "⌘9 is the last item: the group, via the pane focused last")
        vm.stop()
    }
}
