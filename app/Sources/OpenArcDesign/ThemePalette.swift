import Foundation
import OpenArcModel

/// Light or dark, after `ThemeAppearance.automatic` was resolved against the system setting.
/// Our own name (the spec only shows the automatic / light / dark segments [06 §2]).
public enum ResolvedAppearance: String, Hashable, Sendable, CaseIterable {
    case light, dark
}

/// Colors for one space, derived from its theme.
///
/// The derivation follows docs/arc-spec/07-design-system.md §8 (E11, refitted by E12 / B38 / B46 and
/// checked on lossless captures by E8, §8.4) (`ThemeDerivation`). The rules are inferred; the sample
/// values they reproduce are observed. Arc's window is slightly translucent ([07 §8.4]: ≈ 11 % light /
/// 19 % dark of the blurred desktop shows through); the opaque colors here are what the window
/// shows over the mid-gray reference desktop (the E12 / E8 reference). The window paints
/// `windowTint` at `windowOpacity` over a blur of the desktop and draws its controls as
/// `windowLayers` on top (B64, `WindowTranslucency`), so over that reference it shows these colors.
/// Window, sidebar, controls and separators are one color family per Space [07 §8] observed; the
/// command bar, sheets and menus do not follow the theme color, only light or dark [07 §8] observed.
public struct ThemePalette: Hashable, Sendable {
    /// Window and sidebar background (the same color everywhere in a Space). [07 §8] inferred rule:
    /// light = mix(theme, #EBEBEB, 0.37) on sRGB; dark = mixP3(theme, gray 180/255, 0.393).
    public var windowBackground: RGBAColor
    /// Fill for the address field, favorites blocks and dock highlights: window × 0.96 (darker, not
    /// lighter). [07 §8] inferred, light and dark.
    public var controlFill: RGBAColor
    /// Selected tab row background (also the lifted drag row and the hover card). Dark ink:
    /// mix(window, #F7F7F7, 0.894), near white (E8 refit, [07 §8.4]); light ink: mix(window,
    /// #F5F5FF, 0.222), a muted tone close to the window. It follows the ink, not light / dark.
    /// [07 §8.3, §8.4] inferred.
    public var selectedTabFill: RGBAColor
    /// Command bar panel: #F9F9F9 light, #181818 dark, whatever the theme. [07 §5, §8] observed.
    public var commandBarBackground: RGBAColor
    /// Highlighted command bar result: the theme hue at OKLCH L 0.73 (light) / 0.485 (dark).
    /// [07 §8, §8.4] observed samples; the rule (and its chroma factor) is inferred.
    public var commandBarSelection: RGBAColor
    /// Text on the window background (tab and folder titles, toolbar icons): a dark color of the
    /// theme's hue, OKLCH L 0.252, chroma 0.60 × the theme's; the same in dark. [07 §8, §8.4]
    /// observed values (AX), inferred rule. White with a light-ink theme [07 §8.3].
    public var primaryText: RGBAColor
    /// Dimmed text (Space name, "Clear"): the chrome ink at the Space name opacity: black 45 %
    /// [07 §3] observed (AX); white ≈ 50 % on a light-ink window (B32 round-1 PX, inferred).
    public var secondaryText: RGBAColor
    /// Colors for a gradient window background: every color dot of the theme mapped like the window
    /// color, in order. One element for a single-color theme or no theme. How Arc blends several dots
    /// is unknown [00 inventory]; spreading them evenly is inferred. `windowBackground` stays the
    /// first dot.
    public var backgroundGradientColors: [RGBAColor] = []

    // MARK: B21 additions (appearance)

