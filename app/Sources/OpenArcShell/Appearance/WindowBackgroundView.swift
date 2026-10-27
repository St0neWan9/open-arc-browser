import SwiftUI
import AppKit
import OpenArcDesign

// Window background of a Space (plan B21): the theme color or gradient, with the grain overlay.

/// The themed window background: a solid color for a one-color theme, a gradient across the dots
/// for several ([06 §2] observed several dots; the gradient direction is inferred), plus the grain
/// overlay when `palette.grain > 0`.
struct WindowBackgroundView: View {
    let palette: ThemePalette

    /// The grain overlay is drawn (for tests).
    var showsGrain: Bool { GrainNoise.overlayOpacity(for: palette.grain) != nil }

    var body: some View {
        ZStack {
            if palette.backgroundGradientColors.count > 1 {
                LinearGradient(
                    colors: palette.backgroundGradientColors.map(\.swiftUI),
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            } else {
                palette.windowBackground.swiftUI
            }
            if let opacity = GrainNoise.overlayOpacity(for: palette.grain) {
                GrainOverlay(opacity: opacity)
            }
        }
        .allowsHitTesting(false)
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
