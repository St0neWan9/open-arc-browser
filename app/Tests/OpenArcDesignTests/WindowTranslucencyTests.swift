import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// Plan B64: the see-through window. Spec: docs/arc-spec/07-design-system.md §8.4 (E8) and
/// design-tokens.json `ThemeDerivation.windowTranslucency`: window, sidebar, controls and
/// separators at ≈ 0.886 (light) / 0.812 (dark) over the blurred desktop (observed); content,
/// command bar and bubbles opaque (observed); the opaque palette equals Arc over an ≈ 83 % gray
/// desktop (inferred reference).
final class WindowTranslucencyTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func palette(_ hex: UInt32, _ appearance: ResolvedAppearance) -> ThemePalette {
        let theme = Theme(id: UUID(), appearance: appearance == .dark ? .dark : .light, colors: [RGBAColor(hex: hex)], now: t0)
        return ThemeDerivation.palette(for: theme, systemAppearance: .light)
    }

    private func maxDifference(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
    }

    private func assertWithin(_ a: RGBAColor, _ b: RGBAColor, levels: Double, _ message: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThanOrEqual(maxDifference(a, b) * 255, levels, message, file: file, line: line)
    }

    /// The 36 E12 presets ([07 §8.1] table) and the E8 first-page presets with the navy light-ink
    /// one ([07 §8.4]).
    private let presets: [UInt32] = [
        0xF1EBE5, 0xF19CBB, 0xA5729C, 0xF25E6C, 0xFF8557, 0xF8D55A, 0x35E896, 0x6CBAD9, 0x666789,
        0xFFFBFA, 0xFEE9F3, 0xF1D2ED, 0xFFCBD0, 0xFFE1D3, 0xFFF9E4, 0xDEFDEC, 0xDBF3FB, 0xC5C6E5,
        0x4E3A5A, 0x683557, 0x8F4144, 0xAF6D40, 0xD7B35F, 0xCDCCA3, 0x79AA82, 0x226148, 0x27476C,
        0xFFFFFF, 0xE6E6E6, 0xCCCCCC, 0xB2B2B2, 0x7F7F7F, 0x666666, 0x333333, 0x191919, 0x010101,
        0xF3EAE4, 0xF29CBA, 0xA6729D, 0xF25E6B, 0xF8D558, 0x35E894,
    ]

    // MARK: Opacity per appearance

    /// [07 §8.4] observed: ≈ 0.886 light, ≈ 0.812 dark (black / white backdrops differ by 29 and
    /// 48 levels).
    func testOpacityPerAppearance() {
        XCTAssertEqual(WindowTranslucency.opacity(for: .light), 0.886)
        XCTAssertEqual(WindowTranslucency.opacity(for: .dark), 0.812)
        XCTAssertEqual(palette(0xA5729C, .light).windowOpacity, 0.886)
        XCTAssertEqual(palette(0xA5729C, .dark).windowOpacity, 0.812)
        XCTAssertTrue(palette(0xA5729C, .light).isWindowTranslucent)
        // Black vs white backdrop: (1 − α) × 255 = 29 / 48 levels, the E8 readings.
        for (appearance, levels) in [(ResolvedAppearance.light, 29.0), (.dark, 48.0)] {
            let p = palette(0x6CBAD9, appearance)
            let overWhite = WindowTranslucency.composite(p.windowTint, over: RGBAColor(hex: 0xFFFFFF))
            let overBlack = WindowTranslucency.composite(p.windowTint, over: RGBAColor(hex: 0x000000))
            for (w, b) in [(overWhite.red, overBlack.red), (overWhite.green, overBlack.green), (overWhite.blue, overBlack.blue)] {
                XCTAssertEqual((w - b) * 255, levels, accuracy: 0.5, "[07 §8.4] \(appearance.rawValue)")
            }
        }
    }

    // MARK: Composite over the reference reproduces the opaque (E8 / E12) palette

    /// [07 §8.4]: the window tint at α over the ≈ 83 % gray reference desktop shows the opaque
    /// window color (the E12 / E8 fit) within 1/255, for every measured preset, light and dark.
    func testWindowTintOverReferenceReproducesThePalette() {
        for hex in presets {
            for appearance in ResolvedAppearance.allCases {
                let p = palette(hex, appearance)
                let label = String(format: "%06X %@", hex, appearance.rawValue)
                XCTAssertEqual(p.windowTint.alpha, p.windowOpacity, label)
                XCTAssertTrue(WindowTranslucency.canShow(p.windowBackground, opacity: p.windowOpacity), "in gamut \(label)")
                let shown = WindowTranslucency.composite(p.windowTint, over: WindowTranslucency.referenceDesktop)
                assertWithin(shown, p.windowBackground, levels: 1, "window \(label)")
                for (tint, color) in zip(p.backgroundGradientTints, p.backgroundGradientColors) {
                    assertWithin(WindowTranslucency.composite(tint, over: WindowTranslucency.referenceDesktop), color, levels: 1, "stop \(label)")
                }
            }
        }
    }

    /// [07 §8.4] layer split: control, separator, selected row and scroll-edge line drawn as layers
    /// over the see-through window land on the opaque palette colors over the reference, within 1/255.
    func testWindowLayersOverReferenceReproduceThePalette() {
        for hex in presets {
            for appearance in ResolvedAppearance.allCases {
                let p = palette(hex, appearance)
                let label = String(format: "%06X %@", hex, appearance.rawValue)
                let window = WindowTranslucency.composite(p.windowTint, over: WindowTranslucency.referenceDesktop)
                let layers = p.windowLayers
                assertWithin(WindowTranslucency.composite(layers.controlFill, over: window), p.controlFill, levels: 1, "control \(label)")
                assertWithin(WindowTranslucency.composite(layers.separator, over: window), p.separator, levels: 1, "separator \(label)")
                assertWithin(WindowTranslucency.composite(layers.selectedRowFill, over: window), p.selectedTabFill, levels: 1, "selected row \(label)")
                assertWithin(WindowTranslucency.composite(layers.scrollEdgeLine, over: window), p.scrollEdgeLine, levels: 1, "scroll edge \(label)")
            }
        }
    }

    /// [07 §8.4] observed layer amounts: dark ink control + 4 % black, separator + 13 % black
    /// (E8 13.5 %, rule × 0.87), selected row + 89 % #F7F7F7; light ink + 11 % / + 16 % white.
    func testLayerAmountsFollowE8() {
        let dark = WindowLayers.derived(lightInk: false)
        XCTAssertEqual(dark.controlFill, RGBAColor(hex: 0x000000, alpha: 1 - 0.96))
        XCTAssertEqual(dark.separator.alpha, 0.13, accuracy: 1e-9)
        XCTAssertEqual(dark.selectedRowFill, RGBAColor(hex: 0xF7F7F7, alpha: 0.894))
        let light = WindowLayers.derived(lightInk: true)
        XCTAssertEqual(light.controlFill, RGBAColor(hex: 0xFFFFFF, alpha: 0.11))
        XCTAssertEqual(light.separator, RGBAColor(hex: 0xFFFFFF, alpha: 0.16))
        XCTAssertEqual(palette(0x666789, .dark).windowLayers, light, "navy p1-9 uses light ink [07 §8.3]")
    }

    // MARK: Opaque surfaces

    /// [07 §8.4] observed: the content area, the command bar and the theme bubble are opaque; they
    /// keep their colors (alpha 1), whatever the window does.
    func testContentCommandBarAndBubbleStayOpaque() {
        for appearance in ResolvedAppearance.allCases {
            let p = palette(0xA5729C, appearance)
            XCTAssertEqual(p.webPanelBackground.alpha, 1)
            XCTAssertEqual(p.commandBarBackground.alpha, 1)
            XCTAssertEqual(p.floatingPanelBackground.alpha, 1)
        }
    }

    /// Incognito ([06 §20.1] #0C0F14) is darker than an 81 % tint can show over the reference, and
    /// Arc's incognito translucency was not measured: an opaque window with opaque layers.
    func testIncognitoWindowIsOpaque() {
        for appearance in ResolvedAppearance.allCases {
            let p = ThemeDerivation.incognitoPalette(appearance: appearance)
            XCTAssertFalse(p.isWindowTranslucent, appearance.rawValue)
            XCTAssertEqual(p.windowTint, p.windowBackground)
            XCTAssertEqual(p.windowLayers.controlFill, p.controlFill)
            XCTAssertEqual(p.windowLayers.selectedRowFill, p.selectedTabFill)
        }
        let dark = ThemeDerivation.incognitoPalette(appearance: .dark)
        XCTAssertFalse(WindowTranslucency.canShow(dark.windowBackground, opacity: WindowTranslucency.darkOpacity))
    }

    // MARK: Solve

    /// Solving composite = α·c + (1 − α)·backdrop for c, clamped to the gamut.
    func testTintSolveAndClamp() {
        let target = RGBAColor(hex: 0x9ACBE0)
        let tint = WindowTranslucency.tint(showing: target, opacity: 0.886)
        assertWithin(WindowTranslucency.composite(tint, over: WindowTranslucency.referenceDesktop), target, levels: 1e-9, "round trip")
        XCTAssertEqual(WindowTranslucency.tint(showing: target, opacity: 1), target, "opaque = the color itself")
        // Pure black cannot be shown over a light desktop: clamped to 0, shows the desktop's share.
        let black = WindowTranslucency.tint(showing: RGBAColor(hex: 0x000000), opacity: 0.812)
        XCTAssertEqual(black.red, 0)
        XCTAssertFalse(WindowTranslucency.canShow(RGBAColor(hex: 0x000000), opacity: 0.812))
        XCTAssertFalse(WindowTranslucency.canShow(RGBAColor(hex: 0xFFFFFF), opacity: 0.886))
    }

    // MARK: Readability over any wallpaper

    /// The window stays readable over a white, a black and saturated wallpapers: at most 19 % of
    /// the desktop comes through ([07 §8.4]), so the row titles keep at least `minimumShare` of the
    /// contrast they have over the reference desktop (the look Arc's palette was fitted on), and
    /// never drop below `minimumContrast`. inferred bounds (worst case over these presets and
    /// wallpapers when written: 0.58 of the reference contrast, contrast 2.2).
    func testRowTextStaysReadableOverAnyWallpaper() {
        let minimumShare = 0.55, minimumContrast = 2.0
        let wallpapers: [UInt32] = [0xFFFFFF, 0x000000, 0xFF0000, 0x00FF00, 0x0000FF, 0xFF00FF, 0x808080]
        for hex in presets {
            for appearance in ResolvedAppearance.allCases {
                let p = palette(hex, appearance)
                func contrast(over wallpaper: RGBAColor) -> Double {
                    let window = WindowTranslucency.composite(p.windowTint, over: wallpaper)
                    return ThemeDerivation.contrast(WindowTranslucency.composite(p.rowTitleText, over: window), window)
                }
                let reference = contrast(over: WindowTranslucency.referenceDesktop)
                for wallpaper in wallpapers {
                    let ratio = contrast(over: RGBAColor(hex: wallpaper))
                    let label = String(format: "%06X %@ over %06X", hex, appearance.rawValue, wallpaper)
                    XCTAssertGreaterThanOrEqual(ratio / reference, minimumShare, label)
                    XCTAssertGreaterThanOrEqual(ratio, minimumContrast, label)
                }
            }
        }
    }

    /// Over a black wallpaper the window darkens by at most (1 − α) of its value and over white it
    /// lightens by at most (1 − α) of the remainder: ≈ 11 % / 19 %. [07 §8.4] observed ("a dark
    /// wallpaper makes the sidebar ≈ 10 % darker").
    func testWallpaperShiftIsBounded() {
        for appearance in ResolvedAppearance.allCases {
            let p = palette(0xF8D55A, appearance)
            let overBlack = WindowTranslucency.composite(p.windowTint, over: RGBAColor(hex: 0x000000))
            let shift = 1 - ThemeDerivation.luminance(overBlack) / ThemeDerivation.luminance(p.windowBackground)
            XCTAssertGreaterThan(shift, 0)
            XCTAssertLessThan(shift, appearance == .dark ? 0.45 : 0.30, "relative luminance drop over black, \(appearance.rawValue)")
        }
    }
}
