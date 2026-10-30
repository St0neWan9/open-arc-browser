import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Polish items of plan row B140 (F5 comparison, `docs/f5-review.md`): the web toolbar's own
/// tooltips ([06 §17.5], [04 §网页工具栏]), the no-color content gradient and the multi-color
/// window axis ([07 §8.4], [07 §8.5]), the command bar close ([07 §11]) and the dock Home label
/// ([05 §窗口层级]). The drag hot zones are in `SidebarDragTests`, the Little Arc anchor in
/// `FloatingBubbleTests`, the onboarding gap in `OnboardingTests`.
@MainActor
final class F5PolishB140Tests: XCTestCase {

    // MARK: F5-28/64 toolbar tooltips

    /// [06 §17.5] observed: "Go back ⌘ [" with the shortcut as key caps; the other buttons use
    /// their shortcuts from [02 §页面与导航, §复制链接].
    func testTooltipTextsAndKeys_06_17_5() {
        XCTAssertEqual(WebToolbarTooltip.back.text, "Go back")
        XCTAssertEqual(WebToolbarTooltip.back.keys, ["⌘", "["])
        XCTAssertEqual(WebToolbarTooltip.back.keysText, "⌘ [")
        XCTAssertEqual(WebToolbarTooltip.forward.keys, ["⌘", "]"])
        XCTAssertEqual(WebToolbarTooltip.reload.keys, ["⌘", "R"])
        XCTAssertEqual(WebToolbarTooltip.copyLink.keys, ["⇧", "⌘", "C"])
        XCTAssertTrue(WebToolbarTooltip.stop.keys.isEmpty)
    }

    /// [06 §17.5] observed ≈ 0.5 s after hovering (`Metrics.WebToolbar.tooltipDelaySeconds`,
    /// inferred); leaving or pressing hides it at once.
    func testTooltipShowsAfterDelayAndHidesOnExit_06_17_5() async throws {
        XCTAssertEqual(Metrics.WebToolbar.tooltipDelaySeconds, 0.5)
        XCTAssertEqual(WebToolbarTooltipTimer().delay, Metrics.WebToolbar.tooltipDelaySeconds)
        let timer = WebToolbarTooltipTimer(delay: 0.05)
        timer.hover(true)
        XCTAssertFalse(timer.isShown, "not before the delay")
        try await waitFor { timer.isShown }
        timer.hover(false)
        XCTAssertFalse(timer.isShown)
        // Leaving before the delay cancels it.
        timer.hover(true)
        timer.hover(false)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertFalse(timer.isShown)
        // A press hides it.
        timer.hover(true)
        try await waitFor { timer.isShown }
        timer.dismiss()
        XCTAssertFalse(timer.isShown)
    }

