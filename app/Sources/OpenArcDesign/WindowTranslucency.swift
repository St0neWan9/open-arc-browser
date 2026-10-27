import Foundation
import OpenArcModel

// The see-through browser window (plan B64). docs/arc-spec/07-design-system.md §8.4 (E8) and
// design-tokens.json `ThemeDerivation.windowTranslucency`: the window background, the sidebar, its
// controls and separators let ≈ 11 % (light) / 19 % (dark) of the blurred desktop through; the web
// content, the command bar and the bubbles are opaque. The opaque palette (`ThemePalette`) equals
// Arc over a ≈ 83 % gray desktop, so the tint painted over the blur is solved from it here, and the
// fills drawn on the window are expressed as layers on top of it (E8's layer split).

/// Opacity of the window tint and the solve between composited and painted colors.
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

    /// The tint that, painted at `opacity` over `backdrop`, shows `target`: solves
    /// target = α·c + (1 − α)·backdrop for c and clamps it to the sRGB gamut. The result carries
    /// `opacity` as its alpha. With `opacity` 1 it is `target` itself.
    public static func tint(showing target: RGBAColor, opacity: Double,
                            over backdrop: RGBAColor = referenceDesktop) -> RGBAColor {
        let a = min(max(opacity, 0), 1)
        guard a < 1, a > 0 else { return RGBAColor(red: target.red, green: target.green, blue: target.blue, alpha: a) }
        func channel(_ t: Double, _ b: Double) -> Double { min(max((t - (1 - a) * b) / a, 0), 1) }
        return RGBAColor(red: channel(target.red, backdrop.red), green: channel(target.green, backdrop.green),
                         blue: channel(target.blue, backdrop.blue), alpha: a)
    }

    /// Whether `target` can be shown at `opacity` over `backdrop` without clamping (within half a
    /// level). Colors darker than the backdrop's share, or brighter than α + that share, cannot.
    public static func canShow(_ target: RGBAColor, opacity: Double, over backdrop: RGBAColor = referenceDesktop) -> Bool {
        let shown = composite(tint(showing: target, opacity: opacity, over: backdrop), over: backdrop)
        return max(abs(shown.red - target.red), abs(shown.green - target.green), abs(shown.blue - target.blue)) <= 0.5 / 255
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
    /// The color painted over the blur: `windowBackground` solved for `windowOpacity` over the
    /// reference desktop. [07 §8.4] (alpha = `windowOpacity`). Opaque palettes return the window.
    public var windowTint: RGBAColor {
        WindowTranslucency.tint(showing: windowBackground, opacity: windowOpacity)
    }

    /// The gradient stops of a multi-dot theme, solved like `windowTint`.
    public var backgroundGradientTints: [RGBAColor] {
        backgroundGradientColors.map { WindowTranslucency.tint(showing: $0, opacity: windowOpacity) }
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
    /// (incognito's near-black #0C0F14 needs more than the 81 % tint gives).
    public mutating func makeWindowOpaque() {
        windowOpacity = 1
        windowLayers = opaqueWindowLayers
    }
}
