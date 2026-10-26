import Foundation
import OpenArcModel

// Pure logic behind the theme editor bubble [06 §2]. No SwiftUI here, so everything is testable.
// Pad positions are unit coordinates: x and y in 0...1, origin at the top-left of the pad.

/// Mapping between a position on the dot-grid color pad and a color.
///
/// [06 §2] observed: tapping the pad picks "a color for this space". How a position maps to a
/// color is unknown; this mapping is our own (inferred): the horizontal axis walks the hue wheel
/// and the vertical axis goes from vivid (top) to muted (bottom) at a fixed HSB value. Brightness
/// is a separate control (the ring knob), so it is not part of the pad.
enum ThemePad {
    /// How many color points the pad holds. [06 §2] observed "up to several"; the limit is inferred.
    static let maxPoints = 3

    /// Saturation at the top and bottom edge of the pad. inferred.
    static let topSaturation = 0.85
    static let bottomSaturation = 0.15
    /// Fixed HSB value of every pad color. inferred (light enough for dark text, dark enough to read as a color).
    static let value = 0.92

    /// Radius, in unit coordinates of the pad's shorter side, within which a press grabs an existing point.
    static let hitRadius = 0.12

    static func color(at point: CGPoint) -> RGBAColor {
        let p = clamped(point)
        let saturation = topSaturation + (bottomSaturation - topSaturation) * Double(p.y)
        return rgb(hue: Double(p.x), saturation: saturation, value: value)
    }

    /// Inverse of `color(at:)`. Colors that did not come from the pad (presets) land on the
    /// closest hue and saturation; their value is ignored.
    static func position(of color: RGBAColor) -> CGPoint {
        let hsv = hsv(of: color)
        let y = (hsv.saturation - topSaturation) / (bottomSaturation - topSaturation)
        return clamped(CGPoint(x: hsv.hue, y: y))
    }

    static func clamped(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
    }

    // MARK: HSV conversion

    static func rgb(hue: Double, saturation: Double, value: Double) -> RGBAColor {
        let h = (hue - hue.rounded(.down)) * 6   // wrap into 0..<6
        let sector = Int(h), f = h - Double(sector)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch sector {
        case 0: return RGBAColor(red: value, green: t, blue: p)
        case 1: return RGBAColor(red: q, green: value, blue: p)
        case 2: return RGBAColor(red: p, green: value, blue: t)
        case 3: return RGBAColor(red: p, green: q, blue: value)
        case 4: return RGBAColor(red: t, green: p, blue: value)
        default: return RGBAColor(red: value, green: p, blue: q)
        }
    }

    static func hsv(of c: RGBAColor) -> (hue: Double, saturation: Double, value: Double) {
        let maxC = max(c.red, c.green, c.blue), minC = min(c.red, c.green, c.blue)
        let delta = maxC - minC
        guard delta > 0 else { return (0, 0, maxC) }
        var hue: Double
        if maxC == c.red {
            hue = (c.green - c.blue) / delta
        } else if maxC == c.green {
            hue = 2 + (c.blue - c.red) / delta
        } else {
            hue = 4 + (c.red - c.green) / delta
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, delta / maxC, maxC)
    }
}

// MARK: - Point editing on the draft

extension SpaceThemeDraft {
    /// "+" is enabled while there is at least one point and room for another.
    /// [06 §2] observed: with no point placed, "−" and "+" are grayed out.
    var canAddPoint: Bool { !colors.isEmpty && colors.count < ThemePad.maxPoints }
    var canRemovePoint: Bool { !colors.isEmpty }