    /// Light or dark: the space's `Theme.appearance`, with automatic resolved against the system.
    public var appearance: ResolvedAppearance = .light
    /// Content area: the web panel wherever no page paints (no tab selected, behind the command
    /// bar, split panes, the Library's content area). Tinted from the theme in light and dark,
    /// never plain white or black: `ThemeDerivation.contentBackground` [07 §8.1] (E12, inferred
    /// rule, max 2.9/255 over 72 observed samples). On a light-ink window in dark it lands on the
    /// control fill, as observed in [07 §8.1] and B32 round 1.
    public var webPanelBackground: RGBAColor = RGBAColor(hex: 0xFFFFFF)
    /// Command bar result titles: black 80 % (light), white ≈ 85 % (dark). [07 §3] observed.
    public var commandBarText: RGBAColor = RGBAColor(hex: 0x000000, alpha: 0.80)
    /// Opacity of dimmed command bar text relative to an opaque ink (subtitles, action text,
    /// placeholder): 0.33 light, ≈ 0.42 dark. [07 §3] observed.
    public var commandBarSecondaryAlpha: Double = 0.33
    /// Text on the selected command bar row: white. [07 §3] observed.
    public var commandBarSelectedText: RGBAColor = RGBAColor(hex: 0xFFFFFF)
    /// 0.5 pt line under the input row: #E1E1E1 light, #363636 dark. [07 §5] observed.
    public var commandBarSeparator: RGBAColor = RGBAColor(hex: 0xE1E1E1)
    /// Rounded backdrop of small buttons on the panel (Little Arc ✕, unselected arrow box):
    /// black 4 % in light [07 §5] observed (#EFEFEF on #F9F9F9); white 8 % in dark, inferred.
    public var commandBarAccessoryFill: RGBAColor = RGBAColor(hex: 0x000000, alpha: 0.04)
    /// Theme bubble and other floating panels drawn by us: near white tinted by the theme (light)
    /// or a dark tone of the theme hue (dark), fitted so that the tint at
    /// `Metrics.FloatingBubble.tintOpacity` over a neutral backdrop lands on Arc's bubble body.
    /// [07 §6, §8.4] observed samples (E8 lossless); OKLCH rule inferred.
    public var floatingPanelBackground: RGBAColor = RGBAColor(hex: 0xFFFFFF)
    /// Sidebar drop target fill (the Space-name row while a tab is dragged over it): a darker tone
    /// of the theme, not gray. [06 §15.4] observed (E17, sidebar → band: lavender #DFE0FA →
    /// #878CFF, pink light #F2B0C9 → #D26E92, navy dark #7D7E98 → #6A6B85; magenta #E204E6 →
    /// #B828BC). Rule `ThemeDerivation.dropTargetFill`, inferred.
    public var dropTargetFill: RGBAColor = RGBAColor(hex: 0x878CFF)
    /// Split preview block on a row's middle band while a tab is dragged. Follows the theme: light
    /// themes a saturated tone (lavender #838BFE), dark themes a light gray (navy dark #B7B7C9).
    /// [06 §15.2, §15.4] observed samples; rule `ThemeDerivation.splitPreviewFill` inferred.
    public var splitPreviewFill: RGBAColor = RGBAColor(hex: 0x838BFE)
    /// Ink on floating panels, used with opacities: black in light, white in dark.
    /// [04 §dark mode] observed; exact values inferred.
    public var floatingPanelInk: RGBAColor = RGBAColor(hex: 0x000000)
    /// Selected appearance segment in the theme bubble: gray in light ([06 §2] observed "gray
    /// fill"), a pale block of the theme color in dark ([04 §dark mode] observed).
    public var floatingPanelSelection: RGBAColor = RGBAColor(red: 0.86, green: 0.86, blue: 0.88)
    /// Primary buttons ("Create Space"): brand blue in light, the theme color darkened in dark.
    /// [04 §dark mode] observed; values approximate.
    public var primaryButtonFill: RGBAColor = RGBAColor(red: 0.1, green: 0.2, blue: 0.6)
    /// `Theme.grain` clamped to 0...1: strength of the noise overlay on the window background.
    /// 0 = none. [06 §2] wavy slider; the meaning is inferred.
    public var grain: Double = 0

    // MARK: B64 additions (window translucency, [07 §8.4])

    /// Opacity of the window tint over the blurred desktop: 0.886 light, 0.812 dark ([07 §8.4]
    /// observed); 1 = an opaque window (no desktop shows through).
    public var windowOpacity: Double = 1
    /// Sidebar controls, separators and the selected row as layers over the window, so the desktop
    /// shows through them like through the window ([07 §8.4]). Over the opaque window color each
    /// gives `controlFill`, `separator`, `selectedTabFill` and `scrollEdgeLine`.
    public var windowLayers: WindowLayers = .derived(lightInk: false)

    // MARK: B16 additions (E11 design system, 07)

    /// Ink of the theme-neutral chrome texts (address box, Space name, New Tab row): black, or white
    /// when the window is too dark for black (inferred). Used with `Typography` opacities.
    /// [07 §3, §8] observed: black with alpha, not tinted.
    public var chromeInk: RGBAColor = RGBAColor(hex: 0x000000)
    /// Hairline divider between pinned and Today: window × 0.87 (dark ink), window + 16 % white
    /// (light ink). [07 §4, §8, §8.4] inferred.
    public var separator: RGBAColor = RGBAColor(hex: 0xCCCCCC)
    /// Title on the selected tab row (on `selectedTabFill`): the row text color with dark ink
    /// ([07 §8] observed, the AX title color does not change); with light ink the same white as the
    /// other row titles (B46 PX: ≈ 79 % white on the muted fill, [07 §8.3] observed).
    public var selectedTabText: RGBAColor = RGBAColor(hex: 0x1C1C1E)
    /// Command bar input text: #101214 at 80 % (light), ≈ #F0F5F7 (dark). [07 §3] observed.
    public var commandBarInputText: RGBAColor = RGBAColor(hex: 0x101214, alpha: 0.80)
    /// Command bar subtitles and action text: black 33 % (light), white ≈ 42 % (dark). [07 §3] observed.
    public var commandBarSecondaryText: RGBAColor = RGBAColor(hex: 0x000000, alpha: 0.33)
    /// Panel outline: a 0.5 pt black ≈ 25 % hairline outside (light), a 0.5 pt ≈ #565656 line
    /// inside (dark). [07 §5] observed.
    public var commandBarOutline: RGBAColor = RGBAColor(hex: 0x000000, alpha: 0.25)
    /// Second, outer 0.5 pt line of the dark panel: near black. [07 §5] observed (dark: a light
    /// line inside plus a near-black line outside); black 85 % inferred. nil in light, where the
    /// only line is the outer `commandBarOutline`.
    public var commandBarOuterOutline: RGBAColor? = nil
    /// Unselected arrow box fill: black 4 % (light) [07 §5] observed; white 8 % (dark) inferred.
    /// The selected row's box is white with a theme-colored arrow. [07 §5] observed.
    public var commandBarArrowBoxFill: RGBAColor = RGBAColor(hex: 0x000000, alpha: 0.04)
    /// Unselected command glyph box and shortcut chip: ≈ #F0F0F0 in light ([07 §5] E27 observed);
    /// white 8 % in dark, like the arrow box (inferred). Selected: white (observed).
    public var commandBarGlyphBoxFill: RGBAColor = RGBAColor(hex: 0xF0F0F0)
    /// Sheets (New Folder, Delete Space, Rename): #FAFBFF light, #171C30 dark (they follow the
    /// Space's light / dark, not its color). [07 §6] observed.
    public var dialogBackground: RGBAColor = RGBAColor(hex: 0xFAFBFF)
    /// Ink on sheets: near black (light), white (dark). [07 §3] observed (FIT).
    public var dialogInk: RGBAColor = RGBAColor(hex: 0x000000)
    /// Secondary (Cancel) button fill on sheets: #312E64 dark [07 §6] observed; light unknown
    /// (black 6 %, placeholder).
    public var dialogSecondaryButtonFill: RGBAColor = RGBAColor(hex: 0x000000, alpha: 0.06)
    /// Primary (Create) button fill on sheets. Light: the disabled fill #E8E8FF is observed
    /// [07 §6]; the enabled fill is unknown (a saturated blue of the same hue, placeholder).
    public var dialogPrimaryButtonFill: RGBAColor = RGBAColor(hex: 0x3D47F5)
    public var dialogPrimaryButtonDisabledFill: RGBAColor = RGBAColor(hex: 0xE8E8FF)
    /// Destructive (Delete) button fill. [07 §6] observed (#F43616).
    public var dialogDestructiveFill: RGBAColor = RGBAColor(hex: 0xF43616)

