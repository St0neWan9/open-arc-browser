import XCTest
@testable import OpenArcModel

/// `TreeOps.splitTab`: a tab dropped on another tab's row (middle band) or on the web panel forms a
/// split with it, the dropped tab on the pointer's side. Spec: [06 §15.2] observed (one row, two
/// cells, dropped tab on the pointer's side), [06 §15.7] observed (web panel drop).
final class TreeOpsSplitTabTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let profile = UUID(), home = UUID(), work = UUID()
    private let a = UUID(), b = UUID(), c = UUID(), w = UUID()
    private let l1 = UUID(), l2 = UUID()

    /// Today (top to bottom): c, b, a; Work Today: w.
    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: t0)
        s = try TreeOps.createSpace(s, id: work, profileID: profile, name: "Work", now: t0)
        for id in [a, b, c] { s = try TreeOps.openTab(s, id: id, spaceID: home, url: nil, title: "", now: t0) }
        s = try TreeOps.openTab(s, id: w, spaceID: work, url: nil, title: "", now: t0)
        return s
    }

    /// [06 §15.2] observed: leading = dropped tab on the left, trailing = on the right; the tab
    /// moves next to the target; only the dropped tab's placement and the new layout are written.
    func testCreatesTwoPaneLayoutOnPointerSide() throws {
        let s0 = try base()
        let left = try TreeOps.splitTab(s0, layoutID: l1, tabID: a, targetTabID: c, side: .leading, moveNextToTarget: true, now: at(5))
        XCTAssertEqual(left.splits[l1]?.root.tabIDs, [a, c])
        XCTAssertEqual(left.splits[l1]?.spaceID, home)
        XCTAssertEqual(left.today(spaceID: home).map(\.id), [a, c, b], "moved right before the target")
        XCTAssertEqual(left.tabs[c], s0.tabs[c], "target untouched")
        XCTAssertEqual(left.tabs[a]?.meta.modifiedAt(TabNode.FieldGroup.placement), at(5))

        let right = try TreeOps.splitTab(s0, layoutID: l1, tabID: a, targetTabID: c, side: .trailing, moveNextToTarget: true, now: at(5))
        XCTAssertEqual(right.splits[l1]?.root.tabIDs, [c, a])
        XCTAssertEqual(right.today(spaceID: home).map(\.id), [c, a, b])

        let stay = try TreeOps.splitTab(s0, layoutID: l1, tabID: a, targetTabID: c, side: .trailing, moveNextToTarget: false, now: at(5))
        XCTAssertEqual(stay.today(spaceID: home).map(\.id), [c, b, a])
        XCTAssertEqual(stay.tabs[a], s0.tabs[a], "not moved, not stamped")
    }

    /// A pinned target: the dropped Today tab joins it in the pinned container.
    func testPinnedTargetPullsTabIntoPinnedArea() throws {
        var s = try base()
        s = try TreeOps.pinTab(s, id: c, now: t0)
        let out = try TreeOps.splitTab(s, layoutID: l1, tabID: a, targetTabID: c, side: .trailing, moveNextToTarget: true, now: at(5))
        XCTAssertEqual(out.tabs[a]?.location, .pinned(spaceID: home, folderID: nil))
        XCTAssertEqual(out.pinnedChildren(spaceID: home, folderID: nil).map(\.id), [c, a])
    }

    /// Target already in a split: the dropped tab joins that layout beside it (no new layout); the
    /// dropped tab leaves its own old layout, which collapses when one pane is left.
    func testJoinsExistingLayoutAndLeavesOldOne() throws {
        var s = try base()
        s = try TreeOps.addSplitPane(s, layoutID: l1, existingTabID: b, newTabID: c, now: t0)   // [b, c]
        let out = try TreeOps.splitTab(s, layoutID: l2, tabID: a, targetTabID: c, side: .leading, moveNextToTarget: true, now: at(5))
        XCTAssertEqual(out.splits[l1]?.root.tabIDs, [b, a, c])
        XCTAssertNil(out.splits[l2], "no new layout")
        XCTAssertEqual(out.splits[l1]?.meta.modifiedAt(SplitLayout.FieldGroup.layout), at(5))

        // b leaves [b, c] for a split with a: [b, c] collapses (tombstoned), a new [a, b] forms.
        let moved = try TreeOps.splitTab(s, layoutID: l2, tabID: b, targetTabID: a, side: .trailing, moveNextToTarget: true, now: at(6))
        XCTAssertTrue(moved.splits[l1]?.meta.isTombstone == true, "delete by tombstone")
        XCTAssertEqual(moved.splits[l2]?.root.tabIDs, [a, b])
    }

    /// Bad input throws: the same tab, a tombstoned tab, tabs in different Spaces.
    func testRejectsBadInput() throws {
        let s = try base()
        XCTAssertThrowsError(try TreeOps.splitTab(s, layoutID: l1, tabID: a, targetTabID: a, side: .leading, moveNextToTarget: true, now: at(5)))
        XCTAssertThrowsError(try TreeOps.splitTab(s, layoutID: l1, tabID: a, targetTabID: w, side: .leading, moveNextToTarget: true, now: at(5))) {
            XCTAssertEqual($0 as? TreeError, .spaceMismatch)
        }
        let archived = try TreeOps.archiveTab(s, id: c, now: at(1))
        XCTAssertThrowsError(try TreeOps.splitTab(archived, layoutID: l1, tabID: a, targetTabID: c, side: .leading, moveNextToTarget: true, now: at(5))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(c))
        }
    }

    /// `inserting(_:beside:side:axis:)` keeps the "after" behavior for trailing and inserts before
    /// for leading, in a same-axis parent and in a nested pane.
    func testInsertingBesideSides() {
        let x = UUID()
        let two = SplitNode.split(axis: .horizontal, children: [.init(node: .pane(tabID: a), fraction: 0.5), .init(node: .pane(tabID: b), fraction: 0.5)])
        XCTAssertEqual(two.inserting(x, beside: b, side: .leading, axis: .horizontal).tabIDs, [a, x, b])
        XCTAssertEqual(two.inserting(x, beside: b, side: .trailing, axis: .horizontal).tabIDs, [a, b, x])
        XCTAssertEqual(two.inserting(x, after: a, axis: .horizontal), two.inserting(x, beside: a, side: .trailing, axis: .horizontal))
        XCTAssertEqual(SplitNode.pane(tabID: a).inserting(x, beside: a, side: .leading, axis: .horizontal).tabIDs, [x, a])
    }
}
