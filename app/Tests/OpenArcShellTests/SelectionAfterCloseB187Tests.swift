import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Plan B187 (issue #10, part 1): which tab is selected after closing one. Decided with the user:
/// the tab used before it first, else its neighbor below (then above) as observed in Arc, else the
/// nearest pinned tab. Spec: docs/arc-spec/06-flows.md §35.
@MainActor
final class SelectionAfterCloseB187Tests: XCTestCase {
    private var engine: FakeEngine!
    private var vm: SidebarViewModel!

    override func setUp() async throws {
        engine = FakeEngine()
        (vm, _) = makeSidebarViewModel(SidebarFixture(), engine: engine)
    }

    override func tearDown() async throws {
        vm.stop()
        vm = nil
        engine = nil
    }

    private var f: SidebarFixture { SidebarFixture() }
    private var space: UUID { vm.dockSpaces[0].id }

    /// [06 §35]: the tab used before it wins over the neighbor.
    func testReturnsToTheTabUsedBefore() {
        let fx = f
        vm.selectTab(fx.today1)
        vm.selectTab(fx.today2)
        XCTAssertEqual(vm.selectedTabID, fx.today2)
        vm.closeTab(fx.today2)
        XCTAssertEqual(vm.selectedTabID, fx.today1)
    }

    /// Without one, the neighbor below it, as Arc does.
    func testNeighborBelowWithoutHistory() {
        let fx = f
        vm.selectTab(fx.today1)
        vm.selectTab(fx.today2)
        vm.selectTab(fx.today3)
        // History is [today3, today2, today1]; closing today3 leaves today2 first.
        vm.closeTab(fx.today3)
        XCTAssertEqual(vm.selectedTabID, fx.today2)
    }

    /// A tab with nothing before it in history takes the next row below, then above. Today is
    /// ordered newest first: today3, today2, today1.
    func testNeighborOrder() {
        let fx = f
        vm.selectTab(fx.today3)
        vm.selectionHistory.removeAll()
        vm.closeTab(fx.today3)
        XCTAssertEqual(vm.selectedTabID, fx.today2, "below first")

        vm.selectTab(fx.today1)
        vm.selectionHistory.removeAll()
        vm.closeTab(fx.today1)
        XCTAssertEqual(vm.selectedTabID, fx.today2, "then above, nothing below")
    }

    /// Closing the last Today tab falls back to the nearest pinned tab (the last row).
    func testFallsBackToPinned() {
        let fx = f
        for id in [fx.today1, fx.today2, fx.today3] {
            vm.selectTab(id)
            vm.selectionHistory.removeAll()
            vm.closeTab(id)
        }
        let pinned = vm.pinnedOrder()
        XCTAssertFalse(pinned.isEmpty)
        XCTAssertEqual(vm.selectedTabID, pinned.last)
    }

    /// A closed tab never comes back from the history.
    func testHistorySkipsClosedTabs() {
        let fx = f
        vm.selectTab(fx.today1)
        vm.selectTab(fx.today2)
        vm.selectTab(fx.today3)
        vm.closeTab(fx.today1)   // not selected: selection stays
        XCTAssertEqual(vm.selectedTabID, fx.today3)
        vm.closeTab(fx.today3)
        XCTAssertEqual(vm.selectedTabID, fx.today2, "today1 is gone, so today2")
        XCTAssertFalse(vm.selectionHistory.contains(fx.today1))
    }
}
