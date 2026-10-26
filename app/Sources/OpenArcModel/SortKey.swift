import Foundation

/// Fractional-index sort key: a new key can always be generated between any two keys, so
/// moving a node only rewrites that node's own record.
///
/// Why: a move touches only the moved record's placement field group, never its siblings,
/// which keeps the sync conflict surface minimal. When two devices concurrently generate the
/// same key, ties are broken by record UUID (see `SortKey.order`).
///
/// Alphabet is `0-9a-z` (ASCII-ordered). Keys never end in `0` (otherwise nothing could be
/// inserted before them).
public struct SortKey: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.isEmpty,
              !rawValue.hasSuffix("0"),
              rawValue.allSatisfy({ SortKey.alphabet.contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }

    private init(unchecked: String) { self.rawValue = unchecked }

    public var description: String { rawValue }

    public static func < (lhs: SortKey, rhs: SortKey) -> Bool { lhs.rawValue < rhs.rawValue }

    // MARK: - Generation

    static let alphabet: [Character] = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    private static let base = alphabet.count

    /// First key in an empty container.
    public static let initial = SortKey(unchecked: "i")

    /// Returns a key strictly between `lower` and `upper`; `nil` bounds mean unbounded.
    /// Returns `nil` if `lower >= upper` (the caller should rebalance siblings first).
    public static func between(_ lower: SortKey?, _ upper: SortKey?) -> SortKey? {
        if let lower, let upper, lower >= upper { return nil }
        let a = lower.map(digits) ?? []
        let b = upper.map(digits)
        let mid = midpoint(a, b)
        return SortKey(unchecked: String(mid.map { alphabet[$0] }))
    }

    /// Generates `count` strictly increasing keys (used for rebalancing).
    public static func sequence(count: Int) -> [SortKey] {
        var keys: [SortKey] = []
        var previous: SortKey? = nil
        for _ in 0..<count {
            // Always appending at the end, so between(previous, nil) cannot fail.
            let next = between(previous, nil)!
            keys.append(next)
            previous = next
        }
        return keys
    }

    /// Orders by (sort key, UUID) — the deterministic tie-break for concurrently equal keys.
    public static func order(_ lhs: (SortKey, UUID), _ rhs: (SortKey, UUID)) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
        return lhs.1.uuidString < rhs.1.uuidString
    }

    private static func digits(_ key: SortKey) -> [Int] {
        key.rawValue.map { ch in alphabet.firstIndex(of: ch)! }
    }

    /// Midpoint of a and b, reading a as 0.a and b as 0.b (nil b means 1.0).
    /// Precondition: a < b and neither ends in 0.
    private static func midpoint(_ a: [Int], _ b: [Int]?) -> [Int] {
        if let b {
            // Skip the common prefix (a is padded with zeros when shorter).
            var n = 0
            while n < b.count && (n < a.count ? a[n] : 0) == b[n] { n += 1 }
            if n > 0 {
                return Array(b[0..<n]) + midpoint(Array(a.dropFirst(n)), Array(b.dropFirst(n)))
            }
        }
        let digitA = a.first ?? 0
        let digitB = b?.first ?? base
        if digitB - digitA > 1 {
            return [(digitA + digitB) / 2]
        }
        // First digits are adjacent.
        if let b, b.count > 1 {
            return [b[0]]
        }
        return [digitA] + midpoint(Array(a.dropFirst()), nil)
    }
}