    // MARK: B32 additions (light ink on dark windows)

    /// True when the theme color is dark enough that the chrome uses light (white) ink instead of
    /// the theme's dark tone and black, in light and dark alike. `ThemeDerivation.prefersLightInk`
    /// decides. [07 §8.3] observed on the E12 presets (B46).
    public var usesLightInk: Bool = false
    /// Opacities of the chrome ink per element; they differ between dark and light ink.
    public var inkOpacity: ChromeInkOpacities = .darkInk
    /// Thin full-width lines at the scrolling list's top and bottom edges while rows are scrolled
    /// under them. Round-1 PX observed (white ≈ 5 % on the blue-violet window); dark ink uses the
    /// separator rule (inferred).
    public var scrollEdgeLine: RGBAColor = RGBAColor(hex: 0xCCCCCC)

    public var isDark: Bool { appearance == .dark }

    /// The chrome ink at one of the `inkOpacity` values.
    public func ink(_ opacity: KeyPath<ChromeInkOpacities, Double>) -> RGBAColor {
        var c = chromeInk
        c.alpha *= inkOpacity[keyPath: opacity]
        return c
    }

    /// Tab and folder titles: the row text color at the ink's row-title opacity.
    public var rowTitleText: RGBAColor {
        var c = primaryText
        c.alpha *= inkOpacity.rowTitle
        return c
    }
}

/// Opacity of the chrome ink (black or white, `ThemePalette.chromeInk`) for each chrome element.
/// Dark ink: [07 §2, §3, §4, §7] (text from AX, icons PX). Light ink: measured on the round-1
/// side-by-side screenshot of a saturated blue-violet Space (B32, PX on a JPEG, white over the
/// window or control fill; thin strokes read low, so these are inferred).
public struct ChromeInkOpacities: Hashable, Sendable {
    /// Address box text (domain, placeholder).
    public var addressText: Double
    /// Magnifier in front of the placeholder.
    public var addressIcon: Double
    /// Space name in the header.
    public var spaceName: Double
    /// Space icon in the header.
    public var spaceIcon: Double
    /// "+ New Tab" row (icon and title).
    public var newTabRow: Double
    /// Tab and folder titles (on top of `primaryText`).
    public var rowTitle: Double
    /// Toolbar icons (hide sidebar, back, forward, reload).
    public var toolbarEnabled: Double
    public var toolbarDisabled: Double
    /// Dock Home and "+" buttons.
    public var dockButton: Double
    /// Dock icon of the current Space and of the others.
    public var dockCurrentSpace: Double
    public var dockOtherSpace: Double
    /// Rounded placeholder square of a row without a favicon.
    public var faviconPlaceholder: Double

    public init(addressText: Double, addressIcon: Double, spaceName: Double, spaceIcon: Double, newTabRow: Double,
                rowTitle: Double, toolbarEnabled: Double, toolbarDisabled: Double, dockButton: Double,
                dockCurrentSpace: Double, dockOtherSpace: Double, faviconPlaceholder: Double) {
        self.addressText = addressText
        self.addressIcon = addressIcon
        self.spaceName = spaceName
        self.spaceIcon = spaceIcon
        self.newTabRow = newTabRow
        self.rowTitle = rowTitle
        self.toolbarEnabled = toolbarEnabled
        self.toolbarDisabled = toolbarDisabled
        self.dockButton = dockButton
        self.dockCurrentSpace = dockCurrentSpace
        self.dockOtherSpace = dockOtherSpace
        self.faviconPlaceholder = faviconPlaceholder
    }

