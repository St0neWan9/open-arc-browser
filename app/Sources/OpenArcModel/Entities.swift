import Foundation

// Every entity is Codable + Sendable + Identifiable, has a stable UUID and carries SyncMetadata.
// Spec citation shorthand: `06 §5` means section 5 of docs/arc-spec/06-flows.md; `04 §sidebar`
// means the sidebar table of docs/arc-spec/04-visual-metrics.md.
// Evidence levels: observed / inferred / unknown.

// MARK: - Color

/// UI-framework-independent color (sRGB, components 0...1).
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Builds a color from 0xRRGGBB.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Profile

/// Unit of browsing-data isolation (cookies, history, etc. are isolated per profile by the engine).
/// One profile can back several spaces. Source: 03-settings (Profiles), 05 §context menus (Set Profile ▸). Observed.
public struct Profile: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        case naming
        /// Profile-level settings (search engine, Today lifetime). [03 §Profiles] observed.
        case settings
    }
    public static let recordTypeName = "Profile"

    public let id: UUID
    public var name: String
    /// Part of the `naming` group: an emoji or an icon name, like `Space.icon`; nil means the
    /// default icon. Chosen in the New Profile sheet (plan B72; [06 §16.3] observed sheet with a
    /// name field, the icon is ours). Files written before this field existed decode with nil.
    public var icon: String?
    /// Part of the `settings` group. Files and records written before this field existed decode
    /// with `ProfileSettings.default`.
    public var settings: ProfileSettings
    public var meta: SyncMetadata

    public init(id: UUID, name: String, icon: String? = nil, settings: ProfileSettings = .default, now: Date) {
        self.id = id
        self.name = name
        self.icon = icon
        self.settings = settings
        self.meta = .new(at: now, groups: FieldGroup.self)
    }

    private enum CodingKeys: String, CodingKey { case id, name, icon, settings, meta }

    /// Decodes a profile; a missing `settings` (data written before the field existed) becomes
    /// the default. Its group timestamp is then missing too and falls back to `createdAt`, so any
    /// real edit on another device wins a merge.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        settings = try c.decodeIfPresent(ProfileSettings.self, forKey: .settings) ?? .default
        meta = try c.decode(SyncMetadata.self, forKey: .meta)
    }
}

// MARK: - Theme

/// Light/dark mode. Source: 06 §2 (auto / light / dark segments in the theme bubble). Observed.
public enum ThemeAppearance: String, Codable, Hashable, Sendable {
    case automatic, light, dark
}

/// Every value of a theme's `style` field group, as one value. Edits replace the whole group at
/// once, which matches how the group is stamped and merged.
public struct ThemeStyle: Hashable, Sendable {
    public var appearance: ThemeAppearance
    public var colors: [RGBAColor]
    public var grain: Double
    public var brightness: Double

    public init(
        appearance: ThemeAppearance = .automatic,
        colors: [RGBAColor],
        grain: Double = 0,
        brightness: Double = Theme.defaultBrightness
    ) {
        self.appearance = appearance
        self.colors = colors
        self.grain = grain
        self.brightness = brightness
    }
}

