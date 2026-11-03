import XCTest
import AppKit
import OpenArcDesign
import OpenArcPersistence
@testable import OpenArcShell

/// B144: the sidebar's width is resizable by dragging the seam between it and the web panel, with
/// Arc's default, limits, snap and collapse (inferred), saved per
/// window. Spec: [07 §1] (sidebar width 276 observed in the reference; to extend with B144),
/// [04 §window structure].
@MainActor
final class SidebarResizeB144Tests: XCTestCase {
    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                   now: { Date(timeIntervalSince1970: 0) })
    }

    // MARK: Rules

    func testArcWidthValues_07_1() {
        let s = Metrics.Sidebar.self
        XCTAssertEqual(s.defaultWidth, 276, "07 §1 observed (E35)")
        XCTAssertEqual(s.minimumWidth, 164)
        XCTAssertEqual(s.maximumWidth, 500)
        XCTAssertEqual(s.collapseWidth, 82)
        XCTAssertEqual(s.defaultWidthSnapDistance, 14)
        XCTAssertEqual(s.defaultWidth, s.width, "the default is the reference width")
    }

    func testResizeClampsSnapsAndCollapses_07_1() {
        XCTAssertEqual(SidebarWidth.resize(proposed: 300), .width(300))
        XCTAssertEqual(SidebarWidth.resize(proposed: 300.4), .width(300), "whole points")
        XCTAssertEqual(SidebarWidth.resize(proposed: 700), .width(500))
        XCTAssertEqual(SidebarWidth.resize(proposed: 120), .width(164))
        XCTAssertEqual(SidebarWidth.resize(proposed: 82), .width(164))
        XCTAssertEqual(SidebarWidth.resize(proposed: 81), .hidden)
        XCTAssertEqual(SidebarWidth.resize(proposed: 288), .width(276), "snaps within 14 pt of the default")
        XCTAssertEqual(SidebarWidth.resize(proposed: 263), .width(276))
        XCTAssertEqual(SidebarWidth.resize(proposed: 242), .width(242))
        XCTAssertEqual(SidebarWidth.resize(proposed: 214), .width(214))
        XCTAssertEqual(SidebarWidth.sanitized(nil), 276)
        XCTAssertEqual(SidebarWidth.sanitized(.nan), 276)
        XCTAssertEqual(SidebarWidth.sanitized(900), 500)
    }

    // MARK: Layout

    func testWebPanelFollowsTheWidth_07_1() {
        let size = CGSize(width: 1920, height: 985)
        XCTAssertEqual(MainWindowLayout(windowSize: size).webPanelFrame, CGRect(x: 276, y: 10, width: 1634, height: 965),
                       "the reference layout is unchanged at 276")
        let layout = MainWindowLayout(windowSize: size, sidebarWidth: 228)
        XCTAssertEqual(layout.sidebarFrame.width, 228)
        XCTAssertEqual(layout.webPanelFrame, CGRect(x: 228, y: 10, width: 1682, height: 965))
        XCTAssertEqual(layout.addressFieldFrame, CGRect(x: 8, y: 46, width: 212, height: 36))
        // The seam's drag area: 8 wide around the edge, 11 in from the top and bottom.
        XCTAssertEqual(layout.sidebarResizeHandleFrame, CGRect(x: 224, y: 11, width: 8, height: 963))
        var hidden = layout
        hidden.isSidebarVisible = false
        XCTAssertEqual(hidden.sidebarResizeHandleFrame, .zero)
    }

    func testRightAnchoredControlsKeepTheirDistanceToTheEdge_07_4() {
        let wide = SidebarLayout(width: 276), narrow = SidebarLayout(width: 228)
        XCTAssertEqual(narrow.rowFillFrame, CGRect(x: 8, y: 2, width: 212, height: 36))
        XCTAssertEqual(wide.width - wide.reloadButtonFrame.minX, narrow.width - narrow.reloadButtonFrame.minX)
        XCTAssertEqual(wide.width - wide.backButtonFrame.minX, narrow.width - narrow.backButtonFrame.minX)
        XCTAssertEqual(wide.width - wide.dockPlusFrame.maxX, narrow.width - narrow.dockPlusFrame.maxX)
        XCTAssertEqual(narrow.hideSidebarButtonFrame, wide.hideSidebarButtonFrame, "left-anchored")
        XCTAssertEqual(narrow.dockHomeFrame, wide.dockHomeFrame)
        XCTAssertEqual(wide.width - wide.spaceNameRowFrame.maxX, narrow.width - narrow.spaceNameRowFrame.maxX)
        // The dock's Space band (x 42 to 42 pt left of the edge) is 144 pt at 228 wide.
        XCTAssertEqual(SidebarLayout.dockItemPitch(count: 8, trailingShift: narrow.trailingShift), 144 / 8)
        XCTAssertEqual(narrow.favoritesTilesFrame.width, 212)
        // The narrowest sidebar still has a positive dock band.
        XCTAssertGreaterThan(SidebarLayout.dockItemPitch(count: 8, trailingShift: SidebarLayout(width: 164).trailingShift), 0)
    }

    func testPeekPanelUsesTheWindowsWidth_06_14() {
        let layout = SidebarPeekLayout(windowSize: CGSize(width: 1200, height: 800), sidebarWidth: 228)
        XCTAssertEqual(layout.panelFrame, CGRect(x: 5, y: 5, width: 228, height: 790))
        XCTAssertEqual(SidebarPeekTokens.collapsedOffset(sidebarWidth: 276), 291)
        XCTAssertEqual(SidebarPeekTokens.collapsedOffset(sidebarWidth: 400), 415)
    }

    // MARK: Model

    func testDragResizesCollapsesAndRestores_07_1() {
        let model = makeModel()
        defer { model.stop() }
        XCTAssertEqual(model.sidebarWidth, 276, "a new window gets Arc's default (07 §1, E35)")
        model.beginSidebarResize()
        XCTAssertTrue(model.isResizingSidebar)
        model.updateSidebarResize(translation: 24)
        XCTAssertEqual(model.sidebarWidth, 300)
        XCTAssertEqual(model.windowLayout(size: CGSize(width: 1200, height: 800)).webPanelFrame.minX, 300)
        model.updateSidebarResize(translation: -150)
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertEqual(model.sidebarWidth, 164)
        model.updateSidebarResize(translation: -200)
        XCTAssertFalse(model.isSidebarVisible, "past the collapse limit the sidebar hides")
        XCTAssertEqual(model.sidebarWidth, 164, "keeps its last width")
        model.updateSidebarResize(translation: -18)
        XCTAssertTrue(model.isSidebarVisible, "dragging back shows it again")
        model.endSidebarResize()
        XCTAssertFalse(model.isResizingSidebar)
        XCTAssertEqual(model.windowUIState.sidebarWidth, 258)
        XCTAssertEqual(model.sidebarPeek.sidebarWidth, 258)
    }

    func testWidthIsSavedPerWindow_07_1() throws {
        let state = WindowUIState(selectedSpaceID: nil, selectedTabID: nil, isSidebarVisible: true, sidebarWidth: 312)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(WindowUIState.self, from: data).sidebarWidth, 312)
        let old = try JSONDecoder().decode(WindowUIState.self, from: Data(#"{"isSidebarVisible":true}"#.utf8))
        XCTAssertNil(old.sidebarWidth, "files from before B144 restore the default")
        let model = makeModel()
        defer { model.stop() }
        XCTAssertNil(model.windowUIState.sidebarWidth, "the default is not written")
        model.setSidebarWidth(312)
        XCTAssertEqual(model.windowUIState.sidebarWidth, 312)
    }

    // MARK: Seam view

    func testSeamShowsTheResizeCursorAndMeasuresOnScreen_07_1() {
        XCTAssertEqual(SidebarResizeHandleView.cursor, NSCursor.resizeLeftRight)
        XCTAssertEqual(SidebarResizeHandleView.translation(from: NSPoint(x: 100, y: 5), to: NSPoint(x: 137, y: 50)), 37)
        let view = SidebarResizeHandleView(frame: CGRect(x: 0, y: 0, width: 8, height: 400))
        XCTAssertFalse(view.mouseDownCanMoveWindow, "a press on the seam never moves the window")
    }

    /// The page view and the sidebar's scroll view under the seam set their own cursor on every
    /// mouse move, so the seam must hear every move too (user: no resize cursor on the seam).
    func testSeamTracksEveryMoveToKeepItsCursor_07_1() throws {
        let view = SidebarResizeHandleView(frame: CGRect(x: 0, y: 0, width: 8, height: 400))
        view.updateTrackingAreas()
        let area = try XCTUnwrap(view.trackingAreas.first)
        XCTAssertTrue(area.options.contains(.mouseMoved))
        XCTAssertTrue(area.options.contains(.cursorUpdate))
        XCTAssertTrue(area.options.contains(.inVisibleRect))
        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1, "no duplicate areas on relayout")
    }

    // MARK: Seam line (B157)

    /// 4 pt wide around the drag area's left edge, 3.5 pt in from its ends. [07 §1] inferred.
    func testSeamLineGeometry_07_1() {
        let frame = SidebarResizeHandleView.indicatorFrame(in: CGRect(x: 0, y: 0, width: 8, height: 963))
        XCTAssertEqual(frame, CGRect(x: -2, y: 3.5, width: 4, height: 956))
        let view = SidebarResizeHandleView(frame: CGRect(x: 0, y: 0, width: 8, height: 400))
        XCTAssertEqual(view.indicator.cornerRadius, 2, "round ends")
        XCTAssertFalse(view.layer?.masksToBounds ?? true, "half the line lies left of the view")
    }

    func testSeamLineShowsOnPressAndHidesWhenIdle_07_1() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = SidebarResizeHandleView(frame: CGRect(x: 100, y: 0, width: 8, height: 400))
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.indicator.isHidden)
        XCTAssertEqual(view.indicator.opacity, 0)
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 104, y: 200), modifierFlags: [],
                                                     timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                     eventNumber: 0, clickCount: 1, pressure: 1))
        view.mouseDown(with: press)
        XCTAssertFalse(view.indicator.isHidden, "a press shows the line at once")
        XCTAssertEqual(view.indicator.opacity, 0.5)
    }

    /// Landing on the default width by snapping counts once; pointing at it exactly does not.
    func testSnapToTheDefaultWidthPulses_07_1() {
        let model = makeModel()
        defer { model.stop() }
        model.setSidebarWidth(320)
        model.beginSidebarResize()
        model.updateSidebarResize(translation: -36)
        XCTAssertEqual(model.sidebarWidth, 276)
        XCTAssertEqual(model.sidebarResizeSnapCount, 1)
        model.updateSidebarResize(translation: -40)
        XCTAssertEqual(model.sidebarResizeSnapCount, 1, "staying in the snap zone does not pulse again")
        model.updateSidebarResize(translation: 0)
        model.updateSidebarResize(translation: -44)
        XCTAssertEqual(model.sidebarResizeSnapCount, 1, "dragging exactly to the default is no snap")
        model.updateSidebarResize(translation: 0)
        model.updateSidebarResize(translation: -50)
        XCTAssertEqual(model.sidebarResizeSnapCount, 2)
        model.endSidebarResize()
    }
}
