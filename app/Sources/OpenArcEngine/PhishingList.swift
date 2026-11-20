import Foundation
import CryptoKit

// Phishing protection's site list (plan B234, user 2026-11-16: the known gap "Client-side phishing
// detection is off"). Safe Browsing stays off (plan Q22: Google's update API is non-commercial
// only, Web Risk is paid); instead Open Arc publishes a signed list of phishing hosts on its update
// host and the app matches every page it opens against it locally: no visited address leaves the
// device.
//
// Publishing: `scripts/publish-phishing-list.sh` builds the list from Phishing.Database's ACTIVE
// domains (MIT, https://github.com/Phishing-Database/Phishing.Database) and signs a manifest of the
// ad-block ruleset's shape (`AdBlockRulesetManifest`, type `typeIdentifier`) with the same key.
// The app downloads it with `AdBlockRulesetUpdater` into its own store ("Open Arc Phishing").
//
// List file (`ruleset.pb` in the store: the store's generic file name), big-endian:
//   "OAPH" | UInt32 format (1) | UInt64 count | count × UInt64 keys, sorted ascending
// where a key is the first 8 bytes of SHA-256 of a lowercase host. Hashing keeps the file and the
// memory small (≈ 3 MB for 380 000 hosts); a false match needs a 64-bit collision.

public struct PhishingList: Sendable, Equatable {
    public static let typeIdentifier = "org.openarc.phishing-list"
    public static let currentFormat: UInt32 = 1
    static let magic = Data("OAPH".utf8)
    /// The store's directory name in the app's data directory.
    public static let storeDirectoryName = "Open Arc Phishing"
    /// The list file inside a stored version.
    public static let listFileName = "ruleset.pb"
    /// Where the signed manifest lives (the update host of the ad-block ruleset, D14).
    public static let hostedManifestURL = URL(string: "https://raw.githubusercontent.com/St0neWan9/open-arc-browser/updates/phishing/manifest.json")!
    /// Largest list accepted. inferred (≈ 4× today's list).
    public static let maxListBytes = 16 * 1024 * 1024

    private let keys: [UInt64]

    public var count: Int { keys.count }

    public init(keys: [UInt64]) {
        self.keys = keys.sorted()
    }

    /// Reads a list file; nil when it is malformed.
    public init?(data: Data) {
        guard data.count >= 16, data.prefix(4) == Self.magic,
              Self.readUInt32(data, at: 4) == Self.currentFormat else { return nil }
        let count = Self.readUInt64(data, at: 8)
        guard count <= UInt64(Self.maxListBytes / 8), data.count == 16 + Int(count) * 8 else { return nil }
        var keys = [UInt64]()
        keys.reserveCapacity(Int(count))
        for i in 0..<Int(count) { keys.append(Self.readUInt64(data, at: 16 + i * 8)) }
        guard zip(keys, keys.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
        self.keys = keys
    }

    /// The list file for `hosts` (tests and tools; the publish script writes the same bytes).
    public static func file(hosts: [String]) -> Data {
        let keys = Array(Set(hosts.compactMap { normalized($0) }.map(key))).sorted()
        var data = magic
        data.append(bigEndian: currentFormat)
        data.append(bigEndian: UInt64(keys.count))
        for key in keys { data.append(bigEndian: key) }
        return data
    }

    /// Whether `url` is on a listed host: its host as is, and without a leading "www." (the source
    /// lists exact hosts). Only http(s) pages.
    public func contains(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = Self.normalized(url.host ?? "") else { return false }
        if has(Self.key(host)) { return true }
        if host.hasPrefix("www.") { return has(Self.key(String(host.dropFirst(4)))) }
        return has(Self.key("www." + host))
    }

    static func normalized(_ host: String) -> String? {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty || host.contains(" ") ? nil : host
    }

    static func key(_ host: String) -> UInt64 {
        SHA256.hash(data: Data(host.utf8)).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    private func has(_ key: UInt64) -> Bool {
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low < keys.count && keys[low] == key
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data[data.startIndex + offset..<data.startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data[data.startIndex + offset..<data.startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}

private extension Data {
    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
