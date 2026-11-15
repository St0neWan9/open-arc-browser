import Foundation
import CoreGraphics
import OpenArcModel
import OpenArcDesign

// Pure parts of the Library: sections, texts, layout, archive grouping and the Spaces board data.
// Acceptance: docs/arc-spec/06-flows.md §8 (Library), 02 (⇧⌘L View Library), 01 §Window, §Archive.

/// A page of the Library. Rail order, top to bottom: Media, Downloads, Easels, Spaces, Boosts,
/// Archived Tabs. [06 §8] observed.
public enum LibrarySection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case media
    case downloads
    case easels
    case spaces
    case boosts
    case archivedTabs

    public var id: String { rawValue }

    /// Small label under the rail icon. [06 §8] observed.
    public var title: String {
        switch self {
        case .media: return "Media"
        case .downloads: return "Downloads"
        case .easels: return "Easels"
        case .spaces: return "Spaces"
        case .boosts: return "Boosts"
        case .archivedTabs: return "Archived Tabs"
        }
    }

    /// SF Symbol of the rail item. Our own choice: icons may differ from Arc (CLAUDE.md).
    var symbolName: String {
        switch self {
        case .media: return "photo.on.rectangle"
        case .downloads: return "arrow.down.circle"
        case .easels: return "scribble.variable"
        case .spaces: return "square.grid.2x2"
        case .boosts: return "paintbrush"
        case .archivedTabs: return "archivebox"
        }
    }

    /// Placeholder of the section's search field; nil for the Spaces board, which has none.
    /// [06 §8] observed.
    public var searchPlaceholder: String? {
        switch self {
        case .media: return "Search Media…"
        case .downloads: return "Search Downloads…"
        case .easels: return "Search Easels…"
        case .spaces: return nil
        case .boosts: return "Search Boosts…"
        case .archivedTabs: return "Search Archive…"
        }
    }

    /// Whether a "Filter" button sits next to the search field. [06 §8] observed for Downloads
    /// and Archived Tabs only.
    public var hasFilterButton: Bool { self == .downloads || self == .archivedTabs }

    /// The empty state of a section that has no backing feature yet. [06 §8] observed texts.
    /// Media, Spaces and Archived Tabs have no recorded empty state.
    public var emptyState: LibraryEmptyState? {
        switch self {
        case .downloads:
            return LibraryEmptyState(symbolName: "arrow.down.circle", title: LibraryTexts.downloadsEmptyTitle, detail: LibraryTexts.downloadsEmptyDetail)
        case .easels:
            return LibraryEmptyState(symbolName: nil, title: LibraryTexts.easelsEmptyTitle, detail: LibraryTexts.easelsEmptyDetail)
        case .boosts:
            return LibraryEmptyState(symbolName: "paintbrush", title: LibraryTexts.boostsEmptyTitle, detail: LibraryTexts.boostsEmptyDetail)
        case .media, .spaces, .archivedTabs:
            return nil
        }
    }
}

/// Icon, title and detail of an empty section.
public struct LibraryEmptyState: Equatable, Sendable {
    /// nil: the spec shows no icon (Easels). [06 §8] observed.
    public var symbolName: String?
    public var title: String
    public var detail: String
}

/// Texts of the Library. [06 §8] observed, word for word; where a text names the product, our
/// app name replaces it.
public enum LibraryTexts {
    public static let downloadsEmptyTitle = "Nothing here yet!"
    public static let downloadsEmptyDetail = "Come back after you’ve found some cool stuff to save."

    public static let easelsEmptyTitle = "Out of ideas!"
    public static let easelsEmptyDetail = "Click the + sign in the Sidebar to create a new Easel."

    public static let boostsEmptyTitle = "Nothing Boosted Yet!"
    /// The Boosts detail is drawn with a brush icon between the prefix and the middle part, and
    /// "Boost Gallery" as a link. [06 §8] observed.
    public static let boostsDetailPrefix = "Click "
    public static let boostsDetailMiddle = " in URL bar to make your own, or grab one from the "
    public static let boostsGalleryLink = "Boost Gallery"
    public static let boostsDetailSuffix = "."
    /// The detail as plain text, with "[brush]" standing for the icon (accessibility, tests).
    public static var boostsEmptyDetail: String {
        boostsDetailPrefix + "[brush]" + boostsDetailMiddle + boostsGalleryLink + boostsDetailSuffix
    }

