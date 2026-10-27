import Foundation
import OpenArcModel

// Background gradient of the theme bubble (and the bubbles that share its chrome, such as the Site
// Control Center). [07 §8.4] finding 3, observed (E8, lossless): the bubble is not a flat tint. A
// pink-violet glow that does not depend on the theme sits about 10 pt below the top edge (light ≈
// #FFE8FF, dark ≈ #4B2046; within 3/255 over 9 presets), it fades into the theme tint (sampled on
// the strip left of the color board, at the board's middle) and ends in a neutral gray at the
// bottom-right corner (light #F7F6F7, dark #1E1E1E), also theme independent.
//
// The stop colors here are what the bubble shows. Our bubble paints its fill at
// `Metrics.FloatingBubble.tintOpacity` over a blur, so `ThemeDerivation.floatingPanelGradient`
// converts each observed color to the fill that lands on it over the neutral backdrop the tint was
// fitted against (#EEEEEE / #1E1E1E, [07 §8.4]). The axis geometry (top center → bottom-right
// corner) and the straight interpolation between the three stops are inferred: E8 sampled three
// points, not the whole field.

/// A point in a rectangle in unit coordinates: (0, 0) top left, (1, 1) bottom right.
public struct UnitPoint2D: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A linear gradient over a floating panel, independent of the UI framework.
public struct FloatingPanelGradient: Hashable, Sendable {
    public struct Stop: Hashable, Sendable {
        public var color: RGBAColor
        /// Position along the axis, 0 = `start`, 1 = `end`.
        public var location: Double
        public init(color: RGBAColor, location: Double) {
            self.color = color
            self.location = location
        }
    }

    public var stops: [Stop]
    public var start: UnitPoint2D
    public var end: UnitPoint2D

    public init(stops: [Stop], start: UnitPoint2D, end: UnitPoint2D) {
        self.stops = stops
        self.start = start
        self.end = end
    }

    /// A flat fill (one color everywhere).
    public static func flat(_ color: RGBAColor) -> FloatingPanelGradient {
        FloatingPanelGradient(stops: [Stop(color: color, location: 0), Stop(color: color, location: 1)],
                              start: UnitPoint2D(x: 0.5, y: 0), end: UnitPoint2D(x: 0.5, y: 1))
    }

    /// The axis: from the middle of the top edge to the bottom-right corner, where the gray was
    /// read. [07 §8.4] observed "from the top edge to the bottom right"; the exact points inferred.
    public static let axisStart = UnitPoint2D(x: 0.5, y: 0)
    public static let axisEnd = UnitPoint2D(x: 1, y: 1)

    /// Where E8 read the glow and the theme tint on the 356 × 508 theme bubble ([07 §6] size), in
    /// points from the top left: the glow ≈ 10 pt below the top edge (on the axis start's column),
    /// the tint on the 8 pt strip left of the color board at the board's middle (board 340 × 340
    /// from y 52, our layout of [07 §6]). observed positions, approximate.
    public static let referenceSize = (width: 356.0, height: 508.0)
    public static let glowSamplePoint = (x: 178.0, y: 10.0)
    public static let tintSamplePoint = (x: 4.0, y: 222.0)

    /// Location of a point (in points, top-left origin) projected on the axis of a `width` ×
    /// `height` rectangle. The gradient keeps these fractions on other bubble sizes (inferred).
    public static func axisLocation(x: Double, y: Double, width: Double, height: Double) -> Double {
        let sx = axisStart.x * width, sy = axisStart.y * height
        let dx = axisEnd.x * width - sx, dy = axisEnd.y * height - sy
        let t = ((x - sx) * dx + (y - sy) * dy) / (dx * dx + dy * dy)
        return min(max(t, 0), 1)
    }

    /// Stop locations of the glow and the tint on the reference bubble (≈ 0.018 and ≈ 0.28);
    /// the gray is at the axis end (1).
    public static var glowLocation: Double {
        axisLocation(x: glowSamplePoint.x, y: glowSamplePoint.y, width: referenceSize.width, height: referenceSize.height)
    }
    public static var tintLocation: Double {
        axisLocation(x: tintSamplePoint.x, y: tintSamplePoint.y, width: referenceSize.width, height: referenceSize.height)
    }
}

