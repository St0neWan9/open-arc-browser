import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// Plan B36: the content-area tint of docs/arc-spec/07-design-system.md §8.1 (E12).
/// Every preset sampled in E12 (36 colors × light / dark, PX observed, 120 × 120 px averages of
/// JPEG captures) must be reproduced within 3/255 per channel by the inferred P3 blend.
final class ContentBackgroundTests: XCTestCase {
    private struct Sample {
        /// Theme bubble page and swatch ("p3-4" = page 3, fourth swatch). Our own labels.
        let name: String
        let theme: UInt32
        /// Observed content-area color, 0...255 per channel.
        let light: (Double, Double, Double)
        let dark: (Double, Double, Double)

        init(_ name: String, _ theme: UInt32, light: (Double, Double, Double), dark: (Double, Double, Double)) {
            self.name = name
            self.theme = theme
            self.light = light
            self.dark = dark
        }
    }

    /// [07 §8.1] observed sample table (E12).
    private let samples: [Sample] = [
        Sample("p1-1", 0xF1EBE5, light: (249.0, 248.0, 246.0), dark: (222.0, 219.0, 213.0)),
        Sample("p1-2", 0xF19CBB, light: (250.0, 232.0, 239.8), dark: (223.8, 173.8, 192.8)),
        Sample("p1-3", 0xA5729C, light: (234.0, 224.9, 231.1), dark: (180.0, 151.0, 174.0)),
        Sample("p1-4", 0xF25E6C, light: (250.0, 221.0, 222.0), dark: (223.8, 141.8, 148.8)),
        Sample("p1-5", 0xFF8557, light: (253.0, 229.0, 219.0), dark: (231.0, 163.0, 139.0)),
        Sample("p1-6", 0xF8D55A, light: (251.0, 244.0, 218.0), dark: (225.1, 205.9, 141.0)),
        Sample("p1-7", 0x35E896, light: (216.0, 248.0, 230.0), dark: (131.3, 217.3, 169.3)),
        Sample("p1-8", 0x6CBAD9, light: (224.0, 238.0, 245.0), dark: (150.0, 190.0, 208.0)),
        Sample("p1-9", 0x666789, light: (221.0, 222.0, 230.0), dark: (145.0, 145.0, 164.0)),
        Sample("p3-1", 0xFFFBFA, light: (253.0, 251.0, 252.0), dark: (229.0, 227.0, 228.0)),
        Sample("p3-2", 0xFEE9F3, light: (252.0, 248.0, 249.0), dark: (230.0, 218.0, 224.0)),
        Sample("p3-3", 0xF1D2ED, light: (250.0, 243.0, 248.0), dark: (222.7, 203.7, 219.7)),
        Sample("p3-4", 0xFFCBD0, light: (253.0, 242.0, 243.0), dark: (230.0, 201.0, 204.0)),
        Sample("p3-5", 0xFFE1D3, light: (252.0, 246.0, 241.0), dark: (230.0, 212.0, 205.7)),
        Sample("p3-6", 0xFFF9E4, light: (253.0, 252.0, 246.0), dark: (229.9, 227.9, 215.9)),
        Sample("p3-7", 0xDEFDEC, light: (245.9, 253.9, 248.9), dark: (210.0, 229.0, 219.0)),
        Sample("p3-8", 0xDBF3FB, light: (246.0, 250.0, 252.0), dark: (209.0, 223.0, 229.0)),
        Sample("p3-9", 0xC5C6E5, light: (239.0, 240.0, 248.0), dark: (197.8, 197.0, 215.0)),
        Sample("p4-1", 0x4E3A5A, light: (216.7, 213.9, 218.2), dark: (133.0, 123.0, 138.0)),
        Sample("p4-2", 0x683557, light: (222.0, 213.0, 219.0), dark: (145.0, 120.0, 137.0)),
        Sample("p4-3", 0x8F4144, light: (230.0, 214.0, 214.0), dark: (168.0, 125.0, 126.0)),
        Sample("p4-4", 0xAF6D40, light: (237.0, 224.0, 213.0), dark: (186.5, 148.5, 126.5)),
        Sample("p4-5", 0xD7B35F, light: (244.0, 237.0, 219.0), dark: (207.0, 186.0, 142.0)),
        Sample("p4-6", 0xCDCCA3, light: (242.0, 242.0, 233.4), dark: (202.0, 201.0, 179.0)),
        Sample("p4-7", 0x79AA82, light: (227.0, 234.0, 226.4), dark: (154.5, 181.5, 160.2)),
        Sample("p4-8", 0x226148, light: (209.0, 221.0, 217.0), dark: (114.0, 142.0, 131.0)),
        Sample("p4-9", 0x27476C, light: (209.8, 215.8, 223.0), dark: (113.9, 127.9, 148.9)),
        Sample("p5-1", 0xFFFFFF, light: (252.0, 252.0, 252.0), dark: (230.0, 230.0, 230.0)),
        Sample("p5-2", 0xE6E6E6, light: (247.0, 247.0, 247.0), dark: (216.0, 216.0, 216.0)),
        Sample("p5-3", 0xCCCCCC, light: (242.0, 242.0, 242.0), dark: (201.0, 201.0, 201.0)),
        Sample("p5-4", 0xB2B2B2, light: (237.0, 237.0, 237.0), dark: (187.0, 187.0, 187.0)),
        Sample("p5-5", 0x7F7F7F, light: (226.0, 226.0, 226.0), dark: (158.0, 158.0, 158.0)),
        Sample("p5-6", 0x666666, light: (222.0, 222.0, 222.0), dark: (144.1, 144.1, 144.1)),
        Sample("p5-7", 0x333333, light: (212.0, 212.0, 212.0), dark: (118.0, 118.0, 118.0)),
        Sample("p5-8", 0x191919, light: (207.0, 207.0, 207.0), dark: (106.8, 106.8, 106.8)),
        Sample("p5-9", 0x010101, light: (203.0, 203.0, 203.0), dark: (92.0, 92.0, 92.0)),
    ]

