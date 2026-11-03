import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// B157: the line on the sidebar seam takes the theme's strongest tone, drawn at 50 %.
/// [07 §1] inferred; the light tone is fitted to an observed peach Space sample.
final class SeamIndicatorB157Tests: XCTestCase {
    func testSeamIndicatorIsTheThemesStrongTone_07_1() {
        let theme = RGBAColor(hex: 0xF2B0C9)
        let light = ThemeDerivation.palette(forStyle: ThemeStyle(appearance: .light, colors: [theme]), appearance: .light)
        let lch = OKLCH(light.seamIndicator)
        XCTAssertEqual(lch.lightness, ThemeDerivation.seamIndicatorLightness, accuracy: 0.02)
        XCTAssertEqual(lch.hue, OKLCH(theme).hue, accuracy: 3, "same hue as the theme")
        XCTAssertGreaterThan(lch.chroma, OKLCH(light.windowBackground).chroma, "stronger than the window")
        let dark = ThemeDerivation.palette(forStyle: ThemeStyle(appearance: .dark, colors: [theme]), appearance: .dark)
        XCTAssertGreaterThan(OKLCH(dark.seamIndicator).lightness, lch.lightness, "a light tone on a dark window")
        XCTAssertEqual(Metrics.Sidebar.resizeIndicatorOpacity, 0.5)
    }

    /// The sample: peach Space, row text #361C00, line #C8A582 over the sidebar #F8ECE2.
    func testFitReproducesThePeachSample_07_1() {
        // The theme chroma implied by the row text (row text = 0.60 × the theme's chroma).
        let text = OKLCH(RGBAColor(hex: 0x361C00))
        let indicator = OKLCH(lightness: ThemeDerivation.seamIndicatorLightness,
                              chroma: text.chroma / ThemeDerivation.rowTextChromaFactor * ThemeDerivation.seamIndicatorChromaFactor,
                              hue: text.hue).rgb(alpha: 1)
        let sidebar = RGBAColor(hex: 0xF8ECE2)
        let shown = ThemeDerivation.mix(sidebar, indicator, amount: Metrics.Sidebar.resizeIndicatorOpacity)
        let sample = RGBAColor(hex: 0xC8A582)
        XCTAssertEqual(shown.red * 255, sample.red * 255, accuracy: 4)
        XCTAssertEqual(shown.green * 255, sample.green * 255, accuracy: 4)
        XCTAssertEqual(shown.blue * 255, sample.blue * 255, accuracy: 4)
    }
}
