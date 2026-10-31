import XCTest
import OpenArcModel
@testable import OpenArcDesign

/// Plan B21 / B16: light / dark / automatic palettes and the grain texture.
/// Spec: docs/arc-spec/07-design-system.md §8 (E11): sample colors observed (JPEG, ±2/255 on flat
/// fills; text colors from AX), the derivation rules inferred. Supersedes the 04 §dark mode (E7) fit.
final class ThemeAppearanceTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private let purple = RGBAColor(hex: 0x6B4FD8)

    private func theme(_ appearance: ThemeAppearance, colors: [RGBAColor]? = nil, grain: Double = 0) -> Theme {
        Theme(id: UUID(), appearance: appearance, colors: colors ?? [purple], grain: grain, now: t0)
    }

    private func assertClose(_ a: RGBAColor, _ b: RGBAColor, tolerance: Double = 1e-9, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.red, b.red, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.green, b.green, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.blue, b.blue, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(a.alpha, b.alpha, accuracy: tolerance, message, file: file, line: line)
    }

    // MARK: Resolution ([04 §dark mode]: automatic follows the system appearance)

    func testAutomaticFollowsTheInjectedSystemAppearance() {
        XCTAssertEqual(ThemeDerivation.resolve(.automatic, system: .light), .light)
        XCTAssertEqual(ThemeDerivation.resolve(.automatic, system: .dark), .dark)
        XCTAssertEqual(ThemeDerivation.resolve(.light, system: .dark), .light)
        XCTAssertEqual(ThemeDerivation.resolve(.dark, system: .light), .dark)

        let auto = theme(.automatic)
        XCTAssertEqual(ThemeDerivation.palette(for: auto, systemAppearance: .light), ThemeDerivation.palette(for: auto, appearance: .light))
        XCTAssertEqual(ThemeDerivation.palette(for: auto, systemAppearance: .dark), ThemeDerivation.palette(for: auto, appearance: .dark))
        XCTAssertEqual(ThemeDerivation.palette(for: nil, systemAppearance: .dark).appearance, .dark, "no theme = automatic")
        XCTAssertEqual(ThemeDerivation.palette(for: theme(.light), systemAppearance: .dark).appearance, .light)
        XCTAssertEqual(ThemeDerivation.palette(for: theme(.dark), systemAppearance: .light).appearance, .dark)
    }

    // MARK: E11 samples ([07 §8] observed values; rules inferred)

    /// The three preset samples of [07 §8]: window, control, separator, selected row, row text and
    /// command bar selection, light and dark. Flat fills are JPEG measurements (±2/255); the rules
    /// were fitted to them, so each must land within a few levels.
    func testE11SamplesAreReproduced() {
        struct Sample {
            var theme: UInt32
            var appearance: ResolvedAppearance
            var window: UInt32, control: UInt32, separator: UInt32, selectedRow: UInt32
            var rowText: UInt32?
            var commandBarSelection: UInt32?
        }
        let samples = [
            Sample(theme: 0xA5729C, appearance: .light, window: 0xBF9EB8, control: 0xB897B2, separator: 0xA987A2, selectedRow: 0xF0EDF0, rowText: 0x2F1F2C, commandBarSelection: 0xBAA5B6),
            Sample(theme: 0xF8D55A, appearance: .light, window: 0xF5DD8F, control: 0xEAD48A, separator: 0xD6BF70, selectedRow: 0xF8F5EC, rowText: 0x2D2200),
            Sample(theme: 0x6CBAD9, appearance: .light, window: 0x9ACBE0, control: 0x94C3D7, separator: 0x7EB2C5, selectedRow: 0xECF3F4, rowText: 0x002632, commandBarSelection: 0x7FAFBC),
            Sample(theme: 0xF8D55A, appearance: .dark, window: 0xDFC87F, control: 0xD6C079, separator: 0xC5AD62, selectedRow: 0xF4F2EA, rowText: 0x2D2200, commandBarSelection: 0x776621),
            Sample(theme: 0x6CBAD9, appearance: .dark, window: 0x87B7CB, control: 0x83B1C3, separator: 0x71A1B3, selectedRow: 0xEBEFF1, rowText: 0x002632, commandBarSelection: 0x2E6C80),
        ]
        for s in samples {
            let palette = ThemeDerivation.palette(for: theme(s.appearance == .dark ? .dark : .light, colors: [RGBAColor(hex: s.theme)]))
            let label = String(format: "%06X %@", s.theme, s.appearance.rawValue)
            // [07 §8.2]: both window rules stay within 3.1/255 on the E12 table.
            assertClose(palette.windowBackground, RGBAColor(hex: s.window), tolerance: 3.5 / 255, "window \(label)")
            assertClose(palette.controlFill, RGBAColor(hex: s.control), tolerance: 4.0 / 255, "control \(label)")
            // Separator = window × 0.87 [07 §8]: Arc's yellow line is × 0.77 on blue, so up to ≈ 14/255 off.
            assertClose(palette.separator, RGBAColor(hex: s.separator), tolerance: 15.0 / 255, "separator \(label)")
            assertClose(palette.selectedTabFill, RGBAColor(hex: s.selectedRow), tolerance: 4.0 / 255, "selected row \(label)")
            if let rowText = s.rowText {
                assertClose(palette.primaryText, RGBAColor(hex: rowText), tolerance: 12.0 / 255, "row text \(label)")
                XCTAssertEqual(palette.selectedTabText, palette.primaryText, "the title color does not change on selection")
            }
            if let selection = s.commandBarSelection {
                // The chroma rule is unknown [07 §8]: pinned loosely. Separators are thin lines measured on a
                // JPEG; [07 §8] notes their larger error.
                assertClose(palette.commandBarSelection, RGBAColor(hex: selection), tolerance: 24.0 / 255, "command bar selection \(label)")
            }
        }
    }

    /// The theme bubble body [07 §8.4] (E8, lossless): our tint at `Metrics.FloatingBubble.tintOpacity`
    /// over Arc's neutral backdrop (#EEEEEE light, #1E1E1E dark) lands on Arc's bubble beside the color
    /// board. observed samples, inferred rule (max 3.4 / 7.1 per channel over 9 presets).
    func testThemeBubbleBodySamples() {
        let samples: [(theme: UInt32, light: UInt32, dark: UInt32)] = [
            (0xA6729D, 0xFEF2F9, 0x322830), (0x6CBAD9, 0xECF7FD, 0x263036),
            (0xF8D558, 0xFFF5DF, 0x3A321D), (0x35E894, 0xE1FCED, 0x1E3629),
        ]
        let opacity = Metrics.FloatingBubble.tintOpacity
        for s in samples {
            for (appearance, arc, backdrop) in [(ThemeAppearance.light, s.light, 0xEEEEEE as UInt32), (.dark, s.dark, 0x1E1E1E)] {
                let tint = ThemeDerivation.palette(for: theme(appearance, colors: [RGBAColor(hex: s.theme)])).floatingPanelBackground
                let shown = ThemeDerivation.mix(RGBAColor(hex: backdrop), tint, amount: opacity)
                assertClose(shown, RGBAColor(hex: arc), tolerance: 8.0 / 255, String(format: "bubble %06X %@", s.theme, appearance.rawValue))
            }
        }
    }

    /// E8 lossless samples [07 §8.4]: Arc composited over a mid-gray desktop (the reference the
    /// opaque palette stands for), sRGB from ⇧⌘3 PNGs of the display profile. observed values; the
    /// rules (inferred) must stay within the stated bounds.
    func testE8LosslessSamplesAreReproduced() {
        struct Sample { var theme: UInt32; var dark: Bool; var window, control, separator, selected: UInt32; var rowText: UInt32? }
        let samples = [
            Sample(theme: 0xF3EAE4, dark: false, window: 0xF0EBE7, control: 0xE6E1DD, separator: 0xD0CCC8, selected: 0xF7F6F6, rowText: 0x2E2014),
            Sample(theme: 0xF3EAE4, dark: true, window: 0xDBD6D2, control: 0xD3CDCA, separator: 0xBEBAB6, selected: 0xF4F4F3),
            Sample(theme: 0xF29CBA, dark: false, window: 0xF0B8CC, control: 0xE6B1C4, separator: 0xD0A0B1, selected: 0xF7F0F2, rowText: 0x440B22),
            Sample(theme: 0xF29CBA, dark: true, window: 0xDCA4B8, control: 0xD39EB1, separator: 0xBF8EA0, selected: 0xF4EEF0),
            Sample(theme: 0xA6729D, dark: false, window: 0xBF9EBA, control: 0xB898B2, separator: 0xA689A1, selected: 0xF1EDF0, rowText: 0x2F1F2C),
            Sample(theme: 0xA6729D, dark: true, window: 0xAB8BA5, control: 0xA5869F, separator: 0x94788F, selected: 0xEFEBEE),
            Sample(theme: 0xF25E6B, dark: false, window: 0xF0929A, control: 0xE68D94, separator: 0xD17E85, selected: 0xF7ECED, rowText: 0x480409),
            Sample(theme: 0xF25E6B, dark: true, window: 0xDC8087, control: 0xD37B82, separator: 0xC06F75, selected: 0xF5EAEB),
            Sample(theme: 0xFF8557, dark: false, window: 0xF8AA8E, control: 0xEEA389, separator: 0xD8937B, selected: 0xF8EFEC, rowText: 0x421200),
            Sample(theme: 0xFF8557, dark: true, window: 0xE4977D, control: 0xDB9178, separator: 0xC6826B, selected: 0xF5ECEA),
            Sample(theme: 0xF8D558, dark: false, window: 0xF4DD8F, control: 0xEAD48A, separator: 0xD4C07B, selected: 0xF7F4EC, rowText: 0x2D2200),
            Sample(theme: 0xF8D558, dark: true, window: 0xDFC87E, control: 0xD6C179, separator: 0xC2AE6D, selected: 0xF5F2EA),
            Sample(theme: 0x35E894, dark: false, window: 0x7CE9B5, control: 0x78E0AD, separator: 0x6BCA9C, selected: 0xEAF6F0, rowText: 0x00280E),
            Sample(theme: 0x35E894, dark: true, window: 0x73D5A1, control: 0x6FCC9B, separator: 0x63B88B, selected: 0xE9F3ED),
            Sample(theme: 0x6CBAD9, dark: false, window: 0x9BCCE0, control: 0x95C4D7, separator: 0x86B0C2, selected: 0xEDF2F4, rowText: 0x002632),
            Sample(theme: 0x6CBAD9, dark: true, window: 0x89B7CB, control: 0x84B0C3, separator: 0x769FB0, selected: 0xEBF0F2),
            // Navy p1-9: light ink.
            Sample(theme: 0x666789, dark: false, window: 0x9797AD, control: 0xA1A2B5, separator: 0xA7A8B9, selected: 0xACACBE),
            Sample(theme: 0x666789, dark: true, window: 0x848499, control: 0x9091A4, separator: 0x9798A9, selected: 0x9D9DAE),
        ]
        for s in samples {
            let palette = ThemeDerivation.palette(for: theme(s.dark ? .dark : .light, colors: [RGBAColor(hex: s.theme)]))
            let label = String(format: "%06X %@", s.theme, s.dark ? "dark" : "light")
            assertClose(palette.windowBackground, RGBAColor(hex: s.window), tolerance: 4.5 / 255, "window \(label)")
            assertClose(palette.controlFill, RGBAColor(hex: s.control), tolerance: 4.5 / 255, "control \(label)")
            assertClose(palette.separator, RGBAColor(hex: s.separator), tolerance: 4.5 / 255, "separator \(label)")
            assertClose(palette.selectedTabFill, RGBAColor(hex: s.selected), tolerance: 2.5 / 255, "selected row \(label)")
            if let rowText = s.rowText {
                assertClose(palette.primaryText, RGBAColor(hex: rowText), tolerance: 11.0 / 255, "row text \(label)")
            }
        }
    }

    // MARK: Light

    func testLightPaletteValues() {
        let palette = ThemeDerivation.palette(for: theme(.light), systemAppearance: .dark)
        XCTAssertEqual(palette, ThemeDerivation.palette(for: theme(.automatic)), "the default (light system) is the same palette")
        XCTAssertEqual(palette.windowBackground, ThemeDerivation.lightWindow(purple))
        XCTAssertEqual(palette.commandBarBackground, RGBAColor(hex: 0xF9F9F9), "[07 §5] observed")
        XCTAssertEqual(palette.commandBarSeparator, RGBAColor(hex: 0xE1E1E1), "[07 §5] observed")
        XCTAssertEqual(palette.commandBarInputText, RGBAColor(hex: 0x101214, alpha: 0.8), "[07 §3] observed")
        XCTAssertEqual(palette.commandBarText, RGBAColor(hex: 0x000000, alpha: 0.8), "[07 §3] observed")
        XCTAssertEqual(palette.commandBarSecondaryText, RGBAColor(hex: 0x000000, alpha: 0.33), "[07 §3] observed")
        XCTAssertEqual(palette.commandBarArrowBoxFill, RGBAColor(hex: 0x000000, alpha: 0.04), "[07 §5] observed")
        XCTAssertEqual(palette.commandBarSelectedText, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(palette.dialogBackground, RGBAColor(hex: 0xFAFBFF), "[07 §6] observed")
        XCTAssertEqual(palette.webPanelBackground, ThemeDerivation.contentBackground(purple, appearance: .light), "[07 §8.1] light: tinted, not white")
        XCTAssertNotEqual(palette.webPanelBackground, RGBAColor(hex: 0xFFFFFF))
        XCTAssertFalse(palette.isDark)
    }

    // MARK: Dark ([07 §8] observed samples)

    /// The dark window is the theme layer over a black veil on the reference backdrop [07 §8.2]
    /// (B146): the theme color itself, darker than the light window, not black; the empty web panel
    /// shows its own tint.
    func testDarkWindowIsTheDarkThemeLayer() {
        let palette = ThemeDerivation.palette(for: theme(.dark), systemAppearance: .light)
        XCTAssertTrue(palette.isDark)
        assertClose(palette.windowBackground, ThemeDerivation.windowColor(purple, appearance: .dark, strength: ThemeDerivation.darkThemeStrength,
                                                                          backdropGray: ThemeDerivation.darkWindowBackdropGray))
        XCTAssertEqual(palette.windowBackground, ThemeDerivation.darkVariant(purple))
        XCTAssertLessThan(ThemeDerivation.luminance(palette.windowBackground), ThemeDerivation.luminance(ThemeDerivation.lightWindow(purple)))
        let light = HSV(ThemeDerivation.lightWindow(purple)), dark = HSV(palette.windowBackground)
        XCTAssertEqual(dark.hue, light.hue, accuracy: 0.03, "same hue family")
        XCTAssertGreaterThan(dark.saturation, 0.2, "not desaturated")
        XCTAssertGreaterThan(ThemeDerivation.luminance(palette.windowBackground), 0.12, "not black")
        XCTAssertEqual(palette.webPanelBackground, ThemeDerivation.contentBackground(purple, appearance: .dark), "[07 §8.1] dark: tinted, not black")
        XCTAssertGreaterThan(ThemeDerivation.luminance(palette.webPanelBackground), ThemeDerivation.luminance(palette.windowBackground), "a little lighter than the dark window")
        XCTAssertEqual(palette.backgroundGradientColors, [palette.windowBackground])
        // #6B4FD8 (luminance 0.14) is a light-ink theme [07 §8.3]: controls are window + 11 % white.
        XCTAssertTrue(palette.usesLightInk)
        XCTAssertEqual(palette.controlFill, ThemeDerivation.overlayWhite(palette.windowBackground, amount: ThemeDerivation.lightInkControlWhite))
    }

    /// On a dark-ink theme sidebar text stays dark in a dark Space (the AX title color is the same)
    /// and the selected row stays near white. [07 §8, §8.3] observed (E11 purple preset).
    func testDarkSidebarKeepsDarkTextAndLightSelection() {
        let e11Purple = [RGBAColor(hex: 0xA5729C)]
        let palette = ThemeDerivation.palette(for: theme(.dark, colors: e11Purple), systemAppearance: .light)
        XCTAssertFalse(palette.usesLightInk)
        XCTAssertEqual(palette.primaryText, ThemeDerivation.palette(for: theme(.light, colors: e11Purple)).primaryText)
        XCTAssertGreaterThan(ThemeDerivation.luminance(palette.selectedTabFill), 0.8)
        XCTAssertEqual(palette.secondaryText.alpha, 0.45, accuracy: 1e-9)
    }

    /// Command bar in dark: #181818 panel, near-white input, white ≈ 85 % titles, white ≈ 42 %
    /// subtitles, #363636 separator; selection is a mid tone of the theme with white text. [07 §3, §5, §8] observed.
    func testDarkCommandBarColors() {
        let palette = ThemeDerivation.palette(for: theme(.dark), systemAppearance: .light)
        XCTAssertEqual(palette.commandBarBackground, RGBAColor(hex: 0x181818))
        XCTAssertEqual(palette.commandBarSeparator, RGBAColor(hex: 0x363636))
        XCTAssertEqual(palette.commandBarInputText, RGBAColor(hex: 0xF0F5F7))
        XCTAssertEqual(palette.commandBarText.alpha, 0.85, accuracy: 1e-9)
        XCTAssertEqual(palette.commandBarSecondaryText.alpha, 0.42, accuracy: 1e-9)
        XCTAssertEqual(palette.commandBarSelectedText, RGBAColor(hex: 0xFFFFFF))
        let selection = ThemeDerivation.luminance(palette.commandBarSelection)
        XCTAssertLessThan(selection, ThemeDerivation.luminance(palette.windowBackground))
        XCTAssertGreaterThan(selection, ThemeDerivation.luminance(palette.commandBarBackground))
        XCTAssertGreaterThan(ThemeDerivation.contrast(palette.commandBarSelection, palette.commandBarSelectedText), 3)
    }

    /// Floating panels and sheets go dark with light ink. [07 §6] observed (#171C30 sheets).
    func testDarkFloatingPanelsAndSheets() {
        let palette = ThemeDerivation.palette(for: theme(.dark), systemAppearance: .light)
        XCTAssertLessThan(ThemeDerivation.luminance(palette.floatingPanelBackground), 0.2)
        XCTAssertEqual(palette.floatingPanelInk, RGBAColor(hex: 0xFFFFFF))
        XCTAssertLessThan(palette.floatingPanelSelection.alpha, 1)
        XCTAssertEqual(palette.dialogBackground, RGBAColor(hex: 0x171C30))
        XCTAssertEqual(palette.dialogInk, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(palette.dialogSecondaryButtonFill, RGBAColor(hex: 0x312E64))
        XCTAssertEqual(palette.dialogDestructiveFill, RGBAColor(hex: 0xF43616))
    }

    /// A very dark color still gets readable sidebar text: white wins when the theme's dark text
    /// would have less contrast (inferred), and the chrome ink switches to white with it.
    func testVeryDarkColorUsesLightText() {
        let palette = ThemeDerivation.palette(for: theme(.light, colors: [RGBAColor(hex: 0x1F1F24)]))
        XCTAssertEqual(palette.primaryText, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(palette.chromeInk, RGBAColor(hex: 0xFFFFFF))
    }

    /// Several dots: every gradient stop gets the dark mapping, in order.
    func testDarkGradientMapsEveryDot() {
        let b = RGBAColor(hex: 0xE0533F)
        let palette = ThemeDerivation.palette(for: theme(.dark, colors: [purple, b]), systemAppearance: .light)
        XCTAssertEqual(palette.backgroundGradientColors, [ThemeDerivation.darkVariant(purple), ThemeDerivation.darkVariant(b)])
    }

    /// OKLCH round trip (used by the row text and selection rules).
    func testOKLCHRoundTrip() {
        for hex: UInt32 in [0xA5729C, 0xF8D55A, 0x6CBAD9, 0x2F1F2C, 0xFFFFFF, 0x000000] {
            let c = RGBAColor(hex: hex)
            assertClose(OKLCH(c).rgb(alpha: 1), c, tolerance: 1e-6)
        }
    }

    // MARK: Light or dark ink (B32)

    /// The three presets of [07 §8] keep dark ink: the theme's dark row text, black chrome text at
    /// the [07 §3] AX opacities, controls darker than the window, the [07 §8.1] content tint.
    func testPresetsUseDarkInk() {
        for hex: UInt32 in [0xA5729C, 0xF8D55A, 0x6CBAD9] {
            for appearance in [ThemeAppearance.light, .dark] {
                let palette = ThemeDerivation.palette(for: theme(appearance, colors: [RGBAColor(hex: hex)]), systemAppearance: .light)
                let label = String(format: "%06X %@", hex, appearance.rawValue)
                XCTAssertFalse(palette.usesLightInk, label)
                XCTAssertEqual(palette.chromeInk, RGBAColor(hex: 0x000000), label)
                XCTAssertEqual(palette.inkOpacity, .darkInk, label)
                XCTAssertLessThan(ThemeDerivation.luminance(palette.controlFill), ThemeDerivation.luminance(palette.windowBackground), label)
                XCTAssertEqual(palette.webPanelBackground, ThemeDerivation.contentBackground(RGBAColor(hex: hex), appearance: palette.appearance), label)
            }
        }
        // [07 §3] observed AX opacities: address 60 %, Space name 45 %, New Tab 30 %.
        let ink = ChromeInkOpacities.darkInk
        XCTAssertEqual(ink.addressText, 0.60, accuracy: 1e-9)
        XCTAssertEqual(ink.spaceName, 0.45, accuracy: 1e-9)
        XCTAssertEqual(ink.newTabRow, 0.30, accuracy: 1e-9)
        XCTAssertEqual(ink.rowTitle, 1, accuracy: 1e-9)
        let purple = ThemeDerivation.palette(for: theme(.light, colors: [RGBAColor(hex: 0xA5729C)]))
        XCTAssertEqual(purple.ink(\.addressText), RGBAColor(hex: 0x000000, alpha: 0.60))
        XCTAssertEqual(purple.rowTitleText, purple.primaryText, "opaque row text with dark ink")
    }

    /// The light-ink rule follows the theme color, the same in light and dark. [07 §8.3] observed
    /// (B46): on the 36 E12 presets every theme of luminance ≤ 0.143 uses white ink and every one
    /// of ≥ 0.204 dark ink, in both appearances; round 1 (B32) saw white on a saturated blue-violet.
    func testLightInkThreshold() {
        // (preset, theme) with light ink in Arc, then with dark ink. [07 §8.3] observed.
        let light: [UInt32] = [0x010101, 0x191919, 0x333333, 0x4E3A5A, 0x27476C, 0x683557, 0x226148, 0x8F4144, 0x666666, 0x666789, 0x0000FF]
        let dark: [UInt32] = [0xAF6D40, 0x7F7F7F, 0xA5729C, 0xF25E6C, 0x79AA82, 0x6CBAD9, 0xF8D55A, 0xFFFFFF, 0xF1EBE5]
        for hex in light {
            XCTAssertTrue(ThemeDerivation.prefersLightInk(theme: RGBAColor(hex: hex)), String(format: "%06X", hex))
        }
        for hex in dark {
            XCTAssertFalse(ThemeDerivation.prefersLightInk(theme: RGBAColor(hex: hex)), String(format: "%06X", hex))
        }
        for appearance in [ThemeAppearance.light, .dark] {
            XCTAssertTrue(ThemeDerivation.palette(for: theme(appearance, colors: [RGBAColor(hex: 0x666789)])).usesLightInk, "navy keeps white ink")
            XCTAssertFalse(ThemeDerivation.palette(for: theme(appearance, colors: [RGBAColor(hex: 0xA5729C)])).usesLightInk, "purple keeps dark ink")
        }
    }

    // MARK: Selected row fill (B46, [07 §8.3])

    /// [07 §8.3] observed (B46, lossless-equivalent LCU window captures, 8 160 px averages, sd ≤ 1.1):
    /// (theme, appearance, sidebar window, selected row). Light-ink themes get a muted row close to
    /// the window, in light and dark; dark-ink themes keep the near-white row. The fill is computed
    /// from Arc's own window color so only the selected-row rule is checked (within 4/255).
    func testSelectedRowFollowsTheInk() {
        let samples: [(UInt32, ResolvedAppearance, UInt32, UInt32)] = [
            // Light ink, dark appearance: navy, drab purple / plum / red / green / blue, grays.
            (0x666789, .dark, 0x838498, 0x9E9DB0), (0x4E3A5A, .dark, 0x766C7E, 0x928B99),
            (0x683557, .dark, 0x86687A, 0x9D8797), (0x8F4144, .dark, 0x9F6E6E, 0xB28C8D),
            (0x226148, .dark, 0x608172, 0x829B91), (0x27476C, .dark, 0x617188, 0x818EA1),
            (0x666666, .dark, 0x838383, 0x9E9EA0), (0x333333, .dark, 0x666666, 0x868688),
            (0x191919, .dark, 0x595959, 0x7C7C7F), (0x010101, .dark, 0x484848, 0x6F6F71),
            // Light ink, light appearance.
            (0x010101, .light, 0x585858, 0x7B7B7D), (0x191919, .light, 0x686868, 0x878789),
            (0x333333, .light, 0x777777, 0x939395), (0x666666, .light, 0x979797, 0xACACAE),
            (0x666789, .light, 0x9798AE, 0xADADBF), (0x8F4144, .light, 0xB07F7F, 0xC1999B),
            // Dark ink (controls): dark appearance, then light.
            (0xF1EBE5, .dark, 0xDCD6D2, 0xF4F4F4), (0xF19CBB, .dark, 0xDCA4B8, 0xF4EFF0),
            (0xA5729C, .dark, 0xAC8BA6, 0xF0EBEF), (0xF25E6C, .dark, 0xDD8088, 0xF5EAEB),
            (0xFF8557, .dark, 0xE3977C, 0xF4EDE9), (0xF8D55A, .dark, 0xDFC87F, 0xF5F2EB),
            (0x35E896, .dark, 0x73D4A1, 0xE9F3EE), (0x6CBAD9, .dark, 0x87B7CB, 0xEBEFF1),
            (0xAF6D40, .dark, 0xB3896E, 0xEFEBE8), (0xD7B35F, .dark, 0xC9B280, 0xF3EFEA),
            (0xCDCCA3, .dark, 0xC4C2AA, 0xF1F1EF), (0x79AA82, .dark, 0x90AE95, 0xEBEFEE),
            (0x7F7F7F, .dark, 0x939393, 0xECECEC), (0x7F7F7F, .light, 0xA7A7A7, 0xEFEFEF),
            (0xA5729C, .light, 0xBF9EB8, 0xF0EEF0), (0x6CBAD9, .light, 0x9BCCE1, 0xECF3F4),
            (0xAF6D40, .light, 0xC69B7F, 0xF2EDEA),
        ]
        for (hex, appearance, window, row) in samples {
            let label = String(format: "%06X %@", hex, appearance.rawValue)
            let lightInk = ThemeDerivation.prefersLightInk(theme: RGBAColor(hex: hex))
            assertClose(ThemeDerivation.selectedRowFill(window: RGBAColor(hex: window), lightInk: lightInk),
                        RGBAColor(hex: row), tolerance: 4.0 / 255, "selected row \(label)")
            // The palette end to end: our window is within 3.1/255 of Arc's [07 §8.2], so the row
            // lands within a few levels more.
            let palette = ThemeDerivation.palette(for: theme(appearance == .dark ? .dark : .light, colors: [RGBAColor(hex: hex)]))
            assertClose(palette.selectedTabFill, RGBAColor(hex: row), tolerance: 6.0 / 255, "palette selected row \(label)")
        }
    }

    /// [07 §8.3] / [04 §拖动图像(E17)] observed: dark navy shows the selected and the lifted row as
    /// #9293AA over a #7D7E98 window when Arc is in the background, and #9E9DB0 over #838498 in
    /// front; the old near-white rule gave #DADAE0. Titles on it stay white like the other rows.
    func testDarkNavySelectedRowIsMuted() {
        let palette = ThemeDerivation.palette(for: theme(.dark, colors: [RGBAColor(hex: 0x666789)]))
        assertClose(palette.selectedTabFill, RGBAColor(hex: 0x9E9DB0), tolerance: 4.0 / 255, "front window")
        // E17 measured the lifted image, drawn at `rowImageOpacity` over the window.
        let window17 = RGBAColor(hex: 0x7D7E98)
        let lifted = ThemeDerivation.mix(window17, ThemeDerivation.selectedRowFill(window: window17, lightInk: true),
                                         amount: Metrics.SidebarDrag.rowImageOpacity)
        assertClose(lifted, RGBAColor(hex: 0x9293AA), tolerance: 4.0 / 255, "E17 lifted row")
        XCTAssertLessThan(ThemeDerivation.luminance(palette.selectedTabFill), 0.4, "not near white")
        XCTAssertEqual(palette.selectedTabText, RGBAColor(hex: 0xFFFFFF, alpha: ChromeInkOpacities.lightInk.rowTitle))
        XCTAssertEqual(palette.selectedTabText, palette.rowTitleText)
        // White title on the muted row: Arc's own contrast (≈ 2.6 at full white), kept by ours.
        XCTAssertGreaterThan(ThemeDerivation.contrast(palette.selectedTabFill, RGBAColor(hex: 0xFFFFFF)), 2.3)
    }

    /// A saturated blue theme: light ink with the round-1 opacities, controls and lines lighter than
    /// the window (B32 round 1, PX observed values, inferred rules); the empty web panel takes the
    /// [07 §8.1] content tint.
    func testSaturatedBlueUsesLightInk() {
        let palette = ThemeDerivation.palette(for: theme(.light, colors: [RGBAColor(hex: 0x0000FF)]))
        XCTAssertTrue(palette.usesLightInk)
        // Only roughly Arc's window: the round-1 theme color (0000FF here) is a guess and that
        // capture's light / dark mode was not recorded [07 §8.1], so the bound is loose.
        assertClose(palette.windowBackground, RGBAColor(hex: 0x5247FE), tolerance: 17.0 / 255, "window")
        XCTAssertEqual(palette.chromeInk, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(palette.primaryText, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(palette.inkOpacity, .lightInk)
        XCTAssertEqual(palette.rowTitleText, RGBAColor(hex: 0xFFFFFF, alpha: ChromeInkOpacities.lightInk.rowTitle))
        XCTAssertEqual(palette.secondaryText, RGBAColor(hex: 0xFFFFFF, alpha: ChromeInkOpacities.lightInk.spaceName))
        XCTAssertEqual(palette.controlFill, ThemeDerivation.overlayWhite(palette.windowBackground, amount: ThemeDerivation.lightInkControlWhite))
        XCTAssertEqual(palette.separator, ThemeDerivation.overlayWhite(palette.windowBackground, amount: ThemeDerivation.lightInkSeparatorWhite))
        XCTAssertEqual(palette.scrollEdgeLine, palette.separator)
        XCTAssertEqual(palette.webPanelBackground, ThemeDerivation.contentBackground(RGBAColor(hex: 0x0000FF), appearance: .light), "[07 §8.1] the content tint")
        // [07 §8.3] observed (B46): the selected row is a muted tone with the same white title.
        XCTAssertEqual(palette.selectedTabText, palette.rowTitleText, "selected rows keep the white title")
        XCTAssertEqual(palette.selectedTabFill, ThemeDerivation.selectedRowFill(window: palette.windowBackground, lightInk: true))
        // The rules reproduce the round-1 samples from Arc's own window color.
        let arcWindow = RGBAColor(hex: 0x5247FE)
        assertClose(ThemeDerivation.overlayWhite(arcWindow, amount: ThemeDerivation.lightInkControlWhite), RGBAColor(hex: 0x655CFE), tolerance: 2.0 / 255, "control / empty panel")
        // The round-1 separator reading (#5A52FD, + 5 % white) was a JPEG 1 px line; E8's lossless
        // navy captures put light-ink lines at + 16 % white [07 §8.4].
        assertClose(ThemeDerivation.overlayWhite(RGBAColor(hex: 0x9797AD), amount: ThemeDerivation.lightInkSeparatorWhite), RGBAColor(hex: 0xA7A8B9), tolerance: 1.5 / 255, "separator (E8 navy light)")
        // PX opacities (inferred): titles, Space name, New Tab, placeholder, magnifier.
        let ink = ChromeInkOpacities.lightInk
        XCTAssertEqual(ink.rowTitle, 0.78, accuracy: 0.03)
        XCTAssertEqual(ink.spaceName, 0.465, accuracy: 0.03)
        XCTAssertEqual(ink.newTabRow, 0.46, accuracy: 0.03)
        XCTAssertEqual(ink.addressText, 0.30, accuracy: 0.03)
        XCTAssertEqual(ink.addressIcon, 0.40, accuracy: 0.03)
        XCTAssertEqual(ink.toolbarDisabled, Metrics.IconOpacity.disabled, accuracy: 1e-9, "[07 §2] 30 % disabled, seen again in round 1")
        XCTAssertLessThan(ink.dockOtherSpace, ink.dockCurrentSpace)
    }

    /// Round-2 side-by-side (B33, `docs/arc-spec/07-design-system.md` §10, observed readings): each
    /// light-ink value is the round-1 value scaled by (reference reading / our reading) on the same
    /// luma measure of the two JPEGs, so the next capture reads like the reference.
    func testLightInkReproducesRound2Readings() {
        let ink = ChromeInkOpacities.lightInk
        // (name, new value, round-1 value, our reading, reference reading)
        let samples: [(String, Double, Double, Double, Double)] = [
            ("row title", ink.rowTitle, 0.83, 0.849, 0.807), ("Space name", ink.spaceName, 0.50, 0.542, 0.496),
            ("Space icon", ink.spaceIcon, 0.92, 0.944, 0.911), ("New Tab", ink.newTabRow, 0.50, 0.538, 0.492),
            ("placeholder", ink.addressText, 0.35, 0.382, 0.336), ("magnifier", ink.addressIcon, 0.45, 0.489, 0.432),
            ("dock Home / +", ink.dockButton, 0.34, 0.371, 0.335), ("current Space", ink.dockCurrentSpace, 0.50, 0.541, 0.492),
            ("favicon placeholder", ink.faviconPlaceholder, 0.28, 0.315, 0.289),
        ]
        for (name, value, old, ours, reference) in samples {
            XCTAssertEqual(value, old * reference / ours, accuracy: 0.015, name)
        }
        // Other Spaces read 0.11 (not measured on ours: no second Space); disabled toolbar 0.29.
        XCTAssertEqual(ink.dockOtherSpace, 0.10, accuracy: 0.015)
        XCTAssertEqual(ink.toolbarDisabled, Metrics.IconOpacity.disabled, accuracy: 1e-9)
        // Other Spaces in the dock are about a fifth of the current one, not the 33 % of dark ink.
        XCTAssertEqual(ink.dockOtherSpace / ink.dockCurrentSpace, 0.22, accuracy: 0.05)
    }

    /// Dark appearance on a light-ink window: white ink, and the [07 §8.1] dark content tint.
    func testSaturatedBlueDarkKeepsLightInk() {
        let palette = ThemeDerivation.palette(for: theme(.dark, colors: [RGBAColor(hex: 0x0000FF)]), systemAppearance: .light)
        XCTAssertTrue(palette.usesLightInk)
        XCTAssertEqual(palette.webPanelBackground, ThemeDerivation.contentBackground(RGBAColor(hex: 0x0000FF), appearance: .dark))
        XCTAssertEqual(palette.commandBarBackground, RGBAColor(hex: 0x181818), "[07 §5] the command bar ignores the ink")
    }

    // MARK: E12 window samples ([07 §8.1] table observed; [07 §8.2] rules inferred, B38)

    /// (preset, theme, observed light window, observed dark window): the sidebar color of the 36 E12
    /// presets, 60 × 60 px averages of JPEG captures rounded to hex. [07 §8.1] observed.
    private let e12Windows: [(String, UInt32, UInt32, UInt32)] = [
            ("p1-1", 0xF1EBE5, 0xF0EBE6, 0xDCD6D2),
            ("p1-2", 0xF19CBB, 0xF0B8CD, 0xDCA4B8),
            ("p1-3", 0xA5729C, 0xBF9EB8, 0xAC8BA6),
            ("p1-4", 0xF25E6C, 0xF0919A, 0xDD8088),
            ("p1-5", 0xFF8557, 0xF9AA8E, 0xE3977C),
            ("p1-6", 0xF8D55A, 0xF5DD8F, 0xDFC87F),
            ("p1-7", 0x35E896, 0x7BE9B4, 0x73D4A1),
            ("p1-8", 0x6CBAD9, 0x9BCCE1, 0x87B7CB),
            ("p1-9", 0x666789, 0x9798AE, 0x838498),
            ("p3-1", 0xFFFBFA, 0xF7F5F5, 0xE3E0E1),
            ("p3-2", 0xFEE9F3, 0xF8EBF1, 0xE4D6DC),
            ("p3-3", 0xF1D2ED, 0xEFDBEB, 0xDBC7D7),
            ("p3-4", 0xFFCBD0, 0xF8D6DB, 0xE4C1C6),
            ("p3-5", 0xFFE1D3, 0xF8E3DC, 0xE4CFC7),
            ("p3-6", 0xFFF9E4, 0xF8F4E7, 0xE4DFD3),
            ("p3-7", 0xDEFDEC, 0xE3F7EA, 0xCEE3D6),
            ("p3-8", 0xDBF3FB, 0xE2F1F7, 0xCDDCE2),
            ("p3-9", 0xC5C6E5, 0xD2D3E7, 0xBEBFD2),
            ("p4-1", 0x4E3A5A, 0x887C8E, 0x766C7E),
            ("p4-2", 0x683557, 0x9A798E, 0x86687A),
            ("p4-3", 0x8F4144, 0xB07F7F, 0x9F6E6E),
            ("p4-4", 0xAF6D40, 0xC69B7F, 0xB3896E),
            ("p4-5", 0xD7B35F, 0xDFC792, 0xC9B280),
            ("p4-6", 0xCDCCA3, 0xD9D7BE, 0xC4C2AA),
            ("p4-7", 0x79AA82, 0xA2C2A8, 0x90AE95),
            ("p4-8", 0x226148, 0x6E9386, 0x608172),
            ("p4-9", 0x27476C, 0x6F8299, 0x617188),
            ("p5-1", 0xFFFFFF, 0xF8F8F8, 0xE3E3E3),
            ("p5-2", 0xE6E6E6, 0xE7E7E7, 0xD3D3D3),
            ("p5-3", 0xCCCCCC, 0xD8D8D8, 0xC3C3C3),
            ("p5-4", 0xB2B2B2, 0xC7C7C7, 0xB3B3B3),
            ("p5-5", 0x7F7F7F, 0xA7A7A7, 0x939393),
            ("p5-6", 0x666666, 0x979797, 0x838383),
            ("p5-7", 0x333333, 0x777777, 0x666666),
            ("p5-8", 0x191919, 0x686868, 0x595959),
            ("p5-9", 0x010101, 0x585858, 0x484848),
    ]

    /// [07 §8.2] (B146): the theme layer over the reference backdrop, light (max 2.7/255) and dark
    /// (max 3.1/255) over all 36 E12 presets; tolerance 3.5/255.
    func testWindowMatchesEveryE12Sample() {
        XCTAssertEqual(e12Windows.count, 36)
        for (name, themeHex, lightHex, darkHex) in e12Windows {
            let color = RGBAColor(hex: themeHex)
            let light = ThemeDerivation.palette(for: theme(.light, colors: [color]), systemAppearance: .dark)
            let dark = ThemeDerivation.palette(for: theme(.dark, colors: [color]), systemAppearance: .light)
            assertClose(light.windowBackground, RGBAColor(hex: lightHex), tolerance: 3.5 / 255, "\(name) light window")
            assertClose(dark.windowBackground, RGBAColor(hex: darkHex), tolerance: 3.5 / 255, "\(name) dark window")
            XCTAssertEqual(dark.backgroundGradientColors, [dark.windowBackground], "\(name) gradient stop follows the window")
        }
    }

    /// The B36 content tint is untouched by the window refit: [07 §8.1] keeps its own P3 rule.
    func testContentTintDoesNotDependOnTheWindowRule() {
        for (name, themeHex, _, _) in e12Windows {
            let color = RGBAColor(hex: themeHex)
            for appearance in ResolvedAppearance.allCases {
                let palette = ThemeDerivation.palette(for: theme(appearance == .dark ? .dark : .light, colors: [color]), systemAppearance: .light)
                XCTAssertEqual(palette.webPanelBackground, ThemeDerivation.contentBackground(color, appearance: appearance), "\(name) \(appearance.rawValue)")
            }
        }
    }

    // MARK: Grain

    func testGrainIsCarriedAndClamped() {
        XCTAssertEqual(ThemeDerivation.palette(for: theme(.light, grain: 0.4)).grain, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ThemeDerivation.palette(for: theme(.dark, grain: 0.4), systemAppearance: .light).grain, 0.4, accuracy: 1e-9)
        XCTAssertEqual(ThemeDerivation.palette(for: theme(.light, grain: 3)).grain, 1)
        XCTAssertEqual(ThemeDerivation.palette(for: nil).grain, 0)
    }

    func testGrainOverlayOnlyAboveZero() {
        XCTAssertNil(GrainNoise.overlayOpacity(for: 0))
        XCTAssertNil(GrainNoise.overlayOpacity(for: -1))
        XCTAssertEqual(GrainNoise.overlayOpacity(for: 1) ?? 0, GrainNoise.maxOpacity, accuracy: 1e-9)
        XCTAssertEqual(GrainNoise.overlayOpacity(for: 0.5) ?? 0, GrainNoise.maxOpacity / 2, accuracy: 1e-9)
    }

    func testGrainTileIsDeterministicNoise() {
        let tile = GrainNoise.tilePixels(size: 32)
        XCTAssertEqual(tile.count, 32 * 32 * 4)
        XCTAssertEqual(tile, GrainNoise.tilePixels(size: 32), "same seed, same tile")
        XCTAssertNotEqual(tile, GrainNoise.tilePixels(size: 32, seed: 7))
        let levels = Set(stride(from: 0, to: tile.count, by: 4).map { tile[$0] })
        XCTAssertGreaterThan(levels.count, 100, "noise, not a flat color")
        XCTAssertTrue(stride(from: 3, to: tile.count, by: 4).allSatisfy { tile[$0] == 255 }, "opaque pixels")
    }
}
