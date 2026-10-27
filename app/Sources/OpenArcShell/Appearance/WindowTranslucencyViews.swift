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
// Our window: a behind-window blur at the bottom (`BehindWindowBlurView`), the theme tint
// (`ThemePalette.windowTint`, solved so that over the mid-gray reference desktop the window shows
// the opaque palette) at `windowOpacity` above it, and the sidebar's controls drawn as layers
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

/// A plain blur of what is behind the window: an `NSVisualEffectView` in behind-window blending,
/// always active, with the material's own tint layers hidden and its saturation boost neutralized,
/// so the theme tint above composites over the blurred desktop alone ([07 §8.4] observed: plain
/// alpha over a blur). The layer names belong to AppKit's material and may change between macOS
/// versions; if they are not found the material keeps its own (light or dark gray) tint, which is
/// still readable, only less exact.
final class BehindWindowBlurView: NSVisualEffectView {
    /// Names of the material's tint layers (observed on macOS 26 with a layer dump; not API).
    static let tintLayerNames: Set<String> = ["fill", "tone"]
    /// Backdrop saturation: 1 = unchanged colors (the materials boost it ≈ 2×).
    static let backdropSaturation: Double = 1

    /// Number of passes that changed a layer (for tests).
    private(set) var stripCount = 0
    private var isStripScheduled = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        material = .underWindowBackground
        blendingMode = .behindWindow
        // Active in background windows too: Arc's window stays see-through when not key
        // ([07 §8.1] observed it lighter but still themed; the exact inactive look is unknown).
        state = .active
        isEmphasized = false
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        stripMaterialTint()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleStrip()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // The material rebuilds its layers for the new appearance after this call.
        scheduleStrip()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleStrip()
    }

    private func scheduleStrip() {
        stripMaterialTint()
        guard !isStripScheduled else { return }
        isStripScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.isStripScheduled = false
                self?.stripMaterialTint()
            }
        }
    }

    /// Hides the material's tint layers and sets the backdrop saturation to 1. Writes only what
    /// differs, so repeated passes cost nothing.
    func stripMaterialTint() {
        guard let root = layer else { return }
        var changed = false
        func walk(_ layer: CALayer) {
            for sub in layer.sublayers ?? [] {
                if NSStringFromClass(type(of: sub)).hasSuffix("BackdropLayer") {
                    let key = "filters.colorSaturate.inputAmount"
                    if sub.filters?.isEmpty == false,
                       let amount = sub.value(forKeyPath: key) as? NSNumber, amount.doubleValue != Self.backdropSaturation {
                        sub.setValue(Self.backdropSaturation, forKeyPath: key)
                        changed = true
                    }
                } else if let name = sub.name, Self.tintLayerNames.contains(name) || NSStringFromClass(type(of: sub)).hasSuffix("ChameleonLayer") {
                    if !sub.isHidden { sub.isHidden = true; changed = true }
                }
                walk(sub)
            }
        }
        walk(root)
        if changed { stripCount += 1 }
    }

    /// Whether a visible tint layer is left (for tests).
    var hasVisibleMaterialTint: Bool {
        func visible(_ layer: CALayer) -> Bool {
            for sub in layer.sublayers ?? [] {
                if let name = sub.name, Self.tintLayerNames.contains(name), !sub.isHidden { return true }
                if visible(sub) { return true }
            }
            return false
        }
        return layer.map(visible) ?? false
    }
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
