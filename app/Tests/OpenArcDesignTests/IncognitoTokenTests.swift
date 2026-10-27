import XCTest
import OpenArcModel
import OpenArcDesign

/// Plan B48: the incognito tokens pin the values of docs/arc-spec/06-flows.md §20 and
/// design-tokens.json `Metrics.Incognito.colorsDark` (observed, E19).
final class IncognitoTokenTests: XCTestCase {
    /// 06 §20.1, §20.3 observed (design-tokens.json Metrics.Incognito.colorsDark).
    func testDarkColorsMatchDesignTokens() {
        let t = IncognitoTokens.self
        XCTAssertEqual(t.windowBackground, RGBAColor(hex: 0x0C0F14))
        XCTAssertEqual(t.addressFieldFill, RGBAColor(hex: 0x3D4243))
        XCTAssertEqual(t.newTabRowSelectedFill, RGBAColor(hex: 0x46494D))
        XCTAssertEqual(t.selectedRowFill, RGBAColor(hex: 0x4F5257))
        XCTAssertEqual(t.blankPanel, RGBAColor(hex: 0x2A2D31))
        XCTAssertEqual(t.commandBarBackground, RGBAColor(hex: 0x1A1A1D))
        XCTAssertEqual(t.commandBarSelection, RGBAColor(hex: 0x444DDC))
    }

    /// 06 §20.1 observed: the dark palette uses the fixed colors as they are; 06 §20.5 unknown
    /// light colors: a light, neutral fallback.
    func testPalettePerAppearance() {
        let dark = ThemeDerivation.incognitoPalette(appearance: .dark)
        XCTAssertEqual(dark.windowBackground, IncognitoTokens.windowBackground)
        XCTAssertEqual(dark.controlFill, IncognitoTokens.addressFieldFill)
        XCTAssertEqual(dark.commandBarSelection, IncognitoTokens.commandBarSelection)
        XCTAssertTrue(dark.isDark)
        let light = ThemeDerivation.incognitoPalette(appearance: .light)
        XCTAssertFalse(light.isDark)
        XCTAssertFalse(light.usesLightInk)
        XCTAssertEqual(light.commandBarSelection, IncognitoTokens.commandBarSelection)
    }
}
