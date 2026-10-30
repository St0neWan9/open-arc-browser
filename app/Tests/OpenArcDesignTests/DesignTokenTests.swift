import XCTest
import OpenArcModel
import OpenArcDesign

/// Pins the measured values so an accidental edit shows up in review.
/// Spec: docs/arc-spec/07-design-system.md (E11) and design-tokens.json; older values from 04/06
/// were corrected by 07 §10.
final class DesignTokenTests: XCTestCase {
    /// [07 §1, §4] observed sidebar geometry.
    func testMeasuredSidebarValues() {
        let s = Metrics.Sidebar.self
        XCTAssertEqual(s.width, 276)
        XCTAssertEqual(s.contentInset, 8)
        XCTAssertEqual(s.addressFieldTop, 46)
        XCTAssertEqual(s.addressFieldHeight, 36)
        XCTAssertEqual(s.addressFieldHorizontalInset, 8, "[07 §10] corrected from 4")
        XCTAssertEqual(s.addressFieldCornerRadius, 12, "[07 §10] corrected from 10")
        XCTAssertEqual(s.favoritesTop, 90)
        XCTAssertEqual(s.favoritesHeight, 47)
        XCTAssertEqual(s.rowPitch, 41)
        XCTAssertEqual(s.rowButtonHeight, 40)
        XCTAssertEqual(s.selectedRowHeight, 36)
        XCTAssertEqual(s.rowIconLeading, 17)
        XCTAssertEqual(s.rowIconSize, 18)
        XCTAssertEqual(s.rowTitleLeading, 43, "[07 §10] text frame at 43 (ink at 45)")
        XCTAssertEqual(s.listTop, 181)
        XCTAssertEqual(s.dividerRowHeight, 17)
        XCTAssertEqual(s.dockButtonSize, 32)
        XCTAssertEqual(s.dockCenterFromBottom, 25)
        XCTAssertEqual(Metrics.WebPanel.insetTop, 10)
        XCTAssertEqual(Metrics.WebPanel.insetTrailing, 10)
        XCTAssertEqual(Metrics.WebPanel.insetBottom, 10)
        XCTAssertEqual(Metrics.WebPanel.insetLeading, 0)
        XCTAssertEqual(Metrics.WebPanel.cornerRadius, 6, "[07 §10] corrected from 7")
    }

    /// [07 §4, §7] observed: ≈ 1 pt soft shadow under the selected row, pressed shade ≈ 1 % darker;
    /// [07 §12] observed: favorites hover card 240 × 64, radius 11, ≈ #F9F9FB, 0.5 pt line, its left
    /// edge at x 264 for a block ending at 268 (plan B89).
    func testSidebarSurfaceTokens_07_4_7_12() {
        let s = Metrics.Sidebar.self
        XCTAssertLessThanOrEqual(s.selectedRowShadow.radius + s.selectedRowShadow.offsetY, 2)
        XCTAssertEqual(s.pressedRowShade, 0.99)
        let t = Metrics.FavoritesTooltip.self
        XCTAssertEqual(t.size, Size2D(width: 240, height: 64))
        XCTAssertEqual(t.cornerRadius, 11)
        XCTAssertEqual(t.fillRGB, 0xF9F9FB)
        XCTAssertEqual(t.hairlineWidth, 0.5)
        XCTAssertEqual(268 + t.leadingFromBlockTrailing, 264)
        // [04 §sidebar] observed "thin": the knob stays a few points wide (size unknown).
        XCTAssertLessThanOrEqual(Metrics.SidebarScroller.knobWidth, 6)
    }

