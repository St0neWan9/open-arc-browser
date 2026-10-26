import Foundation
import OpenArcModel

/// Per-channel blends toward a gray on the non-linear Display P3 components of a color.
///
/// docs/arc-spec/07-design-system.md §8.1 (E12): Arc's content area (light and dark) and its dark
/// window / sidebar color both fit such a blend far better than the same blend on sRGB components
/// (saturated greens miss by 8–11/255 in sRGB). inferred rule, observed samples.
extension ThemeDerivation {
    /// Moves `color` `amount` of the way to a gray of level `gray` on the non-linear Display P3
    /// components, then returns sRGB (clamped to 0...1; alpha kept).
    public static func mixInDisplayP3(_ color: RGBAColor, gray: Double, amount: Double) -> RGBAColor {
        let a = min(max(amount, 0), 1)
        let p3 = DisplayP3.fromSRGB(color)
        let mixed = p3.map { $0 + (gray - $0) * a }
        var out = DisplayP3.toSRGB(mixed)
        out.alpha = color.alpha
        return out
    }
}

/// sRGB ↔ Display P3 for colors inside the sRGB gamut. Both spaces use the sRGB transfer curve and
/// the D65 white point, so the conversion is a 3 × 3 matrix on linear components.
enum DisplayP3 {
    /// Linear sRGB → linear Display P3.
    private static let fromSRGBMatrix: [[Double]] = [
        [0.8224621, 0.1775380, 0.0000000],
        [0.0331941, 0.9668058, 0.0000000],
        [0.0170827, 0.0723974, 0.9105199],
    ]
    /// Linear Display P3 → linear sRGB.
    private static let toSRGBMatrix: [[Double]] = [
        [1.2249401, -0.2249404, 0.0000000],
        [-0.0420569, 1.0420571, 0.0000000],
        [-0.0196376, -0.0786361, 1.0982735],
    ]

    /// Non-linear Display P3 components (0...1) of an sRGB color.
    static func fromSRGB(_ c: RGBAColor) -> [Double] {
        let linear = [c.red, c.green, c.blue].map(decode)
        return multiply(fromSRGBMatrix, linear).map(encode)
    }

    /// The sRGB color of non-linear Display P3 components, each channel clamped to 0...1.
    static func toSRGB(_ p3: [Double]) -> RGBAColor {
        let rgb = multiply(toSRGBMatrix, p3.map(decode)).map(encode)
        return RGBAColor(red: rgb[0], green: rgb[1], blue: rgb[2])
    }

    private static func multiply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        m.map { row in row[0] * v[0] + row[1] * v[1] + row[2] * v[2] }
    }

    /// sRGB transfer curve, encoded → linear.
    private static func decode(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// sRGB transfer curve, linear → encoded, clamped to 0...1.
    private static func encode(_ v: Double) -> Double {
        let c = min(max(v, 0), 1)
        return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
    }
}
