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
    /// Light content area = mixP3(theme, gray 251/255, 0.80). [07 §8.1] inferred.
    public static let lightContentGray: Double = 251.0 / 255
    public static let lightContentAmount: Double = 0.80
    /// Dark content area = mixP3(theme, gray 197/255, 0.46). [07 §8.1] inferred.
    public static let darkContentGray: Double = 197.0 / 255
    public static let darkContentAmount: Double = 0.46

    /// Content area color of one theme color in a resolved appearance. [07 §8.1] inferred.
    public static func contentBackground(_ theme: RGBAColor, appearance: ResolvedAppearance) -> RGBAColor {
        switch appearance {
        case .light: return mixInDisplayP3(theme, gray: lightContentGray, amount: lightContentAmount)
        case .dark: return mixInDisplayP3(theme, gray: darkContentGray, amount: darkContentAmount)
        }
    }
}
