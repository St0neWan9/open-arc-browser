import Foundation
import OpenArcModel

// The see-through browser window (plan B64). docs/arc-spec/07-design-system.md §8.4 (E8) and
// design-tokens.json `ThemeDerivation.windowTranslucency`: the window background, the sidebar, its
// controls and separators let ≈ 11 % (light) / 19 % (dark) of the blurred desktop through; the web
// content, the command bar and the bubbles are opaque. The opaque palette (`ThemePalette`) equals
// Arc over a ≈ 83 % gray desktop; the window paints Arc's translucent theme layer over the blur
// material (B146, ThemeWindowLayer.swift), and the fills drawn on the window are expressed as
// layers on top of it (E8's layer split).

/// Measured see-through amounts and the plain alpha composite.
public enum WindowTranslucency {
    /// Window tint opacity over the blurred desktop, light. [07 §8.4] observed (black / white
    /// backdrop readings differ by 29/255).
    public static let lightOpacity: Double = 0.886
    /// Window tint opacity over the blurred desktop, dark. [07 §8.4] observed (48/255).
    public static let darkOpacity: Double = 0.812

    /// The tint opacity of a resolved appearance. [07 §8.4] observed.
    public static func opacity(for appearance: ResolvedAppearance) -> Double {
        appearance == .dark ? darkOpacity : lightOpacity
    }

    /// The desktop the opaque palette stands for: ≈ 83 % gray (sRGB ≈ #D4D4D4), where the E12
    /// samples fall between E8's black and white readings. [07 §8.4] inferred
    /// (`windowTranslucency.referenceDesktop`).
    public static let referenceDesktop = RGBAColor(hex: 0xD4D4D4)

    /// `tint` (at its own alpha) over an opaque `backdrop`, per sRGB-encoded channel: E8 found the
    /// composite linear in the encoded values ([07 §8.4] observed: gray backdrops at 0 / 25 / 50 /
    /// 75 / 100 % read 0 / 0.24 / 0.51 / 0.79 / 1 of the black-to-white span). Opaque result.
    public static func composite(_ tint: RGBAColor, over backdrop: RGBAColor) -> RGBAColor {
        let a = min(max(tint.alpha, 0), 1)
        func channel(_ c: Double, _ b: Double) -> Double { a * c + (1 - a) * b }
        return RGBAColor(red: channel(tint.red, backdrop.red), green: channel(tint.green, backdrop.green),
                         blue: channel(tint.blue, backdrop.blue))
    }
}

/// Fills drawn directly on the window background (sidebar controls, separators, the selected row),
/// as layers over it rather than opaque colors, so the desktop shows through them as through the
/// window. E8 solved these layers from its black / white backdrop pairs: dark ink control = window +
/// 4 % black, separator + 13.5 % black, selected row + 89 % #F7F7F7; light ink + 11 % white, + 16 %
/// white, + ≈ 20 % white. [07 §8.4] observed (readings) / inferred (layers). Over an opaque window
/// each layer gives exactly the opaque palette color; with an opaque palette (incognito) the layers
/// are the opaque colors themselves.
public struct WindowLayers: Hashable, Sendable {
    /// Address field, favorites blocks, Library search field, Little Arc capsule.
    public var controlFill: RGBAColor
    /// Divider between pinned and Today.
    public var separator: RGBAColor
    /// Selected tab row.
    public var selectedRowFill: RGBAColor
    /// Lines at the scrolled list's edges.
    public var scrollEdgeLine: RGBAColor

    public init(controlFill: RGBAColor, separator: RGBAColor, selectedRowFill: RGBAColor, scrollEdgeLine: RGBAColor) {
        self.controlFill = controlFill
        self.separator = separator
        self.selectedRowFill = selectedRowFill
        self.scrollEdgeLine = scrollEdgeLine
    }

    /// The layers of the derived palette for an ink: the same rules as the opaque colors in
    /// `ThemeDerivation.palette` (window × 0.96 = 4 % black, …), written as overlays.
    /// [07 §8, §8.3, §8.4] inferred.
    public static func derived(lightInk: Bool) -> WindowLayers {
        let d = ThemeDerivation.self
        let black = RGBAColor(hex: 0x000000), white = RGBAColor(hex: 0xFFFFFF)
        func layer(_ c: RGBAColor, _ alpha: Double) -> RGBAColor {
            RGBAColor(red: c.red, green: c.green, blue: c.blue, alpha: alpha)
        }
        let separator = lightInk ? layer(white, d.lightInkSeparatorWhite) : layer(black, 1 - d.separatorScale)
        return WindowLayers(
            controlFill: lightInk ? layer(white, d.lightInkControlWhite) : layer(black, 1 - d.controlFillScale),
            separator: separator,
            selectedRowFill: lightInk ? layer(d.lightInkSelectedRowMixColor, d.lightInkSelectedRowMixAmount)
                : layer(d.selectedRowMixColor, d.selectedRowMixAmount),
            scrollEdgeLine: separator
        )
    }
}

extension ThemePalette {
    /// The theme layer the see-through window paints over the blur material (B146): Arc's
    /// translucent layer (the theme color over a white / black veil, alpha = its coverage) that
    /// over the reference backdrop shows `windowBackground`. [07 §8.2] inferred (analysis).
    /// Opaque palettes return the window color itself.
    public var windowThemeLayer: RGBAColor {
        guard isWindowTranslucent else { return windowBackground }
        return ThemeDerivation.windowLayer(showing: windowBackground, appearance: appearance)
    }

    /// The gradient stops of a multi-dot theme or the no-color wash, as layers like `windowThemeLayer`.
    public var backgroundGradientLayers: [RGBAColor] {
        guard isWindowTranslucent else { return backgroundGradientColors }
        return backgroundGradientColors.map { ThemeDerivation.windowLayer(showing: $0, appearance: appearance) }
    }

    /// Whether the window lets the desktop through.
    public var isWindowTranslucent: Bool { windowOpacity < 1 }

    /// The window fills as opaque colors (the palette's own), for a surface that is not the
    /// see-through window: the hidden-sidebar peek panel ([06 §14]) keeps its opaque fill.
    public var opaqueWindowLayers: WindowLayers {
        WindowLayers(controlFill: controlFill, separator: separator, selectedRowFill: selectedTabFill,
                     scrollEdgeLine: scrollEdgeLine)
    }

    /// Makes the window opaque: no desktop shows through, and the window layers become the opaque
    /// colors. Used where the observed colors cannot be reached over the reference desktop
    /// (incognito's near-black #0C0F14 is darker than the theme layer can show over the material).
    public mutating func makeWindowOpaque() {
        windowOpacity = 1
        windowLayers = opaqueWindowLayers
    }
}
