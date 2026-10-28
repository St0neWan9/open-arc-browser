import Foundation
import OpenArcModel

// A sidebar read from another sidebar browser (plan D15: Arc), before it is mapped onto the
// workspace by `ForeignSidebarMapper`. Unlike a bookmark tree it already has Spaces, a pinned area,
// a Today area and favorites, so it maps onto our model one to one. Everything here is inferred
// (D15); the spec has no import wizard ([00] not captured).

/// Every Space and favorite of one source sidebar, in the source's order.
public struct ForeignSidebar: Hashable, Sendable {
    public var spaces: [ForeignSpace]
    /// The shared favorites (the icon grid above the Spaces).
    public var favorites: [ForeignSidebarItem]
    /// Items the reader left out: kinds Open Arc has no counterpart for (onboarding pages, notes,
    /// canvases, …), links to items missing from the file, and pages without a URL. Each left-out
    /// item counts once, plus everything inside it.
    public var skipped: Int

    public init(spaces: [ForeignSpace] = [], favorites: [ForeignSidebarItem] = [], skipped: Int = 0) {
        self.spaces = spaces
        self.favorites = favorites
        self.skipped = skipped
    }
}

/// One Space of the source sidebar.
public struct ForeignSpace: Hashable, Sendable {
    public var name: String
    public var icon: ForeignIcon?
    /// nil: the source has no readable theme for this Space (the import uses a default color).
    public var theme: ThemeStyle?
    /// The pinned area, top to bottom.
    public var pinned: [ForeignSidebarItem]
    /// The Today (unpinned) area, top to bottom.
    public var today: [ForeignSidebarItem]
    /// The Space belongs to a profile other than the source's default one. Open Arc imports it
    /// into the current profile anyway and says so in the summary.
    public var isFromOtherProfile: Bool

    public init(
        name: String, icon: ForeignIcon? = nil, theme: ThemeStyle? = nil,
        pinned: [ForeignSidebarItem] = [], today: [ForeignSidebarItem] = [], isFromOtherProfile: Bool = false
    ) {
        self.name = name
        self.icon = icon
        self.theme = theme
        self.pinned = pinned
        self.today = today
        self.isFromOtherProfile = isFromOtherProfile
    }
}

/// A Space or tab icon as the source stores it.
public enum ForeignIcon: Hashable, Sendable {
    /// An emoji: used as is.
    case emoji(String)
    /// A named glyph: used only when the name is one of ours (`ForeignSidebarMapper`'s
    /// `isKnownSymbol`), else the Space gets no icon.
    case symbol(String)
}

/// One row of the source sidebar.
public indirect enum ForeignSidebarItem: Hashable, Sendable {
    case page(ForeignPage)
    case folder(ForeignFolder)
    /// Tabs shown side by side in one row.
    case split(ForeignSplit)
}

/// A tab. `url` is the raw string; the mapper imports http, https and file URLs only.
public struct ForeignPage: Hashable, Sendable {
    /// The title the source showed for the row.
    public var title: String
    public var url: String
    /// An emoji the user gave the tab instead of its favicon.
    public var emoji: String?

    public init(title: String, url: String, emoji: String? = nil) {
        self.title = title
        self.url = url
        self.emoji = emoji
    }
}

/// A folder with its rows in order. Empty folders are kept.
public struct ForeignFolder: Hashable, Sendable {
    public var title: String
    public var children: [ForeignSidebarItem]

    public init(title: String, children: [ForeignSidebarItem] = []) {
        self.title = title
        self.children = children
    }
}

/// A split row: its tabs, leading to trailing.
public struct ForeignSplit: Hashable, Sendable {
    public var axis: SplitAxis
    public var pages: [ForeignPage]

    public init(axis: SplitAxis = .horizontal, pages: [ForeignPage]) {
        self.axis = axis
        self.pages = pages
    }
}
