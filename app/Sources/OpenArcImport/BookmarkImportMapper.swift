import Foundation
import OpenArcModel

/// What an import added. Shown in the sheet after the import.
public struct BookmarkImportSummary: Hashable, Sendable {
    /// The new Space, or nil when nothing was imported.
    public var spaceID: UUID?
    public var spaceName: String
    /// Folders from the source (the "Other Bookmarks" container is not counted).
    public var folders: Int
    /// Bookmarks imported as pinned tabs.
    public var bookmarks: Int
    /// Bookmarks left out because their URL is not http, https or file (bookmarklets, `chrome://`,
    /// `place:`, …) or cannot be parsed.
    public var skipped: Int

    public init(spaceID: UUID? = nil, spaceName: String, folders: Int = 0, bookmarks: Int = 0, skipped: Int = 0) {
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.folders = folders
        self.bookmarks = bookmarks
        self.skipped = skipped
    }
}

/// Maps a `BookmarkTree` onto the workspace through `TreeOps`.
///
/// Mapping (all inferred, D3; the spec only shows the menu item [01 §Arc] observed):
/// - one NEW Space named "Imported from <source>", after `afterSpaceID` like New Space;
/// - the bookmark bar becomes the Space's pinned area: folders → folders (nested), bookmarks →
///   pinned tabs (their pinned URL is the bookmark URL), in the source order;
/// - every other root goes into one pinned folder "Other Bookmarks" below the bar's items (left
///   out when there is nothing in it);
/// - empty folders are kept, duplicates are kept;
/// - only http, https and file URLs are imported; the rest are counted in `skipped`;
/// - imported folders start collapsed except the top level (a large import would otherwise fill
///   the sidebar). inferred.
public enum BookmarkImportMapper {
    public static let otherBookmarksTitle = "Other Bookmarks"
    public static let importableSchemes: Set<String> = ["http", "https", "file"]

    /// The new Space's name for a source.
    public static func spaceName(source: String) -> String { "Imported from \(source)" }

    /// Applies `tree` to `state`. New ids come from `makeID`, every record is stamped with `now`.
    /// Throws (and changes nothing) if the profile or anchor Space is invalid.
    public static func apply(
        _ tree: BookmarkTree,
        to state: WorkspaceState,
        source: String,
        profileID: UUID,
        afterSpaceID: UUID?,
        theme: ThemeStyle?,
        now: Date,
        makeID: () -> UUID
    ) throws -> (state: WorkspaceState, summary: BookmarkImportSummary) {
        var s = state
        let name = spaceName(source: source)
        let spaceID = makeID()
        var themeID: UUID?
        if let theme {
            let id = makeID()
            s = TreeOps.createTheme(s, id: id, style: theme, now: now)
            themeID = id
        }
        let anchor = afterSpaceID.flatMap { id in s.spaces[id].map { !$0.meta.isTombstone && s.localProfileID(for: $0.profileID) == profileID } == true ? id : nil }
        s = try TreeOps.createSpace(s, id: spaceID, profileID: profileID, name: name, themeID: themeID, afterSpaceID: anchor, now: now)
        var summary = BookmarkImportSummary(spaceID: spaceID, spaceName: name)
        var writer = Writer(state: s, spaceID: spaceID, now: now)
        try writer.add(tree.bar, into: nil, depth: 0, summary: &summary, makeID: makeID)
        if !tree.other.isEmpty {
            let folderID = makeID()
            try writer.addFolder(id: folderID, title: otherBookmarksTitle, into: nil, expanded: false)
            try writer.add(tree.other, into: folderID, depth: 1, summary: &summary, makeID: makeID)
        }
        return (writer.state, summary)
    }

    /// The URL to import for a bookmark, or nil when it is skipped.
    public static func importableURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), importableSchemes.contains(scheme) else { return nil }
        if scheme != "file", url.host?.isEmpty ?? true { return nil }
        return url
    }

    /// Tab title: the bookmark title, else the host, else the URL.
    static func title(for bookmark: Bookmark, url: URL) -> String {
        let trimmed = bookmark.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? url.absoluteString
    }

    private struct Writer {
        var state: WorkspaceState
        let spaceID: UUID
        let now: Date

        mutating func add(_ nodes: [BookmarkNode], into folderID: UUID?, depth: Int, summary: inout BookmarkImportSummary, makeID: () -> UUID) throws {
            for node in nodes {
                switch node {
                case .bookmark(let bookmark):
                    guard let url = BookmarkImportMapper.importableURL(bookmark.url) else {
                        summary.skipped += 1
                        continue
                    }
                    let id = makeID()
                    // openTab puts it at the top of Today; moveTab then appends it to the container
                    // and records the pinned URL.
                    state = try TreeOps.openTab(state, id: id, spaceID: spaceID, url: url, title: BookmarkImportMapper.title(for: bookmark, url: url), now: now)
                    state = try TreeOps.moveTab(state, id: id, to: .pinned(spaceID: spaceID, folderID: folderID), position: .last, now: now)
                    summary.bookmarks += 1
                case .folder(let folder):
                    let id = makeID()
                    let title = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    try addFolder(id: id, title: title.isEmpty ? "Untitled" : title, into: folderID, expanded: depth == 0)
                    summary.folders += 1
                    try add(folder.children, into: id, depth: depth + 1, summary: &summary, makeID: makeID)
                }
            }
        }

        /// createFolder puts a folder at the top; it is then moved to the end to keep source order.
        mutating func addFolder(id: UUID, title: String, into parentID: UUID?, expanded: Bool) throws {
            state = try TreeOps.createFolder(state, id: id, spaceID: spaceID, parentFolderID: parentID, title: title, now: now)
            state = try TreeOps.moveFolder(state, id: id, toSpace: spaceID, parentFolderID: parentID, position: .last, now: now)
            if !expanded {
                state = try TreeOps.setFolderExpanded(state, id: id, isExpanded: false, now: now)
            }
        }
    }
}
