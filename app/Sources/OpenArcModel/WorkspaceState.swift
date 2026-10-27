import Foundation

/// The whole persisted sidebar graph as one value. Records are stored flat (keyed by id) with
/// parent references and sort keys, which maps one-to-one onto sync records.
///
/// Tombstoned records stay in the dictionaries until the sync layer purges them; every query
/// below filters them out.
public struct WorkspaceState: Codable, Hashable, Sendable {
    public var profiles: [UUID: Profile]
    public var themes: [UUID: Theme]
    public var spaces: [UUID: Space]
    public var folders: [UUID: Folder]
    public var tabs: [UUID: TabNode]
    public var archive: [UUID: ArchiveItem]
    public var splits: [UUID: SplitLayout]
    /// Easels and their elements (B56, Easel.swift). Data written before they existed decodes
    /// with none.
    public var easels: [UUID: Easel]
    public var easelElements: [UUID: EaselElement]

    public init(
        profiles: [UUID: Profile] = [:],
        themes: [UUID: Theme] = [:],
        spaces: [UUID: Space] = [:],
        folders: [UUID: Folder] = [:],
        tabs: [UUID: TabNode] = [:],
        archive: [UUID: ArchiveItem] = [:],
        splits: [UUID: SplitLayout] = [:],
        easels: [UUID: Easel] = [:],
        easelElements: [UUID: EaselElement] = [:]
    ) {
        self.profiles = profiles
        self.themes = themes
        self.spaces = spaces
        self.folders = folders
        self.tabs = tabs
        self.archive = archive
        self.splits = splits
        self.easels = easels
        self.easelElements = easelElements
    }

    private enum CodingKeys: String, CodingKey {
        case profiles, themes, spaces, folders, tabs, archive, splits, easels, easelElements
    }

    /// Decodes a workspace; tables added after the first format (Easels) may be missing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([UUID: Profile].self, forKey: .profiles)
        themes = try c.decode([UUID: Theme].self, forKey: .themes)
        spaces = try c.decode([UUID: Space].self, forKey: .spaces)
        folders = try c.decode([UUID: Folder].self, forKey: .folders)
        tabs = try c.decode([UUID: TabNode].self, forKey: .tabs)
        archive = try c.decode([UUID: ArchiveItem].self, forKey: .archive)
        splits = try c.decode([UUID: SplitLayout].self, forKey: .splits)
        easels = try c.decodeIfPresent([UUID: Easel].self, forKey: .easels) ?? [:]
        easelElements = try c.decodeIfPresent([UUID: EaselElement].self, forKey: .easelElements) ?? [:]
    }
}

/// One row inside the pinned area: folders and tabs share the same ordering space.
public enum PinnedItem: Hashable, Sendable {
    case folder(Folder)
    case tab(TabNode)

    public var id: UUID {
        switch self {
        case .folder(let f): return f.id
        case .tab(let t): return t.id
        }
    }

    public var sortKey: SortKey {
        switch self {
        case .folder(let f): return f.sortKey
        case .tab(let t): return t.sortKey
        }
    }
}

// MARK: - Queries

extension WorkspaceState {
    /// Live (non-tombstoned) spaces of a profile, in dock order. A space whose profile reference
    /// does not resolve on this device counts as the Default profile's (`localProfileID(for:)`).
    public func spaces(inProfile profileID: UUID) -> [Space] {
        let resolve = profileResolver
        return spaces.values
            .filter { !$0.meta.isTombstone && resolve($0.profileID) == profileID }
            .sorted { SortKey.order(($0.dockSortKey, $0.id), ($1.dockSortKey, $1.id)) }
    }

    /// Live profiles, oldest first (ties broken by id).
    public var liveProfilesOldestFirst: [Profile] {
        profiles.values
            .filter { !$0.meta.isTombstone }
            .sorted { ($0.meta.createdAt, $0.id.uuidString) < ($1.meta.createdAt, $1.id.uuidString) }
    }

    /// The Default profile: the oldest live one. It cannot be deleted. [03 §Profiles] observed
    /// ("The Default Profile cannot be deleted."); "oldest" as the rule is inferred.
    public var defaultProfileID: UUID? { liveProfilesOldestFirst.first?.id }

    /// The local profile a profile reference stands for. Profiles do not sync (plan Q13; Arc says
    /// "Profiles are not synced between computers.", [06 §16.3] observed), while Spaces and
    /// favorites do and keep the profile id of the device that wrote them. A reference to a live
    /// profile of this device is itself; any other (unknown here, or tombstoned) resolves to the
    /// Default profile. Read-only: the stored reference is not rewritten, so nothing is synced
    /// back. nil only when this device has no live profile at all. Mapping to Default is inferred.
    public func localProfileID(for profileID: UUID) -> UUID? {
        profileResolver(profileID)
    }