    /// [07 §2] observed: traffic light centers (20, 24), (43, 24), (66, 24); toolbar buttons are
    /// 32 × 32 hit areas at x 77 / 170 / 204 / 238, center y 23.5 (y 7.5–39.5).
    func testWindowChromeMatchesE11() {
        let w = Metrics.WindowButtons.self
        XCTAssertEqual(w.hitBoxOrigin(index: 0).x, 12)
        XCTAssertEqual(w.hitBoxOrigin(index: 0).y, 16)
        XCTAssertEqual(w.hitBoxOrigin(index: 1).x, 35)
        XCTAssertEqual(w.hitBoxOrigin(index: 2).x, 58)
        XCTAssertEqual(w.hitBoxOrigin(index: 0, inLibrary: true).x, 15, "[07 §2] Library: (15, 20)")
        XCTAssertEqual(w.hitBoxOrigin(index: 0, inLibrary: true).y, 20)
        let s = Metrics.Sidebar.self
        XCTAssertEqual(s.toolbarButtonSize, 32)
        XCTAssertEqual(s.toolbarButtonTop, 7.5)
        XCTAssertEqual([s.hideSidebarButtonX, s.backButtonX, s.forwardButtonX, s.reloadButtonX], [77, 170, 204, 238])
        XCTAssertEqual(s.forwardButtonX - s.backButtonX, s.toolbarButtonPitch)
        XCTAssertEqual(s.reloadButtonX - s.forwardButtonX, s.toolbarButtonPitch)
    }

    /// The sidebar blocks measured in 07 must stack top to bottom without overlapping.
    /// Round-2 side-by-side measurements (B33, `docs/arc-spec/07-design-system.md` §10, observed).
    func testRound2SidebarMeasurements() {
        let s = Metrics.Sidebar.self
        // The Space icon glyph is ≈ 14 pt inside the 26 pt cell, not a cell-filling glyph.
        XCTAssertLessThan(s.spaceIconGlyphInk.height, s.spaceIconFrame.height * 0.7)
        XCTAssertEqual(s.spaceIconGlyphInk.width, 10.5)
        // The favicon placeholder is 14 pt, centered in the 18 pt cell, radius ≈ 3.5.
        XCTAssertEqual(s.faviconPlaceholderSize, 14)
        XCTAssertEqual((s.rowIconSize - s.faviconPlaceholderSize) / 2, 2)
        XCTAssertEqual(s.faviconPlaceholderCornerRadius, 3.5)
        // Text ink sits 1 pt inside its text frame (row 43 → ink 45 with the glyph bearing).
        XCTAssertEqual(s.textInkInset, 1)
        XCTAssertEqual(s.dockSpaceGlyphInk, Size2D(width: 11, height: 15))
        // The placeholder renders at Medium 13 (the domain stays Regular 13).
        XCTAssertEqual(Typography.addressPlaceholder, TextStyle(size: 13, weight: .medium, opacity: 0.60))
    }

    func testSidebarBlocksDoNotOverlap() {
        let s = Metrics.Sidebar.self
        XCTAssertLessThanOrEqual(s.toolbarButtonTop + s.toolbarButtonSize, s.addressFieldTop)
        XCTAssertLessThanOrEqual(s.addressFieldTop + s.addressFieldHeight, s.favoritesTop)
        XCTAssertLessThanOrEqual(s.favoritesTop + s.favoritesHeight, s.spaceHeaderTop)
        XCTAssertLessThanOrEqual(s.spaceIconFrame.maxY, s.listTop)
        XCTAssertLessThan(s.rowIconLeading + s.rowIconSize, s.rowTitleLeading)
        XCTAssertLessThan(s.selectedRowHeight, s.rowButtonHeight)
        XCTAssertLessThan(s.rowButtonHeight, s.rowPitch)
        XCTAssertLessThan(s.dockIconsTrailing, s.dockPlusX)
        XCTAssertLessThan(s.dockHomeX + s.dockButtonSize, s.dockIconsLeading)
    }

    /// [07 §5] observed: 765 × 327, input row 64, results from +68, pitch 50; the parts add up.
    func testCommandBarRowsAddUp() {
        let c = Metrics.CommandBar.self
        XCTAssertEqual(c.width, 765)
        XCTAssertEqual(c.heightWithFiveResults, 327)
        XCTAssertEqual(c.inputRowHeight, 64)
        XCTAssertEqual(c.cornerRadius, 11)
        XCTAssertEqual(c.inputRowHeight + c.resultsTopGap + 5 * c.resultRowPitch + c.bottomPadding, c.heightWithFiveResults)
        XCTAssertGreaterThan(c.bottomPadding, 0)
        // Five results put the panel top at 324 in a 985 window: 5 pt above center.
        let top = (Metrics.referenceWindowSize.height - c.heightWithFiveResults) / 2 - c.centerOffsetAboveMiddle
        XCTAssertEqual(top, c.topWithFiveResults)
    }

