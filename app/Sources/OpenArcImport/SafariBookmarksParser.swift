import Foundation

/// Reads Safari's `Bookmarks.plist` (binary or XML property list).
///
/// The shell never opens `~/Library/Safari` on its own: that folder needs Full Disk Access. The user
/// picks the file (or a copy of it) with "Choose File…", so only that file is read.
///
/// Structure: the root is a list node (`WebBookmarkType` = `WebBookmarkTypeList`) whose `Children`
/// are lists and leaves. A leaf (`WebBookmarkTypeLeaf`) has `URLString` and its title in
/// `URIDictionary.title`; a list has `Title` and `Children`. Proxy nodes (History) are skipped.
///
/// Mapping (inferred, D3): the top-level list titled `BookmarksBar` (shown as Favorites) → `bar`;
/// the children of `BookmarksMenu` → straight into `other`; the Reading List
/// (`com.apple.ReadingList`) → a folder "Reading List" in `other`; any other top-level item → `other`.
public enum SafariBookmarksParser {
    static let barTitle = "BookmarksBar"
    static let menuTitle = "BookmarksMenu"
    static let readingListTitle = "com.apple.ReadingList"

    public static func parse(_ data: Data) throws -> BookmarkTree {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw BookmarkImportError.unrecognizedFormat
        }
        guard let root = object as? [String: Any], root["WebBookmarkType"] as? String == "WebBookmarkTypeList" else {
            throw BookmarkImportError.malformed("not a Safari bookmarks list")
        }
        var tree = BookmarkTree()
        for case let child as [String: Any] in root["Children"] as? [Any] ?? [] {
            let title = child["Title"] as? String
            let isList = child["WebBookmarkType"] as? String == "WebBookmarkTypeList"
            switch (isList, title) {
            case (true, barTitle):
                tree.bar.append(contentsOf: children(of: child))
            case (true, menuTitle):
                tree.other.append(contentsOf: children(of: child))
            case (true, readingListTitle):
                tree.other.append(.folder(BookmarkFolder(title: "Reading List", children: children(of: child))))
            default:
                if let node = node(child) { tree.other.append(node) }
            }
        }
        return tree
    }

    private static func children(of list: [String: Any]) -> [BookmarkNode] {
        (list["Children"] as? [Any] ?? []).compactMap { ($0 as? [String: Any]).flatMap(node) }
    }

    private static func node(_ item: [String: Any]) -> BookmarkNode? {
        switch item["WebBookmarkType"] as? String {
        case "WebBookmarkTypeLeaf":
            guard let url = item["URLString"] as? String else { return nil }
            let title = (item["URIDictionary"] as? [String: Any])?["title"] as? String ?? ""
            return .bookmark(Bookmark(title: title, url: url))
        case "WebBookmarkTypeList":
            return .folder(BookmarkFolder(title: item["Title"] as? String ?? "", children: children(of: item)))
        default:
            return nil
        }
    }
}

/// The supported bookmark file formats.
public enum BookmarkFileFormat: String, CaseIterable, Hashable, Sendable {
    /// A Chromium-family profile's `Bookmarks` JSON.
    case chromiumJSON
    /// The Netscape bookmark HTML export.
    case netscapeHTML
    /// Safari's `Bookmarks.plist`.
    case safariPlist

    /// Guesses the format from the content (the extension is often missing: Chrome's file is
    /// `Bookmarks`). Property lists start with `bplist` or `<?xml … <plist`, JSON with `{`.
    public static func detect(_ data: Data) -> BookmarkFileFormat? {
        if data.starts(with: Array("bplist".utf8)) { return .safariPlist }
        let head = String(decoding: data.prefix(2048), as: UTF8.self)
        let trimmed = head.drop { $0.isWhitespace || $0 == "\u{FEFF}" }
        if trimmed.hasPrefix("{") { return .chromiumJSON }
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<!DOCTYPE plist") || trimmed.hasPrefix("<plist") {
            if trimmed.contains("<plist") || trimmed.contains("DOCTYPE plist") { return .safariPlist }
        }
        if NetscapeBookmarksParser.looksLikeNetscape(String(decoding: data, as: UTF8.self)) { return .netscapeHTML }
        return nil
    }
}

/// Reads one bookmarks file of any supported format.
public enum BookmarkFileReader {
    public static func read(_ data: Data) throws -> (format: BookmarkFileFormat, tree: BookmarkTree) {
        guard let format = BookmarkFileFormat.detect(data) else { throw BookmarkImportError.unrecognizedFormat }
        switch format {
        case .chromiumJSON: return (format, try ChromiumBookmarksParser.parse(data))
        case .netscapeHTML: return (format, try NetscapeBookmarksParser.parse(data))
        case .safariPlist: return (format, try SafariBookmarksParser.parse(data))
        }
    }

    /// Reads the file at `url`. Only the given file is opened.
    public static func read(contentsOf url: URL) throws -> (format: BookmarkFileFormat, tree: BookmarkTree) {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BookmarkImportError.unreadable(url.lastPathComponent)
        }
        return try read(data)
    }
}
