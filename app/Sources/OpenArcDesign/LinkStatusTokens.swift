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
    /// Text size, medium weight. [06 §44] observed (≈ 13).
    public static let fontSize: Double = 13
    /// Border width. [06 §44] observed (≈ 0.5).
    public static let borderWidth: Double = 0.5
    /// Soft shadow around the pill. [06 §44] observed spread (≈ 5); opacity inferred.
    public static let shadowRadius: Double = 4
    public static let shadowOpacity: Double = 0.08

    /// Fill, border and text of the pill for a Space.
    /// Light: #F7F3ED fill, #EBE6E3 border, #615B55 text over a #FEEFE4 window ([06 §44]
    /// observed); the fill as a gray with 40 % of the window color is inferred from that one
    /// sample. Dark: unknown; ours is a dark gray with a light text, inferred.
    public static func colors(windowBackground: RGBAColor, isDark: Bool) -> (fill: RGBAColor, border: RGBAColor, text: RGBAColor) {
        if isDark {
            let fill = ThemeDerivation.mix(RGBAColor(hex: 0x2A2A2A), windowBackground, amount: 0.3)
            return (RGBAColor(red: fill.red, green: fill.green, blue: fill.blue),
                    RGBAColor(hex: 0xFFFFFF, alpha: 0.12), RGBAColor(hex: 0xD9D5D0))
        }
        let fill = ThemeDerivation.mix(RGBAColor(hex: 0xF2F2F2), windowBackground, amount: 0.4)
        return (RGBAColor(red: fill.red, green: fill.green, blue: fill.blue),
                RGBAColor(hex: 0x000000, alpha: 0.07), RGBAColor(hex: 0x615B55))
    }
}

extension Motion {
    /// The hovered link's pill fading in (B218): ≈ 0.15 s; it goes away in 1–2 frames. [06 §44]
    /// observed duration; the ease-out curve is inferred.
    public static let linkStatusFadeIn = MotionToken(.easeOut(duration: 0.15), .inferred)
}
