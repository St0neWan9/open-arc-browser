import Foundation
import OpenArcModel

// Two full-width sidebar controls measured in F4 (E27, 2026-10-29): the "Create Space" button of
// the creation view (B112) and the update-ready pill above the dock (B111).
// docs/arc-spec/07-design-system.md §8.6.

/// The primary "Create Space" button of the creation view. [07 §8.6] observed (E27).
public enum CreateSpaceButtonTokens {
    /// Height: ≈ 39 pt (display y 888–927). [07 §8.6] observed.
    public static let height: Double = 39
    /// Corner radius: ≈ 8. [07 §8.6] observed.
    public static let cornerRadius: Double = 8
    /// The button spans the sidebar content width, x 8–268. [07 §8.6] observed.
    public static var horizontalInset: Double { Metrics.Sidebar.contentInset }
    public static var width: Double { Metrics.Sidebar.width - 2 * horizontalInset }

    /// Fill on a Space with no picked color, name entered (enabled): a saturated blue, white text.
    /// [07 §8.6] observed (≈ #2848FB).
    public static let defaultEnabledFill = RGBAColor(hex: 0x2848FB)
    /// Fill on a Space with no picked color, empty name (disabled): a pale violet. [07 §8.6]
    /// observed (≈ #A6A8F5).
    public static let defaultDisabledFill = RGBAColor(hex: 0xA6A8F5)

    /// The disabled fill follows the theme: OKLCH lightness 0.298 + 0.51 × the window's, chroma
    /// min(0.113, 3.5 × the window's), the window's hue. [07 §8.6] observed samples (no color
    /// #A6A8F5; orange preset p1-5 #D88E64); the rule is inferred, fitted to both: ≤ 5.2/255 per
    /// channel (no color 5.0, orange 5.2). The no-color case draws the observed value instead.
    public static let disabledLightnessOffset: Double = 0.298
    public static let disabledLightnessScale: Double = 0.51
    public static let disabledChromaScale: Double = 3.5
    public static let disabledMaxChroma: Double = 0.113

    /// Disabled fill for a window color (`ThemePalette.windowBackground`). Rule inferred, see above.
    public static func disabledFill(window: RGBAColor) -> RGBAColor {
        let lch = OKLCH(window)
        return OKLCH(lightness: disabledLightnessOffset + disabledLightnessScale * lch.lightness,
                     chroma: min(disabledMaxChroma, disabledChromaScale * lch.chroma),
                     hue: lch.hue).rgb(alpha: 1)
    }

    /// The button fill for a draft theme and state.
    /// - No picked color: the observed blue / pale violet ([07 §8.6] observed).
    /// - A picked color, disabled: `disabledFill` of the theme's window ([07 §8.6] inferred rule).
    /// - A picked color, enabled: [07 §8.6] unknown; our derived `primaryButtonFill` of the theme.
    public static func fill(for style: ThemeStyle, isEnabled: Bool, systemAppearance: ResolvedAppearance) -> RGBAColor {
        guard !style.colors.isEmpty else { return isEnabled ? defaultEnabledFill : defaultDisabledFill }
        let palette = ThemeDerivation.palette(forStyle: style, systemAppearance: systemAppearance)
        return isEnabled ? palette.primaryButtonFill : disabledFill(window: palette.windowBackground)
    }
}

/// The pill shown right above the dock when an update has been downloaded and is ready to install.
/// [07 §8.6] observed (E27): full sidebar content width, about 22 pt tall, fully rounded, the
/// sidebar color lightened, white medium text centered, no border or shadow.
public enum UpdatePillTokens {
    /// Height: ≈ 22 pt (display y 942–965). [07 §8.6] observed.
    public static let height: Double = 22
    /// Spans the sidebar content width, x 8–268. [07 §8.6] observed.
    public static var horizontalInset: Double { Metrics.Sidebar.contentInset }
    /// Gap between the pill's bottom and the dock's top edge. [07 §8.6] inferred: the pill ends at
    /// display y 965 of a 1026 tall capture; with the window's bottom at the capture's bottom the
    /// 50 pt dock starts at 976.
    public static let bottomGap: Double = 11
    /// Gap between the list's bottom and the pill's top. [07 §8.6] unknown (our value).
    public static let topGap: Double = 6
    /// Height the list gives up while the pill shows.
    public static var bandHeight: Double { topGap + height + bottomGap }

    /// Text: white, ≈ 12 pt medium. [07 §8.6] observed.
    public static let titleStyle = TextStyle(size: 12, weight: .medium)
    public static let titleColor = RGBAColor(hex: 0xFFFFFF)

    /// The fill is the sidebar color with this much white over it. [07 §8.6] observed sample
    /// (sage sidebar #6C9174 → pill #7D9C84); the rule is inferred: 11 % white gives #7C9D83,
    /// ≤ 1.1/255 per channel. Drawn as a white layer at this opacity, so a see-through window
    /// lightens whatever shows through the sidebar the same way.
    public static let whiteOverlay: Double = 0.11

    /// The opaque pill color over an opaque sidebar color.
    public static func fill(over sidebar: RGBAColor) -> RGBAColor {
        ThemeDerivation.overlayWhite(sidebar, amount: whiteOverlay)
    }
}