    /// [07 §6, §10] corrected surfaces: theme bubble, Library.
    func testCorrectedSurfaceValues() {
        XCTAssertEqual(Metrics.ThemePicker.size, Size2D(width: 356, height: 508))
        XCTAssertEqual(Metrics.ThemePicker.cornerRadius, 20)
        XCTAssertEqual(Metrics.Library.leftPaneWidth, 417)
        XCTAssertEqual(Metrics.Library.iconRailWidth + Metrics.Library.listColumnWidth, 417)
        XCTAssertEqual(Metrics.Dialog.newFolderSize, Size2D(width: 450, height: 222))
        XCTAssertEqual(Metrics.Dialog.deleteSpaceSize, Size2D(width: 450, height: 273))
    }

    /// [07 §3] observed: every chrome text is SF at these sizes, weights and opacities.
    func testTypographyScale() {
        let t = Typography.self
        XCTAssertEqual(t.addressField, TextStyle(size: 13, weight: .regular, opacity: 0.60))
        XCTAssertEqual(t.spaceName, TextStyle(size: 13, weight: .semibold, opacity: 0.45))
        XCTAssertEqual(t.tabRowTitle, TextStyle(size: 14, weight: .regular))
        XCTAssertEqual(t.folderRowTitle, TextStyle(size: 14, weight: .semibold))
        XCTAssertEqual(t.newTabRow, TextStyle(size: 14, weight: .regular, opacity: 0.30))
        XCTAssertEqual(t.commandBarInput.size, 18)
        XCTAssertEqual(t.commandBarInput.weight, .medium)
        for style in [t.commandBarRowTitle, t.commandBarRowSubtitle, t.commandBarActionLabel] {
            XCTAssertEqual(style.size, 13)
            XCTAssertEqual(style.weight, .medium)
        }
        XCTAssertEqual(t.dialogTitle, TextStyle(size: 17, weight: .bold))
        XCTAssertEqual(t.dialogBody.size, 14)
        XCTAssertEqual(t.settingsBody.size, 13)
        // [07 §3] observed text frame heights.
        XCTAssertEqual(Typography.lineHeight(forSize: 13), 18)
        XCTAssertEqual(Typography.lineHeight(forSize: 14), 19)
        XCTAssertEqual(Typography.lineHeight(forSize: 17), 21)
        XCTAssertEqual(Typography.lineHeight(forSize: 18), 23)
        XCTAssertEqual(Metrics.Sidebar.rowTitleFontSize, 14, "[07 §10] corrected from 13")
    }

    func testMixAndShadeMath() {
        let black = RGBAColor(red: 0, green: 0, blue: 0)
        let tinted = ThemeDerivation.overlayWhite(black, amount: 0.1)
        XCTAssertEqual(tinted.red, 0.1, accuracy: 1e-9)
        XCTAssertEqual(ThemeDerivation.overlayWhite(black, amount: 1).green, 1, accuracy: 1e-9)
        XCTAssertEqual(ThemeDerivation.overlayWhite(black, amount: 2).blue, 1, accuracy: 1e-9) // clamped
        let white = RGBAColor(red: 1, green: 1, blue: 1)
        XCTAssertEqual(ThemeDerivation.overlayWhite(white, amount: 0.1), white)
        XCTAssertEqual(ThemeDerivation.shade(white, by: 0.96).red, 0.96, accuracy: 1e-9)
        XCTAssertEqual(ThemeDerivation.mix(black, white, amount: 0.36).green, 0.36, accuracy: 1e-9)
    }

