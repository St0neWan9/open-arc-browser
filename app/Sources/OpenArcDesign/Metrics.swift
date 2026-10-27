import Foundation

// Layout tokens, in points. Plain `Double` so this module needs no UI framework; Swift converts
// to CGFloat implicitly at the call site.
//
// Every value cites its source and evidence level:
//   [07 §4]       = docs/arc-spec/07-design-system.md, section 4 (E11, measured on the live app);
//   [04 §sidebar] = docs/arc-spec/04-visual-metrics.md, sidebar table;
//   [06 §5]       = docs/arc-spec/06-flows.md, section 5; etc.
//   observed = accessibility frame or pixel measurement (±0.5 pt)
//   inferred = fitted or derived, not directly measured
//   unknown  = placeholder value; replace when measured
// All measurements come from a 1920×985 pt window, in window coordinates (origin top-left).
// Where 07 corrects an older value (07 §10), the 07 value is used.

/// A width/height pair in points.
public struct Size2D: Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in points, origin top-left.
public struct Rect2D: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
}

public enum Metrics {

    /// Window size the measurements were taken at. [07 §1] observed.
    public static let referenceWindowSize = Size2D(width: 1920, height: 985)

    /// Base spacing unit: insets and gaps are multiples of 8. [07 §1] inferred.
    public static let gridUnit: Double = 8

    // MARK: Window chrome

    /// The three standard window buttons ("traffic lights"). [07 §2] observed.
    public enum WindowButtons {
        /// Center of the close button. [07 §2] observed (20, 24).
        public static let closeCenterX: Double = 20
        public static let centerY: Double = 24
        /// Distance between the centers of neighboring buttons. [07 §2] observed (23).
        public static let pitch: Double = 23
        /// Visible circle diameter. [07 §2] observed (12).
        public static let diameter: Double = 12
        /// Hit box edge (the standard button view). [07 §2] observed (16 × 16 at x 12, y 16).
        public static let hitBoxSize: Double = 16
        /// In the Library the buttons move right 3 and down 4: Library draws its own top bar.
        /// [07 §2] observed (close at (15, 20)).
        public static let libraryOffsetX: Double = 3
        public static let libraryOffsetY: Double = 4

        /// Top-left of a button's 16 pt hit box; index 0 = close, 1 = minimize, 2 = zoom.
        public static func hitBoxOrigin(index: Int, inLibrary: Bool = false) -> (x: Double, y: Double) {
            let dx = inLibrary ? libraryOffsetX : 0, dy = inLibrary ? libraryOffsetY : 0
            return (closeCenterX + Double(index) * pitch - hitBoxSize / 2 + dx, centerY - hitBoxSize / 2 + dy)
        }
    }

    // MARK: Sidebar

    public enum Sidebar {
        /// Width of the sidebar area, including its right-hand gap: the web panel's left edge is
        /// at x = 276. [07 §1] observed.
        public static let width: Double = 276
        /// Left and right inset of the sidebar content (URL box, favorites, selected row): the
        /// content spans x 8–268. [07 §1] observed.
        public static let contentInset: Double = 8

        /// Center line of the toolbar buttons (hide sidebar, back, forward, reload). [07 §2]
        /// observed: the buttons' 32 pt hit areas span y 7.5–39.5; the traffic lights are at 24.
        public static let toolbarRowCenterY: Double = 23.5
        /// Toolbar button hit area edge. [07 §2, §9] observed (32 × 32).
        public static let toolbarButtonSize: Double = 32
        /// Distance between the left edges of back, forward and reload. [07 §2] observed (34).
        public static let toolbarButtonPitch: Double = 34
        /// Left edges of the toolbar buttons. [07 §2] observed.
        public static let hideSidebarButtonX: Double = 77
        public static let backButtonX: Double = 170
        public static let forwardButtonX: Double = 204
        public static let reloadButtonX: Double = 238
        /// Top edge of the toolbar buttons. [07 §2] observed (7.5).
        public static var toolbarButtonTop: Double { toolbarRowCenterY - toolbarButtonSize / 2 }
        /// Visible glyph sizes (ink) inside the buttons. [07 §2] observed.
        public static let hideSidebarGlyph = Size2D(width: 18.5, height: 14.5)
        public static let backGlyph = Size2D(width: 14.5, height: 12)
        public static let reloadGlyph = Size2D(width: 14, height: 17)

