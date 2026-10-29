import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// The list's computed geometry: every entry has a fixed height ([07 §1, §4] observed: row pitch
/// 41, the 17 pt divider, "+ New Tab" right under it, a 3 pt spacer on top), so only the rows near
/// the visible area are built and their frames come from the scroll offset.
final class SidebarListGeometryTests: XCTestCase {
    private let f = SidebarFixture()

    private func snapshot(_ ws: WorkspaceState? = nil) -> SidebarSnapshot {
        SidebarSnapshot.make(workspace: ws ?? f.ws, spaceID: f.home, profileID: f.profile)
    }

    /// [07 §1, §4] observed: the same frames as `SidebarLayout.listItemFrames` (the drag, drop and
    /// menu code agree on where a row is), plus the trailing drop space (B33).
    func testEntriesMatchTheLayoutFrames() {
        let snap = snapshot()
        let layout = SidebarLayout()
        let geometry = SidebarListGeometry(snapshot: snap, layout: layout)
        let frames = layout.listItemFrames(snap.listKinds)
        XCTAssertEqual(geometry.entries.count, frames.count)
        for (entry, frame) in zip(geometry.entries, frames) {
            // Layout frames are in window space from `firstRowTop`; entries in content space.
            XCTAssertEqual(entry.top, frame.minY - layout.firstRowTop + CGFloat(Metrics.Sidebar.listTopSpacer), accuracy: 0.001)
            XCTAssertEqual(entry.height, frame.height, accuracy: 0.001)
        }
        XCTAssertEqual(geometry.entries.map(\.id), snap.pinned.map { .row($0.id) } + [.divider, .newTabRow] + snap.today.map { .row($0.id) })
        XCTAssertEqual(geometry.contentHeight, geometry.entries.last!.bottom + SidebarLocalTokens.listTrailingSpace, accuracy: 0.001)
        XCTAssertEqual(geometry.rowIndex[f.pinnedTab], snap.pinned.firstIndex { $0.id == f.pinnedTab })
    }

    /// The band search returns exactly the entries overlapping the range.
    func testRangeIsTheOverlappingEntries() {
        let geometry = SidebarListGeometry(snapshot: snapshot())
        for (minY, maxY) in [(0.0, 10.0), (40.0, 130.0), (250.0, 260.0), (-50.0, 5_000.0), (5_000.0, 6_000.0)] {
            let expected = geometry.entries.indices.filter { geometry.entries[$0].bottom > minY && geometry.entries[$0].top < maxY }
            XCTAssertEqual(Array(geometry.range(overlapping: minY, maxY)), expected, "\(minY)..<\(maxY)")
        }
        XCTAssertTrue(geometry.range(overlapping: 10, 10).isEmpty)
    }

    /// Frames for the drop hit-test: the rows in the visible list plus one on each side, shifted
    /// by the scroll offset; the divider and "+ New Tab" become drop regions.
    func testVisibleFramesFollowTheScrollOffset() {
        let snap = snapshot()
        let layout = SidebarLayout()
        let geometry = SidebarListGeometry(snapshot: snap, layout: layout)
        let pitch = layout.rowHeight
        // Viewport of 2 rows, scrolled by 3 rows: rows 3 and 4 show (the 3 pt spacer puts a sliver
        // of row 2 in view too).
        let offset = 3 * pitch
        let viewport = CGRect(x: 0, y: layout.listTop, width: layout.width, height: 2 * pitch)
        let visible = geometry.visibleFrames(contentMinY: -offset, viewport: viewport, layout: layout)
        let fourth = snap.pinned[3].id
        XCTAssertEqual(visible.rows[fourth]?.minY ?? -1, layout.listTop + CGFloat(Metrics.Sidebar.listTopSpacer) + 3 * pitch - offset, accuracy: 0.001)
        XCTAssertNotNil(visible.rows[snap.pinned[1].id], "one row above the visible ones")
        XCTAssertNil(visible.rows[snap.pinned[0].id], "rows further away are left out")
        XCTAssertNil(visible.regions[.divider])
        // Scrolled to the end: the divider and "+ New Tab" are visible regions.
        let end = geometry.visibleFrames(contentMinY: -(geometry.contentHeight - 600), viewport: CGRect(x: 0, y: layout.listTop, width: layout.width, height: 600), layout: layout)
        XCTAssertNotNil(end.regions[.divider])
        XCTAssertNotNil(end.regions[.newTabRow])
        XCTAssertEqual(geometry.rootFrame(ofRow: fourth, contentMinY: -offset, layout: layout), visible.rows[fourth])
    }

