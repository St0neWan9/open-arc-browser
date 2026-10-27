import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Plan B64: the see-through browser window. Spec: docs/arc-spec/07-design-system.md §8.4 (E8),
/// design-tokens.json `ThemeDerivation.windowTranslucency`: window, sidebar, controls and separators
/// over the blurred desktop (≈ 0.886 light / 0.812 dark, observed, plain alpha over a blur);
/// content, command bar and bubbles opaque (observed). Full screen, Reduce Transparency, the
/// hidden-sidebar peek panel and incognito stay opaque (inferred).
@MainActor
final class WindowTranslucencyShellTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func palette(_ hex: UInt32 = 0xA5729C, _ appearance: ResolvedAppearance = .light) -> ThemePalette {
        let theme = Theme(id: UUID(), appearance: appearance == .dark ? .dark : .light, colors: [RGBAColor(hex: hex)], now: t0)
        return ThemeDerivation.palette(for: theme, systemAppearance: .light)
    }

    // MARK: Surface

    /// [07 §8.4]: see-through by default; full screen and Reduce Transparency opaque (inferred);
    /// an opaque palette (incognito) stays opaque.
    func testSurfaceRules() {
        let p = palette()
        XCTAssertTrue(WindowSurface(palette: p, isFullScreen: false, reduceTransparency: false).isTranslucent)
        XCTAssertFalse(WindowSurface(palette: p, isFullScreen: true, reduceTransparency: false).isTranslucent)
        XCTAssertFalse(WindowSurface(palette: p, isFullScreen: false, reduceTransparency: true).isTranslucent)
        let incognito = ThemeDerivation.incognitoPalette(appearance: .dark)
        XCTAssertFalse(WindowSurface(palette: incognito, isFullScreen: false, reduceTransparency: false).isTranslucent)
        XCTAssertEqual(EnvironmentValues().windowSurface, .opaque, "previews, tests and the peek default to opaque")
    }

    /// On a see-through window the sidebar draws controls as layers and no own background; opaque
    /// surfaces keep the opaque colors. [07 §8.4]
    func testFillsPerSurface() {
        let p = palette()
        XCTAssertEqual(p.windowFills(on: .translucent), p.windowLayers)
        XCTAssertEqual(p.windowFills(on: .opaque).controlFill, p.controlFill)
        XCTAssertEqual(p.windowFills(on: .opaque).selectedRowFill, p.selectedTabFill)
        XCTAssertEqual(p.windowFills(on: .opaque).separator, p.separator)
        XCTAssertLessThan(p.windowFills(on: .translucent).controlFill.alpha, 1)
        XCTAssertEqual(p.sidebarBackground(on: .translucent), Color.clear)
    }

    /// The window background paints the solved tint over the blur when see-through, the opaque
    /// color otherwise; gradients map every stop. [07 §8.4]
    func testWindowBackgroundColors() {
        let p = palette(0x6CBAD9, .dark)
        let see = WindowBackgroundView(palette: p, surface: .translucent)
        XCTAssertTrue(see.showsBlur)
        XCTAssertEqual(see.paintedColors, [p.windowTint])
        XCTAssertEqual(see.paintedColors.first?.alpha, 0.812)
        let opaque = WindowBackgroundView(palette: p, surface: .opaque)
        XCTAssertFalse(opaque.showsBlur)
        XCTAssertEqual(opaque.paintedColors, [p.windowBackground])

        let multi = ThemeDerivation.palette(forStyle: ThemeStyle(appearance: .light, colors: [RGBAColor(hex: 0xF19CBB), RGBAColor(hex: 0x6CBAD9)]),
                                            appearance: .light)
        XCTAssertEqual(WindowBackgroundView(palette: multi, surface: .translucent).paintedColors, multi.backgroundGradientTints)
        XCTAssertEqual(WindowBackgroundView(palette: multi, surface: .translucent).paintedColors.count, 2)

        let host = NSHostingView(rootView: see.frame(width: 300, height: 200))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.layoutSubtreeIfNeeded()
    }

    /// The selected dark favorite tile is a white layer on a see-through window, the opaque mix
    /// otherwise; both give the same color over the opaque window. [06 §21.3], [07 §8.4]
    func testSelectedFavoriteTileLayer() {
        let p = palette(0x6CBAD9, .dark)
        let opaque = SidebarFavoriteCell.fill(palette: p, isSelected: true)
        let layer = SidebarFavoriteCell.fill(palette: p, isSelected: true, surface: .translucent)
        let composite = WindowTranslucency.composite(layer, over: p.windowBackground)
        XCTAssertEqual(composite.red, opaque.red, accuracy: 1e-9)
        XCTAssertEqual(composite.blue, opaque.blue, accuracy: 1e-9)
        XCTAssertEqual(SidebarFavoriteCell.fill(palette: p, isSelected: false, surface: .translucent), p.windowLayers.controlFill)
    }

    // MARK: Blur view

    /// A behind-window blur, always active, with the material's own tint layers hidden and its
    /// saturation boost set to 1: plain alpha over a blur ([07 §8.4] observed: pure red / green /
    /// blue backdrops move only their own channel).
    func testBlurIsPlainBehindWindowBlur() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let blur = BehindWindowBlurView(frame: CGRect(x: 0, y: 0, width: 200, height: 200))
        window.contentView = blur
        XCTAssertEqual(blur.blendingMode, .behindWindow)
        XCTAssertEqual(blur.state, .active)
        XCTAssertNil(blur.hitTest(CGPoint(x: 10, y: 10)), "never takes clicks")
        blur.needsLayout = true
        blur.layoutSubtreeIfNeeded()
        blur.stripMaterialTint()
        XCTAssertFalse(blur.hasVisibleMaterialTint)
        // A second pass changes nothing.
        let count = blur.stripCount
        blur.stripMaterialTint()
        XCTAssertEqual(blur.stripCount, count)
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            blur.layoutSubtreeIfNeeded()
            blur.stripMaterialTint()
            XCTAssertFalse(blur.hasVisibleMaterialTint, appearance.rawValue)
        }
        window.close()
    }

    // MARK: Window

    /// The browser window becomes non-opaque with a clear background; full-screen transitions are
    /// reported on the next run-loop turn. [07 §8.4]
    func testConfiguratorClearsTheWindowAndReportsFullScreen() async {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        XCTAssertTrue(window.isOpaque)
        var reports: [Bool] = []
        let view = TranslucentWindowConfigurator.ConfiguratorView()
        view.onFullScreenChange = { reports.append($0) }
        window.contentView = NSView()
        window.contentView?.addSubview(view)
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
        XCTAssertFalse(TranslucentWindowConfigurator.ConfiguratorView.makeClear(window), "settled: nothing to write")
        NotificationCenter.default.post(name: NSWindow.willEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didEnterFullScreenNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)
        await Task.yield()
        for _ in 0..<5 where reports.count < 3 { try? await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(reports, [false, true, false], "initial state, entering (once), back on the desktop")
        view.detach()
        window.close()
    }

    /// The main window content builds with the see-through background. [07 §8.4]
    func testSidebarLaysOutOnASeeThroughWindow() {
        let vm = SidebarPreviewFixtures.makeViewModel()
        let host = NSHostingView(rootView: SidebarView(viewModel: vm).environment(\.windowSurface, .translucent))
        host.frame = CGRect(x: 0, y: 0, width: 276, height: 985)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 276, accuracy: 0.5)
        vm.stop()
    }
}