        /// Address/search field top edge. [07 §4] observed (y 46–82).
        public static let addressFieldTop: Double = 46
        /// Address/search field height. [07 §4] observed.
        public static let addressFieldHeight: Double = 36
        /// Horizontal inset of the address field from the sidebar edges. [07 §4, §10] observed (8).
        public static let addressFieldHorizontalInset: Double = 8
        /// Address field corner radius. [07 §4] inferred (corner profile fit ≈ 12).
        public static let addressFieldCornerRadius: Double = 12
        /// Left edge of the address text (window x). [07 §4] observed (AX text frame x 20).
        public static let addressFieldTextLeading: Double = 20
        /// Left edge of the address text after the leading icon (the placeholder's magnifier).
        /// Round-1 comparison (B32) observed (AX text frame x 41, ink from 42.5).
        public static let addressFieldTextLeadingAfterIcon: Double = 41
        /// Cell of the address box's leading icon (the placeholder's magnifier): 24 × 24 at
        /// (14, 52), ink ≈ 12 × 12 at x 20–32, y 58–70. Round-1 comparison (B32) observed (AX + PX).
        public static let addressFieldIconFrame = Rect2D(x: 14, y: 52, width: 24, height: 24)
        /// Right edge of the address text (window x). [07 §4] observed (AX 20–264).
        public static let addressFieldTextTrailing: Double = 264

        /// Favorites collection: y 82–145; the blocks inside it span y 90–137. [07 §4] observed.
        public static let favoritesCollectionTop: Double = 82
        public static let favoritesCollectionHeight: Double = 63
        /// Favorites block top edge. [07 §4] observed (y 90–137).
        public static let favoritesTop: Double = 90
        /// Favorites block height. [07 §4] observed (47).
        public static let favoritesHeight: Double = 47
        /// Gap between two favorite blocks (two blocks are 126 wide each). [07 §4] observed (8).
        public static let favoritesGap: Double = 8
        /// Favorite block corner radius. [07 §4] inferred (≈ 12).
        public static let favoritesCornerRadius: Double = 12
        /// Favicon edge inside a favorite block. [07 §4] observed (18 × 18, centered).
        public static let favoriteIconSize: Double = 18

        /// Space header: container from y 145; icon 26 × 26 at (13, 150); name text frame from
        /// x 41 (13 without an icon), y 154–172, ending at x 259. [07 §4] observed.
        public static let spaceHeaderTop: Double = 145
        public static let spaceHeaderHeight: Double = 36
        public static let spaceIconFrame = Rect2D(x: 13, y: 150, width: 26, height: 26)
        public static let spaceNameLeadingWithIcon: Double = 41
        public static let spaceNameLeadingWithoutIcon: Double = 13
        public static let spaceNameTop: Double = 154
        public static let spaceNameTrailing: Double = 259
        /// Visible ink of a Space icon glyph centered in the 26 pt header cell: ≈ 10.5 × 16 for a
        /// lightbulb, i.e. about a 14.5 pt symbol, not a glyph filling the cell. Round-2 comparison
        /// (B33) observed (PX, ink 11 × 16.5 incl. ≈ 0.5 pt JPEG blur, center (26, 163)).
        public static let spaceIconGlyphInk = Size2D(width: 10.5, height: 16)
        /// "More" button: an invisible 2 × 26 strip at (261, 150) until hovered. [07 §4] observed.
        public static let spaceMoreButtonFrame = Rect2D(x: 261, y: 150, width: 2, height: 26)

        /// Old names kept for callers: the space header row (icon line). [07 §4] observed.
        public static var spaceNameRowTop: Double { spaceIconFrame.y }
        public static var spaceNameRowHeight: Double { spaceIconFrame.height }

