import XCTest
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// [06 §15.4] observed 2026-10-26: while a tab is dragged over the Space-name row, the row fills
/// with a darker tone of the theme color, not a fixed blue, and the name keeps its dark theme ink.
@MainActor
final class SpaceNameDropBandTests: XCTestCase {
    func testBandFollowsTheThemeAccent() {
        let lavender = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xC9C6F0)]), appearance: .light)
        let magenta = ThemeDerivation.palette(forStyle: ThemeStyle(colors: [RGBAColor(hex: 0xE204E6)]), appearance: .light)
        XCTAssertEqual(SidebarSpaceNameRowView.dropBandFill(palette: lavender), lavender.dropTargetFill)
        // Magenta theme #E204E6: Arc's band measured ≈ #B828BC.
        let band = magenta.dropTargetFill
        XCTAssertEqual(band.red * 255, 184, accuracy: 14)
        XCTAssertEqual(band.green * 255, 40, accuracy: 14)
        XCTAssertEqual(band.blue * 255, 188, accuracy: 14)
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