    /// Black ink. Text: [07 §3] observed (AX: address 60 %, Space name 45 %, New Tab 30 %, titles
    /// opaque in the row text color). Icons: [07 §2, §4, §7] inferred (75 % / 30 %, other Spaces
    /// 33 %). The magnifier, the Space icon and the favicon placeholder were not measured on a
    /// light window (unknown): the address text value, opaque (the light-ink capture shows the
    /// icon far stronger than the name) and 25 % are used.
    public static let darkInk = ChromeInkOpacities(
        addressText: Typography.addressField.opacity, addressIcon: Typography.addressField.opacity,
        spaceName: Typography.spaceName.opacity, spaceIcon: 1, newTabRow: Typography.newTabRow.opacity,
        rowTitle: 1, toolbarEnabled: 0.75, toolbarDisabled: 0.30, dockButton: 0.75,
        dockCurrentSpace: 1, dockOtherSpace: 0.33, faviconPlaceholder: 0.25
    )

    /// White ink. Round-2 comparison (B33): the same luma-alpha measure on both apps' JPEGs, same
    /// theme; each value is the round-1 value × (reference reading / our reading). Reference
    /// readings: titles 0.81, Space name 0.50, Space icon 0.91, New Tab 0.49, placeholder text 0.34
    /// and magnifier 0.43 (on the control fill), dock Home / "+" 0.33–0.34, current Space 0.49,
    /// other Spaces 0.11, favicon placeholder 0.29. observed readings, inferred values. The four toolbar buttons read ≈ 0.29 and were all
    /// disabled (AX), matching [07 §2]'s 30 % disabled; the enabled value keeps [07 §2]'s 75 %.
    public static let lightInk = ChromeInkOpacities(
        addressText: 0.30, addressIcon: 0.40, spaceName: 0.465, spaceIcon: 0.89, newTabRow: 0.46,
        rowTitle: 0.78, toolbarEnabled: 0.75, toolbarDisabled: 0.30, dockButton: 0.30,
        dockCurrentSpace: 0.46, dockOtherSpace: 0.10, faviconPlaceholder: 0.25
    )
}

public enum ThemeDerivation {
    /// Light window color = mix(theme, `windowMixGray`, `windowMixAmount`) on sRGB components.
    /// [07 §8, §8.2] inferred: refitted over the 36 E12 presets (B38), max 2.8/255 per channel
    /// (0.36 from the three E11 presets missed saturated green by 4.5/255). The same blend in
    /// Display P3 fits worse (≥ 7.4/255), so the light window stays an sRGB blend.
    public static let windowMixGray = RGBAColor(hex: 0xEBEBEB)
    public static let windowMixAmount: Double = 0.37
    /// Dark window color = mixP3(theme, `darkWindowGray`, `darkWindowAmount`): not black, not
    /// desaturated. [07 §8, §8.2] inferred: fitted over the 36 E12 presets (B38), max 3.1/255 per
    /// channel; the former "light window × 0.90" missed saturated green by 8.3/255.
    public static let darkWindowGray: Double = 180.0 / 255
    public static let darkWindowAmount: Double = 0.393
    /// Control fill = window × 0.96. [07 §8, §10] inferred (≤ 1.4/255).
    public static let controlFillScale: Double = 0.96
    /// Separator = window × 0.87. [07 §8] inferred (thin lines on a JPEG: up to ≈ 13/255 off).
    public static let separatorScale: Double = 0.87
    /// Control fill on a light-ink (dark) window: window + 11 % white, i.e. lighter, not darker.
    /// Round-1 PX (B32): #5247FE → #655CFE (≤ 1/255); inferred. The older "≈ 10 % white" of
    /// [04 §theme system] matches this case.
    public static let lightInkControlWhite: Double = 0.11
    /// Separator and scroll-edge lines on a light-ink window: window + 16 % white. [07 §8.4]
    /// inferred: lossless E8 captures of the navy preset (light and dark) fit 0.16 within 0.5/255;
    /// the former 5 % came from a JPEG reading of the 1 px line (B32 round 1) and missed by 13/255.
    public static let lightInkSeparatorWhite: Double = 0.16
    /// Selected row fill with dark ink = mix(window, #F7F7F7, 0.894). [07 §8.4] inferred: refitted
    /// on 16 lossless E8 samples (8 presets × light / dark, max 0.6/255) and the 5 E11 samples
    /// (max 1.3/255); the former mix(window, #F5F5F5, 0.90) missed them by 2.4 / 3.0.
    public static let selectedRowMixColor = RGBAColor(hex: 0xF7F7F7)
    public static let selectedRowMixAmount: Double = 0.894
    /// Selected row fill with light ink = mix(window, #F5F5FF, 0.222): a muted tone close to the
    /// window, not near white (navy dark #838498 → #9E9DB0). [07 §8.3] inferred, fitted to 16
    /// light-ink B46 samples in light and dark, max 1.7/255.
    public static let lightInkSelectedRowMixColor = RGBAColor(hex: 0xF5F5FF)
    public static let lightInkSelectedRowMixAmount: Double = 0.222
    /// Light ink when the theme color's relative luminance is below this. [07 §8.3] observed on the
    /// 36 E12 presets: ≤ 0.143 light ink, ≥ 0.204 dark ink, the same in light and dark; the
    /// midpoint is inferred.
    public static let lightInkThemeLuminance: Double = 0.17
    /// Row text = OKLCH(L, chroma × factor, theme hue). [07 §8.4] inferred: fitted to the AX title
    /// colors of 8 dark-ink presets (E8) and the E11 samples, max 10.6/255 (the former L 0.258 ×
    /// 0.45 missed by 14). Arc's colors keep a near-constant luminance (Y ≈ 0.016) and reach the
    /// sRGB gamut edge for saturated themes; no simple rule matched them better (unknown).
    public static let rowTextLightness: Double = 0.252
    public static let rowTextChromaFactor: Double = 0.60
    /// Command bar selection = OKLCH(L, chroma × factor, theme hue). [07 §8, §8.4]: values observed
    /// (purple, blue, pink light; yellow, blue dark), rule inferred: best fit light L 0.73 × 0.64
    /// (max 9.9/255, was 15.6), dark L 0.485 × 0.62 (max 12.7, was 18.4). Arc's chroma ratio still
    /// varies 0.39–0.89 between presets, so the chroma rule stays unknown.
    public static let commandBarSelectionLightness: Double = 0.73
    public static let commandBarSelectionChromaFactor: Double = 0.64
    public static let darkCommandBarSelectionLightness: Double = 0.485
    public static let darkCommandBarSelectionChromaFactor: Double = 0.62
    /// Theme bubble = OKLCH(L, chroma × factor, theme hue): light L 0.982 × 0.24, dark L 0.318 ×
    /// 0.29. [07 §8.4] inferred: fitted so that this tint at `Metrics.FloatingBubble.tintOpacity`
    /// (0.82) over Arc's neutral backdrop (#EEEEEE / #1E1E1E) matches the bubble body beside the
    /// color board on 9 presets × light / dark (E8 lossless): max 3.4 / 7.1 per channel. The former
    /// L 0.42 × 0.5 dark tint (an E11 JPEG reading near the top) missed the body by 39/255. Arc's
    /// bubble is not flat: this tint is the middle stop of `floatingPanelGradient` (a fixed glow at
    /// the top, neutral gray at the bottom right, [07 §8.4] finding 3).
    public static let floatingPanelLightness: Double = 0.982
    public static let floatingPanelChromaFactor: Double = 0.24
    public static let darkFloatingPanelLightness: Double = 0.318
    public static let darkFloatingPanelChromaFactor: Double = 0.29
    /// Drop target fill (Space-name band), derived from the window color, hue kept.
    /// Light: HSB saturation = max(window saturation × 1.3, 0.475), then the HSB brightness that
    /// puts the OKLCH lightness at min(window L × 0.805, 0.6825), i.e. pale windows get a saturated
    /// band of a fixed depth. Dark: OKLCH L × 0.893, chroma × 1.05.
    /// [06 §15.4] fitted (B118) to the E17 pairs (lavender, pink light, navy dark), the lavender
    /// split block (#838BFE) and the magenta sample: ≤ 2.6/255 per channel (dark ≤ 1/255). The
    /// former OKLCH chroma boost missed lavender and pink by 9–10/255. inferred.
    public static let dropTargetSaturationFactor: Double = 1.3
    public static let dropTargetMinSaturation: Double = 0.475
    public static let dropTargetLightnessFactor: Double = 0.805
    public static let dropTargetMaxLightness: Double = 0.6825
    public static let darkDropTargetLightnessFactor: Double = 0.893
    public static let darkDropTargetChromaFactor: Double = 1.05

