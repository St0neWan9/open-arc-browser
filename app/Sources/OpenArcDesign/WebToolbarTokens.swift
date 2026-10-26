import Foundation
import OpenArcModel

// The web panel toolbar ("Show Toolbar" mode, plan B43): a 32 pt strip inside the top of the web
// panel that takes the address and back / forward / reload out of the sidebar.
//
// Spec sources (docs/arc-spec/):
//   [06 §17]          = 06-flows.md §17 (E16, captured 2026-10-26 on Arc 1.170.0, 1920 × 985 window);
//   [04 §网页工具栏]   = 04-visual-metrics.md, web toolbar table (same capture);
//   design-tokens.json `Metrics.WebToolbar` and `ThemeDerivation.webToolbarBackground`.
// Geometry is AX (points, window coordinates); colors are averages of ≥ 5000 pixels (±3 levels).

extension Metrics {
    public enum WebToolbar {
        /// Strip height; the page starts this far below the panel top. [06 §17.2] observed (32).
        public static let height: Double = 32
        /// Gap between the panel's edges and the first / last button. [06 §17.2] observed (5).
        public static let horizontalPadding: Double = 5

        /// Back, forward, reload and show-sidebar: 32 × 24, 4 pt below the strip's top, left edges
        /// 37 apart. [06 §17.2] observed (x 281 / 318 / 355 with the sidebar shown; 15 / 52 / 89 /
        /// 126 with it hidden).
        public static let navButtonSize = Size2D(width: 32, height: 24)
        public static let navButtonTopInset: Double = 4
        public static let navButtonPitch: Double = 37

        /// Site Control Center button: 32 × 28, 2 pt below the strip's top. [06 §17.2] observed.
        public static let siteControlsButtonSize = Size2D(width: 32, height: 28)
        public static let siteControlsButtonTopInset: Double = 2
        /// Split view menu and the split pane's close ✕: 32 × 24, 4 pt below the top. [06 §17.2,
        /// §17.6] observed.
        public static let trailingButtonSize = Size2D(width: 32, height: 24)
        public static let trailingButtonTopInset: Double = 4
        /// Left edges of the site controls and split menu buttons: 36 apart. [06 §17.2] observed
        /// (x 1837 / 1873).
        public static let trailingButtonPitch: Double = 36
        /// In the active split pane the close ✕ is last and the split menu sits right next to it:
        /// left edges 32 apart. [06 §17.6] observed (x 1805 / 1841 / 1873).
        public static let closePanePitch: Double = 32

        /// Center group: copy link 24 × 24, then (http only) the struck-through lock 24 × 24, then
        /// the domain text (16 tall), then two hidden 24 × 24 spacers that keep the group centered
        /// on the panel (not the window). The items touch. [06 §17.2] observed (AX: panel center
        /// 1093, group 1014–1172); "touching" is inferred from the 158 pt group width.
        public static let centerButtonSize: Double = 24
        public static let centerTrailingSpacerCount = 2
        public static let domainTextHeight: Double = 16
        /// Domain text: ≈ 13 pt, medium. [06 §17.2] inferred (glyph height).
        public static let domainFontSize: Double = 13
        /// Least room kept between the center group and the side groups when the panel is narrow
        /// (the domain text is truncated instead). unknown.
        public static let centerGroupMinimumGap: Double = 4

        /// Hover pill behind the domain: the text plus 6 pt on each side, 23 tall, around the text
        /// only. [06 §17.5] observed (≈ (text + 12) × 23).
        public static let domainHoverPillPadding: Double = 6
        public static let domainHoverPillHeight: Double = 23
        /// Button hover backdrop: ≈ 32 × 21 rounded block centered on the button. [06 §17.5]
        /// observed; the corner radius is unknown.
        public static let buttonHoverSize = Size2D(width: 32, height: 21)
        public static let buttonHoverCornerRadius: Double = 6
        /// Tooltip ("Go back ⌘ [") about half a second after hovering. [06 §17.5] inferred (one
        /// observation); macOS's own tooltip delay is used.
        public static let tooltipDelaySeconds: Double = 0.5

        /// ≈ 0.5 pt line between the strip and the page. [06 §17.2] observed.
        public static let bottomSeparatorThickness: Double = 0.5

        /// With the toolbar on, the sidebar loses its URL box and back / forward / reload, and the
        /// favorites and everything below them move up 46 pt (favorites collection y 82 → 36).
        /// [06 §17.1] observed.
        public static let sidebarContentShift: Double = 46

        /// The split pane's focus ring in toolbar mode: ≈ 1 pt in the theme color. [06 §17.6] observed.
        public static let splitPaneFocusRingWidth: Double = 1

        /// Show Toolbar on a fresh install. [06 §17.1] unknown (both states seen on users' Macs);
        /// off keeps the sidebar address box, the layout every earlier build had.
        public static let defaultIsShown = false
        /// Settings ▸ Advanced "Show full URL when Toolbar is enabled". [03 §Advanced] observed (off).
        public static let defaultShowsFullURL = false
    }
}

/// Where the toolbar's background color comes from. Arc 1.170.0 uses only the Space's light / dark
/// mode ([06 §17.4] observed over 7 pages: not the page's top color, not `theme-color`, not the
/// theme hue, not View ▸ Appearance). A page-color source can be added here later.
public enum WebToolbarBackgroundSource: Hashable, Sendable {
    case spaceMode
}

