import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Pane geometry. [06 §5] observed: panes side by side with a gap of about 10 pt.
final class SplitViewLayoutTests: XCTestCase {
    /// The web panel of a 1920 x 985 window with the sidebar showing, at the panel's own origin.
    private var container: CGRect {
        let frame = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985)).webPanelFrame
        return CGRect(origin: .zero, size: frame.size)
    }

    private func root(_ ids: [UUID], fractions: [Double]? = nil, axis: SplitAxis = .horizontal) -> SplitNode {
        let f = fractions ?? ids.map { _ in 1 / Double(ids.count) }
        return .split(axis: axis, children: zip(ids, f).map { SplitChild(node: .pane(tabID: $0), fraction: $1) })
    }

    private func assertSideBySide(_ frames: [SplitPaneFrame], count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let gap = Metrics.SplitView.paneGap
        XCTAssertEqual(frames.count, count, file: file, line: line)
        let width = (container.width - gap * Double(count - 1)) / Double(count)
        for (index, pane) in frames.enumerated() {
            XCTAssertEqual(pane.frame.width, width, accuracy: 0.001, file: file, line: line)
            XCTAssertEqual(pane.frame.height, container.height, file: file, line: line)
            XCTAssertEqual(pane.frame.minY, 0, file: file, line: line)
            XCTAssertEqual(pane.frame.minX, Double(index) * (width + gap), accuracy: 0.001, file: file, line: line)
        }
        XCTAssertEqual(frames.last?.frame.maxX ?? 0, container.width, accuracy: 0.001, file: file, line: line)
    }

    /// [06 §5] observed: two panes, gap about 10. At 1920 x 985 the panel is 1634 wide: 812 + 10 + 812.
    func testTwoPanesAt1920x985() {
        let ids = [UUID(), UUID()]
        let frames = SplitPaneLayout.frames(for: root(ids), in: container)
        XCTAssertEqual(container.width, 1634)
        XCTAssertEqual(frames.map(\.tabID), ids)
        XCTAssertEqual(frames[0].frame.width, 812)
        XCTAssertEqual(frames[1].frame.minX, 822)
        assertSideBySide(frames, count: 2)
    }

    /// 2-4 panes are supported by the layout tree; widths are equal by default.
    func testThreeAndFourPanesAt1920x985() {
        let three = SplitPaneLayout.frames(for: root((0..<3).map { _ in UUID() }), in: container)
        XCTAssertEqual(three[0].frame.width, 538)
        assertSideBySide(three, count: 3)
        let four = SplitPaneLayout.frames(for: root((0..<4).map { _ in UUID() }), in: container)
        XCTAssertEqual(four[0].frame.width, 401)
        assertSideBySide(four, count: 4)
    }

    /// Ratio hook: unequal fractions (from the model) split the space without the gaps.
    func testFractionsAreHonoredAndNormalized() {
        let ids = [UUID(), UUID()]
        let frames = SplitPaneLayout.frames(for: root(ids, fractions: [0.25, 0.75]), in: container)
        let available = container.width - Metrics.SplitView.paneGap
        XCTAssertEqual(frames[0].frame.width, available * 0.25, accuracy: 0.001)
        XCTAssertEqual(frames[1].frame.width, available * 0.75, accuracy: 0.001)
        // Fractions that do not sum to 1 still fill the container.
        let skewed = SplitPaneLayout.frames(for: root(ids, fractions: [1, 3]), in: container)
        XCTAssertEqual(skewed[1].frame.maxX, container.width, accuracy: 0.001)
    }

    /// Vertical splits stack top to bottom (inferred; not observed).
    func testVerticalSplitStacks() {
        let ids = [UUID(), UUID()]
        let frames = SplitPaneLayout.frames(for: root(ids, axis: .vertical), in: container)
        XCTAssertEqual(frames[0].frame.width, container.width)
        XCTAssertEqual(frames[1].frame.minY, frames[0].frame.maxY + Metrics.SplitView.paneGap, accuracy: 0.001)
        XCTAssertEqual(frames[1].frame.maxY, container.height, accuracy: 0.001)
    }

    /// Nested splits recurse: a pane next to a stacked pair.
    func testNestedSplit() {
        let (a, b, c) = (UUID(), UUID(), UUID())
        let node = SplitNode.split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 0.5),
            SplitChild(node: .split(axis: .vertical, children: [
                SplitChild(node: .pane(tabID: b), fraction: 0.5),
                SplitChild(node: .pane(tabID: c), fraction: 0.5),
            ]), fraction: 0.5),
        ])
        let frames = SplitPaneLayout.frames(for: node, in: container)
        XCTAssertEqual(frames.map(\.tabID), [a, b, c])
        XCTAssertEqual(frames[1].frame.minX, frames[2].frame.minX)
        XCTAssertEqual(frames[1].frame.width, 812)
    }

    /// Expand Current Split: only the focused pane, full size. inferred.
    func testExpandedShowsOnlyFocusedPane() {
        let id = UUID()
        let frames = SplitPaneLayout.expandedFrames(focusedTabID: id, in: container)
        XCTAssertEqual(frames, [SplitPaneFrame(tabID: id, frame: container)])
    }

    func testNeighborPanePrefersThePreviousOne() {
        let ids = (0..<3).map { _ in UUID() }
        let node = root(ids)
        XCTAssertEqual(SplitPaneLayout.neighborPane(of: ids[2], in: node), ids[1])
        XCTAssertEqual(SplitPaneLayout.neighborPane(of: ids[0], in: node), ids[1])
        XCTAssertNil(SplitPaneLayout.neighborPane(of: UUID(), in: node))
    }

    /// A tombstoned layout (single page again) is not active. [06 §5] observed.
    func testActiveLayoutIgnoresDeletedLayouts() throws {
        let now = Date(timeIntervalSince1970: 0)
        var ws = WorkspaceState()
        let space = UUID(), a = UUID(), b = UUID(), layoutID = UUID()
        ws.layoutHelper(space: space, a: a, b: b, layoutID: layoutID, now: now)
        XCTAssertEqual(SplitPaneLayout.activeLayout(in: ws, containing: a)?.id, layoutID)
        XCTAssertNil(SplitPaneLayout.activeLayout(in: ws, containing: UUID()))
        XCTAssertNil(SplitPaneLayout.activeLayout(in: ws, containing: nil))
        ws.splits[layoutID]?.meta.markDeleted(at: now)
        XCTAssertNil(SplitPaneLayout.activeLayout(in: ws, containing: a))
    }

    /// B67: the lookup ignores panes whose tab was deleted or archived on another device, or has
    /// not arrived yet, even before `TreeOps.repairSplits` ran. [06 §5] observed: one pane left is
    /// a single page.
    func testActiveLayoutIgnoresDeadPanes() throws {
        let now = Date(timeIntervalSince1970: 0)
        var ws = WorkspaceState()
        let space = UUID(), a = UUID(), b = UUID(), c = UUID(), layoutID = UUID()
        ws.layoutHelper(space: space, ids: [a, b, c], layoutID: layoutID, now: now)
        ws.tabs[b]?.meta.markDeleted(at: now)
        let layout = try XCTUnwrap(SplitPaneLayout.activeLayout(in: ws, containing: a))
        XCTAssertEqual(layout.root.tabIDs, [a, c], "the deleted pane is hidden")
        XCTAssertNil(SplitPaneLayout.activeLayout(in: ws, containing: b), "a deleted tab has no split")
        XCTAssertEqual(ws.splits[layoutID]?.root.tabIDs, [a, b, c], "the lookup does not change the workspace")

        ws.tabs[c] = nil  // not arrived yet (or purged)
        XCTAssertNil(SplitPaneLayout.activeLayout(in: ws, containing: a), "one live pane: a single page")
    }
}

private extension WorkspaceState {
    /// Adds a two-pane layout and its Today tabs (the lookup checks that the panes' tabs are live).
    mutating func layoutHelper(space: UUID, a: UUID, b: UUID, layoutID: UUID, now: Date) {
        layoutHelper(space: space, ids: [a, b], layoutID: layoutID, now: now)
    }

    /// Adds an equal-width side-by-side layout of `ids` and a Today tab for each id.
    mutating func layoutHelper(space: UUID, ids: [UUID], layoutID: UUID, now: Date) {
        for (id, key) in zip(ids, SortKey.sequence(count: ids.count)) {
            tabs[id] = TabNode(id: id, location: .today(spaceID: space), sortKey: key, url: nil, title: "", now: now)
        }
        let node = SplitNode.split(axis: .horizontal, children: ids.map {
            SplitChild(node: .pane(tabID: $0), fraction: 1 / Double(ids.count))
        })
        splits[layoutID] = SplitLayout(id: layoutID, spaceID: space, root: node, now: now)
    }
}
