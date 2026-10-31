import Foundation
import OpenArcModel

// The window / sidebar color as a layer stack (plan B146). Read from Arc's binary (its window
// theme renderer and the shader library that ships with it), restated in our own words and names;
// docs/arc-spec/07-design-system.md §8.2 (to be extended with these values, labelled
// inferred (analysis)).
//
// What Arc draws behind the sidebar, bottom to top:
// 1. a behind-window blur (an AppKit visual-effect view, emphasized, following the window's
//    active state; its material follows the theme's stored translucency style);
// 2. a GPU layer that paints the theme: the picked color (OKLab is the blend space when there are
//    several stops; a single color passes through unchanged) at coverage `themeLayerAlpha`, laid
//    over a veil (white in a light window, black in a dark one) and written out with the combined
//    coverage, so the layer itself is see-through. The layer is tagged extended sRGB;
// 3. the window server composites that layer over the blur. Doing that on Display P3 components
//    (the display's space) fits the samples; on sRGB components the dark ones miss by up to
//    8/255 (inferred).
//
// The opaque palette is what this stack shows over the reference desktop (the E12 / E8 captures):
// the blur under the layer then reads as a flat gray, fitted per appearance below. The layer math
// (coverage, veil) comes from the binary; the strength Arc stores with preset picks (0.8) was read
// from Arc's own sidebar data (read-only); the backdrop grays and the dark strength are fitted to
// the observed samples.

extension ThemeDerivation {
    /// Strength of the theme layer for a picked preset color (0...1). Arc stores 0.8 with preset
    /// picks (its sidebar data, read-only; full-strength 1.0 also occurs). [07 §8.2] observed (data) /
    /// inferred (analysis: what the value drives). The light E12 / E8 samples fit 0.79–0.80.
    public static let presetThemeStrength: Double = 0.8
    /// Strength that fits the dark samples: 0.74 (E12 max 3.1/255, E8 max 2.5/255; 0.8 misses by
    /// 5.2). Why dark reads weaker than the stored 0.8 is unknown (the blur under a dark window is
    /// the likeliest cause). [07 §8.2] inferred.
    public static let darkThemeStrength: Double = 0.74

    /// Theme layer coverage = `themeLayerAlphaSlope` × strength + `themeLayerAlphaBase`.
    /// [07 §8.2] inferred (analysis).
    public static let themeLayerAlphaSlope: Double = 0.55
    public static let themeLayerAlphaBase: Double = 0.2
    /// The veil under the theme color has the layer coverage, capped at this value. [07 §8.2]
    /// inferred (analysis).
    public static let veilAlphaCap: Double = 0.5
    /// A dark window's (black) veil is this share of the light one's. [07 §8.2] inferred (analysis).
    public static let darkVeilShare: Double = 0.35

    /// The gray the blur under the theme layer shows over the reference desktop, in sRGB / P3
    /// encoded units (a gray is the same in both). Fitted to the 36 E12 presets with the layer
    /// math above: light 219/255 (max 2.7/255), dark 218.2/255 (max 3.1/255). Both land at the same
    /// gray, as expected of one blur under both appearances. [07 §8.2] inferred.
    public static let lightWindowBackdropGray: Double = 219.0 / 255
    public static let darkWindowBackdropGray: Double = 218.2 / 255

    /// Coverage of the theme color for a strength (clamped to 0...1). [07 §8.2] inferred (analysis).
    public static func themeLayerAlpha(strength: Double) -> Double {
        themeLayerAlphaSlope * min(max(strength, 0), 1) + themeLayerAlphaBase
    }

    /// The veil under the theme color: white at min(coverage, 0.5) in light, black at 35 % of that
    /// in dark. [07 §8.2] inferred (analysis).
    public static func windowVeil(strength: Double, appearance: ResolvedAppearance) -> RGBAColor {
        let alpha = min(themeLayerAlpha(strength: strength), veilAlphaCap)
        return appearance == .dark ? RGBAColor(red: 0, green: 0, blue: 0, alpha: alpha * darkVeilShare)
            : RGBAColor(red: 1, green: 1, blue: 1, alpha: alpha)
    }

    /// The theme layer as painted: the theme color at `themeLayerAlpha` over the veil, source-over on
    /// sRGB-encoded components. Returns the straight (not premultiplied) color with the combined
    /// coverage as alpha; it is translucent. [07 §8.2] inferred (analysis).
    public static func themeLayer(_ color: RGBAColor, appearance: ResolvedAppearance, strength: Double) -> RGBAColor {
        let a = themeLayerAlpha(strength: strength)
        let veil = windowVeil(strength: strength, appearance: appearance)
        let below = veil.alpha * (1 - a)
        let coverage = a + below
        func channel(_ c: Double, _ v: Double) -> Double { (min(max(c, 0), 1) * a + v * below) / coverage }
        return RGBAColor(red: channel(color.red, veil.red), green: channel(color.green, veil.green),
                         blue: channel(color.blue, veil.blue), alpha: coverage)
    }

    /// The opaque window color: the theme layer composited over a gray backdrop on Display P3
    /// encoded components (the display's space), returned as sRGB. [07 §8.2] inferred.
    public static func windowColor(_ color: RGBAColor, appearance: ResolvedAppearance, strength: Double,
                                   backdropGray: Double) -> RGBAColor {
        let layer = themeLayer(color, appearance: appearance, strength: strength)
        return compositeInDisplayP3(layer, over: RGBAColor(red: backdropGray, green: backdropGray, blue: backdropGray))
    }

