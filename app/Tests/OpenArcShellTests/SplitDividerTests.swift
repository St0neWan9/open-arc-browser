import XCTest
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// The divider between split panes (plan B58). Spec: docs/arc-spec/06-flows.md §21.6 "调整比例"
/// (E19 capture), observed unless a test says inferred.
@MainActor
final class SplitDividerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    /// The capture's web panel: sidebar showing, 1634 wide (812 + 10 + 812).
    private let shown = CGRect(x: 0, y: 0, width: 1634, height: 900)

    private func two(_ f: Double = 0.5) -> (SplitNode, UUID, UUID) {
        let a = UUID(), b = UUID()
        return (.split(axis: .horizontal, children: [SplitChild(node: .pane(tabID: a), fraction: f),
                                                     SplitChild(node: .pane(tabID: b), fraction: 1 - f)]), a, b)
    }

    private func drag(_ root: SplitNode, pointer: Double, in container: CGRect) -> [SplitPaneFrame] {
        let divider = SplitPaneLayout.dividers(for: root, in: container)[0]
        let f = SplitDividerDrag.fractions(for: root, dividerIndex: 0, splitLength: container.width, pointer: pointer)!
        return SplitPaneLayout.frames(for: root.replacingFractions(at: divider.path, with: f)!, in: container)
    }

    /// [06 §21.6] observed: the divider is exactly the 10 pt gap between the panes.
    func testDividerIsTheTenPointGap() {
        let (root, _, _) = two()
        let dividers = SplitPaneLayout.dividers(for: root, in: shown)
        XCTAssertEqual(dividers.count, 1)
        XCTAssertEqual(dividers[0].frame, CGRect(x: 812, y: 0, width: 10, height: 900))
        XCTAssertEqual(Metrics.SplitDivider.hitThickness, 10)
        let panes = SplitPaneLayout.frames(for: root, in: shown)
        XCTAssertEqual(panes[0].frame.maxX, dividers[0].frame.minX)
        XCTAssertEqual(panes[1].frame.minX, dividers[0].frame.maxX)
    }

    /// [06 §21.6] observed: the gap's center follows the pointer (left pane's right edge =
    /// pointer − 5), live and linear away from the snap range.
    func testGapCenterFollowsPointer() {
        let (root, _, _) = two()
        let panes = drag(root, pointer: 464, in: shown)
        XCTAssertEqual(panes[0].frame.maxX, 459, accuracy: 1e-6)
        XCTAssertEqual(panes[1].frame.minX, 469, accuracy: 1e-6)
        XCTAssertEqual(panes[1].frame.maxX, 1634, accuracy: 1e-6)
    }

    /// [06 §21.6] observed: one snap point, 50 / 50, within ≈ 10 pt of the equal position; no
    /// snap at 1/3 or 2/3.
    func testSnapsOnlyToEqualHalves() {
        let (root, _, _) = two(0.3)
        let center = 812 + 5.0
        for offset in [-10.0, -4, 0, 6, 10] {
            XCTAssertEqual(drag(root, pointer: center + offset, in: shown)[0].frame.width, 812, accuracy: 1e-6, "offset \(offset)")
        }
        XCTAssertEqual(drag(root, pointer: center + 11, in: shown)[0].frame.width, 823, accuracy: 1e-6)
        XCTAssertEqual(drag(root, pointer: center - 11, in: shown)[0].frame.width, 801, accuracy: 1e-6)
        let third = 1624.0 / 3
        XCTAssertEqual(drag(root, pointer: third + 5 + 3, in: shown)[0].frame.width, third + 3, accuracy: 1e-6)
    }

    /// [06 §21.6] observed: neither pane gets narrower than 220 pt.
    func testMinimumPaneWidthOnBothSides() {
        let (root, _, _) = two()
        XCTAssertEqual(drag(root, pointer: 0, in: shown)[0].frame.width, 220, accuracy: 1e-6)
        XCTAssertEqual(drag(root, pointer: 1634, in: shown)[1].frame.width, 220, accuracy: 1e-6)
        XCTAssertEqual(Metrics.SplitDivider.minPaneLength, 220)
    }

    /// [06 §21.6] observed: the stored value is the ratio, so hiding the sidebar keeps the left
    /// pane's share (459 / 1624 = 0.283 → 534 / 1890 = 0.283).
    func testRatioSurvivesWiderPanel() {
        let (root, _, _) = two()
        let f = SplitDividerDrag.fractions(for: root, dividerIndex: 0, splitLength: 1634, pointer: 464)!
        XCTAssertEqual(f[0], 459.0 / 1624.0, accuracy: 1e-9)
        let hidden = CGRect(x: 0, y: 0, width: 1900, height: 900)
        let panes = SplitPaneLayout.frames(for: root.replacingFractions(at: [], with: f)!, in: hidden)
        XCTAssertEqual(panes[0].frame.width, 534, accuracy: 0.5)
    }

    /// Nested splits: each divider moves only its two neighbors. inferred.
    func testNestedDividersAdjustOnlyTheirNeighbors() throws {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let inner = SplitNode.split(axis: .vertical, children: [SplitChild(node: .pane(tabID: c), fraction: 0.5),
                                                                SplitChild(node: .pane(tabID: d), fraction: 0.5)])
        let root = SplitNode.split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 1.0 / 3), SplitChild(node: .pane(tabID: b), fraction: 1.0 / 3),
            SplitChild(node: inner, fraction: 1.0 / 3),
        ])
        let container = CGRect(x: 0, y: 0, width: 1220, height: 900)
        let dividers = SplitPaneLayout.dividers(for: root, in: container)
        XCTAssertEqual(dividers.map(\.path), [[], [], [2]])
        XCTAssertEqual(dividers[2].axis, .vertical)
        XCTAssertEqual(dividers[2].frame, CGRect(x: 820, y: 445, width: 400, height: 10))

        // The second outer divider: a keeps 400, b and the inner split share the rest.
        let f = try XCTUnwrap(SplitDividerDrag.fractions(for: root, dividerIndex: 1, splitLength: 1220, pointer: 905))
        let panes = SplitPaneLayout.frames(for: try XCTUnwrap(root.replacingFractions(at: [], with: f)), in: container)
        XCTAssertEqual(panes[0].frame.width, 400, accuracy: 1e-6)
        XCTAssertEqual(panes[1].frame.width, 490, accuracy: 1e-6)
        XCTAssertEqual(panes[2].frame.width, 310, accuracy: 1e-6)

        // The vertical divider inside the third column: y follows the pointer, minimum 220.
        let vf = try XCTUnwrap(SplitDividerDrag.fractions(for: inner, dividerIndex: 0, splitLength: 900, pointer: 300))
        XCTAssertEqual(vf[0] * 890, 295, accuracy: 1e-6)
        let low = try XCTUnwrap(SplitDividerDrag.fractions(for: inner, dividerIndex: 0, splitLength: 900, pointer: 900))
        XCTAssertEqual(low[1] * 890, 220, accuracy: 1e-6)
    }

    /// Too little room for two 220 pt panes: the drag does nothing.
    func testNoResizeWithoutRoomForMinimums() {
        let (root, _, _) = two()
        XCTAssertNil(SplitDividerDrag.fractions(for: root, dividerIndex: 0, splitLength: 400, pointer: 100))
        XCTAssertNil(SplitDividerDrag.fractions(for: root, dividerIndex: 1, splitLength: 1634, pointer: 100))
    }

    /// [06 §21.6] observed: left-right resize cursor in the gap (up-down for vertical, inferred);
    /// the pointer is measured from the press, so the moving view frame does not matter.
    func testHandleCursorAndPointerMath() {
        let view = SplitDividerHandleView(frame: NSRect(x: 0, y: 0, width: 10, height: 100))
        XCTAssertEqual(view.cursor, NSCursor.resizeLeftRight)
        view.axis = .vertical
        XCTAssertEqual(view.cursor, NSCursor.resizeUpDown)
        XCTAssertFalse(view.mouseDownCanMoveWindow)
        XCTAssertEqual(SplitDividerHandleView.pointer(pressInSplit: 817, pressInWindow: NSPoint(x: 1093, y: 500),
                                                      nowInWindow: NSPoint(x: 740, y: 480), axis: .horizontal), 464)
        XCTAssertEqual(SplitDividerHandleView.pointer(pressInSplit: 450, pressInWindow: NSPoint(x: 0, y: 500),
                                                      nowInWindow: NSPoint(x: 0, y: 480), axis: .vertical), 470)
    }

    // MARK: Shell

    private func splitModel() async throws -> (ShellModel, UUID, UUID) {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let base = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: base)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        return (model, base, try XCTUnwrap(model.selectedTabID))
    }

    /// [06 §21.6] observed: the panes follow the drag live, and the ratio is stored only on
    /// release; it is still there after switching tabs away and back.
    func testDragPreviewsLiveAndStoresRatioOnRelease() async throws {
        let (model, base, new) = try await splitModel()
        let layoutID = try XCTUnwrap(model.activeSplitLayout?.id)
        let divider = try XCTUnwrap(model.splitDividerFrames(in: shown).first)
        model.dragSplitDivider(divider, pointer: 464)
        XCTAssertEqual(model.splitPaneFrames(in: shown)[0].frame.width, 459, accuracy: 1e-6, "live")
        XCTAssertEqual(model.workspace.splits[layoutID]?.root, model.activeSplitLayout?.root)
        guard case .split(_, let before)? = model.workspace.splits[layoutID]?.root else { return XCTFail() }
        XCTAssertEqual(before[0].fraction, 0.5, "not stored while dragging")

        model.endSplitDividerDrag()
        XCTAssertNil(model.splitResizePreview)
        guard case .split(_, let after)? = model.workspace.splits[layoutID]?.root else { return XCTFail() }
        XCTAssertEqual(after[0].fraction, 459.0 / 1624.0, accuracy: 1e-9)

        let other = try XCTUnwrap(model.workspace.today(spaceID: try XCTUnwrap(model.selectedSpaceID)).map(\.id).first { ![base, new].contains($0) })
        model.sidebar.selectTab(other)
        XCTAssertTrue(model.splitPaneFrames(in: shown).isEmpty)
        model.sidebar.selectTab(base)
        XCTAssertEqual(model.splitPaneFrames(in: shown)[0].frame.width, 459, accuracy: 1e-6)
    }

    /// Releasing without moving stores nothing (a click or double-click on the gap does nothing,
    /// [06 §21.6] observed); an expanded split has no dividers.
    func testNoDragNoChangeAndNoDividersWhenExpanded() async throws {
        let (model, _, _) = try await splitModel()
        let before = model.workspace
        model.endSplitDividerDrag()
        XCTAssertEqual(model.workspace, before)
        model.toggleExpandCurrentSplit()
        XCTAssertTrue(model.splitDividerFrames(in: shown).isEmpty)
    }
}