        /// Top of the scrolling tab list. [07 §1] observed (181).
        public static let listTop: Double = 181
        /// The list starts with a 3 pt empty row. [07 §1] observed.
        public static let listTopSpacer: Double = 3
        /// Row pitch: 40 pt row button + 1 pt gap. [07 §1] observed (41).
        public static let rowPitch: Double = 41
        /// Height of the row button (full sidebar width). [07 §1, §4] observed (40).
        public static let rowButtonHeight: Double = 40
        /// Height of the selected tab's rounded background: 2 pt inside the 40 pt button at the
        /// top and bottom. [07 §4] observed (36).
        public static let selectedRowHeight: Double = 36
        /// Selected background spans x 8–268. [07 §4] observed.
        public static let selectedRowHorizontalInset: Double = 8
        public static let selectedRowVerticalInset: Double = 2
        /// Selected background corner radius. [07 §4] inferred (≈ 11).
        public static let selectedRowCornerRadius: Double = 11
        /// Row icon left edge (window x). [07 §4] observed (x 17–35).
        public static let rowIconLeading: Double = 17
        /// Row icon (favicon) edge. [07 §4, §9] observed (18 × 18).
        public static let rowIconSize: Double = 18
        /// Row title left edge (window x): the text frame starts at 43 (ink at 45). [07 §4, §10] observed.
        public static let rowTitleLeading: Double = 43
        /// Text ink starts about 1 pt inside its accessibility text frame (URL box, Space name, row
        /// and New Tab titles), like an AppKit text field. [07 §4] observed (row frame 43, ink 45;
        /// URL frame 20, ink 21.5); round-2 comparison (B33) observed (PX, after the glyphs' own
        /// side bearings: ≈ 0.5–1.5 pt across five strings).
        public static let textInkInset: Double = 1
        /// Favicon placeholder: a 14 × 14 rounded square centered in the 18 pt icon cell (2 pt inset),
        /// radius ≈ 3.5. Round-2 comparison (B33) observed (PX: ink 14.5 × 14.5 at x 18.5–33 incl.
        /// blur); the radius is inferred from the corner profile. Corrects the round-1 16 pt.
        public static let faviconPlaceholderSize: Double = 14
        public static let faviconPlaceholderCornerRadius: Double = 3.5
        /// Row title right edge (window x). [07 §4] observed (text frame width 216, to 259).
        public static let rowTitleTrailing: Double = 259
        /// Folder icon ink, centered on the row icon cell. [07 §4] observed (22.5 × 16.5, x 16–38.5).
        public static let folderGlyph = Size2D(width: 22.5, height: 16.5)
        /// "+" ink of the New Tab row (x 20–31.5). [07 §4] observed.
        public static let newTabGlyph = Size2D(width: 11.5, height: 12)
        /// Extra indent per folder level. [07 §11] unknown (not measured); placeholder.
        public static let folderIndent: Double = 16

        /// Divider between pinned and Today: a 17 pt row with a 0.5 pt hairline across
        /// x 18.5–257.5 in its middle. [07 §1, §4] observed.
        public static let dividerRowHeight: Double = 17
        public static let dividerLineLeading: Double = 18.5
        public static let dividerLineTrailing: Double = 257.5
        public static let dividerLineThickness: Double = 0.5

        /// Bottom dock: 32 pt tall buttons centered on y = window height − 25: Home at x 8, the
        /// Space icons between x 42 and 234, "+" at x 236. [07 §4] observed.
        public static let dockCenterFromBottom: Double = 25
        public static let dockButtonSize: Double = 32
        public static let dockHomeX: Double = 8
        public static let dockIconsLeading: Double = 42
        public static let dockIconsTrailing: Double = 234
        public static let dockPlusX: Double = 236
        /// Height of the dock band above the window bottom (the list ends at H − 50). [07 §4] observed
        /// (dock list y 935–985 in a 985 window).
        public static let dockHeight: Double = 50
        /// Dock Space items: evenly spaced when crowded (pitch 27.5 for 7, 24 for 8); each frame is
        /// 2 pt wider than the pitch and 34 tall. [07 §4] observed. The pitch with few Spaces is
        /// unknown; capped at the button size (inferred).
        public static let dockItemHeight: Double = 34
        public static let dockItemOverlap: Double = 2
        public static let dockMaxItemPitch: Double = 32
        /// Ink of a dock Space glyph: ≈ 11 × 15 for the current Space's lightbulb, 12–14 pt wide for
        /// the others, i.e. about a 14 pt symbol centered in its cell. Round-2 comparison (B33)
        /// observed (PX).
        public static let dockSpaceGlyphInk = Size2D(width: 11, height: 15)
        /// Ink of the dock "+" (14 × 14) and Home (13.5 × 16.5). [07 §4] observed.
        public static let dockPlusGlyph = Size2D(width: 14, height: 14)
        public static let dockHomeGlyph = Size2D(width: 13.5, height: 16.5)

