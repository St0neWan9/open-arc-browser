import CoreGraphics
import SwiftUI
import OpenArcDesign

// Sidebar-local constants. Everything that OpenArcDesign already measures is read from
// `Metrics` / `Motion` / `ThemeDerivation`; the values below are the ones the spec does not
// pin down. Each carries its spec section and evidence level (CLAUDE.md "Evidence levels").
// They are listed in the hand-off report and should move into OpenArcDesign once measured.

enum SidebarLocalTokens {

    // MARK: List

    /// Extra left indent per folder nesting level. [07 §11] unknown (the drag into a folder failed
    /// in E11); 16 pt is a placeholder.
    static var folderIndent: CGFloat { CGFloat(Metrics.Sidebar.folderIndent) }

    /// Height of the divider row. [07 §1] observed (17).
    static var dividerRowHeight: CGFloat { CGFloat(Metrics.Sidebar.dividerRowHeight) }

    /// Favicon / folder icon cell edge. [07 §4] observed (18 × 18).
    static var rowIconSize: CGFloat { CGFloat(Metrics.Sidebar.rowIconSize) }

    /// Favicon placeholder: a 14 × 14 rounded square centered in the 18 pt cell, radius ≈ 3.5.
    /// Round-2 comparison (B33) observed (PX); corrects round 1's 16 pt.
    static var faviconPlaceholderInset: CGFloat {
        CGFloat(Metrics.Sidebar.rowIconSize - Metrics.Sidebar.faviconPlaceholderSize) / 2
    }
    static var faviconPlaceholderCornerRadius: CGFloat { CGFloat(Metrics.Sidebar.faviconPlaceholderCornerRadius) }

    /// Text ink sits 1 pt inside its accessibility text frame. [07 §4] observed; B33 round-2 PX.
    static var textInkInset: CGFloat { CGFloat(Metrics.Sidebar.textInkInset) }

    /// Scroll-edge lines of the list. Round-1 PX (B32) observed (1 pt).
    static let scrollEdgeLineThickness: CGFloat = 1

    /// Magnifier in front of the URL box placeholder: point size giving the ≈ 12 × 12 ink.
    /// Round-1 PX (B32) observed ink; the point size is fitted.
    static let addressIconGlyphSize: CGFloat = 12.5

    /// Hover fill of a tab row: "one step darker, semi-transparent" [06 §12] observed; the
    /// opacity of the black overlay is unknown.
    static let rowHoverBlackOpacity: Double = 0.07

    /// Edge of the ✕ / — button at a row's trailing end. [06 §12] observed that it exists;
    /// the size is unknown (24, centered like the 18 pt icon cell).
    static let rowAccessoryButtonSize: CGFloat = 24

    /// Trailing padding of the row accessory inside the selected fill. unknown.
    static let rowAccessoryTrailingPadding: CGFloat = 6

    /// Hover backdrop of a toolbar button: inset into the 32 pt hit area, rounded. unknown.
    static let toolbarHoverInset: CGFloat = 2
    static let toolbarHoverCornerRadius: CGFloat = 7

    /// Width of the divider's "↓ Clear" button (text right-aligned at the line's end). unknown.
    static let clearButtonWidth: CGFloat = 52

    /// Width of the Space header's "More" button while the header is hovered. [07 §4] observed only
    /// the 2 pt strip at rest; the hovered size is unknown.
    static let spaceMoreHoverWidth: CGFloat = 24

    // MARK: Split group row

    /// Opacity of the thin vertical line between two members of a split-group row, and its height
    /// as a fraction of the row icon size. [06 §5] says only that the split tabs are one group in
    /// the sidebar; the look of that row is unknown (local placeholder).
    static let splitGroupDividerOpacity: Double = 0.25
    static let splitGroupDividerHeight: CGFloat = 16

    /// Gap between a member's favicon and its title inside a split-group row. unknown.
    static let splitGroupMemberIconGap: CGFloat = 6

    /// Horizontal padding of one member cell inside a split-group row. unknown.
    static let splitGroupMemberPadding: CGFloat = 6

    // MARK: Space name row

    /// Thin separator lines (split group dividers). inferred.
    static let separatorThickness: CGFloat = 1

    // MARK: Favorites

    /// Edge of a favorite's icon inside the block. [07 §4] observed (18).
    static var favoriteIconSize: CGFloat { CGFloat(Metrics.Sidebar.favoriteIconSize) }

    // MARK: Dock

    /// Opacity of non-current dock items. [07 §7] inferred (≈ 33 %).
    static var dockInactiveOpacity: Double { Metrics.IconOpacity.inactiveDockItem }

    /// Point size of the Space icon glyph inside a dock item: a 14 pt symbol gives the measured
    /// ≈ 11 × 15 lightbulb ink (`Metrics.Sidebar.dockSpaceGlyphInk`). Round-2 comparison (B33)
    /// observed ink; the point size is fitted.
    static let dockSpaceGlyphSize: CGFloat = 14

