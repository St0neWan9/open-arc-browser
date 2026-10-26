import XCTest
@testable import OpenArcModel

/// `TreeOps.moveSpace`: reordering spaces from the Library Spaces board ("Manage Spaces").
/// Acceptance: `06 §8` observed (each board column has a drag handle).
final class TreeOpsMoveSpaceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// Fixed ids with a < b < c, so ties between equal sort keys break the same way every run.
    private static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    private let profile = id(1), a = id(2), b = id(3), c = id(4)

    private func base() throws -> WorkspaceState {
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: a, profileID: profile, name: "A", now: t0)
        s = try TreeOps.createSpace(s, id: b, profileID: profile, name: "B", now: t0)
        s = try TreeOps.createSpace(s, id: c, profileID: profile, name: "C", now: t0)
        return s
    }

    private func order(_ s: WorkspaceState) -> [UUID] { s.allLiveSpaces.map(\.id) }

    /// [06 §8] observed (drag handle): every position moves the space and keeps the others in order.
    func testMoveSpaceToEveryPosition() throws {
        let s0 = try base()
        XCTAssertEqual(order(s0), [a, b, c])
        XCTAssertEqual(order(try TreeOps.moveSpace(s0, id: c, position: .first, now: at(1))), [c, a, b])
        XCTAssertEqual(order(try TreeOps.moveSpace(s0, id: a, position: .last, now: at(1))), [b, c, a])
        XCTAssertEqual(order(try TreeOps.moveSpace(s0, id: a, position: .after(b), now: at(1))), [b, a, c])
        XCTAssertEqual(order(try TreeOps.moveSpace(s0, id: c, position: .before(b), now: at(1))), [a, c, b])
    }

    /// Stamps only `Space.placement` of the moved space; other spaces stay untouched.
    func testMoveSpaceStampsOnlyPlacement() throws {
        let s0 = try base()
        let s = try TreeOps.moveSpace(s0, id: a, position: .last, now: at(10))
        var expected = s0.spaces[a]?.meta.fieldGroupModifiedAt ?? [:]
        expected[Space.FieldGroup.placement.rawValue] = at(10)
        XCTAssertEqual(s.spaces[a]?.meta.fieldGroupModifiedAt, expected)
        XCTAssertEqual(s.spaces[b], s0.spaces[b])
        XCTAssertEqual(s.spaces[c], s0.spaces[c])
    }

    /// Equal keys (after concurrent edits) are rebalanced; the result is still a strict order.
    func testMoveSpaceRebalancesEqualKeys() throws {
        var s0 = try base()
        let key = try XCTUnwrap(s0.spaces[a]?.dockSortKey)
        s0.spaces[b]?.dockSortKey = key
        s0.spaces[c]?.dockSortKey = key
        XCTAssertEqual(order(s0), [a, b, c]) // equal keys: the UUID tie-break orders them
        // c between a and b: the two neighbours share a key, so every space is re-keyed.
        let s = try TreeOps.moveSpace(s0, id: c, position: .after(a), now: at(10))
        XCTAssertEqual(order(s), [a, c, b])
        XCTAssertEqual(Set(s.allLiveSpaces.map(\.dockSortKey)).count, 3)
        XCTAssertEqual(s.spaces[b]?.meta.fieldGroupModifiedAt[Space.FieldGroup.placement.rawValue], at(10))
    }

    /// Errors: missing or tombstoned space or anchor; moving next to itself is a no-op.
    func testMoveSpaceErrorsAndSelfAnchor() throws {
        let s0 = try base()
        let ghost = UUID()
        XCTAssertThrowsError(try TreeOps.moveSpace(s0, id: ghost, position: .first, now: at(1))) {
            XCTAssertEqual($0 as? TreeError, .notFound(ghost))
        }
        XCTAssertThrowsError(try TreeOps.moveSpace(s0, id: a, position: .before(ghost), now: at(1))) {
            XCTAssertEqual($0 as? TreeError, .notFound(ghost))
        }
        let gone = try TreeOps.deleteSpace(s0, id: b, now: at(1))
        XCTAssertThrowsError(try TreeOps.moveSpace(gone, id: a, position: .after(b), now: at(2))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(self.b))
        }
        XCTAssertEqual(try TreeOps.moveSpace(s0, id: a, position: .after(a), now: at(1)), s0)
    }
}
