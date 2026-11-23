import Foundation
import OpenArcModel

/// Color of the web content area where no page paints: the panel with no tab selected, the panel
/// behind the command bar, split panes and the Library's content area.
///
/// docs/arc-spec/07-design-system.md §8.1 (E12): Arc tints this area from the Space color in both
/// light and dark, never plain white or black. The rule is a per-channel blend toward a gray done on
/// the non-linear Display P3 components of the theme color, fitted over 36 presets × light / dark
/// (72 captures): max error 2.6/255 (light) and 2.9/255 (dark) per channel; the held-out half stays
/// within 2.7 / 2.5. inferred rule, observed samples. The same blend in sRGB misses saturated
/// colors by up to 11/255, which is why the P3 detour matters (`mixInDisplayP3`, P3Mix.swift).
extension ThemeDerivation {
    /// Light content area = mixP3(theme, gray 251/255, 1 − share), with the theme's share
    /// `lightContentThemeShare` × intensity: 0.20 at the preset intensity 0.8 (the E12 fit) and
    /// 0.25 at full intensity (B242: Arc's Spaces at intensity 1 read 0.23–0.25, max 1.9/255 over
    /// eight Spaces at 0.8 and 1). [07 §8.1] inferred.
    public static let lightContentGray: Double = 251.0 / 255
    public static let lightContentThemeShare: Double = 0.25
    /// Dark content area = mixP3(theme, gray 197/255, 0.46). [07 §8.1] inferred.
    public static let darkContentGray: Double = 197.0 / 255
    public static let darkContentAmount: Double = 0.46

    /// Content area color of one theme color in a resolved appearance, at the theme's intensity
    /// (the wavy slider; light only so far, B242). [07 §8.1] inferred.
    public static func contentBackground(_ theme: RGBAColor, appearance: ResolvedAppearance,
                                         intensity: Double = Theme.defaultIntensity) -> RGBAColor {
        switch appearance {
        case .light:
            let share = lightContentThemeShare * min(max(intensity, 0), 1)
            return mixInDisplayP3(theme, gray: lightContentGray, amount: 1 - share)
        case .dark: return mixInDisplayP3(theme, gray: darkContentGray, amount: darkContentAmount)
        }
    }

    /// White over the window in the content area of a picked color: 2/3 in light, 1/10 in dark.
    /// B242: Arc's content panel is a white layer over the sidebar's own background, not a color of
    /// its own. Eight Spaces at intensity 0.8 and 1 (one wide gamut) read 0.665–0.669 in light and
    /// 0.096–0.103 in dark, per channel on the encoded components, and the panel lets the desktop
    /// through at 1/3 of the window's amount, as such a layer would. [07 §8.5d] observed (values) /
    /// inferred (layer).
    public static let lightContentWhite: Double = 2.0 / 3
    public static let darkContentWhite: Double = 0.10

    /// The content area of a picked color: white over the window color. [07 §8.5d] inferred.
    public static func contentOverWindow(_ window: RGBAColor, appearance: ResolvedAppearance) -> RGBAColor {
        let white = RGBAColor(red: 1, green: 1, blue: 1)
        return mix(window, white, amount: appearance == .dark ? darkContentWhite : lightContentWhite)
    }
}
