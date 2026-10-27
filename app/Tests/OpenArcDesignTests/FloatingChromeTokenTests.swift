import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// Plan B92 (F1 pass 3, P4): the theme bubble's background gradient, the command bar shadow token
/// and the dark command bar's outer line.
/// Spec: docs/arc-spec/07-design-system.md §8.4 finding 3 (gradient stops, observed) and §5
/// (command bar shadow profile and outline, observed; SwiftUI values inferred).
final class FloatingChromeTokenTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    /// [07 §8.4] presets used for the bubble body samples.
    private let presets: [UInt32] = [0xA6729D, 0x6CBAD9, 0xF8D558, 0x35E894]

    private func palette(_ hex: UInt32, dark: Bool) -> ThemePalette {
        ThemeDerivation.palette(for: Theme(id: UUID(), appearance: dark ? .dark : .light, colors: [RGBAColor(hex: hex)], grain: 0, now: t0))
    }

    /// What a fill shows at `opacity` over the neutral backdrop the tint was fitted against.
    private func shown(_ fill: RGBAColor, dark: Bool, opacity: Double) -> RGBAColor {
        ThemeDerivation.mix(dark ? ThemeDerivation.floatingPanelBackdropDark : ThemeDerivation.floatingPanelBackdropLight,
                            fill, amount: opacity)
    }

    private func assertClose(_ a: RGBAColor, _ b: RGBAColor, _ tolerance: Double, _ message: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: tolerance, message, file: file, line: line)
    }

    // MARK: [07 §8.4] finding 3: gradient stops

    /// Three stops in order glow → theme tint → gray, on an axis from the top edge to the bottom
    /// right; the glow sits ≈ 10 pt below the top, the tint at the color board's middle, the gray
    /// at the corner. [07 §8.4] observed positions; axis inferred.
    func testGradientGeometry() {
        let g = palette(0xA6729D, dark: false).floatingPanelGradient()
        XCTAssertEqual(g.stops.count, 3)
        XCTAssertEqual(g.start, UnitPoint2D(x: 0.5, y: 0))
        XCTAssertEqual(g.end, UnitPoint2D(x: 1, y: 1))
        XCTAssertEqual(g.stops.map(\.location), g.stops.map(\.location).sorted(), "stops in order")
        XCTAssertEqual(g.stops[0].location, FloatingPanelGradient.glowLocation)
        XCTAssertGreaterThan(g.stops[0].location, 0)
        XCTAssertLessThan(g.stops[0].location, 0.05, "glow ≈ 10 pt below the top edge")
        XCTAssertEqual(g.stops[1].location, 0.28, accuracy: 0.03, "tint beside the color board's middle")
        XCTAssertEqual(g.stops[2].location, 1, "gray at the bottom-right corner")
        // The projection: the top edge's middle is 0, the bottom-right corner is 1.
        XCTAssertEqual(FloatingPanelGradient.axisLocation(x: 178, y: 0, width: 356, height: 508), 0)
        XCTAssertEqual(FloatingPanelGradient.axisLocation(x: 356, y: 508, width: 356, height: 508), 1)
    }

    /// Over the neutral backdrop, the translucent bubble shows Arc's observed stop colors: the glow
    /// (#FFE8FF light / #4B2046 dark) and the corner gray (#F7F6F7 / #1E1E1E), the same for every
    /// theme; the middle stop is the theme tint (`floatingPanelBackground`, which the bubble body
    /// test pins to Arc's samples). [07 §8.4] finding 3, observed (E8, lossless).
    func testGradientStopsShowObservedColors() {
        let opacity = Metrics.FloatingBubble.tintOpacity
        for hex in presets {
            for dark in [false, true] {
                let p = palette(hex, dark: dark)
                let g = p.floatingPanelGradient()
                let label = String(format: "%06X %@", hex, dark ? "dark" : "light")
                // The light glow's red and blue (255) are out of reach of a 0.82 fill over #EEEEEE:
                // the clamped fill (white) shows 252, 3/255 short.
                assertClose(shown(g.stops[0].color, dark: dark, opacity: opacity),
                            RGBAColor(hex: dark ? 0x4B2046 : 0xFFE8FF), 3.5 / 255, "glow \(label)")
                XCTAssertEqual(g.stops[1].color, p.floatingPanelBackground, "tint \(label)")
                assertClose(shown(g.stops[2].color, dark: dark, opacity: opacity),
                            RGBAColor(hex: dark ? 0x1E1E1E : 0xF7F6F7), 1.5 / 255, "corner \(label)")
            }
        }
        // Glow and corner do not follow the theme.
        let a = palette(presets[0], dark: false).floatingPanelGradient(), b = palette(presets[1], dark: false).floatingPanelGradient()
        XCTAssertEqual(a.stops[0], b.stops[0])
        XCTAssertEqual(a.stops[2], b.stops[2])
        XCTAssertNotEqual(a.stops[1], b.stops[1])
    }

    /// On an opaque surface (opacity 1) the stops are the observed colors themselves, and the tint
    /// stop shows what the translucent tint shows. [07 §8.4] finding 3.
    func testOpaqueGradientStops() {
        for dark in [false, true] {
            let p = palette(0x6CBAD9, dark: dark)
            let g = p.floatingPanelGradient(opacity: 1)
            assertClose(g.stops[0].color, RGBAColor(hex: dark ? 0x4B2046 : 0xFFE8FF), 1e-9, "glow")
            assertClose(g.stops[2].color, RGBAColor(hex: dark ? 0x1E1E1E : 0xF7F6F7), 1e-9, "corner")
            assertClose(g.stops[1].color, shown(p.floatingPanelBackground, dark: dark, opacity: Metrics.FloatingBubble.tintOpacity),
                        1e-9, "tint as shown")
            XCTAssertTrue(g.stops.allSatisfy { $0.color.alpha == 1 })
        }
    }

    /// `fill(showing:over:opacity:)` inverts source-over; colors out of reach clamp to 0...1.
    func testFillInvertsSourceOver() {
        let backdrop = RGBAColor(hex: 0xEEEEEE)
        let target = RGBAColor(hex: 0xF7F6F7)
        let fill = ThemeDerivation.fill(showing: target, over: backdrop, opacity: 0.82)
        assertClose(ThemeDerivation.mix(backdrop, fill, amount: 0.82), target, 1e-9, "round trip")
        let clamped = ThemeDerivation.fill(showing: RGBAColor(hex: 0x000000), over: backdrop, opacity: 0.5)
        XCTAssertEqual(clamped.red, 0)
    }

    // MARK: [07 §5]: command bar shadow and outline

    /// The token holds SwiftUI `.shadow` values calibrated on screen against Arc's measured profile
    /// (edge −21 / −13 / −31 %, half-decay 32 / 21 / 43 pt), not the "blur 48" guess halved.
    /// [07 §5] observed profile, inferred values.
    func testCommandBarShadowToken() {
        let s = Metrics.CommandBar.shadow
        XCTAssertEqual(s.opacity, 0.52)
        XCTAssertEqual(s.radius, 47)
        XCTAssertEqual(s.offsetY, 26)
        XCTAssertEqual(s.offsetX, 0)
    }

    /// Light: one outer hairline (black ≈ 25 %); dark: the inner ≈ #565656 line plus an outer
    /// near-black line. [07 §5] observed.
    func testCommandBarOutlines() {
        let light = palette(0x6CBAD9, dark: false), dark = palette(0x6CBAD9, dark: true)
        XCTAssertEqual(light.commandBarOutline, RGBAColor(hex: 0x000000, alpha: 0.25))
        XCTAssertNil(light.commandBarOuterOutline)
        XCTAssertEqual(dark.commandBarOutline, RGBAColor(hex: 0x565656))
        let outer = try? XCTUnwrap(dark.commandBarOuterOutline)
        XCTAssertNotNil(outer)
        XCTAssertLessThan(ThemeDerivation.luminance(outer ?? RGBAColor(hex: 0xFFFFFF)), 0.01, "near black")
        XCTAssertGreaterThan(outer?.alpha ?? 0, 0.5)
    }
}