    /// A translucent layer composited over an opaque backdrop on Display P3 encoded components (the
    /// window server's space, inferred), returned as opaque sRGB.
    public static func compositeInDisplayP3(_ layer: RGBAColor, over backdrop: RGBAColor) -> RGBAColor {
        let a = min(max(layer.alpha, 0), 1)
        let l = DisplayP3.fromSRGB(layer), b = DisplayP3.fromSRGB(backdrop)
        return DisplayP3.toSRGB(zip(l, b).map { a * $0 + (1 - a) * $1 })
    }
}

// MARK: The backdrop under the theme layer (B146, shell composite)

/// The visual-effect material under the theme layer. Arc maps the theme's stored translucency
/// style straight to an AppKit material: light → the fixed light material, dark → the fixed dark
/// one, automatic → the window-background material; without a style it picks light or dark from
/// the window's appearance. Every preset Space in Arc's data stores "light", in light and dark
/// windows alike. [07 §8.2] inferred (analysis + Arc's sidebar data, read-only). Raw values are
/// AppKit's public `NSVisualEffectView.Material` raw values; the shell maps them.
public enum WindowBackdropMaterial: Int, Hashable, Sendable {
    case light = 1
    case dark = 2
    case windowBackground = 12
}

extension ThemeDerivation {
    /// The material our themes use: the fixed light one, as every stored Arc theme does. The view is
    /// behind-window, emphasized and follows the window's active state. [07 §8.2] inferred (analysis).
    public static let windowBackdropMaterial = WindowBackdropMaterial.light

    /// Strength of the theme layer in an appearance (preset 0.8 light, fitted 0.74 dark).
    public static func windowLayerStrength(_ appearance: ResolvedAppearance) -> Double {
        appearance == .dark ? darkThemeStrength : presetThemeStrength
    }

    /// Combined coverage of the theme layer (theme color plus veil): 0.82 light, 0.676 dark.
    public static func windowLayerCoverage(_ appearance: ResolvedAppearance) -> Double {
        let strength = windowLayerStrength(appearance)
        let a = themeLayerAlpha(strength: strength)
        return a + windowVeil(strength: strength, appearance: appearance).alpha * (1 - a)
    }

    /// The fitted backdrop gray of an appearance (what the blur shows over the reference desktop).
    public static func windowBackdropGray(_ appearance: ResolvedAppearance) -> Double {
        appearance == .dark ? darkWindowBackdropGray : lightWindowBackdropGray
    }

    /// The theme layer the window paints over the material for one theme color.
    public static func windowLayer(_ color: RGBAColor, appearance: ResolvedAppearance) -> RGBAColor {
        themeLayer(color, appearance: appearance, strength: windowLayerStrength(appearance))
    }

    /// The layer with the appearance's coverage that shows `target` over the reference backdrop:
    /// the inverse of `windowColor`, for window colors that do not come from a picked color (the
    /// no-color wash's observed stops, incognito's fixed window). Clamped to the sRGB gamut.
    public static func windowLayer(showing target: RGBAColor, appearance: ResolvedAppearance) -> RGBAColor {
        let coverage = windowLayerCoverage(appearance)
        let gray = windowBackdropGray(appearance)
        var out = DisplayP3.toSRGB(DisplayP3.fromSRGB(target).map { ($0 - (1 - coverage) * gray) / coverage })
        out.alpha = coverage
        return out
    }

    /// Share of the desktop that comes through the material, solved from E8's black / white backdrop
    /// readings (29 / 48 levels apart) and the layer coverage: light 0.63, dark 0.58, about equal as
    /// one material under both appearances should be. [07 §8.4] observed readings, inferred split.
    public static func desktopShareThroughBackdrop(_ appearance: ResolvedAppearance) -> Double {
        (appearance == .dark ? 48.0 : 29.0) / 255 / (1 - windowLayerCoverage(appearance))
    }

    /// What the material shows over `desktop`: the desktop's share plus the material's own part,
    /// which puts the reference desktop on the fitted backdrop gray. Linear in the encoded values
    /// ([07 §8.4] observed for gray backdrops). inferred model, for tests and previews.
    public static func backdropShown(over desktop: RGBAColor, appearance: ResolvedAppearance) -> RGBAColor {
        let share = desktopShareThroughBackdrop(appearance)
        let own = windowBackdropGray(appearance) - share * WindowTranslucency.referenceDesktop.red
        func channel(_ d: Double) -> Double { min(max(own + share * d, 0), 1) }
        return RGBAColor(red: channel(desktop.red), green: channel(desktop.green), blue: channel(desktop.blue))
    }
}

extension ThemePalette {
    /// The window color over a desktop: the theme layer over what the material shows there.
    /// Over `WindowTranslucency.referenceDesktop` it is `windowBackground`; an opaque palette shows
    /// its window color everywhere. [07 §8.2, §8.4] inferred.
    public func windowShown(over desktop: RGBAColor) -> RGBAColor {
        guard isWindowTranslucent else { return windowBackground }
        return ThemeDerivation.compositeInDisplayP3(windowThemeLayer,
                                                    over: ThemeDerivation.backdropShown(over: desktop, appearance: appearance))
    }
}