        /// Font family. [07 §3] observed: SF Pro (system font), default tracking.
        public static let usesSystemFont = true
        /// Row title font size. [07 §3, §10] observed (14). Same as `Typography.tabRowTitle`.
        public static var rowTitleFontSize: Double { Typography.tabRowTitle.size }
    }

    // MARK: Web panel

    public enum WebPanel {
        /// Gap above the web panel. [07 §1] observed.
        public static let insetTop: Double = 10
        /// Gap right of the web panel. [07 §1] observed.
        public static let insetTrailing: Double = 10
        /// Gap below the web panel. [07 §1] observed.
        public static let insetBottom: Double = 10
        /// The panel's left edge touches the sidebar area (x 276). [07 §1] observed.
        public static let insetLeading: Double = 0
        /// Panel corner radius. [07 §10] inferred (≈ 6); [07 §7.1] observed: Arc's corner inset
        /// profile on a white page matches a continuous-corner radius 6 within ±0.3 px per row.
        public static let cornerRadius: Double = 6

        /// Edge shadow of every web content surface: the main panel, split panes, the Little Arc
        /// page and the Library's content panel. [07 §7.1] observed: same on white and black pages,
        /// no hairline or inner stroke, slightly stronger in a dark Space.
        public static func shadow(_ appearance: ResolvedAppearance) -> PanelShadow {
            appearance == .dark ? shadowDark : shadowLight
        }

        /// SwiftUI `.shadow` values (black; `radius` is SwiftUI's blur radius, not a Gaussian
        /// sigma). [07 §7.1] inferred: calibrated on screen against Arc's light-Space profile
        /// (Gaussian fit: black 21.5 %, sigma 3.0 pt, y + 1, no spread), residual ≤ 0.8 % alpha.
        public static let shadowLight = PanelShadow(opacity: 0.24, radius: 3.4, offsetY: 1)
        /// Dark Space. [07 §7.1] inferred (Gaussian fit: black 24 %, sigma 3.15 pt, y + 0.75),
        /// residual ≤ 0.7 % alpha.
        public static let shadowDark = PanelShadow(opacity: 0.25, radius: 3.5, offsetY: 1)

        /// Arc draws no border or inner stroke on the panel. [07 §7.1] observed (the first pixel
        /// inside the edge is already page white / black).
        public static let borderWidth: Double = 0
    }

    /// A black drop shadow, in SwiftUI `.shadow` terms.
    public struct PanelShadow: Hashable, Sendable {
        public var opacity: Double
        public var radius: Double
        public var offsetX: Double
        public var offsetY: Double
        public init(opacity: Double, radius: Double, offsetX: Double = 0, offsetY: Double) {
            self.opacity = opacity
            self.radius = radius
            self.offsetX = offsetX
            self.offsetY = offsetY
        }
    }

    // MARK: Split view

    public enum SplitView {
        /// Gap between panes. [06 §5] observed (≈ 10).
        public static let paneGap: Double = 10
        /// Width of the command bar when it opens inside a pane. [06 §5] observed (≈ 400).
        public static let paneCommandBarWidth: Double = 400
    }

    // MARK: Command bar

