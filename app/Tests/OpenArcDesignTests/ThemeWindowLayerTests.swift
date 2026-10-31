import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// Plan B146: the window / sidebar color as Arc's layer stack (ThemeWindowLayer.swift).
/// Spec: docs/arc-spec/07-design-system.md §8.2 (window rule), §8 (E11 samples), §8.4 (E8 lossless
/// samples). Layer math inferred (analysis); backdrop grays and the dark strength fitted to the
/// observed samples. Each sample set must match at least as well as the B38 blends did.
final class ThemeWindowLayerTests: XCTestCase {
    private typealias D = ThemeDerivation

    private func maxChannelError(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255
    }

    // MARK: Layer math ([07 §8.2] inferred (analysis))

    /// Coverage grows linearly with the strength: 0.2 at 0, 0.64 at the preset 0.8, 0.75 at 1.
    func testThemeLayerAlpha() {
        XCTAssertEqual(D.themeLayerAlpha(strength: 0), 0.2, accuracy: 1e-12)
        XCTAssertEqual(D.themeLayerAlpha(strength: 0.8), 0.64, accuracy: 1e-12)
        XCTAssertEqual(D.themeLayerAlpha(strength: 1), 0.75, accuracy: 1e-12)
        XCTAssertEqual(D.themeLayerAlpha(strength: 3), 0.75, accuracy: 1e-12, "clamped")
    }

    /// The veil: white at min(coverage, 0.5) in light, black at 35 % of that in dark.
    func testVeilPerAppearance() {
        let light = D.windowVeil(strength: 0.8, appearance: .light)
        XCTAssertEqual(light, RGBAColor(red: 1, green: 1, blue: 1, alpha: 0.5))
        let dark = D.windowVeil(strength: 0.8, appearance: .dark)
        XCTAssertEqual(dark.red, 0); XCTAssertEqual(dark.alpha, 0.175, accuracy: 1e-12)
        XCTAssertEqual(D.windowVeil(strength: 0, appearance: .light).alpha, 0.2, accuracy: 1e-12, "below the cap")
    }

    /// The layer is see-through: its coverage is the theme's plus the veil's share under it, and a
    /// white theme in light stays white (veil and color agree).
    func testThemeLayerIsTranslucent() {
        let layer = D.themeLayer(RGBAColor(hex: 0x6CBAD9), appearance: .light, strength: 0.8)
        XCTAssertEqual(layer.alpha, 0.64 + 0.5 * 0.36, accuracy: 1e-12)
        XCTAssertLessThan(layer.alpha, 1)
        let white = D.themeLayer(RGBAColor(hex: 0xFFFFFF), appearance: .light, strength: 0.8)
        XCTAssertEqual(white.red, 1, accuracy: 1e-12); XCTAssertEqual(white.blue, 1, accuracy: 1e-12)
        let dark = D.themeLayer(RGBAColor(hex: 0x6CBAD9), appearance: .dark, strength: 0.8)
        XCTAssertLessThan(dark.green, RGBAColor(hex: 0x6CBAD9).green, "a black veil darkens the color")
    }

    /// Over a gray backdrop a gray theme stays gray (P3 and sRGB agree on grays).
    func testGrayThemeStaysGray() {
        for appearance in ResolvedAppearance.allCases {
            let c = appearance == .dark ? D.darkVariant(RGBAColor(hex: 0x7F7F7F)) : D.lightWindow(RGBAColor(hex: 0x7F7F7F))
            XCTAssertEqual(c.red, c.green, accuracy: 1e-6); XCTAssertEqual(c.green, c.blue, accuracy: 1e-6)
        }
    }

    // MARK: Samples

    /// [07 §8.1] / [07 §8.2] observed E12 window samples (36 presets, LCU JPEG): light within 2.7/255
    /// (B38 blend: 2.8), dark within 3.1/255 (B38: 3.1).
    func testE12WindowBounds() {
        var light = 0.0, dark = 0.0
        for (_, themeHex, lightHex, darkHex) in Self.e12 {
            let t = RGBAColor(hex: themeHex)
            light = max(light, maxChannelError(D.lightWindow(t), RGBAColor(hex: lightHex)))
            dark = max(dark, maxChannelError(D.darkVariant(t), RGBAColor(hex: darkHex)))
        }
        XCTAssertLessThanOrEqual(light, 2.75, "light E12 max \(light)")
        XCTAssertLessThanOrEqual(dark, 3.15, "dark E12 max \(dark)")
    }

    /// [07 §8.4] observed E8 lossless window samples (8 dark-ink presets + navy, light and dark):
    /// light within 1.3/255 (B38: 3.7), dark within 2.6/255 (B38: 2.9).
    func testE8WindowBounds() {
        let samples: [(theme: UInt32, light: UInt32, dark: UInt32)] = [
            (0xF3EAE4, 0xF0EBE7, 0xDBD6D2), (0xF29CBA, 0xF0B8CC, 0xDCA4B8), (0xA6729D, 0xBF9EBA, 0xAB8BA5),
            (0xF25E6B, 0xF0929A, 0xDC8087), (0xFF8557, 0xF8AA8E, 0xE4977D), (0xF8D558, 0xF4DD8F, 0xDFC87E),
            (0x35E894, 0x7CE9B5, 0x73D5A1), (0x6CBAD9, 0x9BCCE0, 0x89B7CB), (0x666789, 0x9797AD, 0x848499),
        ]
        var light = 0.0, dark = 0.0
        for s in samples {
            let t = RGBAColor(hex: s.theme)
            light = max(light, maxChannelError(D.lightWindow(t), RGBAColor(hex: s.light)))
            dark = max(dark, maxChannelError(D.darkVariant(t), RGBAColor(hex: s.dark)))
        }
        XCTAssertLessThanOrEqual(light, 1.3, "light E8 max \(light)")
        XCTAssertLessThanOrEqual(dark, 2.6, "dark E8 max \(dark)")
    }