    public static let mediaIntroTitle = "Your Media in the Library"
    /// The spec's text says "the Arc Library"; the product name is ours.
    public static var mediaIntroDetail: String {
        "Quickly grab screenshots, images, and videos from your computer by showing them in the \(AppIdentity.displayName) Library!"
    }
    public static let mediaIntroButton = "Show Media"
    public static let mediaPrivacyNote = "Media never leaves your computer and is not viewable by anyone but you."
    /// Media list with no files, and with no file matching the search. Not observed (the spec
    /// records no Media list): inferred.
    public static let mediaEmpty = "No screenshots, images or videos yet."
    public static let mediaNoMatches = "No matching media."
    /// Archived Tabs with nothing archived, and with no item matching the search or filter. Not
    /// observed (the spec records no empty Archive): inferred.
    public static let archiveEmpty = "Tabs you close or that are archived automatically show up here."
    public static let archiveNoMatches = "No matching tabs."

    public static let filterButton = "Filter"
    /// Filter panel (B94). [06 §8] Filter (E24), observed, word for word.
    public static let filterDone = "Done"
    public static let filterDownloadsTitle = "Filter Downloads…"
    public static let filterArchiveTitle = "Filter Archived Tabs"
    public static let filterProfilesGroup = "Profiles"
    public static let filterClosingGroup = "How was the tab closed?"
    public static let filterOriginGroup = "Where was the tab?"
    public static let filterAutoClosed = "Auto-Closed"
    public static let filterManuallyClosed = "Manually Closed"
    public static let filterLittleArc = "Little Arc"
}

// MARK: - Layout

/// Sizes the spec does not pin down, plus the two it measured. Each carries its evidence level.
enum LibraryLocalTokens {
    /// Width of the icon rail: 97 pt buttons with 8 pt on both sides. [07 §6, §10] observed buttons,
    /// rail width inferred (≈ 113).
    static var railWidth: CGFloat { CGFloat(Metrics.Library.iconRailWidth) }
    /// Width of the list column: the left part ends at x 417. [07 §6, §10] observed / inferred (≈ 304).
    static var listColumnWidth: CGFloat { CGFloat(Metrics.Library.listColumnWidth) }

    /// Space above the first rail item and the list column's search field, below the traffic
    /// lights (which move to y 20–36 in the Library, [07 §2] observed). unknown.
    static let topInset: CGFloat = 48
    /// Rail buttons (icon + label): 97 × 80, x 8, pitch 100; the selected one sits on a rounded
    /// block of the window color darkened (radius ≈ 10). [07 §6] observed.
    static var railItemSize: CGSize { CGSize(width: Metrics.Library.railButtonSize.width, height: Metrics.Library.railButtonSize.height) }
    static var railItemCornerRadius: CGFloat { CGFloat(Metrics.Library.railCornerRadius) }
    static var railItemSpacing: CGFloat { CGFloat(Metrics.Library.railButtonPitch - Metrics.Library.railButtonSize.height) }
    /// Rail icon: ≈ 22 pt symbols (Arc's are 21–26 pt wide), centered 31.5 pt below the button's
    /// top; the label centered 56 pt below it. B225 observed (user's Arc screenshot, 2026-11-15);
    /// the box heights are ours.
    static let railIconSize: CGFloat = 22
    static let railIconCenterY: CGFloat = 31.5
    static let railLabelCenterY: CGFloat = 56
    static let railIconBoxHeight: CGFloat = 27
    static let railLabelBoxHeight: CGFloat = 16
    /// Buttons other than the selected one draw their icon and label at this share of the ink
    /// (#C2C4FE on #5A65FB ≈ 63 % white; the selected one ≈ full white). B225 observed.
    static let railUnselectedInkOpacity: Double = 0.63
    /// Darkening of the selected rail block (window × factor) under dark ink. [07 §6] observed
    /// "window color darkened"; factor inferred (the control fill rule, × 0.96, is too faint: × 0.90).
    static let railSelectedShade: Double = 0.90
    /// Under light ink the selected block is lighter instead: ≈ 9 % white (#6770FB on #5662FB).
    /// B225 observed (user's Arc screenshot, blue Space with white ink).
    static let railSelectedLightInkWhite: Double = 0.09