    public enum CommandBar {
        /// Panel width. [07 §5] observed (765, x 577.5–1342.5, centered).
        public static let width: Double = 765
        /// Panel height with five results. [07 §5] observed (327).
        public static let heightWithFiveResults: Double = 327
        /// Panel top with five results in a 985 pt window. [07 §5] observed (324).
        public static let topWithFiveResults: Double = 324
        /// Corner radius. [07 §5, §10] inferred (≈ 11).
        public static let cornerRadius: Double = 11
        /// Input row height: panel top to the separator. [07 §5, §10] observed (64).
        public static let inputRowHeight: Double = 64
        /// Input field (AX): x 630, y 344, 656 × 23, relative to the panel at (577.5, 324):
        /// leading 52.5, top 20. [07 §5] observed.
        public static let inputFieldLeading: Double = 52.5
        public static let inputFieldTop: Double = 20
        public static let inputFieldHeight: Double = 23
        /// Globe / search icon of the input row: ink 13 × 13 centered 31.5 pt from the panel's
        /// left and top edges. [07 §5] observed (center (609, 355.5)).
        public static let inputIconCenter: Double = 31.5
        /// ⓘ button: 26 × 26 at (1296, 342.5), i.e. 20.5 from the panel's right edge, 18.5 from
        /// its top. [07 §5, §9] observed.
        public static let infoButtonSize: Double = 26
        public static let infoButtonTrailing: Double = 20.5
        public static let infoButtonTop: Double = 18.5
        /// Separator under the input row: y 387.5 (panel + 63.5), 0.5 pt, 12 pt from each side.
        /// [07 §5] observed.
        public static let separatorInset: Double = 12
        public static let separatorThickness: Double = 0.5
        /// Results start 4 pt below the input row (y 392). [07 §5] observed.
        public static let resultsTopGap: Double = 4
        /// Result rows: x 585–1335 (inset 7.5 from the panel), pitch = frame = 50. [07 §5] observed.
        public static let resultRowInset: Double = 7.5
        public static let resultRowPitch: Double = 50
        /// Visible (selected) row height: 2 pt inside the 50 pt row at the top and bottom. [07 §5] observed (46).
        public static let resultRowHeight: Double = 46
        /// Selected row corner radius. [07 §5] inferred (≈ 5).
        public static let resultRowCornerRadius: Double = 5
        /// Row icon 16 × 16, 16 pt from the row's left edge; title 11 pt after the icon. [07 §5] observed.
        public static let resultIconLeading: Double = 16
        public static let resultIconSize: Double = 16
        public static let resultIconTextGap: Double = 11
        /// Arrow box 24 × 24 (radius ≈ 4), 15 pt from the row's right edge; the action text ends
        /// 7 pt before it. [07 §5] observed.
        public static let resultArrowBoxSize: Double = 24
        public static let resultArrowBoxCornerRadius: Double = 4
        public static let resultArrowBoxTrailing: Double = 15
        public static let resultActionToArrowGap: Double = 7
        /// The backdrop is NOT dimmed. [07 §5] observed.
        public static let dimsBackground = false
        /// Shadow: large, soft, offset down. [07 §5] inferred (profile fit: black ≈ 37 %, blur ≈ 48, y + 12).
        public static let shadowOpacity: Double = 0.37
        public static let shadowRadius: Double = 48
        public static let shadowOffsetY: Double = 12
        /// Outline: light = an outer 0.5 pt hairline of black ≈ 25 %; dark = an inner 0.5 pt light
        /// line (≈ #565656). [07 §5] observed.
        public static let outlineThickness: Double = 0.5

        /// Bottom padding under the last row, from 327 = 64 + 4 + 5 × 50 + 9. [07 §5] inferred.
        public static var bottomPadding: Double {
            heightWithFiveResults - inputRowHeight - resultsTopGap - 5 * resultRowPitch
        }

        /// Vertical placement: the five-result panel sits 5 pt above the window's vertical center
        /// (top 324 in 985). [07 §5] observed position; the rule for other heights is inferred
        /// (one sample; the top stays put as results change).
        public static let centerOffsetAboveMiddle: Double = 5

        /// Old name kept for callers that place the panel by fraction. Derived from the 07 position.
        public static var verticalPositionFraction: Double {
            topWithFiveResults / (referenceWindowSize.height - heightWithFiveResults)
        }
    }

    // MARK: Other surfaces

    public enum LittleArc {
        /// Initial (command-bar-only) window size. [06 §7] observed (≈ 490×330).
        public static let initialSize = Size2D(width: 490, height: 330)
        /// Opens at the top right of the screen's visible area, this far from its right and top
        /// edges (not centered). [07 §12] observed (20 / 20).
        public static let screenMargin: Double = 20
    }

