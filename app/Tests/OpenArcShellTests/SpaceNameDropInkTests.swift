import XCTest
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// [06 §15.4]: the Space-name row turns into a saturated blue band while a tab is dragged over
/// it; its name must stay readable on that band in light and dark themes.
@MainActor
final class SpaceNameDropInkTests: XCTestCase {
    func testNameInkIsWhiteOnDropBandInEveryAppearance() {
        let band = RGBAColor(hex: SidebarLocalTokens.spaceNameDropRGB)
        for appearance in ResolvedAppearance.allCases {
            let palette = ThemeDerivation.palette(for: nil, appearance: appearance)
            let ink = SidebarSpaceNameRowView.ink(\.spaceName, palette: palette, isDropTarget: true)
            XCTAssertGreaterThan(ThemeDerivation.contrast(ink, band), 4.5, "\(appearance)")
            XCTAssertEqual(SidebarSpaceNameRowView.ink(\.spaceIcon, palette: palette, isDropTarget: true), ink)
        }
    }

    func testNameInkIsThePaletteInkWithoutDrop() {
        let palette = ThemeDerivation.palette(for: nil)
        XCTAssertEqual(SidebarSpaceNameRowView.ink(\.spaceName, palette: palette, isDropTarget: false), palette.ink(\.spaceName))
    }
}
