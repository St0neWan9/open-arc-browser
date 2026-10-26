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
// Colors follow E18's rewrite of [06 §17.4] (plan B45): the bar takes the page's top-right color.

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

/// Where a toolbar's background comes from (plan B45). [06 §17.4] observed (E18).
public enum WebToolbarBackgroundSource: Hashable, Sendable {
    /// The color the engine sampled at the top-right of the visible page when its last load
    /// finished, copied exactly: no blend, no theme tint, the same in light and dark Spaces.
    case page(RGBAColor)
    /// The Space-mode neutral: the sample landed on a classic scrollbar ([06 §17.4] observed), or
    /// the page has not been sampled yet (inferred).
    case neutral
    /// No page (an empty panel or a new empty split pane): the bar is transparent over the panel
    /// fill. [06 §17.4] observed the panel color; "transparent" is inferred.
    case transparent
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
    /// The neutral bar when the sample hits a classic scrollbar: light #F3F2F3, dark #3E3E3E.
    /// [06 §17.4] observed (E18; E16's #EFEFEF–#F3F3F2 / #3D3E3D were this fallback, inferred).
    public static let webToolbarFallbackLight = RGBAColor(hex: 0xF3F2F3)
    public static let webToolbarFallbackDark = RGBAColor(hex: 0x3E3E3E)

    /// The ink switches from translucent black to translucent white when the bar's relative
    /// luminance falls below this. [06 §17.4]: pure red (≈ 0.21) takes white ink, pure green
    /// (≈ 0.72) takes black ink, observed; the threshold itself is unknown, so the midpoint of
    /// that range is used (inferred).
    public static let webToolbarInkLuminanceThreshold: Double = 0.465

    /// Translucent black ink on light bars. [06 §17.4, §17.5] observed on white: domain text
    /// ≈ #6B6B6B (≈ 58 % black), icons ≈ #7D7D7D (≈ 51 % black); on green the icons were ≈ #007300
    /// (≈ 55 % black over the bar), so the ink is translucent, not a fixed gray.
    public static let webToolbarDarkInkTextOpacity: Double = 0.58
    public static let webToolbarDarkInkIconOpacity: Double = 0.51
    /// Translucent white ink on dark bars. [06 §17.4] observed: domain text ≈ #CBCBCB on black
    /// (≈ 80 % white; ≈ #FFCFC0 on #FD0200 and ≈ #ECC6C4 on #540000 agree). Icons: ≈ #CCCCCC on
    /// the #3D3E3D fallback (E16, ≈ 74 % white); the red-bar icon reading (≈ #F93833) is thin-glyph
    /// antialiasing (inferred).
    public static let webToolbarLightInkTextOpacity: Double = 0.80
    public static let webToolbarLightInkIconOpacity: Double = 0.74
    /// Disabled icons sit this far from the bar toward the enabled icon: light (#C6C6C6 − #FFFFFF)
    /// / (#7D7D7D − #FFFFFF) ≈ 0.44. [06 §17.5] observed on white; the same rule on every bar is
    /// inferred.
    public static let webToolbarDisabledAmount: Double = 0.44
    /// Hover: a button block ≈ 4 % of the ink over the bar, the domain pill ≈ 6 %. [06 §17.5]
    /// observed on white (#F3F3F3 → #E8E8E8; #EFEFEF on #FFFFFF); with white ink, inferred.
    public static let webToolbarButtonHoverAmount: Double = 0.04
    public static let webToolbarDomainHoverAmount: Double = 0.06
    /// Separator: ≈ 5 % black under a light bar. [06 §17.2] observed; white 6 % under a dark bar,
    /// inferred.
    public static let webToolbarSeparatorOpacityDarkInk: Double = 0.05
    public static let webToolbarSeparatorOpacityLightInk: Double = 0.06
    /// Red of the struck-through lock. [06 §17.2] observed "red"; the value is unknown.
    public static let webToolbarInsecureLock = RGBAColor(hex: 0xE0443E)

    /// The bar's own fill. A sampled page color is used as is; `.transparent` is clear (the panel
    /// fill shows through). [06 §17.4] observed.
    public static func webToolbarBackground(appearance: ResolvedAppearance, source: WebToolbarBackgroundSource) -> RGBAColor {
        switch source {
        case .page(let color): return RGBAColor(red: color.red, green: color.green, blue: color.blue)
        case .neutral: return appearance == .dark ? webToolbarFallbackDark : webToolbarFallbackLight
        case .transparent: return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        }
    }

    /// Whether a bar of this (opaque) color takes the translucent white ink. [06 §17.4] observed
    /// on both sides of the range; threshold inferred (`webToolbarInkLuminanceThreshold`).
    public static func webToolbarUsesLightInk(on bar: RGBAColor) -> Bool {
        luminance(bar) < webToolbarInkLuminanceThreshold
    }

    /// Every color of the toolbar. The ink follows what is visible behind it: the bar, or the
    /// panel fill under a transparent bar. [06 §17.4, §17.5].
    public static func webToolbarColors(
        appearance: ResolvedAppearance,
        source: WebToolbarBackgroundSource,
        panelBackground: RGBAColor
    ) -> WebToolbarColors {
        let background = webToolbarBackground(appearance: appearance, source: source)
        let visible = source == .transparent ? panelBackground : background
        let lightInk = webToolbarUsesLightInk(on: visible)
        let ink = lightInk ? RGBAColor(hex: 0xFFFFFF) : RGBAColor(hex: 0x000000)
        let icon = mix(visible, ink, amount: lightInk ? webToolbarLightInkIconOpacity : webToolbarDarkInkIconOpacity)
        let text = mix(visible, ink, amount: lightInk ? webToolbarLightInkTextOpacity : webToolbarDarkInkTextOpacity)
        return WebToolbarColors(
            background: background,
            icon: icon,
            iconDisabled: mix(visible, icon, amount: webToolbarDisabledAmount),
            domainText: text,
            separator: RGBAColor(red: ink.red, green: ink.green, blue: ink.blue,
                                 alpha: lightInk ? webToolbarSeparatorOpacityLightInk : webToolbarSeparatorOpacityDarkInk),
            buttonHoverFill: mix(visible, ink, amount: webToolbarButtonHoverAmount),
            domainHoverFill: mix(visible, ink, amount: webToolbarDomainHoverAmount),
            insecureLock: webToolbarInsecureLock
        )
    }
}
