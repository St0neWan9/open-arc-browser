import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// B244: Arc in a light window over a uniform #D4D4D4 backdrop (the reference desktop), lossless
/// full-screen captures on an sRGB display, flat areas (std ≤ 0.7/255). The derived fills are read
/// against the window color around them, so they check the rules, not the window model.
/// observed (values); the rules are inferred. [07 §8.5e]
final class SpaceColorB244Tests: XCTestCase {
    private func rgb(_ r: Double, _ g: Double, _ b: Double) -> RGBAColor {
        RGBAColor(red: r / 255, green: g / 255, blue: b / 255)
    }

    private func assertClose(_ actual: RGBAColor, _ expected: RGBAColor, within tolerance: Double, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.red * 255, expected.red * 255, accuracy: tolerance, "\(label) red", file: file, line: line)
        XCTAssertEqual(actual.green * 255, expected.green * 255, accuracy: tolerance, "\(label) green", file: file, line: line)
        XCTAssertEqual(actual.blue * 255, expected.blue * 255, accuracy: tolerance, "\(label) blue", file: file, line: line)
    }

    private struct Reading {
        let name: String
        let window: (Double, Double, Double)
        let control: (Double, Double, Double)
        let separator: (Double, Double, Double)?
        let selectedRow: (Double, Double, Double)?
    }

    /// Light ink: the navy preset at intensity 0.8 and 1, the periwinkle Space at 1.
    private let lightInk: [Reading] = [
        Reading(name: "navy 0.8", window: (149.1, 149.7, 171.3), control: (159.1, 159.7, 179.3),
                separator: (165.2, 165.8, 183.9), selectedRow: (169.1, 169.7, 188.3)),
        Reading(name: "navy 1", window: (134.6, 135.4, 160.8), control: (146.0, 147.0, 169.8),
                separator: (152.6, 153.3, 174.8), selectedRow: (157.6, 158.4, 179.8)),
        Reading(name: "periwinkle 1", window: (124.9, 135.6, 201.0), control: (137.1, 147.0, 206.0),
                separator: nil, selectedRow: (149.95, 158.6, 211.9)),
        Reading(name: "forest 1", window: (85.8, 138.5, 101.4), control: (101.9, 149.5, 116.5),
                separator: nil, selectedRow: nil),
    ]

    /// Dark ink: the sky-blue preset at intensity 0.8 and 1.
    private let darkInk: [Reading] = [
        Reading(name: "sky 0.8", window: (152.8, 202.5, 222.7), control: (145.9, 193.5, 212.7),
                separator: (130.0, 172.6, 189.7), selectedRow: (235.0, 241.0, 243.4)),
        Reading(name: "sky 1", window: (139.1, 197.5, 220.9), control: (133.1, 188.4, 211.0),
                separator: (118.3, 167.4, 187.9), selectedRow: (233.3, 240.3, 243.0)),
    ]

    /// Light ink at both intensities: control + 9.5 % white, separator + 15 %, selected row
    /// mix(·, #F5F5FF, 0.209). Before B244: 11 %, 16 % and 0.222 read 1.3–2.3/255 light.
    func testLightInkFillsAreTheSameAtBothIntensities() {
        for r in lightInk {
            let window = rgb(r.window.0, r.window.1, r.window.2)
            let layers = WindowLayers.derived(lightInk: true)
            assertClose(window.compositing(layers.controlFill), rgb(r.control.0, r.control.1, r.control.2), within: 1.2, "\(r.name) control")
            if let s = r.separator {
                assertClose(window.compositing(layers.separator), rgb(s.0, s.1, s.2), within: 1.0, "\(r.name) separator")
            }
            if let s = r.selectedRow {
                assertClose(window.compositing(layers.selectedRowFill), rgb(s.0, s.1, s.2), within: 1.0, "\(r.name) selected row")
                assertClose(ThemeDerivation.selectedRowFill(window: window, lightInk: true), rgb(s.0, s.1, s.2), within: 1.0,
                            "\(r.name) opaque selected row")
            }
        }
    }

    /// Dark ink at both intensities: control × 0.954, separator × 0.85, selected row
    /// mix(·, #F6F6F6, 0.88). Before B244 the separator (× 0.87) read 3/255 light.
    func testDarkInkFillsAreTheSameAtBothIntensities() {
        for r in darkInk {
            let window = rgb(r.window.0, r.window.1, r.window.2)
            let layers = WindowLayers.derived(lightInk: false)
            assertClose(window.compositing(layers.controlFill), rgb(r.control.0, r.control.1, r.control.2), within: 1.0, "\(r.name) control")
            if let s = r.separator {
                assertClose(window.compositing(layers.separator), rgb(s.0, s.1, s.2), within: 1.0, "\(r.name) separator")
            }
            if let s = r.selectedRow {
                assertClose(ThemeDerivation.selectedRowFill(window: window, lightInk: false), rgb(s.0, s.1, s.2), within: 0.6,
                            "\(r.name) selected row")
            }
        }
    }

    /// Arc's no-color Space: a diagonal wash, linear in t = (x / w + y / h) / 2 up to t ≈ 0.76,
    /// then flat. Sidebar left edge (window) and the content area (window + 2/3 white).
    func testNoColorWashFollowsTheDiagonal() {
        let palette = ThemeDerivation.palette(forStyle: nil, appearance: .light)
        let stops = palette.backgroundGradientColors
        let places = palette.backgroundGradientLocations ?? []
        XCTAssertEqual(stops.count, places.count)
        func wash(_ t: Double) -> RGBAColor {
            guard let i = places.firstIndex(where: { $0 >= t }) else { return stops.last! }
            if i == 0 { return stops[0] }
            let f = (t - places[i - 1]) / (places[i] - places[i - 1])
            return ThemeDerivation.mix(stops[i - 1], stops[i], amount: f)
        }
        let window: [(Double, (Double, Double, Double))] = [
            (0.103, (220.5, 219.6, 242.3)), (0.203, (224.2, 221.3, 240.7)), (0.303, (228.2, 222.9, 238.9)),
            (0.403, (232.1, 224.6, 237.2)), (0.483, (235.1, 225.9, 235.6)),
        ]
        for (t, c) in window {
            assertClose(wash(t), rgb(c.0, c.1, c.2), within: 1.0, "window at t \(t)")
        }
        let content: [(Double, (Double, Double, Double))] = [
            (0.3, (246.0, 244.1, 249.9)), (0.5, (248.4, 245.2, 248.4)), (0.6, (250.0, 246.0, 248.0)),
            (0.7, (251.0, 246.4, 247.0)), (0.8, (251.9, 246.9, 247.0)), (0.9, (251.9, 246.9, 247.0)),
        ]
        for (t, c) in content {
            let shown = ThemeDerivation.contentOverWindow(wash(t), appearance: .light)
            assertClose(shown, rgb(c.0, c.1, c.2), within: 1.0, "content at t \(t)")
        }
        XCTAssertEqual(palette.webPanelLayer, RGBAColor(red: 1, green: 1, blue: 1, alpha: 2.0 / 3), "white over the wash")

        // On screen: the see-through window paints the wash's layers over the material, which
        // shows the live gray over the reference desktop. Inverted against the fitted 219 they
        // read 1.6/255 dark.
        let layers = palette.backgroundGradientLayers
        XCTAssertEqual(layers.count, stops.count)
        let live = ThemeDerivation.lightLiveBackdropGray
        let material = RGBAColor(red: live, green: live, blue: live)
        func shown(_ t: Double) -> RGBAColor {
            let f = min(t / places[1], 1)
            var layer = ThemeDerivation.mix(layers[0], layers[1], amount: f)
            layer.alpha = layers[0].alpha
            return ThemeDerivation.compositeInDisplayP3(layer, over: material)
        }
        for (t, c) in window {
            assertClose(shown(t), rgb(c.0, c.1, c.2), within: 1.0, "on screen at t \(t)")
        }
    }
}

private extension RGBAColor {
    /// `layer` painted over this opaque color (sRGB-encoded source-over).
    func compositing(_ layer: RGBAColor) -> RGBAColor {
        let a = layer.alpha
        return RGBAColor(red: red * (1 - a) + layer.red * a, green: green * (1 - a) + layer.green * a,
                         blue: blue * (1 - a) + layer.blue * a)
    }
}
