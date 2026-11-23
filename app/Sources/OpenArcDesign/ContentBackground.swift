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
}
