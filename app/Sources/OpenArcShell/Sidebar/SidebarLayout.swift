import CoreGraphics
import OpenArcDesign

/// One entry of the scrolling list, for frame computation.
enum SidebarListItemKind: Equatable {
    /// A tab or folder row (41 pt pitch: a 40 pt row button plus 1 pt).
    case row
    /// The 17 pt divider row between the pinned area and Today.
    case divider
    /// The "+ New Tab" row (same geometry as a tab row).
    case newTabRow
}

/// Pure frame computation for the sidebar (top-left origin, points, window coordinates).
///
/// All numbers come from `Metrics.Sidebar` ([07 §1, §2, §4] observed) or `SidebarLocalTokens`.
/// The URL box and the favorites block are delegated to `MainWindowLayout` so the two stay
/// consistent.
struct SidebarLayout: Equatable {
    var windowSize: CGSize
    /// View ▸ Show Toolbar is on: no URL box and no back / forward / reload in the sidebar, and
    /// everything from the favorites down sits `contentShift` higher. [06 §17.1] observed.
    var isWebToolbarShown: Bool
    /// The favorites block is absent (incognito window): the Space header and the list sit
    /// `IncognitoTokens.sidebarContentShift` higher. [06 §20.2] observed (B48).
    var hidesFavorites: Bool
    /// Height of the favorites tiles block (one row: 47). More rows, or the empty-state card, push
    /// the Space header and the list down by the difference. [06 §21.2, §21.3] observed (B55).
    var favoritesTilesHeight: CGFloat
    /// A downloaded update waits: its pill sits right above the dock and the list ends above it.
    /// [07 §8.6] observed (B111).
    var showsUpdatePill: Bool

    init(windowSize: CGSize = CGSize(width: Metrics.referenceWindowSize.width, height: Metrics.referenceWindowSize.height),
         isWebToolbarShown: Bool = false, hidesFavorites: Bool = false,
         favoritesTilesHeight: CGFloat = CGFloat(Metrics.FavoritesGrid.tileHeight),
         showsUpdatePill: Bool = false) {
        self.windowSize = windowSize
        self.isWebToolbarShown = isWebToolbarShown
        self.hidesFavorites = hidesFavorites
        self.favoritesTilesHeight = favoritesTilesHeight
        self.showsUpdatePill = showsUpdatePill
    }

    /// How much taller the favorites block is than one row of tiles (0 without favorites). B55.
    var favoritesExtraHeight: CGFloat {
        hidesFavorites ? 0 : favoritesTilesHeight - CGFloat(Metrics.FavoritesGrid.tileHeight)
    }

    private var window: MainWindowLayout { MainWindowLayout(windowSize: windowSize, isWebToolbarShown: isWebToolbarShown) }

    /// Upward shift of the favorites, Space header and list (0 with the toolbar off). [06 §17.1] observed (46).
    /// Without favorites the header and list move up another 60. [06 §20.2] observed (B48).
    var contentShift: CGFloat {
        CGFloat(window.sidebarContentShift + (hidesFavorites ? IncognitoTokens.sidebarContentShift : 0)) - favoritesExtraHeight
    }

    /// Whether the URL box and the back / forward / reload buttons are in the sidebar. [06 §17.1] observed.
    var showsAddressControls: Bool { !isWebToolbarShown }

    /// Sidebar width including the right-hand gap: rows and the list span all of it. [07 §1, §4] observed.
    var width: CGFloat { CGFloat(Metrics.Sidebar.width) }

    /// Width available to content: the whole sidebar; content is inset 8 on both sides.
    var contentWidth: CGFloat { CGFloat(window.sidebarContentWidth) }

    /// Horizontal inset of the URL box, favorites and the selected row fill (x 8–268). [07 §1] observed.
    var horizontalInset: CGFloat { CGFloat(Metrics.Sidebar.contentInset) }

    // MARK: Toolbar ([07 §2] observed)

    /// Center line of the toolbar buttons.
    var toolbarCenterY: CGFloat { CGFloat(Metrics.Sidebar.toolbarRowCenterY) }
    /// Top edge of the 32 pt toolbar buttons (7.5).
    var toolbarButtonFrameY: CGFloat { CGFloat(Metrics.Sidebar.toolbarButtonTop) }
    var toolbarButtonSize: CGFloat { CGFloat(Metrics.Sidebar.toolbarButtonSize) }