    /// The selected rail block: lighter under light ink, darker under dark ink; a layer on a
    /// see-through window, an opaque color otherwise (B64, [07 §8.4]).
    static func railSelectedFill(palette: ThemePalette, translucent: Bool) -> RGBAColor {
        let ink = palette.primaryText
        let isLightInk = 0.2126 * ink.red + 0.7152 * ink.green + 0.0722 * ink.blue > 0.5
        if isLightInk {
            return translucent ? RGBAColor(hex: 0xFFFFFF, alpha: railSelectedLightInkWhite)
                : ThemeDerivation.mix(palette.windowBackground, RGBAColor(hex: 0xFFFFFF), amount: railSelectedLightInkWhite)
        }
        return translucent ? RGBAColor(hex: 0x000000, alpha: 1 - railSelectedShade)
            : ThemeDerivation.shade(palette.windowBackground, by: railSelectedShade)
    }
    /// Bottom "←" and gift icons: ≈ 16 pt, centered 24 pt from the rail's left and right edges and
    /// 22 pt above the window's bottom, in the dimmed ink. B225 observed (user's Arc screenshot).
    static let railFooterIconSize: CGFloat = 16
    static let railFooterPadding: CGFloat = 16
    static let railFooterBottomPadding: CGFloat = 14

    /// List column paddings and rows. unknown.
    static let listHorizontalPadding: CGFloat = 8
    static let searchFieldHeight: CGFloat = 36
    static var searchFieldCornerRadius: CGFloat { CGFloat(Metrics.Sidebar.addressFieldCornerRadius) }
    static let archiveRowHeight: CGFloat = 41
    static let archiveRowIconSize: CGFloat = 16
    static let emptyStateIconSize: CGFloat = 28

    /// Spaces board columns. [06 §8] observed that columns look like the sidebar. B224 (user's Arc
    /// screenshot, 2026-11-15, observed): 240 wide, 24 apart, the first 24 from the rail's edge,
    /// tops 48 and bottoms 46 from the window's edges; each column in its own Space's color with a
    /// faint shadow (≈ 4 pt, inferred from the pixels).
    static let boardColumnWidth: CGFloat = 240
    static let boardColumnSpacing: CGFloat = 24
    static let boardLeading: CGFloat = 24
    static let boardTop: CGFloat = 48
    static let boardBottom: CGFloat = 46
    static let boardColumnShadowOpacity: Double = 0.08
    static let boardColumnShadowRadius: CGFloat = 4
    static let boardColumnCornerRadius: CGFloat = 10

    /// The board's area right of the rail is deeper than the rail: the window color × 0.90 with
    /// its saturation × 1.155 (fit to the screenshot, within 1/255: rail #5E69FB, board #525EF6).
    /// B224 inferred rule, observed colors.
    static let boardAreaShade: Double = 0.90
    static let boardAreaSaturationBoost: Double = 1.155
    /// The rail's right edge: a 1 pt light line (≈ 5 % white, #666FFB on #5E69FB), and a faint
    /// shadow on the board side fading out over ≈ 13 pt (≈ 3 % black at the edge). B224 observed
    /// pixels; the layer values are inferred.
    static let railEdgeHighlightWidth: CGFloat = 1
    static let railEdgeHighlightWhite: Double = 0.05
    static let boardEdgeShadowWidth: CGFloat = 13
    static let boardEdgeShadowBlack: Double = 0.03

    /// The rail's buttons sit in the middle of the window, ≈ 5 pt above center (B224, the
    /// screenshot: the Spaces button at y 529–609 in a 1047 pt window). observed.
    static let railItemsCenterLift: CGFloat = 5

    /// A column's fill: its Space's see-through theme layer (the layer a window of that Space
    /// paints over its blur), so the board's tone shows through as in Arc, where every column is
    /// tinted by the current Space (gray Space → #7A86BE, green → #628467 on a blue board); an
    /// opaque palette paints its window color. B224 observed colors, inferred rule.
    static func boardColumnFill(for palette: ThemePalette) -> RGBAColor {
        palette.isWindowTranslucent ? palette.windowThemeLayer : palette.windowBackground
    }

