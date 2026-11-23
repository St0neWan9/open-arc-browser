import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// B242: eight Space colors as Arc stores them (picked colors at intensity 0.8 and 1, one of them
/// wide gamut), measured in Arc in a light window over a uniform #D4D4D4 backdrop (the reference
/// desktop), lossless full-screen captures, 330 × 70 pt / 540 × 880 pt flat areas (std ≤ 0.6/255).
/// observed (values); the rules they check are inferred.
final class SpaceColorB242Tests: XCTestCase {
    private struct Sample {
        let name: String
        let color: RGBAColor
        let intensity: Double
        let window: (Double, Double, Double)
        let control: (Double, Double, Double)
        let content: (Double, Double, Double)
    }

    private let samples: [Sample] = [
        Sample(name: "periwinkle", color: RGBAColor(red: 0.3493, green: 0.405391, blue: 0.746794), intensity: 1,
               window: (126.8, 137.5, 202.8), control: (138.8, 148.5, 207.8), content: (212.1, 216.0, 237.7)),
        Sample(name: "forest", color: RGBAColor(red: 0.145084, green: 0.420558, blue: 0.226826), intensity: 1,
               window: (87.7, 140.4, 103.3), control: (103.7, 151.4, 118.3), content: (199.1, 217.0, 204.4)),
        Sample(name: "wide-gamut violet", color: RGBAColor(red: 0.115786, green: 0.020893, blue: 1.041854), intensity: 1,
               window: (82.1, 64.0, 255.0), control: (99.1, 83.0, 255.0), content: (197.2, 191.2, 255.0)),
        Sample(name: "linen", color: RGBAColor(red: 0.95, green: 0.918, blue: 0.894), intensity: 0.8,
               window: (241.4, 236.1, 232.2), control: (230.4, 225.1, 221.2), content: (250.4, 248.9, 247.3)),
        Sample(name: "peach", color: RGBAColor(red: 0.999888, green: 0.903528, blue: 0.829878), intensity: 1,
               window: (250.9, 232.7, 218.7), control: (238.9, 221.7, 208.7), content: (253.9, 247.6, 243.0)),
        Sample(name: "khaki", color: RGBAColor(red: 0.8049, green: 0.799828, blue: 0.642828), intensity: 0.8,
               window: (217.8, 216.9, 191.3), control: (207.8, 206.9, 182.3), content: (242.7, 242.1, 234.0)),
        Sample(name: "gray", color: RGBAColor(red: 0.5, green: 0.5, blue: 0.5), intensity: 0.8,
               window: (168.0, 168.0, 167.9), control: (160.0, 160.0, 159.9), content: (226.0, 226.0, 226.0)),
        Sample(name: "lilac", color: RGBAColor(red: 0.811421, green: 0.797062, blue: 0.94685), intensity: 0.8,
               window: (218.9, 216.5, 240.9), control: (208.9, 206.5, 229.9), content: (243.0, 242.0, 250.1)),
    ]

    /// A display can show at most 255 per channel; the captures are sRGB, so compare clamped.
    private func assertMatches(_ actual: RGBAColor, _ expected: (Double, Double, Double), within tolerance: Double,
                               _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        func shown(_ v: Double) -> Double { min(max(v, 0), 1) * 255 }
        XCTAssertEqual(shown(actual.red), expected.0, accuracy: tolerance, "\(label) red", file: file, line: line)
        XCTAssertEqual(shown(actual.green), expected.1, accuracy: tolerance, "\(label) green", file: file, line: line)
        XCTAssertEqual(shown(actual.blue), expected.2, accuracy: tolerance, "\(label) blue", file: file, line: line)
    }

    private func palette(_ s: Sample) -> ThemePalette {
        ThemeDerivation.palette(forStyle: ThemeStyle(colors: [s.color], intensity: s.intensity), appearance: .light)
    }

    /// The content area follows the intensity (it is white over the window). Before B242 it was a
    /// fixed blend and the intensity-1 Spaces read 7–11/255 light.
    func testLightContentFollowsTheIntensity() {
        for s in samples {
            assertMatches(palette(s).webPanelBackground, s.content, within: 2.5, "\(s.name) content")
        }
    }

    /// Window and controls over the reference desktop.
    func testLightWindowAndControlsMatchArc() {
        for s in samples {
            let p = palette(s)
            assertMatches(p.windowBackground, s.window, within: 2.5, "\(s.name) window")
            assertMatches(p.controlFill, s.control, within: 3.5, "\(s.name) control")
        }
    }

    /// The painted layer of a picked color keeps its extended components (Arc's layer is extended
    /// sRGB; clamped, the violet's blue read 250 where Arc shows 255).
    func testWideGamutPaintedLayerStaysExtended() {
        let violet = samples[2]
        let p = palette(violet)
        XCTAssertGreaterThan(p.windowThemeLayer.blue, 1, "not clamped to sRGB")
        assertMatches(p.windowShown(over: WindowTranslucency.referenceDesktop), violet.window, within: 2.5, "violet shown")
    }

    /// The painted layer's coverage follows the intensity: over black and white desktops Arc's
    /// window moved 29.4/255 at 0.8 (gray) and 20.4/255 at 1 (violet); a fresh window, flat
    /// backdrops, lossless captures. observed.
    func testPaintedLayerCoverageFollowsTheIntensity() {
        let black = RGBAColor(hex: 0x000000), white = RGBAColor(hex: 0xFFFFFF)
        let readings: [(Sample, over: RGBAColor, (Double, Double, Double))] = [
            (samples[6], black, (141.3, 141.4, 141.3)), (samples[6], white, (170.7, 170.7, 170.7)),
            (samples[2], black, (63.6, 45.5, 240.7)), (samples[2], white, (84.0, 65.8, 255.0)),
        ]
        for (sample, desktop, expected) in readings {
            assertMatches(palette(sample).windowShown(over: desktop), expected, within: 3,
                          "\(sample.name) over \(desktop == black ? "black" : "white")")
        }
    }

    /// The content area is white over the window: 2/3 in light. [07 §8.5d]
    func testLightContentIsTwoThirdsWhiteOverTheWindow() {
        for s in samples {
            let p = palette(s)
            XCTAssertEqual(p.webPanelBackground, ThemeDerivation.contentOverWindow(p.windowBackground, appearance: .light))
        }
    }
}
