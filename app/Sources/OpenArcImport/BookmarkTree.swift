import Foundation

// Bookmarks read from another browser, before they are mapped onto the workspace.
//
// Spec: [01 §Arc] observed only the menu item "Import from Another Browser…". Everything about what
// is imported and where it lands is inferred (D3): see `BookmarkImportMapper`.

/// One bookmark or folder as the source browser stores it.
public enum BookmarkNode: Hashable, Sendable {
    case bookmark(Bookmark)
    case folder(BookmarkFolder)
}

/// A bookmark. `url` is kept as the raw string from the file; the mapper decides whether it can be
/// imported (only http, https and file are).
public struct Bookmark: Hashable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// A folder with its children in the source browser's order. Empty folders are kept.
public struct BookmarkFolder: Hashable, Sendable {
    public var title: String
    public var children: [BookmarkNode]

    public init(title: String, children: [BookmarkNode] = []) {
        self.title = title
        self.children = children
    }
}

/// Every bookmark of one source, split into the bookmark bar and the rest.
///
/// - `bar`: the bookmarks bar / toolbar / Safari Favorites. Becomes the pinned area of the new Space.
/// - `other`: every other root (Chrome "Other bookmarks" and "Mobile bookmarks", Firefox "Bookmarks
///   Menu" and "Other Bookmarks", Safari "Bookmarks Menu" and Reading List). Becomes one pinned
///   folder "Other Bookmarks". inferred.
public struct BookmarkTree: Hashable, Sendable {
    public var bar: [BookmarkNode]
    public var other: [BookmarkNode]

    public init(bar: [BookmarkNode] = [], other: [BookmarkNode] = []) {
        self.bar = bar
        self.other = other
    }

    /// Number of bookmarks (not folders) at any depth, importable or not.
    public var bookmarkCount: Int { Self.count(bar) + Self.count(other) }

    private static func count(_ nodes: [BookmarkNode]) -> Int {
        nodes.reduce(0) { total, node in
            switch node {
            case .bookmark: return total + 1
            case .folder(let folder): return total + count(folder.children)
            }
        }
    }
}

/// Kinds of data an import can bring over.
///
/// Bookmarks are read by the shell (D3) and become sidebar items. History and passwords go into the
/// profile's engine data through the engine's importer (plan D3b, `EngineImporter`), which reads the
/// other browsers' databases and keychain items; the import sheet shows a checkbox per kind and
/// disables the engine kinds when the engine has no importer. inferred.
public enum ImportDataKind: String, CaseIterable, Hashable, Sendable {
    case bookmarks
    case history
    case passwords

    /// The kinds the import sheet offers.
    public static let availableInShell: Set<ImportDataKind> = [.bookmarks, .history, .passwords]
    /// The kinds the engine imports (the rest the shell reads itself).
    public static let engineKinds: Set<ImportDataKind> = [.history, .passwords]
}

/// Why a bookmarks file could not be read.
public enum BookmarkImportError: Error, Equatable, Sendable {
    /// The file is none of the supported formats (Chromium JSON, Netscape HTML, Safari plist).
    case unrecognizedFormat
    /// The file has the right format but not the expected structure.
    case malformed(String)
    /// The file could not be read.
    case unreadable(String)
}