    /// The board area's color for a window color (`boardAreaShade`, `boardAreaSaturationBoost`).
    static func boardAreaFill(for windowBackground: RGBAColor) -> RGBAColor {
        let c = ThemeDerivation.shade(windowBackground, by: boardAreaShade)
        let gray = 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
        func boost(_ v: Double) -> Double { min(max(gray + (v - gray) * boardAreaSaturationBoost, 0), 1) }
        return RGBAColor(red: boost(c.red), green: boost(c.green), blue: boost(c.blue), alpha: 1)
    }
    static let boardHeaderHeight: CGFloat = 40
    static let boardFooterHeight: CGFloat = 36
    static let boardIconSize: CGFloat = 14

    /// Filter panel (B94): capsule chips on the sidebar tint (the search field's control fill),
    /// selected ones darker; group label above each row of chips. [06 §8] observed capsules;
    /// sizes unknown.
    static let filterChipHeight: CGFloat = 24
    static let filterChipHorizontalPadding: CGFloat = 10
    static let filterChipSpacing: CGFloat = 6
    static let filterGroupSpacing: CGFloat = 10
    /// Darkening of a selected chip (control fill × factor), like the rail's selected block. inferred.
    static let filterChipSelectedShade: Double = 0.85

    /// Media intro card. unknown.
    static let mediaCardCornerRadius: CGFloat = 10
    static let mediaCardPadding: CGFloat = 10
}

/// Frames of the Library mode (top-left origin, points). [06 §8] observed: rail on the left, list
/// column next to it, the web panel stays on the right. The web panel keeps the main window's
/// top/right/bottom insets and touches the list column, like it touches the sidebar. inferred.
/// The Spaces board takes the list column and web panel area. inferred.
struct LibraryLayout: Equatable {
    var windowSize: CGSize

    var railFrame: CGRect {
        CGRect(x: 0, y: 0, width: min(LibraryLocalTokens.railWidth, windowSize.width), height: windowSize.height)
    }

    var listFrame: CGRect {
        CGRect(x: railFrame.maxX, y: 0, width: LibraryLocalTokens.listColumnWidth, height: windowSize.height)
    }

    var webPanelFrame: CGRect { contentFrame(from: listFrame.maxX + CGFloat(Metrics.WebPanel.insetLeading)) }

    /// The Spaces board: everything right of the rail, edge to edge (B224 observed: its deeper
    /// color reaches the window's top, right and bottom edges).
    var boardFrame: CGRect {
        CGRect(x: railFrame.maxX, y: 0, width: max(0, windowSize.width - railFrame.maxX), height: windowSize.height)
    }

    /// Top of the first rail button: the six buttons centered in the window, `railItemsCenterLift`
    /// higher, never under the traffic lights' strip (`LibraryLocalTokens.topInset`).
    var railItemsTop: CGFloat {
        let count = CGFloat(LibrarySection.allCases.count)
        let stack = count * LibraryLocalTokens.railItemSize.height + (count - 1) * LibraryLocalTokens.railItemSpacing
        return max(LibraryLocalTokens.topInset, (windowSize.height - stack) / 2 - LibraryLocalTokens.railItemsCenterLift)
    }

    /// A rail button's frame.
    func railItemFrame(_ section: LibrarySection) -> CGRect {
        let index = CGFloat(LibrarySection.allCases.firstIndex(of: section) ?? 0)
        let size = LibraryLocalTokens.railItemSize
        return CGRect(x: CGFloat(Metrics.Library.railButtonLeading),
                      y: railItemsTop + index * (size.height + LibraryLocalTokens.railItemSpacing),
                      width: size.width, height: size.height)
    }

    private func contentFrame(from minX: CGFloat) -> CGRect {
        let top = CGFloat(Metrics.WebPanel.insetTop)
        let width = windowSize.width - minX - CGFloat(Metrics.WebPanel.insetTrailing)
        let height = windowSize.height - top - CGFloat(Metrics.WebPanel.insetBottom)
        return CGRect(x: minX, y: top, width: max(0, width), height: max(0, height))
    }
}

// MARK: - Archived Tabs