    /// [07 §8, §8.2]: window = mix(theme, #EBEBEB, 0.37); control = window × 0.96 (darker, not +10 %
    /// white); selected row = mix(window, #F5F5F5, 0.9); command bar panel #F9F9F9 whatever the theme.
    func testPaletteFollowsThemeRules() {
        // The E11 purple preset: a dark-ink theme [07 §8.3] (#6B4FD8 would take light ink).
        let purple = RGBAColor(hex: 0xA5729C)
        let theme = Theme(id: UUID(), appearance: .light, colors: [purple], now: Date(timeIntervalSince1970: 0))
        let palette = ThemeDerivation.palette(for: theme)
        let window = ThemeDerivation.mix(purple, RGBAColor(hex: 0xEBEBEB), amount: 0.37)
        XCTAssertEqual(palette.windowBackground, window)
        XCTAssertEqual(palette.controlFill, ThemeDerivation.shade(window, by: 0.96))
        XCTAssertLessThan(ThemeDerivation.luminance(palette.controlFill), ThemeDerivation.luminance(palette.windowBackground), "darker")
        XCTAssertEqual(palette.selectedTabFill, ThemeDerivation.mix(window, RGBAColor(hex: 0xF7F7F7), amount: 0.894), "[07 §8.4] E8 refit")
        XCTAssertEqual(palette.separator, ThemeDerivation.shade(window, by: 0.87))
        XCTAssertEqual(palette.commandBarBackground, RGBAColor(hex: 0xF9F9F9))
        XCTAssertEqual(palette.chromeInk, RGBAColor(hex: 0x000000))
        XCTAssertEqual(palette.secondaryText.alpha, 0.45, accuracy: 1e-9)
        XCTAssertLessThan(ThemeDerivation.luminance(palette.primaryText), 0.05, "dark row text")
    }

    func testDefaultPaletteIsLightWithDarkText() {
        let palette = ThemeDerivation.palette(for: nil)
        XCTAssertEqual(palette.windowBackground, ThemeDerivation.lightWindow(ThemeDerivation.defaultBaseColor))
        XCTAssertGreaterThan(ThemeDerivation.luminance(palette.windowBackground), 0.6)
        XCTAssertLessThan(ThemeDerivation.luminance(palette.primaryText), 0.1)
    }

    /// [07 §5] E27 observed: the default theme's command bar selection is #ADABE2 (light), not
    /// the #A5A5BC the picked-color rule derives from `defaultBaseColor`. B127.
    func testDefaultThemeCommandBarSelection() {
        XCTAssertEqual(ThemeDerivation.defaultCommandBarSelection, RGBAColor(hex: 0xADABE2))
        XCTAssertEqual(ThemeDerivation.palette(for: nil, appearance: .light).commandBarSelection, RGBAColor(hex: 0xADABE2))
        let ruled = ThemeDerivation.tone(of: ThemeDerivation.defaultBaseColor,
                                         lightness: ThemeDerivation.commandBarSelectionLightness,
                                         chromaFactor: ThemeDerivation.commandBarSelectionChromaFactor)
        XCTAssertNotEqual(ruled, ThemeDerivation.defaultCommandBarSelection)
    }

    /// [06 §2] observed: a theme can have several color dots. The gradient stops follow them in
    /// order (inferred), each mapped like the window color; the first dot drives every fill.
    func testGradientStopsFollowTheThemeColors() {
        let a = RGBAColor(hex: 0x3D6FE0), b = RGBAColor(hex: 0xE0533F)
        let theme = Theme(id: UUID(), appearance: .light, colors: [a, b], now: Date(timeIntervalSince1970: 0))
        let palette = ThemeDerivation.palette(for: theme)
        XCTAssertEqual(palette.backgroundGradientColors, [ThemeDerivation.lightWindow(a), ThemeDerivation.lightWindow(b)])
        XCTAssertEqual(palette.windowBackground, ThemeDerivation.lightWindow(a))
        let stops = ThemeDerivation.defaultWindowStops
        XCTAssertEqual(ThemeDerivation.palette(for: nil).backgroundGradientColors, stops)
        let empty = Theme(id: UUID(), appearance: .light, colors: [], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ThemeDerivation.palette(for: empty).backgroundGradientColors, stops)
    }