    /// The Space-name band color for a window color. [06 §15.4] inferred (see the factors above).
    public static func dropTargetFill(window: RGBAColor, isDark: Bool) -> RGBAColor {
        let lch = OKLCH(window)
        if isDark {
            return OKLCH(lightness: lch.lightness * darkDropTargetLightnessFactor,
                         chroma: lch.chroma * darkDropTargetChromaFactor, hue: lch.hue).rgb(alpha: 1)
        }
        let hsv = HSV(window)
        let saturation = max(hsv.saturation * dropTargetSaturationFactor, dropTargetMinSaturation)
        let target = min(lch.lightness * dropTargetLightnessFactor, dropTargetMaxLightness)
        // OKLCH lightness grows with HSB brightness at a fixed hue and saturation: bisect for it.
        var low = 0.0, high = 1.0
        for _ in 0..<32 {
            let mid = (low + high) / 2
            if OKLCH(HSV(hue: hsv.hue, saturation: saturation, value: mid).rgb(alpha: 1)).lightness < target {
                low = mid
            } else {
                high = mid
            }
        }
        return HSV(hue: hsv.hue, saturation: saturation, value: low).rgb(alpha: 1)
    }

    /// Split preview block: light = the Space-name band color (lavender block #838BFE vs band
    /// #878CFF, ≤ 2.4/255 with the B118 rule); dark = window + 45 % white (navy dark #7D7E98 →
    /// #B7B7C9, ≤ 3/255). [06 §15.4] observed samples; rule inferred.
    public static func splitPreviewFill(window: RGBAColor, isDark: Bool) -> RGBAColor {
        isDark ? overlayWhite(window, amount: Metrics.SidebarDrag.darkSplitPreviewWhite)
            : dropTargetFill(window: window, isDark: false)
    }

    /// Window colors of a Space with no picked color (no theme, or a theme with no color dots): a
    /// diagonal wash from lavender at the top left to pale pink at the bottom right.
    /// [07 §8.5] observed (2026-10-28): a Space created without picking a color stores no window
    /// theme, and its window reads sidebar top-left #DEDEF5, mid #E6E3F1, bottom #EAE5EF, top
    /// frame #E9E4F1, right frame #F2E6E6–#F4E9E9 (light). These stops are those window colors.
    public static let defaultWindowStops: [RGBAColor] = [
        RGBAColor(hex: 0xDEDEF5), RGBAColor(hex: 0xE6E3F1), RGBAColor(hex: 0xEAE5EF),
        RGBAColor(hex: 0xF2E8EC), RGBAColor(hex: 0xF4E9E9),
    ]