    /// [07 §8] observed E11 samples: light within 1.5/255 (B38: 1.8), dark within 3.1/255 (B38: 3.1).
    func testE11WindowBounds() {
        let light: [(UInt32, UInt32)] = [(0xA5729C, 0xBF9EB8), (0xF8D55A, 0xF5DD8F), (0x6CBAD9, 0x9ACBE0)]
        let dark: [(UInt32, UInt32)] = [(0xF8D55A, 0xDFC87F), (0x6CBAD9, 0x87B7CB)]
        for (t, w) in light {
            XCTAssertLessThanOrEqual(maxChannelError(D.lightWindow(RGBAColor(hex: t)), RGBAColor(hex: w)), 1.5, String(format: "%06X light", t))
        }
        for (t, w) in dark {
            XCTAssertLessThanOrEqual(maxChannelError(D.darkVariant(RGBAColor(hex: t)), RGBAColor(hex: w)), 3.1, String(format: "%06X dark", t))
        }
    }

    /// [07 §8.5]: the no-color base #D6D6FB still lands on the observed sidebar top #DEDEF5 (≤ 1.5/255).
    func testDefaultBaseColorStillMatchesTheNoColorWindow() {
        XCTAssertLessThanOrEqual(maxChannelError(D.lightWindow(D.defaultBaseColor), RGBAColor(hex: 0xDEDEF5)), 1.5)
    }

    /// E12 window samples [07 §8.1] observed: (preset, theme, light window, dark window).
    static let e12: [(String, UInt32, UInt32, UInt32)] = [
        ("p1-1", 0xF1EBE5, 0xF0EBE6, 0xDCD6D2), ("p1-2", 0xF19CBB, 0xF0B8CD, 0xDCA4B8), ("p1-3", 0xA5729C, 0xBF9EB8, 0xAC8BA6),
        ("p1-4", 0xF25E6C, 0xF0919A, 0xDD8088), ("p1-5", 0xFF8557, 0xF9AA8E, 0xE3977C), ("p1-6", 0xF8D55A, 0xF5DD8F, 0xDFC87F),
        ("p1-7", 0x35E896, 0x7BE9B4, 0x73D4A1), ("p1-8", 0x6CBAD9, 0x9BCCE1, 0x87B7CB), ("p1-9", 0x666789, 0x9798AE, 0x838498),
        ("p3-1", 0xFFFBFA, 0xF7F5F5, 0xE3E0E1), ("p3-2", 0xFEE9F3, 0xF8EBF1, 0xE4D6DC), ("p3-3", 0xF1D2ED, 0xEFDBEB, 0xDBC7D7),
        ("p3-4", 0xFFCBD0, 0xF8D6DB, 0xE4C1C6), ("p3-5", 0xFFE1D3, 0xF8E3DC, 0xE4CFC7), ("p3-6", 0xFFF9E4, 0xF8F4E7, 0xE4DFD3),
        ("p3-7", 0xDEFDEC, 0xE3F7EA, 0xCEE3D6), ("p3-8", 0xDBF3FB, 0xE2F1F7, 0xCDDCE2), ("p3-9", 0xC5C6E5, 0xD2D3E7, 0xBEBFD2),
        ("p4-1", 0x4E3A5A, 0x887C8E, 0x766C7E), ("p4-2", 0x683557, 0x9A798E, 0x86687A), ("p4-3", 0x8F4144, 0xB07F7F, 0x9F6E6E),
        ("p4-4", 0xAF6D40, 0xC69B7F, 0xB3896E), ("p4-5", 0xD7B35F, 0xDFC792, 0xC9B280), ("p4-6", 0xCDCCA3, 0xD9D7BE, 0xC4C2AA),
        ("p4-7", 0x79AA82, 0xA2C2A8, 0x90AE95), ("p4-8", 0x226148, 0x6E9386, 0x608172), ("p4-9", 0x27476C, 0x6F8299, 0x617188),
        ("p5-1", 0xFFFFFF, 0xF8F8F8, 0xE3E3E3), ("p5-2", 0xE6E6E6, 0xE7E7E7, 0xD3D3D3), ("p5-3", 0xCCCCCC, 0xD8D8D8, 0xC3C3C3),
        ("p5-4", 0xB2B2B2, 0xC7C7C7, 0xB3B3B3), ("p5-5", 0x7F7F7F, 0xA7A7A7, 0x939393), ("p5-6", 0x666666, 0x979797, 0x838383),
        ("p5-7", 0x333333, 0x777777, 0x666666), ("p5-8", 0x191919, 0x686868, 0x595959), ("p5-9", 0x010101, 0x585858, 0x484848),
    ]
}