extension ThemeDerivation {
    /// Glow near the bubble's top edge, the same for every theme. [07 §8.4] observed.
    public static let floatingPanelGlowLight = RGBAColor(hex: 0xFFE8FF)
    public static let floatingPanelGlowDark = RGBAColor(hex: 0x4B2046)
    /// Neutral gray at the bubble's bottom-right corner, the same for every theme. [07 §8.4] observed.
    public static let floatingPanelCornerLight = RGBAColor(hex: 0xF7F6F7)
    public static let floatingPanelCornerDark = RGBAColor(hex: 0x1E1E1E)
    /// Neutral backdrop the bubble tint was fitted over (what shows through our translucent fill
    /// on Arc's reference desktop). [07 §8.4] inferred.
    public static let floatingPanelBackdropLight = RGBAColor(hex: 0xEEEEEE)
    public static let floatingPanelBackdropDark = RGBAColor(hex: 0x1E1E1E)

    /// The fill that shows `shown` when painted at `opacity` over `backdrop` (source-over in sRGB,
    /// clamped to 0...1, so a color the fill cannot reach lands as close as it can).
    public static func fill(showing shown: RGBAColor, over backdrop: RGBAColor, opacity: Double) -> RGBAColor {
        guard opacity > 0 else { return shown }
        func channel(_ s: Double, _ b: Double) -> Double { min(max(b + (s - b) / opacity, 0), 1) }
        return RGBAColor(red: channel(shown.red, backdrop.red), green: channel(shown.green, backdrop.green),
                         blue: channel(shown.blue, backdrop.blue), alpha: 1)
    }

    /// The theme bubble's background gradient, as fills to paint at `opacity` (the bubble's
    /// translucent tint, `Metrics.FloatingBubble.tintOpacity`; 1 for an opaque surface): glow →
    /// theme tint (`floatingPanelBackground`, already fitted at that opacity) → neutral gray.
    /// [07 §8.4] finding 3: stop colors observed, geometry inferred.
    public static func floatingPanelGradient(tint: RGBAColor, isDark: Bool,
                                             opacity: Double = Metrics.FloatingBubble.tintOpacity) -> FloatingPanelGradient {
        let backdrop = isDark ? floatingPanelBackdropDark : floatingPanelBackdropLight
        let glow = fill(showing: isDark ? floatingPanelGlowDark : floatingPanelGlowLight, over: backdrop, opacity: opacity)
        let corner = fill(showing: isDark ? floatingPanelCornerDark : floatingPanelCornerLight, over: backdrop, opacity: opacity)
        // The tint was fitted for `Metrics.FloatingBubble.tintOpacity`; at another opacity, keep
        // what it shows there.
        let tintShown = mix(backdrop, tint, amount: Metrics.FloatingBubble.tintOpacity)
        let tintFill = opacity == Metrics.FloatingBubble.tintOpacity ? tint : fill(showing: tintShown, over: backdrop, opacity: opacity)
        typealias G = FloatingPanelGradient
        return G(stops: [G.Stop(color: glow, location: G.glowLocation),
                         G.Stop(color: tintFill, location: G.tintLocation),
                         G.Stop(color: corner, location: 1)],
                 start: G.axisStart, end: G.axisEnd)
    }
}

extension ThemePalette {
    /// The theme bubble's background gradient for this palette, as fills painted at `opacity`
    /// (`Metrics.FloatingBubble.tintOpacity` over a blur, or 1 on an opaque surface). [07 §8.4]
    public func floatingPanelGradient(opacity: Double = Metrics.FloatingBubble.tintOpacity) -> FloatingPanelGradient {
        ThemeDerivation.floatingPanelGradient(tint: floatingPanelBackground, isDark: isDark, opacity: opacity)
    }
}
