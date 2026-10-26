import XCTest
import OpenArcModel
@testable import OpenArcShell

/// Auto-scroll of the sidebar list while dragging near its top or bottom edge.
/// Spec: [06 §15.8] observed: only at the top and bottom edges of the visible list, starting
/// ≈ 13 pt from the edge (21 pt does not), after ≈ 0.3–0.5 s in the band, stopping at the content
/// ends; inferred: speed grows with depth into the band and with time (≈ 25 pt/s → hundreds).
@MainActor
final class SidebarAutoScrollTests: XCTestCase {

    private let viewport = CGRect(x: 0, y: 200, width: 220, height: 400)
    private let band = SidebarLocalTokens.autoScrollEdgeBand
    private let dwell = SidebarLocalTokens.autoScrollDwell

    /// Scrolled somewhere in the middle: both directions possible.
    private let middle = SidebarScrollMetrics(offset: 300, contentHeight: 1_000, viewportHeight: 400)

    /// Velocity once the dwell is over (no time ramp yet).
    private func velocity(_ y: CGFloat, _ metrics: SidebarScrollMetrics, time: Double? = nil) -> CGFloat {
        SidebarAutoScroll.velocity(pointerY: y, viewport: viewport, metrics: metrics, timeInBand: time ?? dwell)
    }

    // MARK: Pure velocity

    /// [06 §15.8] observed: the band is ≈ 13 pt; 21 pt from the edge does not scroll.
    func testBandIsAbout13Points() {
        XCTAssertEqual(band, 13, accuracy: 1)
        XCTAssertNotEqual(velocity(viewport.maxY - 12, middle), 0, "12 pt from the bottom edge scrolls")
        XCTAssertNotEqual(velocity(viewport.minY + 12, middle), 0, "12 pt from the top edge scrolls")
        XCTAssertEqual(velocity(viewport.maxY - 21, middle), 0, "21 pt does not")
        XCTAssertEqual(velocity(viewport.minY + 21, middle), 0)
    }

    /// [06 §15.8] observed: no scrolling in the middle of the list or outside it.
    func testVelocityIsZeroOutsideBands() {
        XCTAssertEqual(velocity(viewport.midY, middle), 0)
        XCTAssertEqual(velocity(viewport.minY + band, middle), 0, "inner edge of the top band")
        XCTAssertEqual(velocity(viewport.maxY - band, middle), 0, "inner edge of the bottom band")
        XCTAssertEqual(velocity(viewport.minY - 1, middle), 0, "above the list (e.g. favorites)")
        XCTAssertEqual(velocity(viewport.maxY + 1, middle), 0, "below the list (e.g. dock)")
        XCTAssertEqual(SidebarAutoScroll.velocity(pointerY: 10, viewport: .null, metrics: middle, timeInBand: 5), 0)
    }

    /// [06 §15.8] observed: scrolling starts only after ≈ 0.3–0.5 s in the band.
    func testDwellBeforeScrolling() {
        XCTAssertGreaterThanOrEqual(dwell, 0.3)
        XCTAssertLessThanOrEqual(dwell, 0.5)
        XCTAssertEqual(velocity(viewport.maxY - 1, middle, time: 0), 0)
        XCTAssertEqual(velocity(viewport.maxY - 1, middle, time: dwell - 0.01), 0)
        XCTAssertGreaterThan(velocity(viewport.maxY - 1, middle, time: dwell), 0)
    }

    /// [06 §15.8] inferred: speed grows toward the edge (slow at the band's inner edge, ≈ 25 pt/s);
    /// top scrolls up (negative), bottom down.
    func testVelocityIncreasesTowardEdge() {
        let topInner = velocity(viewport.minY + band * 0.75, middle)
        let topMid = velocity(viewport.minY + band * 0.5, middle)
        let topEdge = velocity(viewport.minY, middle)
        XCTAssertLessThan(topInner, 0)
        XCTAssertLessThan(topMid, topInner)
        XCTAssertLessThan(topEdge, topMid)
        XCTAssertEqual(topEdge, -SidebarLocalTokens.autoScrollMaxSpeed, accuracy: 0.001)

        let bottomInner = velocity(viewport.maxY - band * 0.99, middle)
        let bottomMid = velocity(viewport.maxY - band * 0.5, middle)
        let bottomEdge = velocity(viewport.maxY, middle)
        XCTAssertEqual(bottomInner, SidebarLocalTokens.autoScrollMinSpeed, accuracy: 1, "slow at the inner edge")
        XCTAssertGreaterThan(bottomMid, bottomInner)
        XCTAssertGreaterThan(bottomEdge, bottomMid)
    }