/// Date groups of the Archived Tabs list. [06 §8] observed the labels Today, Yesterday and
/// Earlier This Week (Media and Archived Tabs); "Older" and the boundaries are inferred.
public enum LibraryDateGroup: Int, CaseIterable, Comparable, Sendable {
    case today
    case yesterday
    case earlierThisWeek
    case older

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .earlierThisWeek: return "Earlier This Week"
        case .older: return "Older"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Rule (inferred): same calendar day as `now` → Today (later dates from clock skew too);
    /// the day before → Yesterday; otherwise since the start of `now`'s calendar week →
    /// Earlier This Week; everything before → Older.
    public static func group(of date: Date, now: Date, calendar: Calendar) -> LibraryDateGroup {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), date >= startOfYesterday {
            return .yesterday
        }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), date >= week.start { return .earlierThisWeek }
        return .older
    }
}

/// One date group of archived tabs, newest first.
public struct LibraryArchiveGroup: Equatable, Sendable {
    public var group: LibraryDateGroup
    public var items: [ArchiveItem]
}

public enum LibraryArchive {
    /// Whether an item matches the search text: case- and diacritic-insensitive substring of the
    /// title or the URL. An empty (or blank) query matches everything. inferred.
    public static func matches(_ item: ArchiveItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if item.title.range(of: q, options: options) != nil { return true }
        return item.url?.absoluteString.range(of: q, options: options) != nil
    }

    /// Live archive items filtered by `query`, grouped by date (group order Today → Older),
    /// newest first inside each group. Empty groups are left out. `filter`: the Filter panel's
    /// chips (B94); an empty selection keeps everything.
    public static func groups(in workspace: WorkspaceState, query: String, filter: LibraryFilterSelection = LibraryFilterSelection(),
                              now: Date, calendar: Calendar) -> [LibraryArchiveGroup] {
        var buckets: [LibraryDateGroup: [ArchiveItem]] = [:]
        for item in workspace.archiveNewestFirst
        where matches(item, query: query) && filter.allows(LibraryFilter.traits(of: item)) {
            buckets[LibraryDateGroup.group(of: item.archivedAt, now: now, calendar: calendar), default: []].append(item)
        }
        return LibraryDateGroup.allCases.compactMap { group in
            buckets[group].map { LibraryArchiveGroup(group: group, items: $0) }
        }
    }

    /// The gray second line of a row: the URL without its scheme. inferred.
    static func displayURL(_ url: URL?) -> String {
        guard let url else { return "" }
        let text = url.absoluteString
        guard let scheme = url.scheme, text.hasPrefix(scheme + "://") else { return text }
        return String(text.dropFirst(scheme.count + 3))
    }
}

// MARK: - Spaces board

/// One column of the Spaces board ("Manage Spaces"). [06 §8] observed: each column is the space's
/// theme color, with a header (icon, name, brush) and the space's folders and tabs in the
/// sidebar style.
struct LibraryBoardColumn: Identifiable, Equatable {
    var space: Space
    var palette: ThemePalette
    var pinned: [SidebarItemModel]
    var today: [SidebarItemModel]

    var id: UUID { space.id }
}

enum LibraryBoard {
    /// Columns in dock order (the order the dock shows: every live space). Rows come from the
    /// same derivation as the sidebar, so collapsed folders hide their children and split tabs
    /// are one row.
    static func columns(in workspace: WorkspaceState, systemAppearance: ResolvedAppearance = .light) -> [LibraryBoardColumn] {
        workspace.allLiveSpaces.map { space in
            let theme = space.themeID.flatMap { workspace.themes[$0] }.flatMap { $0.meta.isTombstone ? nil : $0 }
            let snapshot = SidebarSnapshot.make(workspace: workspace, spaceID: space.id, profileID: workspace.profileID(ofSpace: space.id))
            return LibraryBoardColumn(
                space: space,
                palette: ThemeDerivation.palette(for: theme, systemAppearance: systemAppearance),
                pinned: snapshot.pinned,
                today: snapshot.today
            )
        }
    }

    /// Where a column dragged by its handle lands when dropped on `target` at `locationX`
    /// (in the target column's coordinates): its left half means before, its right half after.
    /// inferred. nil when dropped on itself.
    static func dropPosition(dragged: UUID, target: UUID, locationX: CGFloat, columnWidth: CGFloat) -> InsertPosition? {
        guard dragged != target else { return nil }
        return locationX < columnWidth / 2 ? .before(target) : .after(target)
    }
}