    public enum Dialog {
        /// New Folder modal. [07 §6] observed (450 × 222).
        public static let newFolderSize = Size2D(width: 450, height: 222)
        /// Delete Space confirmation. [07 §6] observed (450 × 273).
        public static let deleteSpaceSize = Size2D(width: 450, height: 273)
        /// Corner radius. [07 §12] observed (corner profile of the New Folder sheet fits a
        /// continuous r = 26, RMS 0.1 pt; the older ≈ 24 of [07 §6] was an estimate).
        public static let cornerRadius: Double = 26
        /// Content left edge (title x inside the sheet). [07 §6] observed (38).
        public static let contentLeading: Double = 38
        /// Right and bottom margins of the button row. [07 §6] observed (28 / 26.5).
        public static let contentTrailing: Double = 28
        public static let contentBottom: Double = 26.5
        /// Text field: 375.5 × 37.5, radius ≈ 6, white with a light gray outline. [07 §6] observed.
        public static let textFieldSize = Size2D(width: 375.5, height: 37.5)
        public static let textFieldCornerRadius: Double = 6
        /// Buttons: Cancel 110 × 40, primary 100 × 38.5. [07 §6] observed.
        public static let cancelButtonSize = Size2D(width: 110, height: 40)
        public static let primaryButtonSize = Size2D(width: 100, height: 38.5)
        /// Button corner radius. [07 §6] unknown (not measured); placeholder.
        public static let buttonCornerRadius: Double = 10
        /// Delete Space: app icon 62 × 62 at (38, 38); title at y 117, body at y 154, buttons at
        /// y 207 (sheet coordinates). [07 §6] observed.
        public static let appIconSize: Double = 62
        public static let appIconTop: Double = 38
        public static let deleteTitleTop: Double = 117
        public static let deleteBodyTop: Double = 154
        public static let deleteButtonsTop: Double = 207
    }

    public enum ThemePicker {
        /// Visible bubble size (the AX frame is 382 × 534 incl. arrow and shadow). [07 §6, §10] observed.
        public static let size = Size2D(width: 356, height: 508)
        /// Corner radius. [07 §6] inferred (corner profile fits r = 20).
        public static let cornerRadius: Double = 20
        /// Inner padding. [07 §6] observed (8).
        public static let padding: Double = 8
        /// Dot-grid color pad. [07 §6] observed (340 × 340).
        public static let dotGridSize: Double = 340
        /// Preset swatches: 24 × 24 at a 29.5 pitch. [07 §6] observed.
        public static let swatchSize: Double = 24
        public static let swatchPitch: Double = 29.5
        /// Appearance segment buttons: 32 × 32 at a 40 pitch. [07 §6] observed.
        public static let segmentButtonSize: Double = 32
        public static let segmentButtonPitch: Double = 40
        /// Preset swatches per page. [06 §2] observed.
        public static let swatchesPerPage = 9
    }

    public enum Library {
        /// Total width of the left part (rail + list column). [07 §6] observed (417).
        public static let leftPaneWidth: Double = 417
        /// Rail buttons: 97 × 80 at x 8, pitch 100. [07 §6] observed.
        public static let railButtonSize = Size2D(width: 97, height: 80)
        public static let railButtonLeading: Double = 8
        public static let railButtonPitch: Double = 100
        /// Rail width: button plus 8 pt on both sides. [07 §10] inferred (≈ 113).
        public static var iconRailWidth: Double { railButtonLeading * 2 + railButtonSize.width }
        /// List column width: the rest of the left part. [07 §10] inferred (≈ 304).
        public static var listColumnWidth: Double { leftPaneWidth - iconRailWidth }
        /// Selected rail block corner radius. [07 §6] observed (≈ 10).
        public static let railCornerRadius: Double = 10
        /// Media rows (B57): [06 §8] observed "thumbnail rows"; sizes not measured. unknown.
        public static let mediaRowHeight: Double = 52
        public static let mediaThumbnailSize = Size2D(width: 56, height: 40)
        public static let mediaThumbnailCornerRadius: Double = 5
    }

    public enum SiteControls {
        /// Visible bubble width. [07 §12] observed (AX content 236 wide; the old 120 of [06 §12]
        /// was a pixel value halved twice).
        public static let popoverWidth: Double = 236
        /// Bubble corner radius. [07 §12] observed (corner profile fits r = 20).
        public static let cornerRadius: Double = 20
    }