/// A space theme. Spaces reference it through `themeID`.
/// Source: 04 §theme system, 06 §2. The color derivation algorithm is unknown (00 inventory);
/// see the approximate implementation in OpenArcDesign.
public struct Theme: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup { case style }
    public static let recordTypeName = "Theme"

    public let id: UUID
    public var appearance: ThemeAppearance
    /// Color dots on the picker; there can be several (06 §2, observed). The first one is the primary.
    public var colors: [RGBAColor]
    /// Texture/grain strength 0...1 (06 §2 wavy slider; purpose inferred).
    public var grain: Double
    /// Brightness 0...1 set with the ring knob; 0.5 is neutral (06 §2 ring knob, "brightness/contrast",
    /// inferred). Part of the `style` group. Files and records written before this field existed
    /// decode with the neutral default.
    public var brightness: Double
    public var meta: SyncMetadata

    /// Neutral brightness: the theme colors are used as picked. inferred.
    public static let defaultBrightness = 0.5

    public init(
        id: UUID,
        appearance: ThemeAppearance = .automatic,
        colors: [RGBAColor],
        grain: Double = 0,
        brightness: Double = Theme.defaultBrightness,
        now: Date
    ) {
        self.id = id
        self.appearance = appearance
        self.colors = colors
        self.grain = grain
        self.brightness = brightness
        self.meta = .new(at: now, groups: FieldGroup.self)
    }

    /// The `style` group's values. Setting it does not stamp; use `TreeOps.editTheme`.
    public var style: ThemeStyle {
        get { ThemeStyle(appearance: appearance, colors: colors, grain: grain, brightness: brightness) }
        set {
            appearance = newValue.appearance
            colors = newValue.colors
            grain = newValue.grain
            brightness = newValue.brightness
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, appearance, colors, grain, brightness, meta
    }

    /// Decodes a theme; a missing `brightness` (data written before the field existed) becomes the default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        appearance = try c.decode(ThemeAppearance.self, forKey: .appearance)
        colors = try c.decode([RGBAColor].self, forKey: .colors)
        grain = try c.decode(Double.self, forKey: .grain)
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? Theme.defaultBrightness
        meta = try c.decode(SyncMetadata.self, forKey: .meta)
    }
}

// MARK: - Space

/// A workspace holding a set of tabs. Source: 05 §window hierarchy, 06 §1. Observed.
public struct Space: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        /// Name and icon.
        case naming
        /// Theme reference.
        case theme
        /// Owning profile.
        case profile
        /// Order in the bottom dock.
        case placement
    }
    public static let recordTypeName = "Space"

    public let id: UUID
    public var profileID: UUID
    public var name: String
    /// Icon: an emoji or an icon name; nil means the default icon.
    public var icon: String?
    /// Theme reference; nil means the default light neutral theme (06 §1, observed).
    public var themeID: UUID?
    /// Order within the dock.
    public var dockSortKey: SortKey
    public var meta: SyncMetadata

    public init(id: UUID, profileID: UUID, name: String, icon: String? = nil, themeID: UUID? = nil, dockSortKey: SortKey, now: Date) {
        self.id = id
        self.profileID = profileID
        self.name = name
        self.icon = icon
        self.themeID = themeID
        self.dockSortKey = dockSortKey
        self.meta = .new(at: now, groups: FieldGroup.self)
    }
}

// MARK: - Folder

/// A folder in the pinned area; folders can nest. Source: 06 §3, §12. Observed.
public struct Folder: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        /// spaceID + parentFolderID + sortKey, always moved together.
        case placement
        /// Title and icon.
        case naming
        /// Expanded / collapsed.
        case display
    }
    public static let recordTypeName = "Folder"

    public let id: UUID
    public var spaceID: UUID
    /// nil means top level of the pinned area.
    public var parentFolderID: UUID?
    public var title: String
    /// Icon set with Change Icon… (an emoji or an icon name, like `Space.icon`); nil = the folder
    /// glyph. Part of the `naming` group. [06 §21.5] observed item (B77). Data written before the
    /// field existed decodes as nil.
    public var icon: String?
    public var isExpanded: Bool
    public var sortKey: SortKey
    public var meta: SyncMetadata

    public init(id: UUID, spaceID: UUID, parentFolderID: UUID? = nil, title: String, icon: String? = nil, isExpanded: Bool = true, sortKey: SortKey, now: Date) {
        self.id = id
        self.spaceID = spaceID
        self.parentFolderID = parentFolderID
        self.title = title
        self.icon = icon
        self.isExpanded = isExpanded
        self.sortKey = sortKey
        self.meta = .new(at: now, groups: FieldGroup.self)
    }
}

// MARK: - Tab

