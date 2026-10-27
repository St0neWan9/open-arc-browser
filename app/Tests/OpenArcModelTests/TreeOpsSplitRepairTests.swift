import XCTest
@testable import OpenArcModel

/// B67 (review F1 #5): `TreeOps.repairSplits` after remote changes. A merge can leave a split
/// layout naming a tab another device deleted or archived, because the tab's tombstone and the
/// layout travel as separate records. Spec: [06 §5] observed (closing a pane leaves the other as a
/// single page; a split's tabs are one group), [06 §21.6] observed (Separate All Tabs turns the
/// panes into plain rows; the stored ratio is relative). Applying this to remote deletes, and
/// keeping panes whose tab has not arrived yet, is inferred.
final class TreeOpsSplitRepairTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let profile = UUID(), home = UUID()
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let l1 = UUID(), l2 = UUID()

    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: t0)
        for id in [a, b, c, d] { s = try TreeOps.openTab(s, id: id, spaceID: home, url: nil, title: "", now: t0) }
        return s
    }

    /// A layout with `ids` side by side at `fractions`, as it arrived from the server.
    private func layout(_ s: inout WorkspaceState, _ id: UUID, _ ids: [UUID], _ fractions: [Double]) {
        let root = SplitNode.split(axis: .horizontal, children: zip(ids, fractions).map {
            SplitChild(node: .pane(tabID: $0), fraction: $1)
        })
        s.splits[id] = SplitLayout(id: id, spaceID: home, root: root, now: t0)
    }

    /// The merged result of a remote tab tombstone: only the tab record changed.
    private func remoteDelete(_ s: inout WorkspaceState, _ id: UUID) {
        s.tabs[id]?.meta.markDeleted(at: at(1))
    }

    /// B67 acceptance: a remote delete of one tab of a two-pane split tombstones the layout; the
    /// other tab is untouched and is a plain row again. [06 §5] observed.
    func testRemoteDeleteInTwoPaneSplitTombstonesLayout() throws {
        var s = try base()
        layout(&s, l1, [a, b], [0.3, 0.7])
        remoteDelete(&s, b)
        let out = TreeOps.repairSplits(s, now: at(2))
        XCTAssertEqual(out.splits[l1]?.meta.isTombstone, true, "delete wins")
        XCTAssertEqual(out.splits[l1]?.meta.deletedAt, at(2))
        XCTAssertEqual(out.splits[l1]?.root, s.splits[l1]?.root, "only the tombstone changes")
        XCTAssertEqual(out.tabs, s.tabs, "no tab is touched")
        XCTAssertEqual(out.today(spaceID: home).map(\.id), s.today(spaceID: home).map(\.id))
    }

    /// B67: a three-pane split losing one pane keeps the other two, renormalized in proportion
    /// (the ratio is relative, [06 §21.6] observed). Only the `layout` group is stamped.
    func testRemoteDeleteInThreePaneSplitLeavesRenormalizedTwoPaneSplit() throws {
        var s = try base()
        layout(&s, l1, [a, b, c], [0.2, 0.5, 0.3])
        remoteDelete(&s, b)
        let out = TreeOps.repairSplits(s, now: at(2))
        let repaired = try XCTUnwrap(out.splits[l1])
        XCTAssertFalse(repaired.meta.isTombstone)
        guard case .split(.horizontal, let children) = repaired.root else { return XCTFail("still a split") }
        XCTAssertEqual(children.map(\.node), [.pane(tabID: a), .pane(tabID: c)])
        XCTAssertEqual(children[0].fraction, 0.4, accuracy: 1e-9)
        XCTAssertEqual(children[1].fraction, 0.6, accuracy: 1e-9)
        XCTAssertEqual(repaired.meta.modifiedAt(SplitLayout.FieldGroup.layout), at(2))
        // Only `layout` is stamped; the row's title/icon group (B77) keeps its creation time.
        XCTAssertEqual(repaired.meta.modifiedAt(SplitLayout.FieldGroup.naming), t0)
        XCTAssertEqual(out.tabs, s.tabs)
    }

    /// B67: a tab archived on another device (archive item + tab tombstone) leaves the split too,
    /// and so does a pane whose archive item arrived before its tab tombstone (delete wins).
    func testRemoteArchiveDropsPane() throws {
        var s = try base()
        layout(&s, l1, [a, b, c], [1.0 / 3, 1.0 / 3, 1.0 / 3])
        layout(&s, l2, [d, b], [0.5, 0.5])
        // A full archive from the other device, then only the layouts' own copies stay stale.
        let archived = try TreeOps.archiveTab(try base(), id: a, now: at(1))
        s.archive[a] = archived.archive[a]
        s.tabs[a] = archived.tabs[a]
        // `b`: only the archive item has arrived so far.
        let archivedB = try TreeOps.archiveTab(try base(), id: b, now: at(1))
        s.archive[b] = archivedB.archive[b]
        XCTAssertEqual(s.tabs[b]?.meta.isTombstone, false)

        let out = TreeOps.repairSplits(s, now: at(2))
        XCTAssertEqual(out.splits[l1]?.meta.isTombstone, true, "only c is left")
        XCTAssertEqual(out.splits[l2]?.meta.isTombstone, true, "only d is left")
        XCTAssertEqual(out.tabs[c], s.tabs[c])
        XCTAssertEqual(out.tabs[d], s.tabs[d])
    }

    /// A pane whose tab record is missing is kept by the repair (the tab may not have arrived
    /// yet; a tombstone would be final), but `livePanes(dropMissing: true)` hides it.
    func testMissingTabIsKeptByRepairButHiddenByLookup() throws {
        var s = try base()
        let ghost = UUID()
        layout(&s, l1, [a, ghost], [0.5, 0.5])
        layout(&s, l2, [b, c, ghost], [0.25, 0.25, 0.5])
        XCTAssertEqual(TreeOps.repairSplits(s, now: at(2)), s)
        XCTAssertEqual(s.livePanes(of: try XCTUnwrap(s.splits[l1]?.root), dropMissing: true), .pane(tabID: a))
        let shown = s.livePanes(of: try XCTUnwrap(s.splits[l2]?.root), dropMissing: true)
        guard case .split(_, let children)? = shown else { return XCTFail() }
        XCTAssertEqual(children.map(\.node), [.pane(tabID: b), .pane(tabID: c)])
        XCTAssertEqual(children.map(\.fraction), [0.5, 0.5])
    }

    /// A removed pane next to a missing one: the removed pane goes, the missing one stays.
    func testRepairDropsRemovedButKeepsMissingPane() throws {
        var s = try base()
        let ghost = UUID()
        layout(&s, l1, [a, b, ghost], [0.25, 0.25, 0.5])
        remoteDelete(&s, b)
        let out = TreeOps.repairSplits(s, now: at(2))
        XCTAssertEqual(out.splits[l1]?.root.tabIDs, [a, ghost])
        XCTAssertEqual(out.splits[l1]?.meta.isTombstone, false)
    }

    /// Nested layouts: a dead pane inside an inner split collapses that split into its sibling,
    /// which takes the inner split's share.
    func testNestedDeadPaneCollapsesInnerSplit() throws {
        var s = try base()
        s.splits[l1] = SplitLayout(id: l1, spaceID: home, root: .split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 0.4),
            SplitChild(node: .split(axis: .vertical, children: [
                SplitChild(node: .pane(tabID: b), fraction: 0.5),
                SplitChild(node: .pane(tabID: c), fraction: 0.5),
            ]), fraction: 0.6),
        ]), now: t0)
        remoteDelete(&s, c)
        let out = TreeOps.repairSplits(s, now: at(2))
        XCTAssertEqual(out.splits[l1]?.root, .split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 0.4),
            SplitChild(node: .pane(tabID: b), fraction: 0.6),
        ]))
    }

    /// B67: repairing twice changes nothing more; a healthy workspace, and layouts that are
    /// already tombstoned, are returned unchanged (no stamps, no version bumps).
    func testIdempotentAndLeavesHealthyLayoutsAlone() throws {
        var s = try base()
        layout(&s, l1, [a, b, c], [0.2, 0.5, 0.3])
        layout(&s, l2, [d, a], [0.5, 0.5])
        s.splits[l2]?.meta.markDeleted(at: t0)
        XCTAssertEqual(TreeOps.repairSplits(s, now: at(2)), s, "nothing dead: unchanged")

        remoteDelete(&s, b)
        let once = TreeOps.repairSplits(s, now: at(2))
        XCTAssertNotEqual(once, s)
        XCTAssertEqual(TreeOps.repairSplits(once, now: at(3)), once)
        XCTAssertEqual(once.splits[l2], s.splits[l2], "a tombstoned layout is not touched")
    }

    /// A pane that is a live tab is never dropped, wherever the tab sits (pinned, another
    /// folder): repair only reacts to tab tombstones and live archive items.
    func testLiveTabsInOtherContainersStay() throws {
        var s = try base()
        s = try TreeOps.pinTab(s, id: a, now: t0)
        layout(&s, l1, [a, b], [0.5, 0.5])
        XCTAssertEqual(TreeOps.repairSplits(s, now: at(2)), s)
        XCTAssertTrue(s.isLiveSplitPane(a))
        XCTAssertFalse(s.isRemovedTab(UUID()), "missing is not removed")
        XCTAssertFalse(s.isLiveSplitPane(UUID()), "missing is not live")
    }

    /// `livePanes(of:)` is the pure piece the window lookup uses: nil when nothing is left.
    func testLivePanesReturnsNilWhenEveryPaneIsDead() throws {
        var s = try base()
        remoteDelete(&s, a)
        remoteDelete(&s, b)
        let root = SplitNode.split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 0.5),
            SplitChild(node: .pane(tabID: b), fraction: 0.5),
        ])
        XCTAssertNil(s.livePanes(of: root, dropMissing: false))
    }
}