    /// [07 §8.5] observed: a Space with no picked color shows Arc's default, a lavender (top left)
    /// to pale pink (bottom right) window, address box ≈ #D8D8EB, content ≈ #F9F7F9 at the center.
    func testNoColorThemeMatchesArcDefault() {
        func hex(_ c: RGBAColor) -> String {
            String(format: "%02X%02X%02X", Int((c.red * 255).rounded()), Int((c.green * 255).rounded()), Int((c.blue * 255).rounded()))
        }
        func near(_ c: RGBAColor, _ expected: UInt32, _ tolerance: Double = 2.5) -> Bool {
            let e = RGBAColor(hex: expected)
            return [abs(c.red - e.red), abs(c.green - e.green), abs(c.blue - e.blue)].allSatisfy { $0 * 255 <= tolerance }
        }
        let style = ThemeStyle(appearance: .light, colors: [])
        let palette = ThemeDerivation.palette(forStyle: style, systemAppearance: .light)
        XCTAssertEqual(palette.backgroundGradientColors.first.map(hex), "DEDEF5")
        XCTAssertEqual(palette.backgroundGradientColors.last.map(hex), "F4E9E9")
        XCTAssertTrue(near(palette.windowBackground, 0xDEDEF5), hex(palette.windowBackground))
        XCTAssertTrue(near(palette.controlFill, 0xD8D8EB, 3.5), hex(palette.controlFill))
        XCTAssertEqual(hex(palette.webPanelBackground), "F9F7F9")
        XCTAssertFalse(palette.usesLightInk)
    }

    /// `Theme.brightness` (the [06 §2] ring knob, inferred): 0.5 leaves the colors exactly as
    /// picked, higher lightens and lower darkens every color dot before the [07 §8] mapping.
    func testBrightnessShiftsThemeColors() {
        let color = RGBAColor(hex: 0x6E5BD6)
        var theme = Theme(id: UUID(), appearance: .light, colors: [color, RGBAColor(hex: 0x3FAE6A)], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ThemeDerivation.palette(for: theme).windowBackground, ThemeDerivation.lightWindow(color))
        XCTAssertEqual(ThemeDerivation.applyBrightness(color, brightness: 0.5), color)

        theme.brightness = 1
        let bright = ThemeDerivation.palette(for: theme)
        let lifted = ThemeDerivation.overlayWhite(color, amount: ThemeDerivation.maxBrightnessShift)
        XCTAssertEqual(bright.windowBackground, ThemeDerivation.lightWindow(lifted))
        XCTAssertEqual(bright.backgroundGradientColors.count, 2)

        theme.brightness = 0
        let dark = ThemeDerivation.palette(for: theme)
        XCTAssertLessThan(ThemeDerivation.luminance(dark.windowBackground), ThemeDerivation.luminance(ThemeDerivation.lightWindow(color)))
        XCTAssertEqual(dark.windowBackground.alpha, color.alpha)
    }

    /// [07 §7.1] E14: the web panel edge shadow per appearance (calibrated against Arc on white
    /// and black pages), and no border.
    func testWebPanelEdgeShadowMatchesE14() {
        let light = Metrics.WebPanel.shadow(.light)
        XCTAssertEqual(light, Metrics.PanelShadow(opacity: 0.24, radius: 3.4, offsetY: 1))
        let dark = Metrics.WebPanel.shadow(.dark)
        XCTAssertEqual(dark, Metrics.PanelShadow(opacity: 0.25, radius: 3.5, offsetY: 1))
        XCTAssertEqual(light.offsetX, 0)
        XCTAssertGreaterThanOrEqual(dark.opacity, light.opacity, "[07 §7.1] slightly stronger in a dark Space")
        XCTAssertGreaterThan(light.opacity, 0.18, "B41: stronger than the B32 round-1 value")
        XCTAssertEqual(Metrics.WebPanel.borderWidth, 0, "[07 §7.1] observed: no hairline or inner stroke")
        XCTAssertEqual(Metrics.WebPanel.cornerRadius, 6, "[07 §7.1] observed corner profile")
    }
}