/// Colors of the web toolbar for one appearance.
public struct WebToolbarColors: Hashable, Sendable {
    public var background: RGBAColor
    public var icon: RGBAColor
    public var iconDisabled: RGBAColor
    public var domainText: RGBAColor
    /// Line between the strip and the page.
    public var separator: RGBAColor
    /// Rounded block behind a hovered button.
    public var buttonHoverFill: RGBAColor
    /// Pill behind the hovered domain text.
    public var domainHoverFill: RGBAColor
    /// The struck-through lock of an insecure (http) page.
    public var insecureLock: RGBAColor

    public init(background: RGBAColor, icon: RGBAColor, iconDisabled: RGBAColor, domainText: RGBAColor,
                separator: RGBAColor, buttonHoverFill: RGBAColor, domainHoverFill: RGBAColor, insecureLock: RGBAColor) {
        self.background = background
        self.icon = icon
        self.iconDisabled = iconDisabled
        self.domainText = domainText
        self.separator = separator
        self.buttonHoverFill = buttonHoverFill
        self.domainHoverFill = domainHoverFill
        self.insecureLock = insecureLock
    }
}

extension ThemeDerivation {
    /// Light toolbar: #FFFFFF. [06 §17.4] observed for a new default-theme Space; some Spaces
    /// showed #EFEFEF–#F3F3F2 (`webToolbarLightAlt`) and the rule between the two is unknown, so
    /// the alternative is not used.
    public static let webToolbarLight = RGBAColor(hex: 0xFFFFFF)
    public static let webToolbarLightAlt = RGBAColor(hex: 0xF2F3F2)
    /// Dark toolbar on a single page, and on each split pane. [06 §17.4] observed.
    public static let webToolbarDark = RGBAColor(hex: 0x3D3E3D)
    public static let webToolbarDarkSplitPane = RGBAColor(hex: 0x474747)
    /// Icons: light enabled ≈ #7D7D7D, disabled ≈ #C6C6C6; dark ≈ #C5C5C5–#D3D3D3. [06 §17.4,
    /// §17.5] observed.
    public static let webToolbarIconLight = RGBAColor(hex: 0x7D7D7D)
    public static let webToolbarIconDisabledLight = RGBAColor(hex: 0xC6C6C6)
    public static let webToolbarIconDark = RGBAColor(hex: 0xCCCCCC)
    /// Domain text in light ≈ #646464–#6C6C6C. [06 §17.2] observed. Dark: unknown, the icon color.
    public static let webToolbarDomainLight = RGBAColor(hex: 0x666666)
    /// Disabled icons sit this far from the background toward the enabled color: light
    /// (#C6C6C6 − #FFFFFF) / (#7D7D7D − #FFFFFF) ≈ 0.44. Reused for dark. inferred.
    public static let webToolbarDisabledAmount: Double = 0.44
    /// Hover: a button block ≈ 4 % darker, the domain pill ≈ 6 % black on white. [06 §17.5]
    /// observed in light; the dark-mode hover is unknown (white at the same amounts).
    public static let webToolbarButtonHoverAmount: Double = 0.04
    public static let webToolbarDomainHoverAmount: Double = 0.06
    /// Separator: ≈ 5 % black in light. [06 §17.2] observed; dark unknown (white 6 %).
    public static let webToolbarSeparatorOpacityLight: Double = 0.05
    public static let webToolbarSeparatorOpacityDark: Double = 0.06
    /// Red of the struck-through lock. [06 §17.2] observed "red"; the value is unknown.
    public static let webToolbarInsecureLock = RGBAColor(hex: 0xE0443E)

    /// Toolbar background. The only input that counts in Arc 1.170.0 is the Space's light / dark
    /// mode (resolved, so Automatic follows the system); split panes are a lighter gray in dark.
    /// [06 §17.4] observed. Light split panes were not measured (unknown): the single-page white.
    public static func webToolbarBackground(
        appearance: ResolvedAppearance,
        isSplitPane: Bool = false,
        source: WebToolbarBackgroundSource = .spaceMode
    ) -> RGBAColor {
        switch source {
        case .spaceMode:
            switch appearance {
            case .light: return webToolbarLight
            case .dark: return isSplitPane ? webToolbarDarkSplitPane : webToolbarDark
            }
        }
    }

    /// Every color of the toolbar, derived from its background. [06 §17.4, §17.5].
    public static func webToolbarColors(
        appearance: ResolvedAppearance,
        isSplitPane: Bool = false,
        source: WebToolbarBackgroundSource = .spaceMode
    ) -> WebToolbarColors {
        let background = webToolbarBackground(appearance: appearance, isSplitPane: isSplitPane, source: source)
        let isDark = appearance == .dark
        let icon = isDark ? webToolbarIconDark : webToolbarIconLight
        let hoverInk = isDark ? RGBAColor(hex: 0xFFFFFF) : RGBAColor(hex: 0x000000)
        return WebToolbarColors(
            background: background,
            icon: icon,
            iconDisabled: isDark ? mix(background, icon, amount: webToolbarDisabledAmount) : webToolbarIconDisabledLight,
            domainText: isDark ? webToolbarIconDark : webToolbarDomainLight,
            separator: RGBAColor(red: hoverInk.red, green: hoverInk.green, blue: hoverInk.blue,
                                 alpha: isDark ? webToolbarSeparatorOpacityDark : webToolbarSeparatorOpacityLight),
            buttonHoverFill: mix(background, hoverInk, amount: webToolbarButtonHoverAmount),
            domainHoverFill: mix(background, hoverInk, amount: webToolbarDomainHoverAmount),
            insecureLock: webToolbarInsecureLock
        )
    }
}
