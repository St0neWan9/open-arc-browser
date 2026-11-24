import Foundation
import OpenArcModel

// The link address shown at the web panel's bottom left while the pointer rests on a link
// (plan B218). Spec: docs/arc-spec/06-flows.md §44, measured in a 1920 × 985 window on a light
// peach Space. Short form: [06 §44].

public enum LinkStatusTokens {
    /// Gap between the pill and the panel's left and bottom edges. [06 §44] observed.
    public static let inset: Double = 10
    /// Pill height; the corners are fully round. [06 §44] observed (≈ 24).
    public static let height: Double = 24
    /// Text inset left and right inside the pill. [06 §44] observed (≈ 9).
    public static let horizontalPadding: Double = 9
    /// Widest pill; longer addresses are cut in the middle. [06 §44] observed in a ≈ 1550 pt
    /// panel; a fixed width at other panel sizes is inferred.
    public static let maxWidth: Double = 400
    /// After the pill has shown one link this long, it widens at once to the whole address (up to
    /// the panel's width less the insets). [06 §44] observed (1.0 s, one frame, no animation);
    /// the panel-wide limit is inferred.
    public static let expandDelay: Double = 1.0
    /// Text size, medium weight. [06 §44] observed (≈ 13).
    public static let fontSize: Double = 13
    /// Border width. [06 §44] observed (≈ 0.5).
    public static let borderWidth: Double = 0.5
    /// Soft shadow around the pill: ≈ 14/255 darker right at its edge, gone ≈ 11 pt out. [06 §44]
    /// observed (B251, user's capture, 2026-11-24); as a SwiftUI radius (≈ 2σ) inferred.
    public static let shadowRadius: Double = 9
    public static let shadowOpacity: Double = 0.11

    /// Fill, border and text of the pill for a Space.
    /// Light (B251, user's capture of Arc on a Display P3 screen, violet Space, white page,
    /// 2026-11-24; [06 §44] observed): fill = white with 13 % of the window color (P3 232 / 230 / 254
    /// over a 79 / 64 / 248 window: 0.131 / 0.131 / 0.14 per channel), border = the fill 10 %
    /// darker, text = the fill 70 % darker; all on Display P3 components. The rule from those
    /// readings is inferred. The earlier one-sample rule (gray with 40 % of the window) read gray
    /// and heavy. Dark: unknown; ours is a dark gray with a light text, inferred.
    /// Light pill: white over the window color, then the border and the text as black over the
    /// fill. [06 §44] observed (B251, see `colors`).
    public static let lightFillWhite = 0.87
    public static let lightBorderBlack = 0.10
    public static let lightTextBlack = 0.70

    public static func colors(windowBackground: RGBAColor, isDark: Bool) -> (fill: RGBAColor, border: RGBAColor, text: RGBAColor) {
        if isDark {
            let fill = ThemeDerivation.mix(RGBAColor(hex: 0x2A2A2A), windowBackground, amount: 0.3)
            return (RGBAColor(red: fill.red, green: fill.green, blue: fill.blue),
                    RGBAColor(hex: 0xFFFFFF, alpha: 0.12), RGBAColor(hex: 0xD9D5D0))
        }
        var window = windowBackground
        window.alpha = 1
        let fill = ThemeDerivation.mixInDisplayP3(window, gray: 1, amount: lightFillWhite)
        return (fill, ThemeDerivation.mixInDisplayP3(fill, gray: 0, amount: lightBorderBlack),
                ThemeDerivation.mixInDisplayP3(fill, gray: 0, amount: lightTextBlack))
    }
}

extension Motion {
    /// The hovered link's pill fading in (B218): ≈ 0.15 s; it goes away in 1–2 frames. [06 §44]
    /// observed duration; the ease-out curve is inferred.
    public static let linkStatusFadeIn = MotionToken(.easeOut(duration: 0.15), .inferred)
}
