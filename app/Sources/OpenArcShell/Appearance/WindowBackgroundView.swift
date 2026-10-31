import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Window background of a Space (plan B21): the theme color or gradient, with the grain overlay.

/// The themed window background: a solid color for a one-color theme, a gradient across the dots
/// for several ([06 §2] observed several dots; the gradient direction is inferred), plus the grain
/// overlay when `palette.grain > 0`. On a see-through surface (B64, [07 §8.4]; B146 [07 §8.2]) the
/// colors are Arc's translucent theme layers over the light blur material behind the window.
struct WindowBackgroundView: View {
    let palette: ThemePalette
    var surface: WindowSurface = .opaque

    /// The grain overlay is drawn (for tests).
    var showsGrain: Bool { GrainNoise.overlayOpacity(for: palette.grain) != nil }
    /// The blur of the desktop is drawn (for tests).
    var showsBlur: Bool { surface.isTranslucent }

    /// The colors painted: the opaque palette, or its theme layers over the blur material.
    var paintedColors: [RGBAColor] {
        if surface.isTranslucent {
            return palette.backgroundGradientColors.count > 1 ? palette.backgroundGradientLayers : [palette.windowThemeLayer]
        }
        return palette.backgroundGradientColors.count > 1 ? palette.backgroundGradientColors : [palette.windowBackground]
    }

    var body: some View {
        let colors = paintedColors
        ZStack {
            if showsBlur {
                BehindWindowBlur()
            }
            if colors.count > 1 {
                // Several dots run top → bottom [07 §8.4]; the no-color wash runs diagonally with
                // its stops at the sampled places [07 §8.5].
                let axis = palette.backgroundGradientAxis
                LinearGradient(
                    stops: Self.stops(colors, locations: palette.backgroundGradientLocations),
                    startPoint: UnitPoint(x: axis.startX, y: axis.startY),
                    endPoint: UnitPoint(x: axis.endX, y: axis.endY)
                )
            } else {
                (colors.first ?? palette.windowBackground).swiftUI
            }
            if let opacity = GrainNoise.overlayOpacity(for: palette.grain) {
                GrainOverlay(opacity: opacity)
            }
        }
        .allowsHitTesting(false)
    }

    /// Gradient stops: at `locations` when there is one per color, else evenly spread.
    static func stops(_ colors: [RGBAColor], locations: [Double]?) -> [Gradient.Stop] {
        let places: [Double]
        if let locations, locations.count == colors.count {
            places = locations
        } else {
            places = colors.indices.map { colors.count > 1 ? Double($0) / Double(colors.count - 1) : 0 }
        }
        return zip(colors, places).map { Gradient.Stop(color: $0.swiftUI, location: CGFloat($1)) }
    }
}

/// The content area's fill where no page paints: the palette's content gradient (top left →
/// bottom right) when it has one, else `webPanelBackground` flat. [07 §8.1], [07 §8.5] observed.
struct WebPanelBackgroundView: View {
    let palette: ThemePalette

    var body: some View {
        let gradient = palette.webPanelBackgroundGradient
        if gradient.count > 1 {
            LinearGradient(stops: WindowBackgroundView.stops(gradient, locations: nil),
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        } else {
            palette.webPanelBackground.swiftUI
        }
    }
}

/// The noise tile, tiled over the whole area with an overlay blend. inferred look (our own).
struct GrainOverlay: View {
    let opacity: Double

    var body: some View {
        if let tile = GrainTile.image {
            Image(decorative: tile, scale: GrainTile.scale)
                .resizable(resizingMode: .tile)
                .blendMode(.overlay)
                .opacity(opacity)
                .accessibilityHidden(true)
                .accessibilityIdentifier("openarc.window.grain")
        }
    }
}

/// The cached grain tile image, made once from `GrainNoise.tilePixels()`.
enum GrainTile {
    /// Points per tile pixel: 2 so the grain is one device pixel on Retina screens.
    static let scale: CGFloat = 2

    static let image: CGImage? = {
        let size = GrainNoise.tileSize
        let data = Data(GrainNoise.tilePixels()) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(
            width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }()
}

/// Gives the hosting window the Space's light or dark appearance, so system-drawn floating panels
/// (popovers, menus, sheets) match it. [04 §dark mode] observed: floating panels go dark in a dark
/// Space (an incognito window: its fixed palette's, B48). nil leaves the window alone.
struct WindowAppearanceApplier: NSViewRepresentable {
    let appearance: ResolvedAppearance?

    func makeNSView(context: Context) -> AppearanceApplierView {
        let view = AppearanceApplierView()
        view.appearanceToApply = appearance
        return view
    }

    func updateNSView(_ nsView: AppearanceApplierView, context: Context) {
        nsView.appearanceToApply = appearance
    }

    final class AppearanceApplierView: NSView {
        var appearanceToApply: ResolvedAppearance? {
            didSet { apply() }
        }

        /// Transparent to the mouse: as the window content's background it would otherwise take
        /// every press and right-click that lands on a gap between the sidebar's blocks (B147).
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window, let appearanceToApply else { return }
            let name: NSAppearance.Name = appearanceToApply == .dark ? .darkAqua : .aqua
            if window.appearance?.name != name { window.appearance = NSAppearance(named: name) }
        }
    }
}