    /// The one-pass snapshot builds the same rows as walking `pinnedChildren` folder by folder
    /// ([06 §3, §12] observed: collapsed folders hide their children, order by sort key).
    func testSnapshotMatchesThePinnedChildrenWalk() throws {
        var ws = try TreeOps.setFolderExpanded(f.ws, id: f.folderB, isExpanded: false, now: f.now)
        ws = try TreeOps.openTab(ws, id: SidebarFixture.id(900), spaceID: f.work, url: URL(string: "https://other.example.com"), title: "other", now: f.now)
        var expected: [UUID] = []
        func walk(_ folderID: UUID?) {
            for child in ws.pinnedChildren(spaceID: f.home, folderID: folderID) {
                expected.append(child.id)
                if case .folder(let folder) = child, folder.isExpanded { walk(folder.id) }
            }
        }
        walk(nil)
        let snap = snapshot(ws)
        XCTAssertEqual(snap.pinned.map(\.id), expected)
        XCTAssertEqual(snap.today.map(\.id), ws.today(spaceID: f.home).map(\.id))
    }

    /// The row band follows the scroll offset in row-pitch steps, so a scroll within a row does
    /// not rebuild rows, and it covers the viewport plus the margin on each side.
    @MainActor
    func testRowBandMovesInSteps() {
        let window = SidebarListWindow()
        window.update(offset: 0, viewportHeight: 700)
        XCTAssertEqual(window.minY, 0)
        let firstMax = window.maxY
        XCTAssertGreaterThanOrEqual(firstMax, 700 + SidebarListWindow.margin)
        window.update(offset: 10, viewportHeight: 700)
        XCTAssertEqual(window.maxY, firstMax, "a scroll within one row keeps the band")
        window.update(offset: 10_000, viewportHeight: 700)
        XCTAssertLessThanOrEqual(window.minY, 10_000 - SidebarListWindow.margin)
        XCTAssertGreaterThanOrEqual(window.maxY, 10_000 + 700 + SidebarListWindow.margin)
    }

    /// The memoized snapshot changes with the workspace and with the window's own state.
    @MainActor
    func testSnapshotCacheFollowsItsInputs() {
        let (vm, _) = makeSidebarViewModel()
        defer { vm.stop() }
        let before = vm.snapshot
        XCTAssertTrue(vm.listContent === vm.listContent, "one object until an input changes")
        vm.toggleFolder(f.folderA)
        XCTAssertNotEqual(vm.snapshot.pinned.map(\.id), before.pinned.map(\.id), "a workspace change rebuilds it")
        vm.toggleCollapsePinned()
        XCTAssertTrue(vm.snapshot.pinned.isEmpty, "Collapse Pinned Tabs rebuilds it")
        vm.toggleCollapsePinned()
        vm.selectSpace(f.work)
        XCTAssertEqual(vm.snapshot.today.map(\.id), [f.workTab], "a Space switch rebuilds it")
    }

    // MARK: B99

    /// B99: the band moves one row pitch at a time with a fixed margin, so a fast fling builds a
    /// row or two per frame instead of a burst of rows every few frames.
    @MainActor
    func testRowBandMovesOneRowAtATime() {
        let window = SidebarListWindow()
        window.update(offset: 5_000, viewportHeight: 700)
        let (minY, maxY) = (window.minY, window.maxY)
        XCTAssertLessThanOrEqual(minY, 5_000 - SidebarListWindow.margin)
        XCTAssertGreaterThanOrEqual(maxY, 5_000 + 700 + SidebarListWindow.margin)
        XCTAssertLessThan(maxY - minY, 700 + 2 * SidebarListWindow.margin + 2 * SidebarListWindow.step, "no more than the margin is built")
        window.update(offset: 5_000 + 50, viewportHeight: 700)
        XCTAssertLessThanOrEqual(window.maxY - maxY, 2 * SidebarListWindow.step, "one frame of a fling adds a row or two")
    }

