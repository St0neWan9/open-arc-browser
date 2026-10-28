import Foundation
import OpenArcModel

/// What a sidebar import added. Shown in the sheet after the import.
public struct ForeignSidebarImportSummary: Hashable, Sendable {
    /// The new Spaces, in dock order.
    public var spaceIDs: [UUID] = []
    public var folders = 0
    /// Pinned and Today tabs (split members included).
    public var tabs = 0
    /// Of `tabs`, the ones in the Today area.
    public var todayTabs = 0
    public var favorites = 0
    /// Favorites left out because the profile already has a favorite with that URL.
    public var existingFavorites = 0
    /// Split rows rebuilt as split views.
    public var splits = 0
    /// Rows the reader or the mapper left out: unknown kinds, folders among the favorites, and
    /// pages whose URL is not http, https or file.
    public var skipped = 0
    /// Spaces that belonged to another profile of the source (imported into this profile).
    public var spacesFromOtherProfiles = 0

    public init() {}

    public var spaces: Int { spaceIDs.count }
}

/// Maps a `ForeignSidebar` onto the workspace through `TreeOps` (plan D15). All inferred:
/// - every source Space becomes a NEW Space appended to the end of the dock of `profileID`, in the
///   source order, with the source name; existing Spaces are never touched and a second import
///   adds the Spaces again (no merge);
/// - the Space's color becomes a new theme (`defaultTheme` when the source has none); an emoji icon
///   is kept, a named icon only when it is one of `knownSymbols` (else no icon);
/// - pinned rows become pinned tabs, folders (nested; top level expanded, deeper ones collapsed
///   like D3) and split views; Today rows become Today tabs in the same order;
/// - favorites are appended to the profile's favorites, except URLs that are already favorites
///   there (favorites are shared by every Space of the profile, so a repeat would duplicate them);
///   folders cannot be favorites and are skipped, a split's tabs become separate favorites;
/// - only http, https and file URLs are imported; the rest are counted in `skipped`.
public enum ForeignSidebarMapper {
    public static let untitledSpaceName = "Untitled"
    public static let untitledFolderName = "Untitled"

    public static func apply(
        _ sidebar: ForeignSidebar,
        to state: WorkspaceState,
        profileID: UUID,
        defaultTheme: ThemeStyle,
        knownSymbols: Set<String>,
        now: Date,
        makeID: () -> UUID
    ) throws -> (state: WorkspaceState, summary: ForeignSidebarImportSummary) {
        var writer = Writer(state: state, profileID: profileID, now: now)
        writer.summary.skipped = sidebar.skipped
        for space in sidebar.spaces {
            try writer.addSpace(space, defaultTheme: defaultTheme, knownSymbols: knownSymbols, makeID: makeID)
        }
        try writer.addFavorites(sidebar.favorites, makeID: makeID)
        return (writer.state, writer.summary)
    }

    /// The icon to store for a source icon, or nil.
    public static func icon(_ icon: ForeignIcon?, knownSymbols: Set<String>) -> String? {
        switch icon {
        case .emoji(let emoji)?:
            let trimmed = emoji.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .symbol(let name)?:
            return knownSymbols.contains(name) ? name : nil
        case nil:
            return nil
        }
    }

    private struct Writer {
        var state: WorkspaceState
        let profileID: UUID
        let now: Date
        var summary = ForeignSidebarImportSummary()

        mutating func addSpace(_ space: ForeignSpace, defaultTheme: ThemeStyle, knownSymbols: Set<String>, makeID: () -> UUID) throws {
            let spaceID = makeID()
            let themeID = makeID()
            state = TreeOps.createTheme(state, id: themeID, style: space.theme ?? defaultTheme, now: now)
            let name = space.name.trimmingCharacters(in: .whitespacesAndNewlines)
            state = try TreeOps.createSpace(
                state, id: spaceID, profileID: profileID, name: name.isEmpty ? ForeignSidebarMapper.untitledSpaceName : name,
                icon: ForeignSidebarMapper.icon(space.icon, knownSymbols: knownSymbols), themeID: themeID,
                afterSpaceID: nil, now: now
            )
            summary.spaceIDs.append(spaceID)
            if space.isFromOtherProfile { summary.spacesFromOtherProfiles += 1 }
            try add(space.pinned, to: .pinned(spaceID: spaceID, folderID: nil), spaceID: spaceID, depth: 0, makeID: makeID)
            let before = summary.tabs
            try add(space.today, to: .today(spaceID: spaceID), spaceID: spaceID, depth: 0, makeID: makeID)
            summary.todayTabs += summary.tabs - before
        }