    /// Theme color that the default window stops would come from under the light window rule
    /// (`lightWindow`): the first stop solved back through mix(·, #EBEBEB, 0.37). It drives the
    /// derived fills (controls, text, command bar selection) of a Space with no picked color.
    /// [07 §8.5] inferred; the derived control fill lands on the observed address box #D8D8EB.
    public static let defaultBaseColor = RGBAColor(hex: 0xD6D6FB)

    /// Command bar selected row of a Space with no picked color, light. [07 §5] observed (E27,
    /// 2026-10-30): #ADABE2. The picked-color rule above gives #A5A5BC from `defaultBaseColor`
    /// (too gray), so the default theme uses the observed value. Dark keeps the rule (unknown).
    public static let defaultCommandBarSelection = RGBAColor(hex: 0xADABE2)

    /// Content area of a Space with no picked color, light: #F6F6FC at the top left to #FDF8F8 at
    /// the bottom right, center #F9F7F9. [07 §8.5] observed; one flat color is drawn (the center).
    public static let defaultLightContent = RGBAColor(hex: 0xF9F7F9)

    /// Command bar background in light. [07 §5, §10] observed (#F9F9F9).
    public static let commandBarBackground = RGBAColor(hex: 0xF9F9F9)
    /// Command bar background in dark. [07 §5, §10] observed (#181818), for every theme.
    public static let darkCommandBarBackground = RGBAColor(hex: 0x181818)

    /// The gray veil over the whole browser window while a modal card (New Folder, Rename Space,
    /// Delete Space, …) is up. [07 §12] observed (2026-10-27): solving content and sidebar samples
    /// before/after New Folder gives gray #B8B8B8 at ≈ 61 % (it lightens a dark sidebar and darkens
    /// a light page).
    public static let windowModalDim = RGBAColor(hex: 0xB8B8B8, alpha: 0.61)

    /// The Settings window is always light, whatever the system light / dark setting or the Space
    /// theme. A user decision (2026-10-28), not the spec: [07 §6] observed Arc's Settings as a dark
    /// purple (≈ #241F29), which the user rejected ("Settings must not be dark"). Its fill is
    /// white #FFFFFF ([03 §外观] observed), drawn by the Settings palette in the shell.
    public static let settingsAppearance = ResolvedAppearance.light

    /// Source-over blend of `amount` white on top of `color` (sRGB, non-linear).
    public static func overlayWhite(_ color: RGBAColor, amount: Double) -> RGBAColor {
        mix(color, RGBAColor(red: 1, green: 1, blue: 1), amount: amount)
    }

    /// `color` moved `amount` (0...1) of the way to `other`, per sRGB channel (non-linear).
    public static func mix(_ color: RGBAColor, _ other: RGBAColor, amount: Double) -> RGBAColor {
        let a = min(max(amount, 0), 1)
        return RGBAColor(
            red: color.red + (other.red - color.red) * a,
            green: color.green + (other.green - color.green) * a,
            blue: color.blue + (other.blue - color.blue) * a,
            alpha: color.alpha
        )
    }

    /// Multiplies the color channels by `factor` (1 = unchanged, 0 = black).
    public static func shade(_ color: RGBAColor, by factor: Double) -> RGBAColor {
        let f = min(max(factor, 0), 1)
        return RGBAColor(red: color.red * f, green: color.green * f, blue: color.blue * f, alpha: color.alpha)
    }

    /// Strongest lightening or darkening the brightness knob applies at its ends (0 or 1).
    /// inferred: [06 §2] shows the knob ("brightness/contrast", inferred) but not its range.
    public static let maxBrightnessShift: Double = 0.5

    /// Applies `Theme.brightness` to one theme color. 0.5 is neutral and returns the color unchanged;
    /// above it the color is blended toward white, below it toward black, linearly up to
    /// `maxBrightnessShift` at the ends. inferred (the original mapping is unknown).
    public static func applyBrightness(_ color: RGBAColor, brightness: Double) -> RGBAColor {
        let b = min(max(brightness, 0), 1)
        guard b != Theme.defaultBrightness else { return color }
        let amount = abs(b - 0.5) * 2 * maxBrightnessShift
        if b > 0.5 { return overlayWhite(color, amount: amount) }
        return shade(color, by: 1 - amount)
    }

    /// Light window color of one theme color. [07 §8] inferred.
    public static func lightWindow(_ color: RGBAColor) -> RGBAColor {
        mix(color, windowMixGray, amount: windowMixAmount)
    }

    /// Dark window color of one theme color: a Display P3 blend toward gray 180/255. [07 §8.2] inferred.
    public static func darkVariant(_ color: RGBAColor) -> RGBAColor {
        mixInDisplayP3(color, gray: darkWindowGray, amount: darkWindowAmount)
    }

    /// The theme hue at a given OKLCH lightness, with the theme's chroma scaled by `chromaFactor`.
    public static func tone(of theme: RGBAColor, lightness: Double, chromaFactor: Double) -> RGBAColor {
        let lch = OKLCH(theme)
        return OKLCH(lightness: lightness, chroma: lch.chroma * chromaFactor, hue: lch.hue).rgb(alpha: 1)
    }