    /// The local profile of a Space (`localProfileID(for:)` of its reference); nil for an unknown
    /// Space.
    public func profileID(ofSpace spaceID: UUID) -> UUID? {
        spaces[spaceID].flatMap { localProfileID(for: $0.profileID) }
    }

    /// `localProfileID(for:)` with the Default profile looked up once, for filters over many records.
    private var profileResolver: (UUID) -> UUID? {
        let profiles = self.profiles
        let fallback = defaultProfileID
        return { id in
            if let profile = profiles[id], !profile.meta.isTombstone { return id }
            return fallback
        }
    }

    /// Settings of the profile behind a space (its local profile, see `localProfileID(for:)`). A
    /// missing space, or no live profile at all, gives the defaults, so orphaned data still
    /// behaves predictably.
    public func profileSettings(forSpace spaceID: UUID) -> ProfileSettings {
        guard let profileID = profileID(ofSpace: spaceID), let profile = profiles[profileID] else { return .default }
        return profile.settings
    }

    /// "Archive tabs after" for the Today tabs of a space (its profile's setting).
    public func todayLifetime(forSpace spaceID: UUID) -> TimeInterval {
        profileSettings(forSpace: spaceID).todayLifetime
    }

    /// Live spaces of all profiles, in dock order.
    public var allLiveSpaces: [Space] {
        spaces.values
            .filter { !$0.meta.isTombstone }
            .sorted { SortKey.order(($0.dockSortKey, $0.id), ($1.dockSortKey, $1.id)) }
    }

    /// Live tabs at exactly this location, in display order. Favorites are matched by local
    /// profile (`localProfileID(for:)`): the Default profile's favorites include those whose
    /// profile is unknown on this device.
    public func tabs(at location: TabLocation) -> [TabNode] {
        let matches: (TabLocation) -> Bool
        if case .favorite(let profileID) = location {
            let resolve = profileResolver
            matches = { if case .favorite(let p) = $0 { return resolve(p) == profileID } else { return false } }
        } else {
            matches = { $0 == location }
        }
        return tabs.values
            .filter { !$0.meta.isTombstone && matches($0.location) }
            .sorted { SortKey.order(($0.sortKey, $0.id), ($1.sortKey, $1.id)) }
    }

    public func favorites(profileID: UUID) -> [TabNode] { tabs(at: .favorite(profileID: profileID)) }

    public func today(spaceID: UUID) -> [TabNode] { tabs(at: .today(spaceID: spaceID)) }

    /// Live direct children (folders + tabs) of a pinned container, in display order.
    /// `folderID == nil` means the top level of the space's pinned area.
    public func pinnedChildren(spaceID: UUID, folderID: UUID?) -> [PinnedItem] {
        let childFolders = folders.values
            .filter { !$0.meta.isTombstone && $0.spaceID == spaceID && $0.parentFolderID == folderID }
            .map(PinnedItem.folder)
        let childTabs = tabs(at: .pinned(spaceID: spaceID, folderID: folderID)).map(PinnedItem.tab)
        return (childFolders + childTabs)
            .sorted { SortKey.order(($0.sortKey, $0.id), ($1.sortKey, $1.id)) }
    }

    /// Every live tab inside a space's pinned area (recursively) and Today area.
    public func allTabs(inSpace spaceID: UUID) -> [TabNode] {
        tabs.values.filter { !$0.meta.isTombstone && $0.location.spaceID == spaceID }
    }

    /// Folder titles from the top of the pinned area down to `folderID` (inclusive).
    public func folderPath(_ folderID: UUID?) -> [String] {
        var path: [String] = []
        var current = folderID
        var guardCount = 0
        while let id = current, let folder = folders[id], guardCount < 1_000 {
            path.insert(folder.title, at: 0)
            current = folder.parentFolderID
            guardCount += 1
        }
        return path
    }

    /// Whether `folderID` equals `ancestorID` or is nested (at any depth) inside it.
    public func folder(_ folderID: UUID?, isWithin ancestorID: UUID) -> Bool {
        var current = folderID
        var guardCount = 0
        while let id = current, guardCount < 1_000 {
            if id == ancestorID { return true }
            current = folders[id]?.parentFolderID
            guardCount += 1
        }
        return false
    }

    /// Live archive items, newest first.
    public var archiveNewestFirst: [ArchiveItem] {
        archive.values
            .filter { !$0.meta.isTombstone }
            .sorted { ($0.archivedAt, $0.id.uuidString) > ($1.archivedAt, $1.id.uuidString) }
    }
}