        mutating func add(_ items: [ForeignSidebarItem], to location: TabLocation, spaceID: UUID, depth: Int, makeID: () -> UUID) throws {
            for item in items {
                switch item {
                case .page(let page):
                    if try addTab(page, to: location, spaceID: spaceID, makeID: makeID) != nil { summary.tabs += 1 }
                case .split(let split):
                    var members: [UUID] = []
                    for page in split.pages {
                        if let id = try addTab(page, to: location, spaceID: spaceID, makeID: makeID) {
                            members.append(id)
                            summary.tabs += 1
                        }
                    }
                    guard members.count > 1 else { continue }
                    let layoutID = makeID()
                    for member in members.dropFirst() {
                        state = try TreeOps.addSplitPane(
                            state, layoutID: layoutID, existingTabID: members[0], newTabID: member, axis: split.axis, now: now
                        )
                    }
                    summary.splits += 1
                case .folder(let folder):
                    // Folders live in the pinned area only; a folder found in Today keeps its
                    // contents there as plain rows. inferred.
                    guard case .pinned(_, let parentID) = location else {
                        try add(folder.children, to: location, spaceID: spaceID, depth: depth, makeID: makeID)
                        continue
                    }
                    let id = makeID()
                    let title = folder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    state = try TreeOps.createFolder(
                        state, id: id, spaceID: spaceID, parentFolderID: parentID,
                        title: title.isEmpty ? ForeignSidebarMapper.untitledFolderName : title, now: now
                    )
                    state = try TreeOps.moveFolder(state, id: id, toSpace: spaceID, parentFolderID: parentID, position: .last, now: now)
                    if depth > 0 { state = try TreeOps.setFolderExpanded(state, id: id, isExpanded: false, now: now) }
                    summary.folders += 1
                    try add(folder.children, to: .pinned(spaceID: spaceID, folderID: id), spaceID: spaceID, depth: depth + 1, makeID: makeID)
                }
            }
        }

        /// Opens a tab (at the top of Today) and moves it to the end of `location`. Returns nil and
        /// counts a skip when the URL cannot be imported.
        mutating func addTab(_ page: ForeignPage, to location: TabLocation, spaceID: UUID, makeID: () -> UUID) throws -> UUID? {
            guard let url = BookmarkImportMapper.importableURL(page.url) else {
                summary.skipped += 1
                return nil
            }
            let id = makeID()
            state = try TreeOps.openTab(state, id: id, spaceID: spaceID, url: url, title: Self.title(page, url: url), now: now)
            state = try TreeOps.moveTab(state, id: id, to: location, position: .last, now: now)
            if let emoji = page.emoji?.trimmingCharacters(in: .whitespacesAndNewlines), !emoji.isEmpty {
                state = try TreeOps.setTabIcon(state, id: id, icon: emoji, now: now)
            }
            return id
        }

        mutating func addFavorites(_ items: [ForeignSidebarItem], makeID: () -> UUID) throws {
            var pages: [ForeignPage] = []
            for item in items {
                switch item {
                case .page(let page): pages.append(page)
                case .split(let split): pages += split.pages
                case .folder(let folder): summary.skipped += 1 + Self.count(folder.children)
                }
            }
            guard !pages.isEmpty else { return }
            // A favorite is opened in a Space first; the first new Space hosts it, else the
            // profile's first Space. Favorites need one to exist.
            guard let hostID = summary.spaceIDs.first ?? state.spaces(inProfile: profileID).first?.id else {
                summary.skipped += pages.count
                return
            }
            var existing = Set(state.favorites(profileID: profileID).compactMap { ($0.pinnedURL ?? $0.url)?.absoluteString })
            for page in pages {
                guard let url = BookmarkImportMapper.importableURL(page.url) else {
                    summary.skipped += 1
                    continue
                }
                guard existing.insert(url.absoluteString).inserted else {
                    summary.existingFavorites += 1
                    continue
                }
                _ = try addTab(page, to: .favorite(profileID: profileID), spaceID: hostID, makeID: makeID)
                summary.favorites += 1
            }
        }

        static func count(_ items: [ForeignSidebarItem]) -> Int {
            items.reduce(0) { total, item in
                switch item {
                case .page: return total + 1
                case .split(let split): return total + split.pages.count
                case .folder(let folder): return total + 1 + count(folder.children)
                }
            }
        }

        /// The row title, else the host, else the URL.
        static func title(_ page: ForeignPage, url: URL) -> String {
            let trimmed = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return url.host ?? url.absoluteString
        }
    }
}