    private func toolbarButton(x: Double) -> CGRect {
        CGRect(x: x, y: toolbarButtonFrameY, width: toolbarButtonSize, height: toolbarButtonSize)
    }
    var hideSidebarButtonFrame: CGRect { toolbarButton(x: Metrics.Sidebar.hideSidebarButtonX) }
    var backButtonFrame: CGRect { toolbarButton(x: Metrics.Sidebar.backButtonX) }
    var forwardButtonFrame: CGRect { toolbarButton(x: Metrics.Sidebar.forwardButtonX) }
    var reloadButtonFrame: CGRect { toolbarButton(x: Metrics.Sidebar.reloadButtonX) }

    // MARK: Blocks

    var urlBoxFrame: CGRect { window.addressFieldFrame }

    var favoritesFrame: CGRect { window.favoritesFrame }

    /// The whole favorites tiles block: x 8–268 from the favorites top, `favoritesTilesHeight` tall.
    /// [06 §21.3] observed (B55).
    var favoritesTilesFrame: CGRect {
        let first = favoritesFrame
        return CGRect(x: first.minX, y: first.minY, width: first.width, height: favoritesTilesHeight)
    }

    /// The Space header line: 26 pt icon at (13, 150), name from x 41 (13 without an icon) to 259,
    /// "More" strip at 261. [07 §4] observed.
    var spaceNameRowFrame: CGRect {
        let icon = Metrics.Sidebar.spaceIconFrame
        return CGRect(x: icon.x, y: icon.y - contentShift, width: Metrics.Sidebar.spaceMoreButtonFrame.maxX - icon.x, height: icon.height)
    }

    /// Top of the scrolling list. [07 §1] observed (181); 46 higher with the toolbar ([06 §17.1]).
    var listTop: CGFloat { CGFloat(Metrics.Sidebar.listTop) - contentShift }

    /// Top edge of the first list row: the list starts with a 3 pt spacer. [07 §1] observed (184).
    var firstRowTop: CGFloat { listTop + CGFloat(Metrics.Sidebar.listTopSpacer) }

    /// Height of a list row: the 40 pt row button plus the 1 pt gap below it, so rows touch.
    /// [07 §1] observed (pitch 41).
    var rowHeight: CGFloat { CGFloat(Metrics.Sidebar.rowPitch) }

    /// Rows are laid out back to back (the 1 pt gap is inside `rowHeight`).
    var rowSpacing: CGFloat { 0 }

    var rowPitch: CGFloat { rowHeight + rowSpacing }

    /// Height of the visible row button inside a row. [07 §4] observed (40).
    var rowButtonHeight: CGFloat { CGFloat(Metrics.Sidebar.rowButtonHeight) }

    /// Selected / hovered fill inside a row (row-relative): x 8–268, y 2–38. [07 §4] observed.
    var rowFillFrame: CGRect {
        let s = Metrics.Sidebar.self
        return CGRect(
            x: s.selectedRowHorizontalInset, y: s.selectedRowVerticalInset,
            width: s.width - 2 * s.selectedRowHorizontalInset, height: s.selectedRowHeight
        )
    }

    /// Icon / title left edges inside a row. Rows span the full sidebar width, so these equal the
    /// window x values 17 and 43. [07 §4] observed.
    var rowIconLeading: CGFloat { CGFloat(Metrics.Sidebar.rowIconLeading) }
    var rowTitleLeading: CGFloat { CGFloat(Metrics.Sidebar.rowTitleLeading) }
    var rowIconSize: CGFloat { CGFloat(Metrics.Sidebar.rowIconSize) }
    /// Gap between the 18 pt icon cell and the title (43 − 35 = 8). [07 §4] observed.
    var rowTitleGap: CGFloat { rowTitleLeading - rowIconLeading - rowIconSize }

    /// Frames of consecutive list items starting at `firstRowTop`.
    func listItemFrames(_ kinds: [SidebarListItemKind]) -> [CGRect] {
        var y = firstRowTop
        var frames: [CGRect] = []
        for kind in kinds {
            let height = kind == .divider ? CGFloat(Metrics.Sidebar.dividerRowHeight) : rowHeight
            frames.append(CGRect(x: 0, y: y, width: width, height: height))
            y += height + rowSpacing
        }
        return frames
    }