/// Where a tab lives: favorites / pinned / Today.
public enum TabLocation: Codable, Hashable, Sendable {
    /// Favorites. Favorites are shared across spaces (06 §12, observed); scoping them to a profile is inferred.
    case favorite(profileID: UUID)
    /// Pinned area; `folderID == nil` means top level.
    case pinned(spaceID: UUID, folderID: UUID?)
    /// Today area (unpinned tabs below the divider; subject to auto-archive).
    case today(spaceID: UUID)

    public var spaceID: UUID? {
        switch self {
        case .favorite: return nil
        case .pinned(let spaceID, _), .today(let spaceID): return spaceID
        }
    }

    public var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }
}

/// A tab node in the sidebar (the persisted part; the live web contents come from OpenArcEngine).
public struct TabNode: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        /// location + sortKey, always moved together.
        case placement
        /// Current URL, page title, favicon.
        case content
        /// User-defined title (Rename…) and icon (Change Icon…).
        case naming
        /// Original URL of a pinned page (Edit Pinned Page ▸).
        case pin
        /// Last active time (drives auto-archive).
        case activity
    }
    public static let recordTypeName = "Tab"

    public let id: UUID
    public var location: TabLocation
    public var sortKey: SortKey
    public var url: URL?
    public var title: String
    /// Title set by the user; nil means use the page title.
    public var customTitle: String?
    /// Icon set with Change Icon… (an emoji or an icon name, like `Space.icon`); nil = the
    /// favicon. Part of the `naming` group. [06 §21.5] observed item (B77). Data written before
    /// the field existed decodes as nil.
    public var icon: String?
    /// Original URL captured when pinned / favorited (05 §context menus "Replace Pinned URL with Current", observed).
    public var pinnedURL: URL?
    public var faviconURL: URL?
    public var lastActiveAt: Date
    public var meta: SyncMetadata

    public init(
        id: UUID,
        location: TabLocation,
        sortKey: SortKey,
        url: URL?,
        title: String,
        customTitle: String? = nil,
        icon: String? = nil,
        pinnedURL: URL? = nil,
        faviconURL: URL? = nil,
        now: Date
    ) {
        self.id = id
        self.location = location
        self.sortKey = sortKey
        self.url = url
        self.title = title
        self.customTitle = customTitle
        self.icon = icon
        self.pinnedURL = pinnedURL
        self.faviconURL = faviconURL
        self.lastActiveAt = now
        self.meta = .new(at: now, groups: FieldGroup.self)
    }

    /// Title shown in the sidebar.
    public var displayTitle: String { customTitle ?? title }
}

// MARK: - Archive

/// Why a tab was archived. Source: 05 §window/app entry points (⌘W archives, Clear, auto-archive), 06 §11 (delete space).
public enum ArchiveReason: String, Codable, Hashable, Sendable {
    /// Closed by the user (⌘W archives instead of deleting by default).
    case closed
    /// Auto-archived after the idle timeout (12 hours by default).
    case autoArchived
    /// Today area "Clear".
    case clearedToday
    /// Its space was deleted. Also used for favorites of a deleted profile (`TreeOps.deleteProfile`):
    /// their container went away. No separate case, so older builds still decode the data.
    case spaceDeleted
}