    /// Whether a theme takes light (white) ink: decided by the theme color, not the window, so a
    /// Space keeps its ink when switched between light and dark. [07 §8.3] observed (B46): the dark
    /// navy preset uses white ink although its dark window (luminance 0.24) has more contrast with
    /// the dark row text, while purple's (0.30) keeps dark ink. The former window-contrast test got
    /// navy and mid-gray wrong. Threshold `lightInkThemeLuminance`, inferred.
    public static func prefersLightInk(theme: RGBAColor) -> Bool {
        luminance(theme) < lightInkThemeLuminance
    }

    /// The selected row fill for a window color and ink. [07 §8.3] inferred.
    public static func selectedRowFill(window: RGBAColor, lightInk: Bool) -> RGBAColor {
        lightInk ? mix(window, lightInkSelectedRowMixColor, amount: lightInkSelectedRowMixAmount)
            : mix(window, selectedRowMixColor, amount: selectedRowMixAmount)
    }

    /// Relative luminance (WCAG formula).
    public static func luminance(_ c: RGBAColor) -> Double {
        func channel(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(c.red) + 0.7152 * channel(c.green) + 0.0722 * channel(c.blue)
    }

    /// WCAG contrast ratio of two colors (1...21).
    public static func contrast(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Light or dark for a theme appearance: automatic follows the system. [04 §dark mode] observed
    /// (light / dark / automatic segments; automatic follows the system appearance).
    public static func resolve(_ appearance: ThemeAppearance, system: ResolvedAppearance) -> ResolvedAppearance {
        switch appearance {
        case .light: return .light
        case .dark: return .dark
        case .automatic: return system
        }
    }

    /// The palette of a theme, resolving its `appearance` against `systemAppearance`.
    /// The default `.light` keeps callers that know no system setting (previews) on the light palette.
    public static func palette(for theme: Theme?, systemAppearance: ResolvedAppearance = .light) -> ThemePalette {
        palette(forStyle: theme?.style, systemAppearance: systemAppearance)
    }

    /// The palette of a theme in an already resolved appearance.
    public static func palette(for theme: Theme?, appearance: ResolvedAppearance) -> ThemePalette {
        palette(forStyle: theme?.style, appearance: appearance)
    }

    /// The palette of a theme style (a theme record, or the theme bubble's draft).
    public static func palette(forStyle style: ThemeStyle?, systemAppearance: ResolvedAppearance = .light) -> ThemePalette {
        palette(forStyle: style, appearance: resolve(style?.appearance ?? .automatic, system: systemAppearance))
    }

    /// Derives the palette for a theme in an already resolved appearance ([07 §8]). With several
    /// color dots only the first drives the fills (how several colors blend is unknown).
    /// `Theme.brightness` lightens or darkens the theme colors first (`applyBrightness`, inferred).
    public static func palette(forStyle style: ThemeStyle?, appearance: ResolvedAppearance) -> ThemePalette {
        let brightness = style?.brightness ?? Theme.defaultBrightness
        let picked = (style?.colors ?? []).map { applyBrightness($0, brightness: brightness) }
        let theme = picked.first ?? defaultBaseColor
        let isDark = appearance == .dark
        let windowOf: (RGBAColor) -> RGBAColor = { isDark ? darkVariant($0) : lightWindow($0) }
        let window = windowOf(theme)
        let white = RGBAColor(hex: 0xFFFFFF), black = RGBAColor(hex: 0x000000)

        // Row text: the theme's dark tone, unless the theme is dark (then white) [07 §8.3].
        let rowText = tone(of: theme, lightness: rowTextLightness, chromaFactor: rowTextChromaFactor)
        let lightInk = prefersLightInk(theme: theme)
        let primaryText = lightInk ? white : rowText
        let chromeInk = lightInk ? white : black
        let inkOpacity: ChromeInkOpacities = lightInk ? .lightInk : .darkInk
        // Dark ink: controls are darker than the window [07 §8]; light ink: lighter (B32 round 1).
        let controlFill = lightInk ? overlayWhite(window, amount: lightInkControlWhite) : shade(window, by: controlFillScale)
        let separator = lightInk ? overlayWhite(window, amount: lightInkSeparatorWhite) : shade(window, by: separatorScale)

        var palette = ThemePalette(
            windowBackground: window,
            controlFill: controlFill,
            selectedTabFill: selectedRowFill(window: window, lightInk: lightInk),
            commandBarBackground: isDark ? darkCommandBarBackground : commandBarBackground,
            commandBarSelection: isDark
                ? tone(of: theme, lightness: darkCommandBarSelectionLightness, chromaFactor: darkCommandBarSelectionChromaFactor)
                : picked.isEmpty
                    ? defaultCommandBarSelection
                    : tone(of: theme, lightness: commandBarSelectionLightness, chromaFactor: commandBarSelectionChromaFactor),
            primaryText: primaryText,
            secondaryText: withAlpha(chromeInk, inkOpacity.spaceName),
            backgroundGradientColors: picked.isEmpty
                ? (isDark ? defaultWindowStops.map(darkVariant) : defaultWindowStops)
                : picked.map(windowOf)
        )
        palette.appearance = appearance
        palette.grain = min(max(style?.grain ?? 0, 0), 1)
        palette.chromeInk = chromeInk
        palette.usesLightInk = lightInk
        palette.inkOpacity = inkOpacity
        palette.separator = separator
        palette.scrollEdgeLine = separator
        // Content area, light and dark alike: the E12 tint of the theme color [07 §8.1].
        palette.webPanelBackground = picked.isEmpty && !isDark
            ? defaultLightContent : contentBackground(theme, appearance: appearance)
        // The see-through window [07 §8.4]: content, command bar and bubbles stay opaque.
        palette.windowOpacity = WindowTranslucency.opacity(for: appearance)
        palette.windowLayers = .derived(lightInk: lightInk)
        palette.selectedTabText = lightInk ? withAlpha(white, inkOpacity.rowTitle) : rowText
        palette.dropTargetFill = dropTargetFill(window: window, isDark: isDark)
        palette.splitPreviewFill = splitPreviewFill(window: window, isDark: isDark)
        palette.floatingPanelBackground = isDark
            ? tone(of: theme, lightness: darkFloatingPanelLightness, chromaFactor: darkFloatingPanelChromaFactor)
            : tone(of: theme, lightness: floatingPanelLightness, chromaFactor: floatingPanelChromaFactor)

        if isDark {
            // [07 §3] observed (PX): input ≈ #F0F5F7, titles white ≈ 85 %, subtitles white ≈ 42 %.
            palette.commandBarInputText = RGBAColor(hex: 0xF0F5F7)
            palette.commandBarText = withAlpha(white, 0.85)
            palette.commandBarSecondaryAlpha = 0.42
            palette.commandBarSecondaryText = withAlpha(white, 0.42)
            palette.commandBarSeparator = RGBAColor(hex: 0x363636)
            palette.commandBarOutline = RGBAColor(hex: 0x565656)
            palette.commandBarOuterOutline = withAlpha(black, 0.85)
            palette.commandBarAccessoryFill = withAlpha(white, 0.08)
            palette.commandBarArrowBoxFill = withAlpha(white, 0.08)
            palette.commandBarGlyphBoxFill = withAlpha(white, 0.08)
            palette.floatingPanelInk = white
            palette.floatingPanelSelection = withAlpha(window, 0.45)
            palette.primaryButtonFill = tone(of: theme, lightness: 0.40, chromaFactor: 0.8)
            // [07 §6] observed: a dark Space shows dark sheets.
            palette.dialogBackground = RGBAColor(hex: 0x171C30)
            palette.dialogInk = white
            palette.dialogSecondaryButtonFill = RGBAColor(hex: 0x312E64)
            palette.dialogPrimaryButtonDisabledFill = RGBAColor(hex: 0x312E64)
        }
        return palette
    }

    private static func withAlpha(_ color: RGBAColor, _ alpha: Double) -> RGBAColor {
        var c = color
        c.alpha = alpha
        return c
    }
}

/// OKLCH components of an sRGB color (Björn Ottosson's OKLab, polar form). Lightness 0...1,
/// chroma ≥ 0, hue in degrees.
struct OKLCH {
    var lightness: Double
    var chroma: Double
    var hue: Double

    init(lightness: Double, chroma: Double, hue: Double) {
        self.lightness = lightness
        self.chroma = chroma
        self.hue = hue
    }

    init(_ c: RGBAColor) {
        func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let r = linear(c.red), g = linear(c.green), b = linear(c.blue)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        var h = atan2(B, A) * 180 / .pi
        if h < 0 { h += 360 }
        self.init(lightness: L, chroma: (A * A + B * B).squareRoot(), hue: h)
    }

    /// The sRGB color, each channel clamped to 0...1.
    func rgb(alpha: Double) -> RGBAColor {
        let a = chroma * cos(hue * .pi / 180), b = chroma * sin(hue * .pi / 180)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return RGBAColor(
            red: encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            green: encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            blue: encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s),
            alpha: alpha
        )
    }
}

/// HSB components of an sRGB color (all 0...1).
struct HSV {
    var hue: Double
    var saturation: Double
    var value: Double

