import Foundation
import OpenArcModel

// Peek: the floating preview of a link over the dimmed page (plan B49).
//
// Spec: docs/arc-spec/06-flows.md §22, 04-visual-metrics.md (Peek rows), design-tokens.json
// `Metrics.Peek` and `motion.peekOpen`. Measured in a 1920 × 985 pt window whose web panel was
// x 276–1910, y 10–975 (sidebar shown), dark appearance. Short form: [06 §22.2].

public enum PeekMetrics {
    /// The measured panel, window coordinates: x 440–1755, y 12–972. [06 §22.2] observed.
    public static let referencePanel = (x: 440.0, y: 12.0, width: 1315.0, height: 961.0)
    /// The web panel the reference was measured over (1920 × 985 window). [07 §1] observed.
    public static let referenceWebPanel = (x: 276.0, y: 10.0, width: 1634.0, height: 965.0)

    /// Panel width as a share of the web panel's width (1315 / 1634). [06 §22.2] observed values;
    /// scaling with the web panel at other sizes is inferred ([06 §22.5] lists it as not captured).
    public static let widthFraction = referencePanel.width / referenceWebPanel.width
    /// The panel's center sits this far right of the web panel's center (1097.5 vs 1093). [06 §22.2] observed.
    public static let centerOffsetX = (referencePanel.x + referencePanel.width / 2) - (referenceWebPanel.x + referenceWebPanel.width / 2)
    /// Gap from the window's top edge to the panel (12). [06 §22.2] observed.
    public static let windowInsetTop = referencePanel.y
    /// Gap from the panel to the window's bottom edge: 985 − (12 + 961) = 12. [06 §22.2] observed
    /// height 961 (the same section's "y 12–972" and "bottom 13" are 1 pt off it; AX height kept).
    public static let windowInsetBottom = 985.0 - (referencePanel.y + referencePanel.height)

    /// The page behind shrinks by this much on every side. [06 §22.2] observed ≈ 9–10 pt
    /// (design-tokens `Peek.backgroundInset` 9.5).
    public static let backgroundInset = 9.5

    /// Round buttons right of the panel: 34 × 33. [06 §22.2] observed.
    public static let buttonSize = (width: 34.0, height: 33.0)
    /// Gap between the panel's right edge and the buttons (1768 − 1755). [06 §22.2] observed.
    public static let buttonGap = 13.0
    /// First button's top edge below the panel's top edge (19 − 12). [06 §22.2] observed.
    public static let firstButtonOffsetY = 7.0
    /// Vertical pitch of the buttons (y 19 / 63 / 106). [06 §22.2] observed 44.
    public static let buttonPitch = 44.0

    /// Panel corner radius. unknown ([06 §22.2] records "rounded"); inferred 10.
    public static let cornerRadius = 10.0
    /// Soft shadow around the panel, darkening ≈ 15 px outside its edges. [06 §22.2] observed
    /// extent; blur radius and opacity inferred.
    public static let shadowRadius = 10.0
    public static let shadowOpacity = 0.35

    /// Smallest room kept right of the buttons when the window is narrow. inferred.
    public static let minimumTrailingMargin = 10.0
}

public enum PeekColors {
    /// The dimming layer over the page behind. [06 §22.2] observed: a white page becomes ≈ #76727E
    /// in a dark Space; this color at `dimOpacity` over white gives (118, 115, 126). The split into
    /// color and opacity is inferred; light appearance unknown, uses the same.
    public static let dim = RGBAColor(hex: 0x060014)
    public static let dimOpacity = 0.55
    /// Round button fill: "dark circle". [06 §22.2] observed; exact color unknown (inferred).
    public static let buttonFill = RGBAColor(hex: 0x1C1C1E, alpha: 0.85)
    /// Button icon: "light icon". [06 §22.2] observed; exact color unknown (inferred).
    public static let buttonInk = RGBAColor(hex: 0xFFFFFF, alpha: 0.92)
    /// Corner badge on the source favorite while its Peek is open: a small dark rounded square.
    /// [06 §22.2] observed; color inferred.
    public static let sourceBadge = RGBAColor(hex: 0x1C1C1E, alpha: 0.9)
}

public enum PeekBadgeMetrics {
    /// ≈ 10 × 10, over the favorite's top-right corner. [06 §22.2] observed.
    public static let size = 10.0
    /// Corner radius of the badge. inferred.
    public static let cornerRadius = 3.0
    /// How far the badge hangs over the block's corner. inferred.
    public static let overhang = 3.0
}

extension Motion {
    /// Peek opening: ≈ 0.3 s; the button column slides in from 133 pt to the left. [06 §22.4]
    /// observed timing and start offset; the curve is unknown (ease-out is a placeholder), so the
    /// token is labelled unknown. Closing was not captured (unknown): it is instant.
    public static let peekOpen = MotionToken(.easeOut(duration: 0.3), .unknown)
    /// Start offset of the button column (x 1635.5 → 1768.5). [06 §22.4] observed.
    public static let peekButtonsStartOffsetX: Double = -133
}