    // MARK: Dock ([07 §4] observed)

    /// Bottom dock band: 50 pt glued to the window bottom; its buttons are centered on H − 25.
    var dockFrame: CGRect {
        let height = CGFloat(Metrics.Sidebar.dockHeight)
        return CGRect(x: 0, y: windowSize.height - height, width: width, height: height)
    }

    var dockCenterY: CGFloat { windowSize.height - CGFloat(Metrics.Sidebar.dockCenterFromBottom) }

    // MARK: Update pill ([07 §8.6] observed, B111)

    /// The update-ready pill: x 8–268, 22 pt tall, `UpdatePillTokens.bottomGap` above the dock.
    /// nil while no update is ready.
    var updatePillFrame: CGRect? {
        guard showsUpdatePill else { return nil }
        let t = UpdatePillTokens.self
        let height = CGFloat(t.height), inset = CGFloat(t.horizontalInset)
        return CGRect(x: inset, y: dockFrame.minY - CGFloat(t.bottomGap) - height, width: width - 2 * inset, height: height)
    }

    /// Bottom edge of the Space pages (the list's viewport): the dock's top, or above the update
    /// pill while it shows. Shrinking the list rather than covering its last rows is inferred.
    var listBottom: CGFloat {
        dockFrame.minY - (showsUpdatePill ? CGFloat(UpdatePillTokens.bandHeight) : 0)
    }

    private func dockButton(x: Double) -> CGRect {
        let size = CGFloat(Metrics.Sidebar.dockButtonSize)
        return CGRect(x: x, y: dockCenterY - size / 2, width: size, height: size)
    }
    /// Home button at the far left (x 8–40).
    var dockHomeFrame: CGRect { dockButton(x: Metrics.Sidebar.dockHomeX) }
    /// "+" (New Space) at the right (x 236–268).
    var dockPlusFrame: CGRect { dockButton(x: Metrics.Sidebar.dockPlusX) }

    /// Distance between the Space icons: they share x 42–234 evenly, at most one button apart.
    /// [07 §4] observed for 7 and 8 Spaces (27.5 / 24); the cap with few Spaces is inferred.
    static func dockItemPitch(count: Int) -> CGFloat {
        let s = Metrics.Sidebar.self
        guard count > 0 else { return CGFloat(s.dockMaxItemPitch) }
        return CGFloat(min((s.dockIconsTrailing - s.dockIconsLeading) / Double(count), s.dockMaxItemPitch))
    }

    /// Frames of the Space icons in the dock (left to right). Each frame is 2 pt wider than the
    /// pitch and 34 tall, so neighbors overlap by 2. [07 §4] observed.
    func dockItemFrames(count: Int) -> [CGRect] {
        let s = Metrics.Sidebar.self
        let pitch = Self.dockItemPitch(count: count)
        let overlap = CGFloat(s.dockItemOverlap)
        let height = CGFloat(s.dockItemHeight)
        return (0..<max(count, 0)).map {
            CGRect(
                x: CGFloat(s.dockIconsLeading) + CGFloat($0) * pitch - overlap / 2,
                y: dockCenterY - height / 2,
                width: pitch + overlap,
                height: height
            )
        }
    }

    // MARK: Favorites

    /// Favorite tiles in the grid of `SidebarFavoritesGrid` (rows = ⌈n / 4⌉, columns = ⌈n / rows⌉,
    /// 47 tall, 8 pt gaps, last row left-aligned), in window coordinates. [07 §4] observed for one
    /// and two, [06 §21.3] observed for 1, 2, 4–9 (B55).
    func favoriteSlotFrames(count: Int) -> [CGRect] {
        let block = favoritesFrame
        return SidebarFavoritesGrid.slotFrames(count: count, origin: block.origin, width: block.width)
    }

    /// Insertion gap (0...count) nearest to a point at `x` (block-relative).
    static func favoriteGapIndex(forX x: CGFloat, count: Int, blockWidth: CGFloat) -> Int {
        guard count > 0, blockWidth > 0 else { return 0 }
        let slotWidth = blockWidth / CGFloat(count)
        return min(max(Int((x / slotWidth).rounded()), 0), count)
    }
}

