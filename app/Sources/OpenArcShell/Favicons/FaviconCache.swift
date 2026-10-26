import Foundation
import OpenArcEngine

// Favicon images for the sidebar rows, favorites, split groups, command bar and Library (C9).
// Our own design (inferred; the spec only records where icons are drawn, [07 §4] observed the
// 18 pt row icon cell):
// - The engine delivers PNG bytes with every favicon change. The cache keeps them in memory by
//   icon URL, by page URL (without fragment) and by page host (without "www."). Lookups go from
//   the most to the least specific key, so a tab that is not loaded yet shows its page's icon, and
//   a page whose icon has not arrived shows the last icon seen on its site.
// - With a directory, each image is also written to `<data dir>/Favicons/` (one small PNG per
//   key), so icons show after relaunch before any page loads. The directory is pruned to
//   `maxDiskEntries` files (oldest first) when the cache is created.
// - Incognito controllers keep theirs in memory only.

/// In-memory favicon cache with an optional on-disk copy. Main actor: the views read it while
/// they render.
@MainActor
public final class FaviconCache {
    /// Most files kept on disk (inferred: a few thousand sites is ~5 MB of 32 px PNGs).
    nonisolated static let maxDiskEntries = 2000
    /// Name of the cache folder inside the data directory.
    public nonisolated static let folderName = "Favicons"

    /// nil: memory only.
    public nonisolated let directory: URL?
    private var memory: [String: Data] = [:]
    /// Keys looked up on disk and not found (avoids a file read per render).
    private var misses: Set<String> = []

    public init(directory: URL?) {
        self.directory = directory
        if let directory {
            Task.detached(priority: .background) { FaviconCache.prune(directory, keeping: FaviconCache.maxDiskEntries) }
        }
    }

    /// The cache for a data directory: `<directory>/Favicons`.
    public convenience init(dataDirectory: URL) {
        self.init(directory: dataDirectory.appendingPathComponent(Self.folderName, isDirectory: true))
    }

    // MARK: Storing

    /// Remembers `favicon`'s image for its icon URL and for `pageURL`'s host. Ignores favicons
    /// without image bytes.
    public func store(_ favicon: Favicon, pageURL: URL?) {
        guard let data = favicon.pngData, !data.isEmpty else { return }
        var keys: [String] = []
        if let iconURL = favicon.url { keys.append(Self.iconKey(iconURL)) }
        if let page = pageURL.flatMap(Self.pageKey) { keys.append(page) }
        if let host = pageURL.flatMap(Self.hostKey) { keys.append(host) }
        for key in keys where memory[key] != data {
            memory[key] = data
            misses.remove(key)
            write(data, key: key)
        }
    }

    // MARK: Lookup

    /// The image for an icon URL, if known.
    public func image(iconURL: URL?) -> Data? {
        iconURL.flatMap { lookup(Self.iconKey($0)) }
    }

    /// The image last seen for this page, else for a page of its site, if any.
    public func image(forPage pageURL: URL?) -> Data? {
        guard let pageURL else { return nil }
        return Self.pageKey(pageURL).flatMap(lookup) ?? Self.hostKey(pageURL).flatMap(lookup)
    }

    /// The icon of a stored tab: its favicon URL first, then its site.
    public func image(iconURL: URL?, pageURL: URL?) -> Data? {
        image(iconURL: iconURL) ?? image(forPage: pageURL)
    }

    private func lookup(_ key: String) -> Data? {
        if let data = memory[key] { return data }
        guard let directory, !misses.contains(key) else { return nil }
        if let data = try? Data(contentsOf: Self.fileURL(directory, key: key)), !data.isEmpty {
            memory[key] = data
            return data
        }
        misses.insert(key)
        return nil
    }

    // MARK: Disk

    private func write(_ data: Data, key: String) {
        guard let directory else { return }
        let file = Self.fileURL(directory, key: key)
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Removes the oldest files beyond `limit`.
    nonisolated static func prune(_ directory: URL, keeping limit: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > limit else { return }
        let dated = files.map { file -> (URL, Date) in
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return (file, date)
        }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? fm.removeItem(at: file)
        }
    }

    // MARK: Keys

    nonisolated static func iconKey(_ url: URL) -> String { "i:" + url.absoluteString }

    /// "p:<url>" without the fragment; nil without a host.
    nonisolated static func pageKey(_ url: URL) -> String? {
        guard url.host?.isEmpty == false else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return "p:" + (components?.url?.absoluteString ?? url.absoluteString)
    }

    /// "h:<host>" with the host lowercased and a leading "www." removed; nil without a host.
    nonisolated static func hostKey(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return "h:" + host
    }

    /// Same site (`hostKey`) for two page URLs.
    nonisolated static func isSameSite(_ a: URL?, _ b: URL?) -> Bool {
        guard let a = a.flatMap(hostKey), let b = b.flatMap(hostKey) else { return false }
        return a == b
    }

    /// `<directory>/<16 hex digits of the key's FNV-1a hash>.png`.
    nonisolated static func fileURL(_ directory: URL, key: String) -> URL {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return directory.appendingPathComponent(String(format: "%016llx.png", hash))
    }
}
