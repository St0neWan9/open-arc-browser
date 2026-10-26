import Foundation

/// Procedural grain texture for `Theme.grain` (plan B21). Our own implementation: a tile of
/// deterministic white noise (SplitMix64), drawn tiled over the window background at an opacity
/// that grows with `grain`. [06 §2] observed the wavy slider; that it controls a grain/texture
/// strength is inferred, and the look of Arc's texture was not captured (unknown).
public enum GrainNoise {
    /// Tile side in pixels. unknown (our choice: large enough that the repeat is not visible).
    public static let tileSize = 128
    /// Overlay opacity at grain = 1. unknown (our choice: subtle).
    public static let maxOpacity: Double = 0.16
    /// Seed of the tile, so every window shows the same texture.
    public static let seed: UInt64 = 0x0A7C_6A1B_5EED_0001

    /// Opacity of the grain overlay for `grain`; nil when there is no overlay (grain ≤ 0).
    public static func overlayOpacity(for grain: Double) -> Double? {
        let g = min(max(grain, 0), 1)
        guard g > 0 else { return nil }
        return g * maxOpacity
    }

    /// Premultiplied RGBA bytes of one `size` × `size` tile: gray noise with alpha 1, so the
    /// overlay's opacity sets the strength. Deterministic for a given seed.
    public static func tilePixels(size: Int = tileSize, seed: UInt64 = seed) -> [UInt8] {
        var state = seed
        var pixels = [UInt8](repeating: 255, count: size * size * 4)
        for index in 0..<(size * size) {
            let level = UInt8(truncatingIfNeeded: splitMix(&state) >> 56)
            pixels[index * 4] = level
            pixels[index * 4 + 1] = level
            pixels[index * 4 + 2] = level
        }
        return pixels
    }

    private static func splitMix(_ state: inout UInt64) -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
