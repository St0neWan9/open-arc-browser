import Foundation
import AppKit
import CoreGraphics
import CoreText
import Combine

// Settings ▸ Icon (plan B84). [03 §Icon] observed: a list of six app icons with a CURRENT ICON
// marker next to the chosen one; some of Arc's are unlocked by sharing Arc. Ours are six of our
// own color variants of the placeholder icon drawn by scripts/make-app-icon.swift (a rounded
// square with a gradient and the letters "OA"); none is locked (we have no referral program).
// The choice is shown in the Dock and the app switcher while the app runs
// (`NSApplication.applicationIconImage`) and stored per device, so it is applied again at launch.
// The Finder icon of the bundle stays the default one (changing it would modify the signed bundle).

/// An app icon variant. Raw values are persisted (`AppPreferences.appIconChoice`); never rename.
public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    /// The bundle's own icon (app/Bundle/AppIcon.icns): neutral slate.
    case slate
    case sunrise
    case lagoon
    case night
    case paper
    case prism

    public static let `default`: AppIconChoice = .slate

    public var id: String { rawValue }

    /// Name under the tile. Our own names.
    public var displayName: String {
        switch self {
        case .slate: return "Slate"
        case .sunrise: return "Sunrise"
        case .lagoon: return "Lagoon"
        case .night: return "Night"
        case .paper: return "Paper"
        case .prism: return "Prism"
        }
    }

    /// Body gradient, top to bottom (sRGB hex).
    var gradient: [UInt32] {
        switch self {
        // Same colors as scripts/make-app-icon.swift, so the default matches AppIcon.icns.
        case .slate: return [0x8F99A8, 0x3D4552]
        case .sunrise: return [0xFFB25B, 0xF2546E]
        case .lagoon: return [0x5EE0C8, 0x2F6BE0]
        case .night: return [0x2A2D3A, 0x0B0C12]
        case .paper: return [0xFBFAF6, 0xE4E1D8]
        case .prism: return [0xFF7A9C, 0xFFC857, 0x58D6A6, 0x5B8CFF]
        }
    }

    /// Letter color (sRGB hex).
    var ink: UInt32 {
        switch self {
        case .night: return 0x7CF5C4
        case .paper: return 0x2B2E36
        default: return 0xFFFFFF
        }
    }
}

// MARK: - Rendering

/// Draws an `AppIconChoice` the way scripts/make-app-icon.swift draws the bundle icon: a body
/// inset like the macOS icon grid (824 of 1024), corner radius 185, a soft shadow, a top-to-bottom
/// gradient and the letters "OA".
public enum AppIconRenderer {
    /// Draws `choice` into a square bitmap `pixels` wide. nil only if CoreGraphics fails.
    public static func cgImage(_ choice: AppIconChoice, pixels: Int = 1024) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let scale = CGFloat(pixels) / 1024
        ctx.scaleBy(x: scale, y: scale)

        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
        let colors = choice.gradient.map { color($0) }

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
        ctx.addPath(shape)
        ctx.setFillColor(colors.last ?? color(0x000000))
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape)
        ctx.clip()
        let locations = colors.indices.map { CGFloat($0) / CGFloat(max(1, colors.count - 1)) }
        if let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        }
        ctx.restoreGState()

        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 380, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(choice.ink, alpha: 0.95),
            NSAttributedString.Key(kCTKernAttributeName as String): -10,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "OA", attributes: attributes))
        let bounds = CTLineGetImageBounds(line, ctx)
        ctx.textPosition = CGPoint(x: body.midX - bounds.midX, y: body.midY - bounds.midY)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    /// `choice` as an image of `points` × `points` (rendered at 2×).
    public static func image(_ choice: AppIconChoice, points: CGFloat = 512) -> NSImage? {
        guard let cg = cgImage(choice, pixels: Int(points * 2)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: points, height: points))
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - Display

/// Shows the chosen icon in the Dock. Injected through `AppDependencies`, so tests and previews
/// never change the running app's icon.
@MainActor
public protocol AppIconDisplay: AnyObject, Sendable {
    func show(_ choice: AppIconChoice)
}

/// Remembers the last icon instead of showing it (tests, previews, `.fake()`).
@MainActor
public final class RecordingAppIconDisplay: AppIconDisplay {
    public private(set) var shown: [AppIconChoice] = []
    public nonisolated init() {}
    public func show(_ choice: AppIconChoice) { shown.append(choice) }
}

/// The running app's Dock tile and app switcher icon (`NSApplication.applicationIconImage`).
@MainActor
public final class SystemAppIconDisplay: AppIconDisplay {
    public nonisolated init() {}

    public func show(_ choice: AppIconChoice) {
        // nil restores the bundle's icon, which is the default variant.
        NSApplication.shared.applicationIconImage = choice == .default ? nil : AppIconRenderer.image(choice)
        NSApplication.shared.dockTile.display()
    }
}

/// The Icon pane's state: the current icon, persisted, and the tile images. One per app.
@MainActor
public final class AppIconSettings: ObservableObject {
    private let preferences: AppPreferences
    private let display: any AppIconDisplay
    /// CURRENT ICON. [03 §Icon] observed marker.
    @Published public private(set) var current: AppIconChoice
    private var tiles: [AppIconChoice: NSImage] = [:]

    init(preferences: AppPreferences, display: any AppIconDisplay) {
        self.preferences = preferences
        self.display = display
        current = preferences.appIconChoice
    }

    /// At launch: shows the stored choice. The default needs nothing (the bundle icon shows).
    func applyStored() {
        guard current != .default else { return }
        display.show(current)
    }

    /// A tile was clicked: store the choice and show it in the Dock.
    public func select(_ choice: AppIconChoice) {
        guard choice != current else { return }
        current = choice
        preferences.appIconChoice = choice
        display.show(choice)
    }

    /// Tile image, rendered once.
    func tileImage(_ choice: AppIconChoice) -> NSImage {
        if let image = tiles[choice] { return image }
        let image = AppIconRenderer.image(choice, points: 128) ?? NSImage()
        tiles[choice] = image
        return image
    }
}