    /// [06 §15.8] inferred: the speed also grows with the time spent scrolling, up to a cap.
    func testVelocityAcceleratesWithTime() {
        let y = viewport.maxY - band / 2
        let start = velocity(y, middle, time: dwell)
        let later = velocity(y, middle, time: dwell + 0.5)
        let much = velocity(y, middle, time: dwell + 10)
        XCTAssertGreaterThan(later, start)
        XCTAssertGreaterThan(much, later)
        XCTAssertEqual(much, velocity(y, middle, time: dwell + 100), "capped")
    }

    /// [06 §15.8] observed: never scroll past the content ends.
    func testVelocityIsClampedAtContentEnds() {
        let atTop = SidebarScrollMetrics(offset: 0, contentHeight: 1_000, viewportHeight: 400)
        XCTAssertEqual(velocity(viewport.minY + 1, atTop), 0, "already at the top")
        XCTAssertGreaterThan(velocity(viewport.maxY - 1, atTop), 0, "can still scroll down")

        let atBottom = SidebarScrollMetrics(offset: 600, contentHeight: 1_000, viewportHeight: 400)
        XCTAssertEqual(velocity(viewport.maxY - 1, atBottom), 0, "already at the bottom")
        XCTAssertLessThan(velocity(viewport.minY + 1, atBottom), 0, "can still scroll up")

        let fits = SidebarScrollMetrics(offset: 0, contentHeight: 300, viewportHeight: 400)
        XCTAssertEqual(velocity(viewport.minY + 1, fits), 0, "content shorter than the viewport")
        XCTAssertEqual(velocity(viewport.maxY - 1, fits), 0)

        // A long step lands exactly on the end, not past it.
        XCTAssertEqual(SidebarAutoScroll.offset(after: 10, velocity: 400, from: middle), 600)
        XCTAssertEqual(SidebarAutoScroll.offset(after: 10, velocity: -400, from: middle), 0)
        XCTAssertEqual(SidebarAutoScroll.offset(after: 0.1, velocity: 100, from: middle), 310, accuracy: 0.001)
    }

    /// A band larger than half a short viewport is capped, so the two bands never overlap.
    func testBandsDoNotOverlapInShortViewport() {
        let short = CGRect(x: 0, y: 0, width: 200, height: 40)
        let metrics = SidebarScrollMetrics(offset: 50, contentHeight: 500, viewportHeight: 40)
        XCTAssertLessThan(SidebarAutoScroll.velocity(pointerY: 5, viewport: short, metrics: metrics, timeInBand: 1, band: 100), 0)
        XCTAssertGreaterThan(SidebarAutoScroll.velocity(pointerY: 35, viewport: short, metrics: metrics, timeInBand: 1, band: 100), 0)
        XCTAssertEqual(SidebarAutoScroll.velocity(pointerY: 20, viewport: short, metrics: metrics, timeInBand: 1, band: 100), 0)
    }

    // MARK: View-model level

    /// In-memory stand-in for the list's scroll view.
    private final class FakeScroller: SidebarListScrolling {
        var metrics: SidebarScrollMetrics?
        var scrolls: [CGFloat] = []
        init(_ metrics: SidebarScrollMetrics) { self.metrics = metrics }
        func scroll(toOffset offset: CGFloat) {
            scrolls.append(offset)
            metrics?.offset = offset
        }
    }

