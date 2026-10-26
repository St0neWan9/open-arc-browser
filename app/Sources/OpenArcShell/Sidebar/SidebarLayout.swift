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

    init(windowSize: CGSize = CGSize(width: Metrics.referenceWindowSize.width, height: Metrics.referenceWindowSize.height)) {
        self.windowSize = windowSize
    }

    private var window: MainWindowLayout { MainWindowLayout(windowSize: windowSize) }

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

    /// The Space header line: 26 pt icon at (13, 150), name from x 41 (13 without an icon) to 259,
    /// "More" strip at 261. [07 §4] observed.
    var spaceNameRowFrame: CGRect {
        let icon = Metrics.Sidebar.spaceIconFrame
        return CGRect(x: icon.x, y: icon.y, width: Metrics.Sidebar.spaceMoreButtonFrame.maxX - icon.x, height: icon.height)
    }

    /// Top of the scrolling list. [07 §1] observed (181).
    var listTop: CGFloat { CGFloat(Metrics.Sidebar.listTop) }

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

    /// Favorite blocks: the row is split evenly with an 8 pt gap between blocks (one block = 260,
    /// two = 126 + 8 + 126). [07 §4] observed for one and two; more is inferred.
    func favoriteSlotFrames(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let block = favoritesFrame
        let gap = CGFloat(Metrics.Sidebar.favoritesGap)
        let slotWidth = (block.width - gap * CGFloat(count - 1)) / CGFloat(count)
        return (0..<count).map {
            CGRect(x: block.minX + CGFloat($0) * (slotWidth + gap), y: block.minY, width: slotWidth, height: block.height)
        }
    }

    /// Insertion gap (0...count) nearest to a point at `x` (block-relative).
    static func favoriteGapIndex(forX x: CGFloat, count: Int, blockWidth: CGFloat) -> Int {
        guard count > 0, blockWidth > 0 else { return 0 }
        let slotWidth = blockWidth / CGFloat(count)
        return min(max(Int((x / slotWidth).rounded()), 0), count)
    }
}

/// Placement of the hover card (pure, so it can be tested). [06 §12] observed: below the row,
/// slightly to the left; exact offsets inferred.
enum SidebarHoverCardPlacement {
    static func frame(rowFrame: CGRect, containerWidth: CGFloat) -> CGRect {
        let width = min(SidebarLocalTokens.hoverCardMaxWidth, max(0, rowFrame.width - 2 * SidebarLocalTokens.hoverCardOffsetX))
        var x = rowFrame.minX + SidebarLocalTokens.hoverCardOffsetX
        x = min(x, containerWidth - width - 2)
        x = max(x, 2)
        return CGRect(x: x, y: rowFrame.maxY + SidebarLocalTokens.hoverCardOffsetY, width: width, height: SidebarLocalTokens.hoverCardHeight)
    }
}
