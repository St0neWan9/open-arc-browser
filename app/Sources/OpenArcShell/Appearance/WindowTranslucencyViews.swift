import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The see-through browser window (plan B64). docs/arc-spec/07-design-system.md §8.4 (E8),
// design-tokens.json `ThemeDerivation.windowTranslucency`: Arc lets ≈ 11 % (light) / 19 % (dark)
// of the blurred desktop through the window background, the sidebar, its controls and separators,
// as a plain alpha composite over a blur (pure red / green / blue backdrops only move their own
// channel, so no vibrancy, no saturation boost) [07 §8.4] observed. The web content, the command
// bar and the bubbles stay opaque.
//
// Our window, composited like Arc's (B146, [07 §8.2] inferred (analysis)): the light blur
// material behind the window, untouched (`BehindWindowBlurView`), Arc's translucent theme layer
// above it (`ThemePalette.windowThemeLayer`: the theme color over a white / black veil, which over
// the reference desktop shows the opaque palette), and the sidebar's controls drawn as layers
// (`WindowLayers`) on top. The window itself is non-opaque with a clear background.
// Opaque instead (the palette's own colors, no blur) in full screen (no desktop behind the window;
// Arc there is unknown, inferred), with Reduce Transparency on (system setting, inferred), and for
// palettes that ask for it (incognito, B48).

/// Whether the window chrome is see-through right now. Views that draw on the window background
/// read it from the environment to pick layers or opaque colors.
struct WindowSurface: Equatable, Sendable {
    var isTranslucent: Bool

    /// Opaque: the palette's own colors, no desktop through them. The default, so surfaces that
    /// are not the window (the peek panel, previews, tests) keep opaque fills.
    static let opaque = WindowSurface(isTranslucent: false)
    static let translucent = WindowSurface(isTranslucent: true)

    init(isTranslucent: Bool) {
        self.isTranslucent = isTranslucent
    }

    /// The window's surface: see-through when the palette is, unless the window is in full screen
    /// or the system asks for reduced transparency. [07 §8.4]; the exceptions are inferred.
    init(palette: ThemePalette, isFullScreen: Bool, reduceTransparency: Bool) {
        isTranslucent = palette.isWindowTranslucent && !isFullScreen && !reduceTransparency
    }
}

private struct WindowSurfaceKey: EnvironmentKey {
    static let defaultValue: WindowSurface = .opaque
}

extension EnvironmentValues {
    /// The surface of the window this view draws on. [07 §8.4] B64.
    var windowSurface: WindowSurface {
        get { self[WindowSurfaceKey.self] }
        set { self[WindowSurfaceKey.self] = newValue }
    }
}

extension ThemePalette {
    /// Fills drawn on the window background: layers on a see-through window (so the desktop shows
    /// through them as through the window, [07 §8.4]), the opaque colors otherwise. Over the
    /// opaque window color both give the same result.
    func windowFills(on surface: WindowSurface) -> WindowLayers {
        surface.isTranslucent ? windowLayers : opaqueWindowLayers
    }

    /// The sidebar's own background on `surface`: nothing on a see-through window (the window
    /// background under it already shows the window color; painting the tint twice would hide the
    /// desktop), the window color when opaque.
    func sidebarBackground(on surface: WindowSurface) -> Color {
        surface.isTranslucent ? Color.clear : windowBackground.swiftUI
    }
}

/// The material under the theme layer, as Arc sets it up (B146, [07 §8.2] inferred (analysis)): an
/// `NSVisualEffectView` blending behind the window, emphasized, following the window's active state,
/// with the material the theme picks (`ThemeDerivation.windowBackdropMaterial`, the fixed light
/// material) and left untouched. The theme layer painted above it is translucent itself, so the
/// window shows layer + material + blurred desktop like Arc's.
final class BehindWindowBlurView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    /// AppKit's material for one of ours (the raw values are AppKit's public ones).
    static func material(for backdrop: WindowBackdropMaterial) -> NSVisualEffectView.Material {
        NSVisualEffectView.Material(rawValue: backdrop.rawValue) ?? .windowBackground
    }

    private func configure() {
        material = Self.material(for: ThemeDerivation.windowBackdropMaterial)
        blendingMode = .behindWindow
        state = .followsWindowActiveState
        isEmphasized = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// SwiftUI host of the blur.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> BehindWindowBlurView { BehindWindowBlurView(frame: .zero) }
    func updateNSView(_ nsView: BehindWindowBlurView, context: Context) {}
}

/// Makes the hosting window non-opaque with a clear background (so the blur and the tint show),
/// and reports whether it is in full screen. Writes only what differs and reports changes on the
/// next run-loop turn, never from inside a SwiftUI update (B28).
struct TranslucentWindowConfigurator: NSViewRepresentable {
    let onFullScreenChange: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.onFullScreenChange = onFullScreenChange
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.onFullScreenChange = onFullScreenChange
    }

    static func dismantleNSView(_ nsView: ConfiguratorView, coordinator: ()) {
        nsView.detach()
    }

    final class ConfiguratorView: NSView {
        var onFullScreenChange: (@MainActor (Bool) -> Void)?
        private weak var observedWindow: NSWindow?
        private var reportedFullScreen: Bool?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== observedWindow else { return }
            detach()
            observedWindow = window
            Self.makeClear(window)
            let center = NotificationCenter.default
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                center.addObserver(self, selector: #selector(fullScreenDidChange(_:)), name: name, object: window)
            }
            scheduleReport(window.styleMask.contains(.fullScreen))
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            observedWindow = nil
        }

        /// Non-opaque, clear background. Returns whether anything changed.
        @discardableResult
        static func makeClear(_ window: NSWindow) -> Bool {
            var changed = false
            if window.isOpaque { window.isOpaque = false; changed = true }
            if window.backgroundColor != .clear { window.backgroundColor = .clear; changed = true }
            return changed
        }

        @objc private func fullScreenDidChange(_ notification: Notification) {
            // Entering: opaque from the start of the transition; exiting: see-through again once
            // the window is back on the desktop.
            let entering = notification.name == NSWindow.willEnterFullScreenNotification
                || notification.name == NSWindow.didEnterFullScreenNotification
            scheduleReport(entering)
        }

        private func scheduleReport(_ isFullScreen: Bool) {
            guard reportedFullScreen != isFullScreen else { return }
            reportedFullScreen = isFullScreen
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onFullScreenChange?(isFullScreen) }
            }
        }
    }
}
