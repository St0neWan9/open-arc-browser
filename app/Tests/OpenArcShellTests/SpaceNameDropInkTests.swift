import XCTest
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// [06 §15.4] observed 2026-10-26: while a tab is dragged over the Space-name row, the row fills
/// with a darker tone of the theme color, not a fixed blue, and the name keeps its dark theme ink.
@MainActor
final class SpaceNameDropBandTests: XCTestCase {
    /// [06 §15.4] observed (E17): sidebar → band pairs on three themes, each within 4/255 (B118).
    /// The rule (`ThemeDerivation.dropTargetFill`) is inferred and works on the window color.
    func testBandMatchesTheThreeE17Samples() {
        let samples: [(window: UInt32, band: UInt32, dark: Bool)] = [
            (0xDFE0FA, 0x878CFF, false), // lavender (light)
            (0xF2B0C9, 0xD26E92, false), // pink (light, most saturated)
            (0x7D7E98, 0x6A6B85, true),  // navy (dark)
        ]
        for sample in samples {
            let band = ThemeDerivation.dropTargetFill(window: RGBAColor(hex: sample.window), isDark: sample.dark)
            let expected = RGBAColor(hex: sample.band)
            XCTAssertEqual(band.red * 255, expected.red * 255, accuracy: 4, String(sample.band, radix: 16))
            XCTAssertEqual(band.green * 255, expected.green * 255, accuracy: 4, String(sample.band, radix: 16))
            XCTAssertEqual(band.blue * 255, expected.blue * 255, accuracy: 4, String(sample.band, radix: 16))
        }
        // The band is darker than the sidebar in every case (a darker tone, not gray).
        for sample in samples {
            let window = RGBAColor(hex: sample.window)
            let band = ThemeDerivation.dropTargetFill(window: window, isDark: sample.dark)
            XCTAssertLessThan(ThemeDerivation.luminance(band), ThemeDerivation.luminance(window))
        }
    }

    func testBandFollowsTheThemeAccent() {
        let lavender = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xC9C6F0)]), appearance: .light)
        let magenta = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xE204E6)]), appearance: .light)
        XCTAssertEqual(SidebarSpaceNameRowView.dropBandFill(palette: lavender), lavender.dropTargetFill)
        // Magenta theme #E204E6: Arc's band measured ≈ #B828BC.
        let band = magenta.dropTargetFill
        XCTAssertEqual(band.red * 255, 184, accuracy: 4)
        XCTAssertEqual(band.green * 255, 40, accuracy: 4)
        XCTAssertEqual(band.blue * 255, 188, accuracy: 4)
        XCTAssertNotEqual(SidebarSpaceNameRowView.dropBandFill(palette: lavender), SidebarSpaceNameRowView.dropBandFill(palette: magenta))
    }

    func testNameStaysReadableOnTheBand() {
        for appearance in ResolvedAppearance.allCases {
            for hex: UInt32 in [0xC9C6F0, 0xE204E6, 0x7FA6E8, 0x2E8B57, 0xF5C542] {
                let palette = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: hex)]), appearance: appearance)
                let band = SidebarSpaceNameRowView.dropBandFill(palette: palette)
                let ink = palette.ink(\.spaceName)
                let opaqueInk = ThemeDerivation.mix(band, RGBAColor(red: ink.red, green: ink.green, blue: ink.blue), amount: ink.alpha)
                XCTAssertGreaterThan(ThemeDerivation.contrast(opaqueInk, band), 1.5, "\(appearance) \(String(hex, radix: 16))")
            }
        }
    }
}
