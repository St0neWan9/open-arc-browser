import XCTest
@testable import OpenArcModel

/// `TreeOps.setSplitFractions` (plan B58): a divider drag stores the ratio of the panes, not
/// their widths. Spec: docs/arc-spec/06-flows.md §21.6 "调整比例", observed: the ratio survives tab
/// switches and hiding the sidebar.
final class TreeOpsSplitFractionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private let profile = UUID(), home = UUID()
    private let a = UUID(), b = UUID(), c = UUID()
    private let layout = UUID()

    /// Home Today: a, b, c. Layout: a | b, then c added below b (a | (b / c)).
    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: t0)
        for id in [a, b, c] { s = try TreeOps.openTab(s, id: id, spaceID: home, url: nil, title: "", now: t0) }
        s = try TreeOps.addSplitPane(s, layoutID: layout, existingTabID: a, newTabID: b, now: t0)
        return try TreeOps.addSplitPane(s, layoutID: UUID(), existingTabID: b, newTabID: c, axis: .vertical, now: t0)
    }

    private func fractions(_ node: SplitNode?) -> [Double] {
        guard case .split(_, let children)? = node else { return [] }
        return children.map(\.fraction)
    }

    /// [06 §21.6] observed: the stored value is the fraction (459 / 1624 = 0.283 in the capture);
    /// only the layout group is stamped and the tabs are untouched.
    func testStoresNormalizedFractionsAndStampsLayoutOnly() throws {
        let s0 = try base()
        let s = try TreeOps.setSplitFractions(s0, layoutID: layout, path: [], fractions: [459, 1165], now: at(10))
        let root = try XCTUnwrap(s.splits[layout]?.root)
        XCTAssertEqual(fractions(root)[0], 459.0 / 1624.0, accuracy: 1e-9)
        XCTAssertEqual(fractions(root).reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(root.tabIDs, [a, b, c], "panes keep their order")
        XCTAssertEqual(s.splits[layout]?.meta.modifiedAt(SplitLayout.FieldGroup.layout), at(10))
        XCTAssertEqual(s.tabs, s0.tabs)
    }

    /// Nested splits: each divider adjusts only the split node it belongs to. inferred.
    func testNestedPathChangesOnlyThatSplit() throws {
        let s0 = try base()
        let s = try TreeOps.setSplitFractions(s0, layoutID: layout, path: [1], fractions: [0.3, 0.7], now: at(10))
        let root = try XCTUnwrap(s.splits[layout]?.root)
        XCTAssertEqual(fractions(root), fractions(s0.splits[layout]?.root), "outer split unchanged")
        let inner = fractions(root.node(at: [1]))
        XCTAssertEqual(inner[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(inner[1], 0.7, accuracy: 1e-9)
    }

    /// The same fractions again change nothing and write no stamp.
    func testUnchangedFractionsDoNotStamp() throws {
        let s0 = try base()
        let s = try TreeOps.setSplitFractions(s0, layoutID: layout, path: [], fractions: [0.5, 0.5], now: at(10))
        XCTAssertEqual(s, s0)
    }

    func testRejectsBadInputWithoutChanges() throws {
        let s0 = try base()
        XCTAssertThrowsError(try TreeOps.setSplitFractions(s0, layoutID: UUID(), path: [], fractions: [0.5, 0.5], now: at(1)))
        for (path, f) in [([Int](), [1.0]), ([], [0.5, 0, 0.5]), ([], [-1, 2]), ([], [.nan, 1]), ([0], [0.5, 0.5]), ([7], [0.5, 0.5])] {
            XCTAssertThrowsError(try TreeOps.setSplitFractions(s0, layoutID: layout, path: path, fractions: f, now: at(1))) {
                XCTAssertEqual($0 as? TreeError, .invalidSplitFractions)
            }
        }
        var dead = s0
        dead.splits[layout]?.meta.markDeleted(at: at(1))
        XCTAssertThrowsError(try TreeOps.setSplitFractions(dead, layoutID: layout, path: [], fractions: [0.4, 0.6], now: at(2)))
    }
}