    /// Floating bubbles drawn by us (theme bubble, Site Control Center, hover card): placement
    /// relative to their anchor and their chrome. [07 §12].
    public enum FloatingBubble {
        /// Gap between the anchor edge and the bubble edge (the arrow spans it). [07 §12] observed:
        /// 13 for a bubble right of its anchor ("Choose a Theme"), 12 for one below (Site Control
        /// Center).
        public static let gapTrailing: Double = 13
        public static let gapBelow: Double = 12
        /// Arrow height and base width (soft triangle with concave flanks and a rounded tip).
        /// [07 §12] observed (height ≈ 10.5; half width ≈ 12.25 one point from the base).
        public static let arrowHeight: Double = 10.5
        public static let arrowBaseWidth: Double = 26
        /// Bubbles stay this far inside the window. [07 §12] observed (Edit Theme… clamps its
        /// 13 pt frame inset to the window edges); applied to attached bubbles too, inferred.
        public static let windowMargin: Double = 13
        /// Edit Theme… (menu or Space menu): no arrow; the bubble's left edge is this far right of
        /// the web panel's left edge. [07 §12] observed (x 289 with the panel at 276).
        public static let editThemeLeadingInset: Double = 13
        /// 1 pt inner rim: white 70 % on a light bubble, white 20 % on a dark one. [07 §12] inferred
        /// (edge pixels about 60–80 % / 15–25 % toward white).
        public static let rimWidth: Double = 1
        public static let rimOpacityLight: Double = 0.7
        public static let rimOpacityDark: Double = 0.2
        /// The bubble is translucent: a within-window blur under the theme tint at this opacity.
        /// [07 §12] observed (blurred page text shows through; the fill shifts 10–25 % toward what
        /// is behind it); 0.82 inferred. No drop shadow. [07 §12] observed.
        public static let tintOpacity: Double = 0.82
    }

    /// Tab-row hover card. [07 §12] observed: a separate floating window placed at the pointer
    /// (not at the row), fixed once shown; a speech-bubble corner at the top left.
    public enum HoverCard {
        /// Card top-left = pointer + this offset (points, y down). [07 §12] observed (11.5, 5.5).
        public static let pointerOffsetX: Double = 11.5
        public static let pointerOffsetY: Double = 5.5
        /// Top-left corner radius (next to the pointer) and the other three. [07 §12] observed
        /// (corner profiles fit 3.5 and 15.5).
        public static let pointerCornerRadius: Double = 3.5
        public static let cornerRadius: Double = 15.5
        /// Shadow: black, SwiftUI radius, no offset. [07 §12] inferred (≈ 12 % darker at the edge,
        /// gone ≈ 10 pt out, same below and to the right).
        public static let shadowOpacity: Double = 0.24
        public static let shadowRadius: Double = 8
        /// Inner padding. [07 §12] inferred (card 141.5 × 42.5 around a 13 pt and an 11 pt line).
        public static let horizontalPadding: Double = 10
        public static let verticalPadding: Double = 6
    }

    public enum ContextMenu {
        /// System menu metrics, for reference (we use NSMenu). [07 §6] observed.
        public static let itemHeight: Double = 24
        public static let separatorHeight: Double = 11
        public static let verticalPadding: Double = 5
    }

    public enum Settings {
        /// Settings window size and toolbar. [07 §6] observed (684 × 650; toolbar 56; toggle rows 37 apart).
        public static let windowSize = Size2D(width: 684, height: 650)
        public static let toolbarHeight: Double = 56
        public static let toggleRowPitch: Double = 37
    }

    // MARK: Sidebar drag image

