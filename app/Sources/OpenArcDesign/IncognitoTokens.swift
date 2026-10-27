import Foundation
import OpenArcModel

// The incognito window's look (plan B48). docs/arc-spec/06-flows.md §20, 04-visual-metrics.md
// (E19 table), design-tokens.json `Metrics.Incognito`. The window has no Space theme: it uses one
// fixed set of near-black neutral colors without a purple or blue cast, and a fixed blue-violet
// command bar selection. Colors are 2× JPEG averages (±3 levels) in the dark appearance.

/// Fixed colors and geometry of the incognito window.
public enum IncognitoTokens {
    /// Sidebar and window background. [06 §20.1] observed (#0C0F14).
    public static let windowBackground = RGBAColor(hex: 0x0C0F14)
    /// Address field fill. [06 §20.1] observed (≈ #3D4243–#404445).
    public static let addressFieldFill = RGBAColor(hex: 0x3D4243)
    /// "+ New Tab" row fill while selected. [06 §20.1] observed (≈ #46494D).
    public static let newTabRowSelectedFill = RGBAColor(hex: 0x46494D)
    /// Selected tab row fill. [06 §20.1] observed (≈ #4F5257).
    public static let selectedRowFill = RGBAColor(hex: 0x4F5257)
    /// Empty web panel. [06 §20.1] observed (≈ #2A2D31).
    public static let blankPanel = RGBAColor(hex: 0x2A2D31)
    /// Command bar panel: darker than the normal dark bar (#181818 is close, but this one has no
    /// tint at all). [06 §20.3] observed (≈ #1A1A1D).
    public static let commandBarBackground = RGBAColor(hex: 0x1A1A1D)
    /// Command bar selected row, with white text. [06 §20.3] observed (≈ #414ADC–#444DDC).
    public static let commandBarSelection = RGBAColor(hex: 0x444DDC)
    /// Sidebar text: a neutral gray (≈ #878789), which is white at the light-ink Space-name
    /// opacity (50 %) over the window. [06 §20.1] observed color; the white-ink reading is inferred.
    public static let sidebarText = RGBAColor(hex: 0x878789)
    /// White-ink opacity that gives `sidebarText` over `windowBackground` (#868789 at 0.50).
    /// [06 §20.1] observed color; the opacity is derived (inferred).
    public static let sidebarTextWhiteOpacity: Double = 0.50

    /// Light-appearance base color. [06 §20.5] unknown (not captured): our own neutral light gray,
    /// put through the normal light derivation so the window stays untinted.
    public static let lightFallbackBase = RGBAColor(hex: 0xE6E6E6)

    /// Without the favorites block the Space-name row and the list move up: name text y 154 → 94
    /// (window pt; AX y 124 on screen with the window at y 30), header 85–122. [06 §20.1, §20.2]
    /// observed (60 pt).
    public static let sidebarContentShift: Double = 60
}

extension ThemeDerivation {
    /// The incognito window's palette in `appearance`, with an opaque window (B64). Dark: the observed fixed colors of
    /// [06 §20] on top of the dark derivation of the window color (light ink, dark command bar
    /// text); light: [06 §20.5] unknown, a neutral light fallback. Both use the fixed blue-violet
    /// command bar selection (dark observed; light inferred: a fixed incognito accent).
    public static func incognitoPalette(appearance: ResolvedAppearance) -> ThemePalette {
        let t = IncognitoTokens.self
        guard appearance == .dark else {
            // [06 §20.5] unknown: no light capture. A neutral light gray, no theme tint.
            var light = palette(forStyle: ThemeStyle(appearance: .light, colors: [t.lightFallbackBase]), appearance: .light)
            light.commandBarSelection = t.commandBarSelection
            light.commandBarSelectedText = RGBAColor(hex: 0xFFFFFF)
            light.makeWindowOpaque()
            return light
        }
        var p = palette(forStyle: ThemeStyle(appearance: .dark, colors: [t.windowBackground]), appearance: .dark)
        let window = t.windowBackground
        p.windowBackground = window
        p.backgroundGradientColors = [window]
        p.controlFill = t.addressFieldFill
        p.selectedTabFill = t.selectedRowFill
        p.webPanelBackground = t.blankPanel
        p.commandBarBackground = t.commandBarBackground
        p.commandBarSelection = t.commandBarSelection
        p.commandBarSelectedText = RGBAColor(hex: 0xFFFFFF)
        // Lines and drop fills follow the fixed window color (the derivation rules, inferred).
        p.separator = overlayWhite(window, amount: lightInkSeparatorWhite)
        p.scrollEdgeLine = p.separator
        p.dropTargetFill = dropTargetFill(window: window, isDark: true)
        p.splitPreviewFill = splitPreviewFill(window: window, isDark: true)
        p.floatingPanelSelection = RGBAColor(hex: 0xFFFFFF, alpha: 0.12)
        p.grain = 0
        // Sidebar text ≈ #878789 [06 §20.1] observed: the Space name and "+ New Tab" at 50 % white.
        p.inkOpacity.spaceName = t.sidebarTextWhiteOpacity
        p.inkOpacity.newTabRow = t.sidebarTextWhiteOpacity
        p.secondaryText = RGBAColor(hex: 0xFFFFFF, alpha: t.sidebarTextWhiteOpacity)
        // Opaque window (B64): the observed #0C0F14 is darker than an 81 % tint can show over the
        // [07 §8.4] reference desktop, and whether Arc's incognito window is translucent was not
        // measured ([06 §20] unknown). The light fallback stays opaque too.
        p.makeWindowOpaque()
        return p
    }
}