    /// B99: selecting a tab only stamps its activity time; the list keeps the same rows object, so
    /// no row is rebuilt. A change the rows draw (a rename) still makes a new one.
    @MainActor
    func testSelectingKeepsTheListRows() throws {
        let (vm, _) = makeSidebarViewModel()
        defer { vm.stop() }
        let before = vm.listContent
        vm.selectTab(f.today2)
        XCTAssertEqual(vm.selectedTabID, f.today2)
        XCTAssertNotEqual(vm.workspace.tabs[f.today2]?.lastActiveAt, f.now, "the activity time was stamped")
        XCTAssertTrue(vm.listContent === before, "same rows after a selection")
        vm.commitRename(f.today2, text: "Renamed")
        XCTAssertFalse(vm.listContent === before, "a rename rebuilds the rows")
        XCTAssertEqual(vm.snapshot.today.first { $0.id == f.today2 }.flatMap {
            if case .tab(let tab) = $0.kind { return tab.displayTitle } else { return nil }
        }, "Renamed")
    }

    /// B99: switching back to a Space reuses its rows (no walk of a large Space per switch).
    @MainActor
    func testSwitchingBackReusesTheSpaceRows() {
        let (vm, _) = makeSidebarViewModel()
        defer { vm.stop() }
        let home = vm.listContent
        vm.selectSpace(f.work)
        XCTAssertEqual(vm.snapshot.today.map(\.id), [f.workTab])
        vm.selectSpace(f.home)
        XCTAssertTrue(vm.listContent === home, "the Home rows are reused")
    }

    /// B99: the selected row (own row or split-group row) is an index lookup.
    @MainActor
    func testSelectedListRowIDLookup() throws {
        let (vm, _) = makeSidebarViewModel()
        defer { vm.stop() }
        vm.selectTab(f.pinnedTab)
        XCTAssertEqual(vm.selectedListRowID, f.pinnedTab)
        vm.selectTab(f.fav1)
        XCTAssertNil(vm.selectedListRowID, "a favorite has no list row")
        let geometry = SidebarListGeometry(snapshot: snapshot())
        XCTAssertEqual(geometry.rowID(showingTab: f.today1), f.today1)
        let collapsed = try TreeOps.setFolderExpanded(f.ws, id: f.folderA, isExpanded: false, now: f.now)
        XCTAssertNil(SidebarListGeometry(snapshot: snapshot(collapsed)).rowID(showingTab: f.inFolderTab), "hidden in a collapsed folder")
    }

    /// B99: rows get their state by value. Hovering publishes nothing, selecting changes only the
    /// two rows involved.
    @MainActor
    func testRowStatesChangeOnlyForTheRowsInvolved() {
        let (vm, _) = makeSidebarViewModel()
        defer { vm.stop() }
        vm.selectTab(f.today1)
        let palette = vm.palette
        func states() -> [UUID: SidebarTabRowState] {
            var result: [UUID: SidebarTabRowState] = [:]
            for item in vm.snapshot.pinned + vm.snapshot.today {
                if case .tab(let tab) = item.kind { result[tab.id] = vm.tabRowState(tab, depth: item.depth, area: item.area, palette: palette) }
            }
            return result
        }
        let before = states()
        var publishes = 0
        let watch = vm.objectWillChange.sink { publishes += 1 }
        vm.hoverBegan(f.today2)
        vm.hoverEnded(f.today2)
        XCTAssertEqual(publishes, 0, "hovering a row publishes nothing")
        watch.cancel()
        vm.selectTab(f.today2)
        let after = states()
        let changed = Set(before.keys.filter { before[$0] != after[$0] })
        XCTAssertEqual(changed, [f.today1, f.today2], "only the old and new selection change")
    }
}