    private let tolerance = 3.0 / 255

    private func assertMatches(_ actual: RGBAColor, _ expected: (Double, Double, Double), _ label: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.red, expected.0 / 255, accuracy: tolerance, "\(label) red", file: file, line: line)
        XCTAssertEqual(actual.green, expected.1 / 255, accuracy: tolerance, "\(label) green", file: file, line: line)
        XCTAssertEqual(actual.blue, expected.2 / 255, accuracy: tolerance, "\(label) blue", file: file, line: line)
    }

    private func theme(_ appearance: ThemeAppearance, _ hex: UInt32) -> Theme {
        Theme(id: UUID(), appearance: appearance, colors: [RGBAColor(hex: hex)], now: Date(timeIntervalSince1970: 0))
    }

    /// [07 §8.1]: light = mixP3(theme, 251/255, 0.80), within 3/255 for all 36 presets.
    func testLightContentMatchesEverySample() {
        XCTAssertEqual(samples.count, 36)
        for s in samples {
            assertMatches(ThemeDerivation.contentBackground(RGBAColor(hex: s.theme), appearance: .light), s.light, "\(s.name) light")
        }
    }

    /// [07 §8.1]: dark = mixP3(theme, 197/255, 0.46), within 3/255 for all 36 presets.
    func testDarkContentMatchesEverySample() {
        for s in samples {
            assertMatches(ThemeDerivation.contentBackground(RGBAColor(hex: s.theme), appearance: .dark), s.dark, "\(s.name) dark")
        }
    }

    /// The palette carries the tint in the web panel for light, dark and automatic (B21 semantics:
    /// automatic follows the system; [07 §8.1] observed automatic == light on a light system).
    func testPaletteUsesTheContentTintInEveryAppearance() {
        for s in samples {
            let light = ThemeDerivation.palette(for: theme(.light, s.theme), systemAppearance: .dark)
            let dark = ThemeDerivation.palette(for: theme(.dark, s.theme), systemAppearance: .light)
            assertMatches(light.webPanelBackground, s.light, "\(s.name) light palette")
            assertMatches(dark.webPanelBackground, s.dark, "\(s.name) dark palette")
            XCTAssertEqual(ThemeDerivation.palette(for: theme(.automatic, s.theme), systemAppearance: .light).webPanelBackground,
                           light.webPanelBackground, "\(s.name) automatic on a light system")
            XCTAssertEqual(ThemeDerivation.palette(for: theme(.automatic, s.theme), systemAppearance: .dark).webPanelBackground,
                           dark.webPanelBackground, "\(s.name) automatic on a dark system")
        }
    }

    /// The user-reported bug: the content area was plain white (light) or black / window (dark).
    /// [07 §8.1] observed: never white, never black, and lighter than the window in both modes.
    func testContentIsNeverPlainWhiteOrBlack() {
        for s in samples {
            for appearance in ResolvedAppearance.allCases {
                let palette = ThemeDerivation.palette(for: theme(appearance == .dark ? .dark : .light, s.theme), systemAppearance: .light)
                let label = "\(s.name) \(appearance.rawValue)"
                XCTAssertNotEqual(palette.webPanelBackground, RGBAColor(hex: 0xFFFFFF), label)
                XCTAssertNotEqual(palette.webPanelBackground, RGBAColor(hex: 0x000000), label)
                XCTAssertGreaterThan(ThemeDerivation.luminance(palette.webPanelBackground), 0.1, label)
            }
        }
    }

    /// [07 §8.1] observed: on the ten dark (light-ink) presets the dark content area equals the
    /// address-field fill (rounded hex, ≤ 2/255 apart in the JPEGs); the formula gets there on its
    /// own. Tolerance: the formula's 3/255 plus that 2/255 capture spread. Arc's own control values,
    /// not ours, so only the content rule is under test.
    func testDarkContentOfDarkPresetsMatchesTheirControlFill() {
        // (theme, observed dark control fill)
        let darkPresets: [(UInt32, UInt32)] = [
            (0x666789, 0x9191A4), (0x4E3A5A, 0x847A89), (0x683557, 0x917889), (0x8F4144, 0xA87D7E),
            (0x226148, 0x728E83), (0x27476C, 0x728095), (0x666666, 0x909090), (0x333333, 0x767676),
            (0x191919, 0x6B6B6D), (0x010101, 0x5C5C5C),
        ]
        for (themeHex, control) in darkPresets {
            let c = RGBAColor(hex: control)
            let content = ThemeDerivation.contentBackground(RGBAColor(hex: themeHex), appearance: .dark)
            let label = String(format: "%06X", themeHex)
            XCTAssertEqual(content.red, c.red, accuracy: 5.0 / 255, label)
            XCTAssertEqual(content.green, c.green, accuracy: 5.0 / 255, label)
            XCTAssertEqual(content.blue, c.blue, accuracy: 5.0 / 255, label)
        }
    }

    /// The P3 round trip is lossless inside the sRGB gamut, and the blend keeps alpha.
    func testDisplayP3RoundTrip() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x35E896, 0xA5729C, 0xFF0000, 0x0000FF] {
            let c = RGBAColor(hex: hex)
            let back = DisplayP3.toSRGB(DisplayP3.fromSRGB(c))
            XCTAssertEqual(back.red, c.red, accuracy: 1e-5)
            XCTAssertEqual(back.green, c.green, accuracy: 1e-5)
            XCTAssertEqual(back.blue, c.blue, accuracy: 1e-5)
        }
        let gray = ThemeDerivation.mixInDisplayP3(RGBAColor(hex: 0x808080, alpha: 0.5), gray: 1, amount: 0)
        XCTAssertEqual(gray.red, 128.0 / 255, accuracy: 1e-5)
        XCTAssertEqual(gray.alpha, 0.5)
    }
}