    /// Point size of the Space icon glyph in the Space header, centered in the 26 pt cell: a 14 pt
    /// symbol gives the measured ≈ 10.5 × 16 lightbulb ink (`Metrics.Sidebar.spaceIconGlyphInk`).
    /// Round-2 comparison (B33) observed ink; the point size is fitted.
    static let spaceIconGlyphSize: CGFloat = 14

    /// Toolbar glyphs (point size, weight). Round-2 comparison (B33) observed: the reference
    /// strokes reach the full disabled ink (≈ 30 %) and cover ≈ 44 pt² (arrows), ≈ 60 pt² (reload)
    /// and ≈ 104 pt² (hide sidebar) of ink; regular SF strokes are thinner. Medium weight at these
    /// sizes gives the measured ink sizes [07 §2] and areas. inferred (fitted).
    static let toolbarGlyphWeight: Font.Weight = .medium
    static let toolbarArrowGlyphSize: CGFloat = 16
    static let toolbarReloadGlyphSize: CGFloat = 16
    static let toolbarSidebarGlyphSize: CGFloat = 15.5

    /// "+" glyphs, from the round-2 ink (B33, PX observed; sizes and weights fitted, inferred):
    /// dock "+" 14 × 14 ink [07 §4] covering ≈ 52 pt² (17 pt semibold); New Tab row "+"
    /// 12 × 12 ink [07 §4] covering ≈ 37 pt² (15 pt medium).
    static let dockPlusGlyphSize: CGFloat = 17
    static let dockPlusGlyphWeight: Font.Weight = .semibold
    static let newTabPlusGlyphSize: CGFloat = 15
    static let newTabPlusGlyphWeight: Font.Weight = .medium

    /// Dock Home (Library) glyph: a filled box, 14 pt → ≈ 14 × 15 ink of ≈ 130 pt², near the
    /// reference's filled 13.5 × 16.5 ink [07 §4] (≈ 128 pt², round-2 PX). The shape is our own.
    static let dockHomeSymbol = "shippingbox.fill"
    static let dockHomeGlyphSize: CGFloat = 14

    /// Empty space below the last list row. Round-2 comparison (B33) inferred from the
    /// reference's scroller: the knob (y 482–842 of the 181–934 track) gives ≈ 1575 pt of
    /// content for rows ending at 1315, i.e. ≈ 260 pt of trailing space. Dropping there appends to
    /// Today; it also makes the bottom scroll-edge line show once rows come within that distance
    /// of the dock (seen in both captures).
    static let listTrailingSpace: CGFloat = 260

    // MARK: Hover card

    /// Hover card geometry. [06 §12] "small rounded white bubble, two lines, below the row,
    /// slightly left" observed; the numbers are inferred.
    static let hoverCardCornerRadius: CGFloat = 8
    static let hoverCardMaxWidth: CGFloat = 220
    static let hoverCardHeight: CGFloat = 48
    static let hoverCardOffsetX: CGFloat = 6
    static let hoverCardOffsetY: CGFloat = 4

    /// Text of the second hover-card line. [06 §12] observed.
    static let hoverCardHint = "Double-click to rename"

    // MARK: Drag and drop

    /// Fraction of a folder row's height, at the top and at the bottom, that means
    /// "before" / "after" instead of "into". [06 §12] only shows "dropped on the folder row
    /// goes inside"; the band sizes are unknown.
    static let dropEdgeBand: CGFloat = 0.25

    /// Thickness of the drop indicator line. unknown.
    static let dropIndicatorThickness: CGFloat = 2

    /// Fill opacity of the accent color on a folder row (or dock icon) that would receive the
    /// drop. [06 §12] observed only the result ("goes inside"), not the highlight. unknown.
    static let dropIntoFillOpacity: Double = 0.18

    /// Opacity of the source row while it is being dragged. unknown.
    static let draggedRowOpacity: Double = 0.4

    /// Drag preview ("lifted row"): shadow and scale. unknown.
    static let dragPreviewShadowRadius: CGFloat = 6
    static let dragPreviewScale: CGFloat = 1.02

    /// How long a dragged item must hover over a dock icon before the sidebar switches to that
    /// Space, so the item can be placed inside it. Spec: [06 §12] does not cover cross-Space
    /// drags. inferred (macOS spring-loading uses roughly this delay).
    static let dockSwitchDelay: Double = 0.8

    /// How often the drag watchdog checks that the mouse button is still down. A cancelled drag
    /// (released outside any drop target, or Esc) gives SwiftUI no callback. unknown (tuning value).
    static let dragWatchInterval: Double = 0.15

    /// Auto-scroll while dragging near the top or bottom edge of the list. The spec does not
    /// describe auto-scroll at all ([06 §12] covers drag results only): band height, top speed and
    /// tick rate are inferred (about one row pitch; a speed that crosses a long list in about a
    /// second; one tick per display frame).
    static let autoScrollEdgeBand: CGFloat = 40
    static let autoScrollMaxSpeed: CGFloat = 600
    static let autoScrollTickInterval: Double = 1.0 / 60.0

    // MARK: Colors

    /// Dark text on white floating cards (hover card, drag preview). inferred.
    static let cardTextRGB: UInt32 = 0x1C1C1E
}