    init(hue: Double, saturation: Double, value: Double) {
        self.hue = hue
        self.saturation = min(max(saturation, 0), 1)
        self.value = min(max(value, 0), 1)
    }

    init(_ c: RGBAColor) {
        let maxC = max(c.red, c.green, c.blue), minC = min(c.red, c.green, c.blue)
        let delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == c.red {
                h = ((c.green - c.blue) / delta).truncatingRemainder(dividingBy: 6)
            } else if maxC == c.green {
                h = (c.blue - c.red) / delta + 2
            } else {
                h = (c.red - c.green) / delta + 4
            }
            h /= 6
            if h < 0 { h += 1 }
        }
        self.init(hue: h, saturation: maxC == 0 ? 0 : delta / maxC, value: maxC)
    }

    func rgb(alpha: Double) -> RGBAColor {
        let h = (hue - hue.rounded(.down)) * 6
        let sector = Int(h) % 6, f = h - Double(Int(h))
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch sector {
        case 0: return RGBAColor(red: value, green: t, blue: p, alpha: alpha)
        case 1: return RGBAColor(red: q, green: value, blue: p, alpha: alpha)
        case 2: return RGBAColor(red: p, green: value, blue: t, alpha: alpha)
        case 3: return RGBAColor(red: p, green: q, blue: value, alpha: alpha)
        case 4: return RGBAColor(red: t, green: p, blue: value, alpha: alpha)
        default: return RGBAColor(red: value, green: p, blue: q, alpha: alpha)
        }
    }
}