    /// Geometry whose list viewport is `viewport` and has no rows (every point hits end of Today).
    private func emptyGeometry() -> SidebarDropGeometry {
        SidebarDropGeometry(list: viewport, entries: [], favorites: .null, favoriteCount: 0, dockItems: [])
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A drag in the bottom band scrolls the list down after the dwell ([06 §15.8] observed); a
    /// manual step moves by velocity × time.
    func testDragInBottomBandScrollsDownAfterDwell() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let scroller = FakeScroller(middle)
        vm.listScroller = scroller
        vm.autoScrollTickInterval = 60 // keep the loop from stepping on its own
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.maxY - 1), in: emptyGeometry())
        XCTAssertTrue(vm.isAutoScrolling)
        XCTAssertTrue(vm.autoScrollStep(elapsed: 0.1), "dwell: the loop keeps running")
        XCTAssertEqual(vm.autoScrollVelocity, 0)
        XCTAssertTrue(scroller.scrolls.isEmpty, "nothing scrolls during the dwell")
        XCTAssertTrue(vm.autoScrollStep(elapsed: dwell))
        XCTAssertGreaterThan(vm.autoScrollVelocity, 0)
        XCTAssertGreaterThan(scroller.metrics!.offset, middle.offset)
        vm.stop()
    }

    /// The running loop scrolls by itself and stops once the content end is reached.
    func testLoopScrollsUntilContentEnd() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let scroller = FakeScroller(SidebarScrollMetrics(offset: 590, contentHeight: 1_000, viewportHeight: 400))
        vm.listScroller = scroller
        vm.autoScrollTickInterval = 0.01
        vm.autoScrollDwell = 0.02
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.maxY - 0.5), in: emptyGeometry())
        let stopped = await waitUntil { !vm.isAutoScrolling }
        XCTAssertTrue(stopped)
        XCTAssertEqual(scroller.metrics?.offset, 600, "clamped at the bottom end")
        XCTAssertEqual(vm.autoScrollVelocity, 0)
        XCTAssertNotNil(vm.draggingItem, "the drag itself continues")
        vm.stop()
    }

    /// Moving the pointer out of the band stops the scroll.
    func testLeavingBandStopsScroll() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let scroller = FakeScroller(middle) // `listScroller` is weak: keep it alive
        vm.listScroller = scroller
        vm.autoScrollTickInterval = 60
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.minY + 1), in: emptyGeometry())
        XCTAssertTrue(vm.isAutoScrolling)
        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.midY), in: emptyGeometry())
        XCTAssertFalse(vm.isAutoScrolling)
        XCTAssertEqual(vm.autoScrollVelocity, 0)
        XCTAssertTrue(scroller.scrolls.isEmpty)
        vm.stop()
    }

    /// [06 §15.8] inferred: the drop ends the scroll.
    func testDropStopsScroll() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let scroller = FakeScroller(middle)
        vm.listScroller = scroller
        vm.autoScrollTickInterval = 60
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.maxY - 1), in: emptyGeometry())
        XCTAssertTrue(vm.isAutoScrolling)
        XCTAssertTrue(vm.performDrop(on: .todayAreaEnd))
        XCTAssertFalse(vm.isAutoScrolling)
        XCTAssertNil(vm.lastDragPointer)
        XCTAssertFalse(vm.autoScrollStep(elapsed: 0.1), "no step after the drop")
        XCTAssertTrue(scroller.scrolls.isEmpty)
    }

    /// [06 §15.9] observed: Esc ends the drag (session end), which ends the scroll; so does the
    /// pointer leaving the sidebar.
    func testCancelAndExitStopScroll() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let scroller = FakeScroller(middle) // `listScroller` is weak: keep it alive
        vm.listScroller = scroller
        vm.autoScrollTickInterval = 60
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.maxY - 1), in: emptyGeometry())
        XCTAssertTrue(vm.isAutoScrolling)
        vm.clearDropTarget() // dropExited
        XCTAssertFalse(vm.isAutoScrolling)

        vm.updateDropTarget(at: CGPoint(x: 20, y: viewport.maxY - 1), in: emptyGeometry())
        XCTAssertTrue(vm.isAutoScrolling)
        vm.dragSessionEnded() // Esc
        XCTAssertFalse(vm.isAutoScrolling)
        XCTAssertFalse(vm.autoScrollStep(elapsed: 0.1))
        XCTAssertTrue(scroller.scrolls.isEmpty)
    }

    /// No drag, no scroll: a pointer update outside a drag does not start the loop.
    func testNoScrollWithoutDrag() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let scroller = FakeScroller(middle)
        vm.listScroller = scroller
        vm.updateAutoScroll(pointer: CGPoint(x: 20, y: viewport.maxY - 1), viewport: viewport)
        XCTAssertFalse(vm.isAutoScrolling)
        XCTAssertTrue(scroller.scrolls.isEmpty)
    }

    /// After the list scrolled under a resting pointer, the target is re-hit-tested against the
    /// fresh row frames (the view passes them in through `refreshDropTarget`).
    func testRefreshRehitTestsWithScrolledFrames() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        let pointer = CGPoint(x: 20, y: 293)
        func geometry(rowTop: CGFloat) -> SidebarDropGeometry {
            SidebarDropGeometry(
                list: viewport,
                entries: [
                    .init(kind: .row(f.today2, style: .tab), frame: CGRect(x: 0, y: rowTop, width: 200, height: 41)),
                    .init(kind: .row(f.today3, style: .tab), frame: CGRect(x: 0, y: rowTop + 41, width: 200, height: 41)),
                ],
                favorites: .null, favoriteCount: 0, dockItems: []
            )
        }
        vm.beginDrag(.tab(f.today1))
        vm.updateDropTarget(at: pointer, in: geometry(rowTop: 290))
        XCTAssertEqual(vm.dropTarget, .row(f.today2, .above))
        // Rows moved up by one pitch (scrolled down); the pointer did not move.
        vm.refreshDropTarget(in: geometry(rowTop: 249))
        // The pointer is now in today3's top band: the slot between today2 and today3, reported
        // as "below today2" ([06 §15.2] one slot per boundary).
        XCTAssertEqual(vm.dropTarget, .row(f.today2, .below))
        vm.endDrag()
        vm.refreshDropTarget(in: geometry(rowTop: 290))
        XCTAssertNil(vm.dropTarget, "no re-hit-test outside a drag")
    }
}
