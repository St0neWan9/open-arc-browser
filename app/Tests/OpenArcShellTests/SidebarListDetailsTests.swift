import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Never runs autosave work: the hint tests only look at `ui-state.json`.
private struct NoAutosave: AutosaveScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {}
}

/// B76: sidebar list details: the first-pin rename hint ([06 §4]), the ↓ / ↑ jump button
/// ([06 §15.8]), the folder quick list ([06 §14]) and trackpad paging between Spaces
/// ([05 §window hierarchy]).
@MainActor
final class SidebarListDetailsTests: XCTestCase {
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b76-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    // MARK: [06 §4] first-pin "Double-click to rename"

    /// [06 §4] observed: the first pin shows the hint under the title; later pins do not.
    func testFirstPinShowsRenameHintOnce_06_4() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.pinTab(f.today1)
        XCTAssertTrue(vm.showsPinRenameHint(f.today1))
        XCTAssertTrue(vm.controller.pinRenameHintShown)
        vm.pinTab(f.today2)
        XCTAssertFalse(vm.showsPinRenameHint(f.today2), "only the first pin gets the hint")
        XCTAssertTrue(vm.showsPinRenameHint(f.today1))
    }

    /// [06 §4]: renaming (double-click) or unpinning the tab removes the hint. inferred.
    func testRenameOrUnpinClearsHint_06_4() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.pinTab(f.today1)
        vm.beginRename(f.today1)
        XCTAssertFalse(vm.showsPinRenameHint(f.today1))
        vm.cancelRename()
        XCTAssertFalse(vm.showsPinRenameHint(f.today1))

        let (other, _) = makeSidebarViewModel(f)
        defer { other.stop() }
        other.pinTab(f.today2)
        XCTAssertTrue(other.showsPinRenameHint(f.today2))
        other.unpinTab(f.today2)
        XCTAssertFalse(other.showsPinRenameHint(f.today2))
    }

    /// [06 §4]: dragging a Today tab into the pinned area is a pin too.
    func testDropIntoPinnedAreaShowsHint_06_4() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.beginDrag(.tab(f.today2))
        XCTAssertTrue(vm.performDrop(on: .row(f.pinnedTab, .above)))
        XCTAssertTrue(vm.workspace.tabs[f.today2]?.location.isPinned == true)
        XCTAssertTrue(vm.showsPinRenameHint(f.today2))
    }

    /// [06 §4]: the "shown" flag is per device in `ui-state.json` (not the synced workspace), so
    /// after a relaunch a new pin shows no hint.
    func testHintFlagPersistsPerDevice_06_4() throws {
        func launch() -> ShellModel {
            let store = WorkspaceStore(directory: directory, scheduler: NoAutosave(), now: { Date(timeIntervalSince1970: 1_000) })
            let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), persistence: store)
            let model = ShellModel(dependencies: deps, workspace: .firstLaunch(now: Date(timeIntervalSince1970: 1_000)),
                                   now: { Date(timeIntervalSince1970: 1_000) }, notificationCenter: NotificationCenter())
            addTeardownBlock { @MainActor in model.stop() }
            return model
        }
        let first = launch()
        let tab = try XCTUnwrap(first.sidebar.newTab(url: URL(string: "https://a.example"), title: "a"))
        first.sidebar.pinTab(tab)
        XCTAssertTrue(first.sidebar.showsPinRenameHint(tab))
        XCTAssertEqual(UIStateFile.load(from: directory)?.pinRenameHintShown, true)
        first.stop()

        let second = launch()
        let next = try XCTUnwrap(second.sidebar.newTab(url: URL(string: "https://b.example"), title: "b"))
        second.sidebar.pinTab(next)
        XCTAssertFalse(second.sidebar.showsPinRenameHint(next))
    }

    /// The flag decodes as false from files written before B76.
    func testOldUIStateFileHasNoHintFlag_06_4() throws {
        let data = Data(#"{"version": 1, "isSidebarVisible": true}"#.utf8)
        let state = try JSONDecoder().decode(UIState.self, from: data)
        XCTAssertFalse(state.pinRenameHintShown)
    }

    // MARK: [06 §15.8] jump button

    private let viewport = CGRect(x: 0, y: 181, width: 276, height: 400)
    private var fill: CGRect { SidebarLayout().rowFillFrame }

    /// [06 §15.8] observed: ↓ when the selected row is below the visible list, ↑ when above,
    /// nothing while any of it is visible.
    func testJumpDirection_06_15_8() {
        typealias J = SidebarSelectionJump
        XCTAssertEqual(J.direction(rowFrame: CGRect(x: 0, y: 700, width: 276, height: 41), viewport: viewport, fill: fill), .down)
        XCTAssertEqual(J.direction(rowFrame: CGRect(x: 0, y: 100, width: 276, height: 41), viewport: viewport, fill: fill), .up)
        XCTAssertNil(J.direction(rowFrame: CGRect(x: 0, y: 300, width: 276, height: 41), viewport: viewport, fill: fill))
        // Fill partly visible at the bottom edge: no button.
        XCTAssertNil(J.direction(rowFrame: CGRect(x: 0, y: viewport.maxY - 10, width: 276, height: 41), viewport: viewport, fill: fill))
        XCTAssertNil(J.direction(rowFrame: nil, viewport: viewport, fill: fill))
        XCTAssertNil(J.direction(rowFrame: CGRect(x: 0, y: 700, width: 276, height: 41), viewport: .null, fill: fill))
    }

    /// [06 §15.8] observed: the button sits at the middle of the list's bottom (↓) or top (↑).
    func testJumpButtonPlacement_06_15_8() {
        let down = SidebarSelectionJump.buttonCenter(direction: .down, viewport: viewport)
        let up = SidebarSelectionJump.buttonCenter(direction: .up, viewport: viewport)
        XCTAssertEqual(down.x, viewport.midX)
        XCTAssertEqual(up.x, viewport.midX)
        XCTAssertGreaterThan(down.y, viewport.midY)
        XCTAssertLessThan(down.y, viewport.maxY)
        XCTAssertLessThan(up.y, viewport.midY)
        XCTAssertGreaterThan(up.y, viewport.minY)
    }

    private final class FakeScroller: SidebarListScrolling {
        var metrics: SidebarScrollMetrics?
        init(_ metrics: SidebarScrollMetrics) { self.metrics = metrics }
        func scroll(toOffset offset: CGFloat) { metrics?.offset = offset }
    }

    /// [06 §15.8]: a click scrolls the selected row into the middle of the list, clamped. inferred.
    func testJumpScrollsSelectedRowIntoView_06_15_8() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        let scroller = FakeScroller(SidebarScrollMetrics(offset: 0, contentHeight: 2_000, viewportHeight: 400))
        vm.listScroller = scroller
        // Row 600 pt below the list's middle.
        let row = CGRect(x: 0, y: viewport.midY + 600 - 20.5, width: 276, height: 41)
        vm.revealSelectedRow(rowFrame: row, viewport: viewport)
        XCTAssertEqual(scroller.metrics?.offset ?? -1, 600, accuracy: 0.001)
        // Past the end: clamped to the last offset.
        let far = CGRect(x: 0, y: viewport.midY + 5_000, width: 276, height: 41)
        vm.revealSelectedRow(rowFrame: far, viewport: viewport)
        XCTAssertEqual(scroller.metrics?.offset ?? -1, 1_600, accuracy: 0.001)
        withExtendedLifetime(scroller) {}
    }

    /// The row that stands for the selection: the tab row, or nothing for a favorite.
    func testSelectedListRow_06_15_8() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.selectTab(f.today1)
        XCTAssertEqual(vm.selectedListRowID, f.today1)
        vm.selectTab(f.fav1)
        XCTAssertNil(vm.selectedListRowID)
    }

    // MARK: [06 §14] folder quick list

    /// [06 §14] observed: hovering a folder opens its quick list (after a short delay); leaving
    /// closes it. Only a collapsed folder with tabs has one (inferred).
    func testHoverOpensQuickList_06_14() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.quickListDelay = 0.02
        vm.quickListDismissDelay = 0.02

        // Expanded folder: no list.
        vm.folderHoverBegan(f.folderA)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(vm.quickListFolderID)
        vm.folderHoverEnded(f.folderA)

        vm.toggleFolder(f.folderA) // collapse
        vm.folderHoverBegan(f.folderA)
        XCTAssertNil(vm.quickListFolderID, "not before the delay")
        let opened = await waitUntil { vm.quickListFolderID == f.folderA }
        XCTAssertTrue(opened)

        vm.folderHoverEnded(f.folderA)
        let closed = await waitUntil { vm.quickListFolderID == nil }
        XCTAssertTrue(closed)

        // Empty folder (C, collapsed): no list.
        vm.toggleFolder(f.folderC)
        vm.folderHoverBegan(f.folderC)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(vm.quickListFolderID)
    }

    /// Moving from the row into the list keeps it open; leaving the list closes it.
    func testPointerInListKeepsItOpen_06_14() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.quickListDelay = 0.01
        vm.quickListDismissDelay = 0.05
        vm.toggleFolder(f.folderA)
        vm.folderHoverBegan(f.folderA)
        _ = await waitUntil { vm.quickListFolderID == f.folderA }
        vm.folderHoverEnded(f.folderA)
        vm.quickListHoverChanged(true)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(vm.quickListFolderID, f.folderA)
        vm.quickListHoverChanged(false)
        let closed = await waitUntil { vm.quickListFolderID == nil }
        XCTAssertTrue(closed)
    }

    /// [06 §14] observed: the list holds the folder's items with their relative times and a
    /// "Search <folder>…" field. Nested folders are flattened, in sidebar order (inferred).
    func testQuickListRowsAndSearch_06_14() {
        let f = SidebarFixture()
        let now = f.now.addingTimeInterval(3 * 3_600)
        let rows = FolderQuickList.rows(folderID: f.folderA, workspace: f.ws, query: "", now: now)
        XCTAssertEqual(rows.map(\.tabID), [f.deepTab, f.inFolderTab])
        XCTAssertEqual(rows.first?.relativeTime, "3h")
        XCTAssertEqual(FolderQuickList.rows(folderID: f.folderA, workspace: f.ws, query: "DEEP", now: now).map(\.tabID), [f.deepTab])
        XCTAssertTrue(FolderQuickList.rows(folderID: f.folderA, workspace: f.ws, query: "zzz", now: now).isEmpty)
        XCTAssertEqual(FolderQuickList.searchPlaceholder(folderTitle: "A"), "Search A…")
    }

    /// Relative time format (inferred).
    func testRelativeTime_06_14() {
        let base = Date(timeIntervalSince1970: 0)
        func r(_ s: TimeInterval) -> String { FolderQuickList.relativeTime(from: base, to: base.addingTimeInterval(s)) }
        XCTAssertEqual(r(10), "now")
        XCTAssertEqual(r(5 * 60), "5m")
        XCTAssertEqual(r(2 * 86_400), "2d")
        XCTAssertEqual(r(14 * 86_400), "2w")
        XCTAssertEqual(r(60 * 86_400), "2mo")
        XCTAssertEqual(r(400 * 86_400), "1y")
        XCTAssertEqual(FolderQuickList.relativeTime(from: base.addingTimeInterval(10), to: base), "now")
    }

    /// Picking an item selects that tab and closes the list; Space switches close it too.
    func testPickFromQuickList_06_14() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.quickListDelay = 0.01
        vm.toggleFolder(f.folderA)
        vm.folderHoverBegan(f.folderA)
        _ = await waitUntil { vm.quickListFolderID == f.folderA }
        vm.openFromQuickList(f.inFolderTab)
        XCTAssertNil(vm.quickListFolderID)
        XCTAssertEqual(vm.selectedTabID, f.inFolderTab)

        vm.folderHoverBegan(f.folderA)
        _ = await waitUntil { vm.quickListFolderID == f.folderA }
        vm.selectSpace(f.work)
        XCTAssertNil(vm.quickListFolderID)
    }

    // MARK: [05 §window hierarchy] trackpad swipe

    /// [05 §window hierarchy] observed: Spaces are horizontal pages switched by swiping. One
    /// gesture moves one Space; it does not wrap (inferred).
    func testSwipePagesSpaces_05_windowHierarchy() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.swipeSpace(by: 1)
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        vm.swipeSpace(by: 1)
        XCTAssertEqual(vm.selectedSpaceID, f.work, "no page after the last Space")
        vm.swipeSpace(by: -1)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.swipeSpace(by: -1)
        XCTAssertEqual(vm.selectedSpaceID, f.home, "no page before the first Space")
    }

    /// [05 §window hierarchy]: a horizontal gesture past the threshold fires once; vertical
    /// scrolling and short swipes do not.
    func testSwipeRecognizer_05_windowHierarchy() {
        var r = SidebarSwipeRecognizer()
        XCTAssertNil(r.feed(phase: .began, deltaX: -10, deltaY: 0))
        XCTAssertNil(r.feed(phase: .changed, deltaX: -20, deltaY: 1))
        XCTAssertEqual(r.feed(phase: .changed, deltaX: -30, deltaY: 1), 1)
        XCTAssertNil(r.feed(phase: .changed, deltaX: -100, deltaY: 0), "one step per gesture")
        XCTAssertNil(r.feed(phase: .ended, deltaX: 0, deltaY: 0))

        XCTAssertNil(r.feed(phase: .began, deltaX: 30, deltaY: 0))
        XCTAssertEqual(r.feed(phase: .changed, deltaX: 30, deltaY: 0), -1)
        _ = r.feed(phase: .ended, deltaX: 0, deltaY: 0)

        // Mostly vertical: list scrolling, no page.
        XCTAssertNil(r.feed(phase: .began, deltaX: 20, deltaY: 40))
        XCTAssertNil(r.feed(phase: .changed, deltaX: 40, deltaY: 80))
        _ = r.feed(phase: .ended, deltaX: 0, deltaY: 0)

        // Changes without a began (momentum after the gesture): ignored.
        XCTAssertNil(r.feed(phase: .changed, deltaX: -200, deltaY: 0))
    }

    /// No paging while a drag is running (the drag has its own edge switch, [06 §15.6]).
    func testNoSwipeDuringDrag_05_windowHierarchy() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.beginDrag(.tab(f.today1))
        vm.swipeSpace(by: 1)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.endDrag()
    }
}