/// An archived tab. Convention: `id` equals the archived tab's id (a tab is archived at most once;
/// restoring creates a new tab), so archiving stays a pure function with no ID generation.
public struct ArchiveItem: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup { case content }
    public static let recordTypeName = "ArchiveItem"

    public let id: UUID
    public var url: URL?
    public var title: String
    public var faviconURL: URL?
    /// Space it came from (nil for favorites).
    public var spaceID: UUID?
    /// Title path of the folders it was in (the folders themselves may be gone).
    public var folderPath: [String]
    public var reason: ArchiveReason
    public var archivedAt: Date
    /// Part of the `content` group: the page came from a Little Arc window (`TreeOps.archivePage`),
    /// not from a tab of the sidebar. The Library's archive filter "Where was the tab?" ▸ Little Arc
    /// needs it ([06 §8] Filter, observed). Files and records written before this field existed
    /// decode with false.
    public var isFromLittleArc: Bool
    public var meta: SyncMetadata

    public init(id: UUID, url: URL?, title: String, faviconURL: URL?, spaceID: UUID?, folderPath: [String], reason: ArchiveReason, archivedAt: Date, isFromLittleArc: Bool = false) {
        self.id = id
        self.url = url
        self.title = title
        self.faviconURL = faviconURL
        self.spaceID = spaceID
        self.folderPath = folderPath
        self.reason = reason
        self.archivedAt = archivedAt
        self.isFromLittleArc = isFromLittleArc
        self.meta = .new(at: archivedAt, groups: FieldGroup.self)
    }

    private enum CodingKeys: String, CodingKey {
        case id, url, title, faviconURL, spaceID, folderPath, reason, archivedAt, isFromLittleArc, meta
    }

    /// Decodes an archive item; a missing `isFromLittleArc` (data written before the field existed)
    /// becomes false.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decodeIfPresent(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        faviconURL = try c.decodeIfPresent(URL.self, forKey: .faviconURL)
        spaceID = try c.decodeIfPresent(UUID.self, forKey: .spaceID)
        folderPath = try c.decode([String].self, forKey: .folderPath)
        reason = try c.decode(ArchiveReason.self, forKey: .reason)
        archivedAt = try c.decode(Date.self, forKey: .archivedAt)
        isFromLittleArc = try c.decodeIfPresent(Bool.self, forKey: .isFromLittleArc) ?? false
        meta = try c.decode(SyncMetadata.self, forKey: .meta)
    }
}

// MARK: - Split

/// Split direction.
public enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Side by side (the default form observed in 06 §5).
    case horizontal
    /// Stacked top/bottom (inferred; not observed).
    case vertical
}

/// Which side of a pane a new pane goes to. Horizontal splits: leading = left, trailing = right.
/// 06 §15 observed: a tab dropped on a row's middle band, or on the web panel, lands on the
/// side of the pointer.
public enum SplitSide: String, Codable, Hashable, Sendable {
    case leading
    case trailing
}

/// Split layout tree. Leaves are tabs; inner nodes are weighted splits.
public indirect enum SplitNode: Codable, Hashable, Sendable {
    case pane(tabID: UUID)
    case split(axis: SplitAxis, children: [SplitChild])

    /// All tab ids in display order.
    public var tabIDs: [UUID] {
        switch self {
        case .pane(let id): return [id]
        case .split(_, let children): return children.flatMap { $0.node.tabIDs }
        }
    }
}

/// A child of a split and the fraction of space it takes (siblings sum to 1).
public struct SplitChild: Codable, Hashable, Sendable {
    public var node: SplitNode
    public var fraction: Double

    public init(node: SplitNode, fraction: Double) {
        self.node = node
        self.fraction = fraction
    }
}

/// One split group. The sidebar treats the tabs in a group as a unit (06 §5, observed).
public struct SplitLayout: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        /// spaceID + pane tree.
        case layout
        /// The split row's own title and icon (split row ▸ Rename… / Change Icon…). Added in B77;
        /// records written before have no group time, which falls back to `createdAt`.
        case naming
    }
    public static let recordTypeName = "SplitLayout"

    public let id: UUID
    public var spaceID: UUID
    public var root: SplitNode
    /// Title set with the split row's Rename…; nil shows the members' titles. [06 §21.5] observed
    /// item (B77); what the row shows then is inferred.
    public var title: String?
    /// Icon set with the split row's Change Icon… (emoji or icon name); nil = the members' favicons.
    public var icon: String?
    public var meta: SyncMetadata

    public init(id: UUID, spaceID: UUID, root: SplitNode, title: String? = nil, icon: String? = nil, now: Date) {
        self.id = id
        self.spaceID = spaceID
        self.root = root
        self.title = title
        self.icon = icon
        self.meta = .new(at: now, groups: FieldGroup.self)
    }
}
