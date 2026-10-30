import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// B110: the blank list area below the last row moves the window. Spec:
/// docs/arc-spec/06-flows.md §15.1 (observed: "在列表下方的空白处按下再拖,拖动的是整个窗口(不是拖放)").
/// Rows, favorites and the ↓ / ↑ button keep their own presses.
@MainActor
final class SidebarWindowMoveTests: XCTestCase {
    private let layout = SidebarLayout()

    private var viewport: CGRect {
        CGRect(x: 0, y: layout.listTop, width: layout.width, height: layout.dockFrame.minY - layout.listTop)
    }

    /// A sidebar whose list shows unscrolled in the reference window.
    private func makeShownSidebar(_ f: SidebarFixture = SidebarFixture()) -> (SidebarViewModel, SidebarListScrollState) {
        let (vm, _) = makeSidebarViewModel(f)
        let scroll = SidebarListScrollState()
        let geometry = vm.listGeometry
        scroll.update(vm.selectedSpaceID, contentFrame: CGRect(x: 0, y: 0, width: layout.width, height: geometry.contentHeight),
                      viewportSize: viewport.size)
        scroll.setPageRegions([.list: viewport])
        return (vm, scroll)
    }

    // MARK: Pure area

    /// [06 §15.1] observed: the blank band runs from the last entry's bottom to the list's bottom.
    func testBlankAreaIsBelowTheLastEntry() {
        let area = SidebarWindowMoveArea.make(listViewport: viewport, contentBottom: 500)
        XCTAssertEqual(area.blank, CGRect(x: 0, y: 500, width: layout.width, height: viewport.maxY - 500))
        XCTAssertTrue(area.contains(CGPoint(x: 100, y: 600)))
        XCTAssertFalse(area.contains(CGPoint(x: 100, y: 499)), "above the last entry's bottom")
        XCTAssertFalse(area.contains(CGPoint(x: 100, y: viewport.maxY + 5)), "the dock is not part of it")
    }

    /// Rows filling the list leave no blank area; a short list scrolled up starts it at the top.
    func testNoBlankAreaWhenRowsFillTheList() {
        XCTAssertEqual(SidebarWindowMoveArea.make(listViewport: viewport, contentBottom: viewport.maxY + 40), .none)
        XCTAssertEqual(SidebarWindowMoveArea.make(listViewport: .null, contentBottom: 300), .none)
        let scrolledPast = SidebarWindowMoveArea.make(listViewport: viewport, contentBottom: viewport.minY - 10)
        XCTAssertEqual(scrolledPast.blank.minY, viewport.minY)
    }

    /// Controls over the list (the ↓ / ↑ button) keep their presses.
    func testExcludedControlsAreNotTheBlankArea() {
        let button = CGRect(x: 120, y: 800, width: 36, height: 36)
        let area = SidebarWindowMoveArea.make(listViewport: viewport, contentBottom: 500, excluded: [button, CGRect(x: 0, y: 200, width: 10, height: 10)])
        XCTAssertEqual(area.excluded, [button], "only controls inside the band are kept")
        XCTAssertFalse(area.contains(CGPoint(x: 130, y: 810)))
        XCTAssertTrue(area.contains(CGPoint(x: 60, y: 810)))
    }

    // MARK: Press targets

    /// [06 §15.1]: a press on a row starts the row's press (select + drag); below the rows it is a
    /// window move; on the Space name row or the dock it is neither.
    func testPressTargetsOnTheShownSidebar() {
        let f = SidebarFixture()
        let (vm, scroll) = makeShownSidebar(f)
        let items = scroll.dragSourceItems(viewModel: vm, layout: layout)
        let area = scroll.windowMoveArea(viewModel: vm, layout: layout)
        XCTAssertFalse(area.blank.isNull)
        let lastEntry = vm.listGeometry.entries.last!
        XCTAssertEqual(area.blank.minY, layout.listTop + lastEntry.bottom, accuracy: 0.001)

        let rowFrame = scroll.rowFrame(of: f.today2, viewModel: vm, layout: layout)!
        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: 60, y: rowFrame.midY), items: items, windowMoveArea: area).itemID, .tab(f.today2))
        let lastRow = scroll.rowFrame(of: f.today1, viewModel: vm, layout: layout)!
        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: 60, y: lastRow.maxY - 1), items: items, windowMoveArea: area).itemID, .tab(f.today1))

        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: 60, y: lastRow.maxY + 30), items: items, windowMoveArea: area), .windowMove)
        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: 200, y: viewport.maxY - 2), items: items, windowMoveArea: area), .windowMove)
        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: 60, y: layout.dockCenterY), items: items, windowMoveArea: area), .none)
        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: 60, y: layout.spaceNameRowFrame.midY), items: items, windowMoveArea: area), .none)
        let fav = layout.favoriteSlotFrames(count: 2)[0]
        XCTAssertEqual(SidebarPressTarget.at(CGPoint(x: fav.midX, y: fav.midY), items: items, windowMoveArea: area).itemID, .tab(f.fav1))
        vm.stop()
    }

    /// Scrolling moves the blank band with the content.
    func testBlankAreaFollowsTheScrollOffset() {
        let (vm, scroll) = makeShownSidebar()
        let before = scroll.windowMoveArea(viewModel: vm, layout: layout).blank.minY
        scroll.update(vm.selectedSpaceID, contentFrame: CGRect(x: 0, y: -100, width: layout.width, height: vm.listGeometry.contentHeight),
                      viewportSize: viewport.size)
        XCTAssertEqual(scroll.windowMoveArea(viewModel: vm, layout: layout).blank.minY, before - 100, accuracy: 0.001)
        vm.stop()
    }

    /// The drop side is untouched: a drag released over the blank area still appends to Today
    /// (B33's trailing drop space), so row drag-and-drop keeps working there.
    func testDropsOnTheBlankAreaStillGoToToday() {
        let (vm, scroll) = makeShownSidebar()
        let area = scroll.windowMoveArea(viewModel: vm, layout: layout)
        let point = CGPoint(x: 60, y: area.blank.minY + 40)
        let target = SidebarDropHitTester.target(at: point, in: scroll.dropGeometry(viewModel: vm, layout: layout), allowsSplit: true)
        XCTAssertNotNil(target)
        vm.stop()
    }
}

private extension SidebarPressTarget {
    var itemID: SidebarDragItem? {
        if case .item(let hit) = self { return hit.item }
        return nil
    }
}
