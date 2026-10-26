import XCTest
@testable import OpenArcModel

final class SortKeyTests: XCTestCase {
    func testBetweenUnboundedGivesInitialRange() throws {
        let key = try XCTUnwrap(SortKey.between(nil, nil))
        XCTAssertEqual(key, SortKey.initial)
    }

    func testBetweenRejectsInvertedOrEqualBounds() throws {
        let a = try XCTUnwrap(SortKey(rawValue: "m"))
        let b = try XCTUnwrap(SortKey(rawValue: "c"))
        XCTAssertNil(SortKey.between(a, b))
        XCTAssertNil(SortKey.between(a, a))
    }

    func testRawValueValidation() {
        XCTAssertNil(SortKey(rawValue: ""))
        XCTAssertNil(SortKey(rawValue: "a0"))   // trailing zero
        XCTAssertNil(SortKey(rawValue: "A"))    // outside alphabet
        XCTAssertNotNil(SortKey(rawValue: "0a"))
    }

    /// Randomized: hundreds of inserts before / after / between existing keys keep a strictly
    /// increasing order and never produce a key ending in "0".
    func testRandomInsertionsStayStrictlyOrdered() throws {
        var rng = SeededGenerator(seed: 42)
        var keys: [SortKey] = [SortKey.initial]
        for _ in 0..<600 {
            let slot = Int.random(in: 0...keys.count, using: &rng)
            let lower = slot > 0 ? keys[slot - 1] : nil
            let upper = slot < keys.count ? keys[slot] : nil
            let key = try XCTUnwrap(SortKey.between(lower, upper))
            if let lower { XCTAssertLessThan(lower, key) }
            if let upper { XCTAssertLessThan(key, upper) }
            XCTAssertFalse(key.rawValue.hasSuffix("0"), "key \(key) ends in 0")
            keys.insert(key, at: slot)
        }
        for i in 1..<keys.count {
            XCTAssertLessThan(keys[i - 1], keys[i])
        }
    }

    func testRepeatedPrependAndAppend() throws {
        var first = SortKey.initial
        var last = SortKey.initial
        for _ in 0..<200 {
            let before = try XCTUnwrap(SortKey.between(nil, first))
            let after = try XCTUnwrap(SortKey.between(last, nil))
            XCTAssertLessThan(before, first)
            XCTAssertLessThan(last, after)
            first = before
            last = after
        }
    }

    func testSequenceIsStrictlyIncreasing() {
        let keys = SortKey.sequence(count: 50)
        XCTAssertEqual(keys.count, 50)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertEqual(Set(keys).count, 50)
    }

    /// Two devices can create the same key concurrently; order must still be deterministic.
    func testEqualKeysTieBreakByUUID() throws {
        let key = SortKey.initial
        let a = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let b = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        XCTAssertTrue(SortKey.order((key, a), (key, b)))
        XCTAssertFalse(SortKey.order((key, b), (key, a)))
    }

    func testPlacementRebalancesWhenNeighboursCollide() throws {
        let key = SortKey.initial
        let a = UUID(), b = UUID()
        let siblings = [(key, a), (key, b)].sorted { SortKey.order($0, $1) }
        let result = try TreeOps.placementKey(siblings: siblings, position: .after(siblings[0].1))
        XCTAssertEqual(result.rebalanced.count, 2)
        let k0 = try XCTUnwrap(result.rebalanced[siblings[0].1])
        let k1 = try XCTUnwrap(result.rebalanced[siblings[1].1])
        XCTAssertLessThan(k0, result.key)
        XCTAssertLessThan(result.key, k1)
    }
}

/// Small deterministic RNG (SplitMix64) so randomized tests are reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