    /// Index of the point closest to `position` within the hit radius, if any.
    func pointIndex(near position: CGPoint, radius: Double = ThemePad.hitRadius) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, color) in colors.enumerated() {
            let p = ThemePad.position(of: color)
            let d = hypot(Double(p.x - position.x), Double(p.y - position.y))
            if d <= radius, best == nil || d < best!.distance { best = (index, d) }
        }
        return best?.index
    }

    /// A press on the pad. It grabs the point under the press; on empty space it places a new
    /// point when there is room, otherwise it grabs the nearest point so the press still does
    /// something (inferred). Returns the index to keep moving while the pointer is dragged.
    mutating func beginPadInteraction(at position: CGPoint) -> Int {
        if let hit = pointIndex(near: position) {
            movePoint(hit, to: position)
            return hit
        }
        if colors.count < ThemePad.maxPoints {
            colors.append(ThemePad.color(at: position))
            return colors.count - 1
        }
        let nearest = colors.indices.min { lhs, rhs in
            distance(from: position, to: colors[lhs]) < distance(from: position, to: colors[rhs])
        } ?? 0
        movePoint(nearest, to: position)
        return nearest
    }

    /// Moves a point to a pad position (dragging). Out-of-range indexes are ignored.
    mutating func movePoint(_ index: Int, to position: CGPoint) {
        guard colors.indices.contains(index) else { return }
        colors[index] = ThemePad.color(at: position)
    }

    /// "+": adds a point one third of the hue wheel away from the last one (inferred). The new
    /// point is easy to tell apart and can be dragged where the user wants it.
    mutating func addPoint() {
        guard canAddPoint, let last = colors.last else { return }
        let p = ThemePad.position(of: last)
        let next = CGPoint(x: (p.x + 1.0 / 3).truncatingRemainder(dividingBy: 1), y: p.y)
        colors.append(ThemePad.color(at: next))
    }

    /// "−": removes the most recently added point.
    mutating func removeLastPoint() {
        guard canRemovePoint else { return }
        colors.removeLast()
    }

    /// Tapping a preset swatch makes it the only color of the theme (inferred).
    mutating func applyPreset(_ color: RGBAColor) {
        colors = [color]
    }

    private func distance(from position: CGPoint, to color: RGBAColor) -> Double {
        let p = ThemePad.position(of: color)
        return hypot(Double(p.x - position.x), Double(p.y - position.y))
    }
}

// MARK: - Presets

/// A named page of nine round swatches. [06 §2] observed: nine per page, several named groups
/// ("Brand", "Pastel", "Drab", …). The colors and the group order are our own picks (not Arc's).
struct ThemePresetGroup: Equatable {
    let name: String
    let colors: [RGBAColor]
}

enum ThemePresets {
    static let groups: [ThemePresetGroup] = [
        ThemePresetGroup(name: "Brand", colors: hexes([
            0x3D6FE0, 0x6B4FD8, 0xC2478F, 0xE0533F, 0xEE8A2B, 0xE6BE2E, 0x3FAE6A, 0x1F9E9A, 0x4A5568,
        ])),
        ThemePresetGroup(name: "Pastel", colors: hexes([
            0xBFD4F6, 0xD3C8F3, 0xF2C6DD, 0xF6CBC4, 0xF8DCBB, 0xF5EBB9, 0xC9E8CF, 0xBDE6E3, 0xDADDE3,
        ])),
        ThemePresetGroup(name: "Drab", colors: hexes([
            0x8A94A6, 0x8D8AA3, 0xA3868F, 0xA58C84, 0xA89A82, 0xA8A585, 0x8B9F8C, 0x829C9B, 0x9A9A96,
        ])),
    ]

    private static func hexes(_ values: [UInt32]) -> [RGBAColor] { values.map { RGBAColor(hex: $0) } }

    /// Page after a left (-1) or right (+1) arrow press. The arrows stop at the first and last page. inferred.
    static func page(after current: Int, step: Int) -> Int {
        min(max(current + step, 0), groups.count - 1)
    }

    /// Page whose swatches contain `color`, so the editor opens on the page of the current theme.
    static func pageContaining(_ color: RGBAColor?) -> Int {
        guard let color else { return 0 }
        return groups.firstIndex { $0.colors.contains(color) } ?? 0
    }
}

// MARK: - Slider and knob math

enum ThemeControlMath {
    /// Value 0...1 for a pointer at `x` on a slider `width` wide whose thumb travels between
    /// `inset` and `width - inset`.
    static func sliderValue(x: Double, width: Double, inset: Double) -> Double {
        let span = width - 2 * inset
        guard span > 0 else { return 0 }
        return min(max((x - inset) / span, 0), 1)
    }

    /// The ring knob sweeps 270 degrees, clockwise from the lower left (value 0) over the top
    /// (0.5) to the lower right (1). The sweep is inferred; [06 §2] only shows a ring with dots.
    static let knobSweepDegrees = 270.0

    /// Value for a pointer at `point` relative to the knob's center (y grows downwards). Points in
    /// the gap at the bottom snap to the nearer end.
    static func knobValue(dx: Double, dy: Double) -> Double {
        let degrees = atan2(dx, -dy) * 180 / .pi   // clockwise from 12 o'clock, -180...180
        let half = knobSweepDegrees / 2
        return (min(max(degrees, -half), half) + half) / knobSweepDegrees
    }

    /// Angle in degrees, clockwise from 12 o'clock, of the knob indicator for `value`.
    static func knobAngle(value: Double) -> Double {
        (min(max(value, 0), 1) - 0.5) * knobSweepDegrees
    }
}
