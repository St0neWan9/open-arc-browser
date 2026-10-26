import CoreGraphics
import SwiftUI
import OpenArcDesign
import OpenArcModel

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

    /// Widest hover card; longer titles are truncated. inferred. Placement and shape:
    /// `Metrics.HoverCard` ([07 §12] observed).
    static let hoverCardMaxWidth: CGFloat = 260

    /// Text of the second hover-card line. [06 §12] observed.
    static let hoverCardHint = "Double-click to rename"

    // MARK: Drag and drop

    // Row bands. [06 §15.2] observed on Arc's 41 pt pitch (35 pt highlight + 6 pt gap): about
    // 21 pt around each row boundary inserts (≈ 6 pt of the upper row's bottom, the 6 pt gap and
    // ≈ 8–9 pt of the lower row's top); the middle ≈ 20 pt of a tab row (highlight top + 8–9 to
    // highlight bottom − 7) is the split band. Mapped onto our 41 pt row (fill at y 2–38): inferred.

    /// Height of a tab row's "insert above" band, from the row frame top (fill top 2 + 8.5).
    static let tabRowAboveBand: CGFloat = 10.5
    /// Height of a tab row's "insert below" band, from the row frame bottom (41 − 38 + 7).
    static let tabRowBelowBand: CGFloat = 10

    /// Collapsed (or empty) folder row: the top ≈ 11 pt inserts above, the bottom ≈ 8 pt below,
    /// the middle drops into the folder. [06 §15.3] observed (3 pt steps).
    static let folderRowAboveBand: CGFloat = 11
    static let folderRowBelowBand: CGFloat = 8

    /// Drag start threshold, per axis: ≥ 4 pt vertically or ≥ 5 pt horizontally; (3, 3) does not
    /// start. [06 §15.1] observed.
    static let dragStartThresholdY: CGFloat = 4
    static let dragStartThresholdX: CGFloat = 5

    /// Insertion line: 2 pt, near white (#ECEDFF in a dark theme), from x ≈ 16 to the content
    /// edge, with a hollow ring (outer ⌀ 8, 2 pt stroke, center x ≈ 20) at its left end; +16 pt per
    /// folder level. [06 §15.2] observed (dark theme only; the light-theme color is inferred).
    static let dropIndicatorThickness: CGFloat = 2
    static let dropIndicatorRingDiameter: CGFloat = 8
    static let dropIndicatorLeading: CGFloat = 16
    /// The line ends at x ≈ 265 in Arc's 270 pt sidebar: 3 pt inside our 268 content edge. inferred.
    static let dropIndicatorTrailingInset: CGFloat = 3
    static let dropIndicatorDarkThemeRGB: UInt32 = 0xECEDFF
    /// Light themes: the spec only captured a dark theme; a dark ink line keeps contrast. inferred.
    static let dropIndicatorLightThemeRGB: UInt32 = 0x1C1C1E

    /// Split preview block on a tab row: light gray-violet (≈ #94939F), as tall as the row
    /// highlight, ≈ 105 of the row's ≈ 250 pt, on the pointer's side; the row content moves to the
    /// other side. [06 §15.2] observed.
    static let splitPreviewRGB: UInt32 = 0x94939F
    static let splitPreviewWidthFraction: CGFloat = 105.0 / 250.0

    /// Folder "drop into" highlight: a light gray-violet rounded fill (≈ #9493A6), no stroke.
    /// [06 §15.3] observed.
    static let dropIntoRGB: UInt32 = 0x9493A6

    /// Opacity of a dragged Space column on the Library board (the sidebar source row stays
    /// unchanged, [06 §15.1]). unknown.
    static let draggedRowOpacity: Double = 0.4

    /// Opacity of that fill on a dock dot under a drag. unknown.
    static let dockDropFillOpacity: Double = 0.5


    /// Drag image: the spec sees no row snapshot following the pointer inside the window
    /// [06 §15.1] observed; outside the window its look is unknown. The image is transparent.
    static let dragImageSize: CGFloat = 1

    /// How long a dragged item must hover over a dock icon before the sidebar switches to that
    /// Space. [06 §15.6] observed: within 1 s (sampling ≈ 0.8 s); 0.8 s stays inside that bound.
    static let dockSwitchDelay: Double = 0.8

    /// Edge switching while dragging: the pointer at the sidebar's left edge (x < 20) switches to
    /// the previous Space after ≈ 0.5–1.5 s; at the right edge (fires at 4 pt from Arc's edge, not
    /// at 20 pt) to the next Space after ≈ 0.8 s. [06 §15.6] observed; the exact delay of the left
    /// edge and the right band width (between 4 and 20 pt) are inferred.
    static let edgeSwitchLeftBand: CGFloat = 20
    static let edgeSwitchRightBand: CGFloat = 12
    static let edgeSwitchLeftDelay: Double = 1.0
    static let edgeSwitchRightDelay: Double = 0.8

    /// How often the drag watchdog checks that the mouse button is still down (tests and the
    /// fallback path; the AppKit drag source reports the end itself). unknown (tuning value).
    static let dragWatchInterval: Double = 0.15

    /// Auto-scroll while dragging near the top or bottom edge of the visible list.
    /// [06 §15.8]: starts ≈ 13 pt from the edge (21 pt does not), after ≈ 0.3–0.5 s in the band
    /// (observed); slow at the band's inner edge and much faster at the edge, growing with time,
    /// ≈ 25 pt/s up to hundreds of pt/s (inferred). Stops at the content ends (observed).
    static let autoScrollEdgeBand: CGFloat = 13
    static let autoScrollDwell: Double = 0.4
    static let autoScrollMinSpeed: CGFloat = 25
    static let autoScrollMaxSpeed: CGFloat = 400
    /// Speed multiplier gained per second spent scrolling, capped after `autoScrollRampCap` s. inferred.
    static let autoScrollRampPerSecond: Double = 1
    static let autoScrollRampCap: Double = 1.5
    static let autoScrollTickInterval: Double = 1.0 / 60.0

    // MARK: Colors

    /// Dark text on white floating cards (hover card, drag preview). inferred.
    static let cardTextRGB: UInt32 = 0x1C1C1E
}

extension ThemePalette {
    /// Color of the insertion line and its ring: near white in dark themes ([06 §15.2] observed
    /// #ECEDFF), dark ink in light themes (inferred).
    var dropIndicatorColor: RGBAColor {
        RGBAColor(hex: isDark || usesLightInk ? SidebarLocalTokens.dropIndicatorDarkThemeRGB : SidebarLocalTokens.dropIndicatorLightThemeRGB)
    }
}