    /// The tag sits under the button, centered on it, and stays inside the window.
    func testTooltipPlacedUnderButton_06_17_5() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 90, height: 22)
        let button = CGRect(x: 300, y: 4, width: 32, height: 24)
        let tag = WebToolbarTooltipLayout.frame(size: size, below: button, inside: bounds)
        XCTAssertEqual(tag.midX, button.midX)
        XCTAssertEqual(tag.minY, button.maxY + WebToolbarTooltipTokens.gapBelowButton)
        let edge = WebToolbarTooltipLayout.frame(size: size, below: CGRect(x: 2, y: 4, width: 32, height: 24), inside: bounds)
        XCTAssertEqual(edge.minX, 0)
    }

    /// The toolbar no longer uses the system help tag (it cannot draw key caps or take our delay).
    func testToolbarButtonsDoNotUseSystemHelp_06_17_5() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/OpenArcShell/WebToolbar/WebToolbarViews.swift")
        let text = try String(contentsOf: dir, encoding: .utf8)
        XCTAssertFalse(text.contains(".help("))
        XCTAssertTrue(text.contains(".webToolbarTooltip("))
    }

    /// The tag view renders with its key caps.
    func testTooltipViewRenders() {
        let host = NSHostingView(rootView: WebToolbarTooltipView(tooltip: .back))
        let size = host.fittingSize
        XCTAssertEqual(size.height, WebToolbarTooltipTokens.height, accuracy: 0.5)
        XCTAssertGreaterThan(size.width, NSHostingView(rootView: WebToolbarTooltipView(tooltip: WebToolbarTooltip(text: "Go back"))).fittingSize.width,
                             "key caps add width")
    }

    // MARK: F5-53/68 and F5-54/67 gradients

    /// [07 §8.4] finding 4 observed: a multi-dot theme's main axis runs top → bottom, the top near
    /// the first dot's window color. [07 §8.5] observed: the no-color wash runs top left → bottom
    /// right through the sampled window colors, the top frame #E9E4F1 among them.
    func testWindowGradientGeometry_07_8_4_8_5() {
        let dots = Theme(id: UUID(), appearance: .light, colors: [RGBAColor(hex: 0xF29BBB), RGBAColor(hex: 0xA6729D), RGBAColor(hex: 0x6CBAD9)],
                         now: Date(timeIntervalSince1970: 0))
        let multi = ThemeDerivation.palette(for: dots)
        XCTAssertEqual(multi.backgroundGradientAxis, .vertical)
        XCTAssertNil(multi.backgroundGradientLocations)
        XCTAssertEqual(multi.backgroundGradientColors.first, multi.windowBackground)

        let none = ThemeDerivation.palette(for: nil)
        XCTAssertEqual(none.backgroundGradientAxis, .diagonal)
        XCTAssertEqual(none.backgroundGradientLocations?.count, none.backgroundGradientColors.count)
        XCTAssertTrue(none.backgroundGradientColors.contains(RGBAColor(hex: 0xE9E4F1)), "top frame stop")
        XCTAssertEqual(none.backgroundGradientLocations?.first, 0)
        XCTAssertEqual(none.backgroundGradientLocations?.last, 1)
        XCTAssertEqual(none.backgroundGradientLocations, none.backgroundGradientLocations?.sorted())

        let stops = WindowBackgroundView.stops(none.backgroundGradientColors, locations: none.backgroundGradientLocations)
        XCTAssertEqual(stops.map(\.location), ThemeDerivation.defaultWindowStopLocations.map { CGFloat($0) })
        let even = WindowBackgroundView.stops(multi.backgroundGradientColors, locations: nil)
        XCTAssertEqual(even.map(\.location), [0, 0.5, 1])
    }

    /// [07 §8.5] observed: the no-color light content area runs #F6F6FC (top left) → #FDF8F8
    /// (bottom right) through the center #F9F7F9; picked themes and dark stay flat ([07 §8.1]).
    func testNoColorContentGradient_07_8_5() {
        let light = ThemeDerivation.palette(forStyle: ThemeStyle(appearance: .light, colors: []), systemAppearance: .light)
        XCTAssertEqual(light.webPanelBackgroundGradient,
                       [RGBAColor(hex: 0xF6F6FC), RGBAColor(hex: 0xF9F7F9), RGBAColor(hex: 0xFDF8F8)])
        XCTAssertEqual(light.webPanelBackground, RGBAColor(hex: 0xF9F7F9), "flat value = the center")
        let dark = ThemeDerivation.palette(forStyle: ThemeStyle(appearance: .dark, colors: []), systemAppearance: .light)
        XCTAssertTrue(dark.webPanelBackgroundGradient.isEmpty)
        let picked = ThemeDerivation.palette(forStyle: ThemeStyle(appearance: .light, colors: [RGBAColor(hex: 0x6CBAD9)]),
                                             systemAppearance: .light)
        XCTAssertTrue(picked.webPanelBackgroundGradient.isEmpty)
        // Drawn by the panel: the gradient view renders.
        let host = NSHostingView(rootView: WebPanel(tab: nil, background: light.webPanelBackground,
                                                    backgroundGradient: light.webPanelBackgroundGradient)
            .frame(width: 200, height: 120))
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 120)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize, CGSize(width: 200, height: 120))
    }

    // MARK: F5-58/70 command bar close

    /// [07 §11] observed: the panel is gone ≈ 40–60 ms after closing (design-tokens.json
    /// `motion.commandBar.closeMs` 50); the curve is unknown, so ours is a short fade (inferred).
    /// Opening stays a one-frame jump.
    func testCommandBarCloseIsShortFade_07_11() {
        XCTAssertEqual(Motion.commandBarClose.evidence, .inferred)
        XCTAssertEqual(Motion.commandBarClose.curve.nominalDuration, 0.05, accuracy: 0.011)
        XCTAssertGreaterThanOrEqual(Motion.commandBarClose.curve.nominalDuration, 0.04)
        XCTAssertLessThanOrEqual(Motion.commandBarClose.curve.nominalDuration, 0.06)
        XCTAssertNil(ShellMotion.commandBarPresence(isPresented: true), "open: no animation")
        XCTAssertNotNil(ShellMotion.commandBarPresence(isPresented: false))
    }

    // MARK: F5-33 dock Home label

    /// [05 §窗口层级] observed (AX): the dock's last button is "Home"; it opens the Library ([06 §20.2]).
    func testDockHomeButtonLabel_05() {
        XCTAssertEqual(SidebarLocalTokens.dockHomeAccessibilityLabel, "Home")
    }

    // MARK: Helpers

    private func waitFor(timeout: Double = 2, _ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return XCTFail("timed out") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