    /// The lifted copy of a sidebar row that follows the pointer while it is dragged, and the
    /// shapes it takes over the upper sidebar. [06 §15.1, §15.4, §15.5] and [04 §拖动图像(E17)];
    /// design-tokens.json `Metrics.SidebarDrag`. Arc draws it in a window above everything, so it
    /// shows over the web panel and outside the window too (observed).
    public enum SidebarDrag {
        /// Full-size image: the row's size. [06 §15.1] observed (≈ 258 × 36; the row fill is
        /// 257 × 35.5).
        public static let rowImageSize = Size2D(width: 258, height: 36)
        /// The image's left edge sits this far left of the row fill's left edge, so a press 90 pt
        /// into the row is 91.5 pt into the image. [06 §15.1] observed.
        public static let rowImageLeadingOutset: Double = 1.5
        /// Corner radius of the full-size image, as the selected row. [06 §15.1] inferred (≈ 10).
        public static let rowImageCornerRadius: Double = 10
        /// Opacity of the full-size image (row text below shows through). [06 §15.1] inferred (≈ 0.85).
        public static let rowImageOpacity: Double = 0.85
        /// Soft shadow under the image: offset (0, 3), ≈ 10 pt blur, ≈ 9–13 pt below and ≈ 2 pt
        /// above; at most ≈ 15 % darker on light themes, nearly invisible on dark ones.
        /// [06 §15.1] observed (extent) / inferred (parameters). The SwiftUI radius and the two
        /// opacities are our fit to that extent and darkening (inferred).
        public static let shadowOffsetY: Double = 3
        public static let shadowRadius: Double = 6
        public static let shadowOpacityLight: Double = 0.28
        public static let shadowOpacityDark: Double = 0.06
        /// Room around the image for the shadow inside the drag image bitmap (ours).
        public static let shadowMargin: Double = 16

        /// Compact pill over the Space-name row, the address field and the window top: smaller
        /// text, still icon + title + ✕, near-white and translucent. [06 §15.4] observed (≈ 186 × 26).
        public static let pillSize = Size2D(width: 186, height: 26)
        /// The pill's corners: a rounded rectangle, not a full capsule. B44 side-by-side PX
        /// (lossless full-screen capture of Arc 1.170.0, edge fit ≈ 7 pt); inferred.
        public static let pillCornerRadius: Double = 7
        /// The pill's text and icon. [06 §15.4] observed "smaller text"; sizes inferred (scaled
        /// with the height, 26 / 36).
        public static let pillTitleSize: Double = 10.5
        public static let pillIconSize: Double = 13
        public static let pillAccessorySize: Double = 8
        /// Insets of the pill content (scaled from the row: icon at 9, title gap 8). inferred.
        public static let pillIconLeading: Double = 8
        public static let pillTitleGap: Double = 6
        public static let pillTrailing: Double = 8

        /// Favorite-tile shape over Favorites: the favorite block's height, only the centered icon.
        /// [06 §15.5] observed (≈ 126 × 47, radius ≈ 10–12).
        public static let favoriteTileSize = Size2D(width: 126, height: 47)
        public static let favoriteTileCornerRadius: Double = 11
        /// Its fill: near white / light gray whatever the theme (lavender #F0F0F6, pink light
        /// #F6E5EB, navy dark #B9BBC8 observed). The tile sits over the favorites block (window ×
        /// 0.96), so it is modeled as white at this opacity over that fill: 0.66 in light (≤ 4/255
        /// for lavender and pink), 0.48 in dark (≤ 3/255 for navy). [06 §15.5] observed samples;
        /// rule inferred (B44 side-by-side check).
        public static let favoriteTileWhiteOpacity: Double = 0.66
        public static let favoriteTileWhiteOpacityDark: Double = 0.48

        /// Split preview block on a row's middle band: about half the row (≈ 129 of 258 wide).
        /// [06 §15.4] observed (E17, ≈ 129 × 37); E9 measured ≈ 105 of 250 on a narrower sidebar.
        public static let splitPreviewWidthFraction: Double = 0.5
        /// Dark themes: the split preview is the window lightened by this much white (navy dark
        /// #7D7E98 → #B7B7C9 observed, ≤ 3/255). [06 §15.4] observed sample; rule inferred.
        /// Light themes use the Space-name band color (lavender band #878CFF vs block #838BFE,
        /// observed; rule inferred).
        public static let darkSplitPreviewWhite: Double = 0.45
    }

    // MARK: Icon opacity

    public enum IconOpacity {
        /// Toolbar icons: enabled ≈ 75 %, disabled ≈ 30 % of the theme text color. [07 §2, §7] inferred.
        public static let enabled: Double = 0.75
        public static let disabled: Double = 0.30
        /// Dock items of other Spaces. [07 §4, §7] inferred (≈ 33 %).
        public static let inactiveDockItem: Double = 0.33
    }
}

// Timing and animation tokens live in Motion.swift ([07 §11 动效(E7)]).
