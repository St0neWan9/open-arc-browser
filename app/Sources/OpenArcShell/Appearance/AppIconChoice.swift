import Foundation
import AppKit
import CoreGraphics
import Combine

// Settings ▸ Icon [03 §Icon] observed: six choices with a CURRENT ICON marker.
// All treatments share the approved folded-ribbon artwork. Selection is stored per device
// and applied to the Dock at launch. Finder keeps the signed bundle's default icon.

/// An app icon variant. Raw values are persisted (`AppPreferences.appIconChoice`); never rename.
public enum AppIconChoice: String, CaseIterable, Identifiable, Sendable {
    /// The bundle's own icon (app/Bundle/AppIcon.icns): lavender folded ribbon.
    case slate
    case sunrise
    case night
    case lagoon
    case paper
    case prism

    public static let `default`: AppIconChoice = .slate

    public var id: String { rawValue }

    /// Name under the tile. Our own names.
    public var displayName: String {
        switch self {
        case .slate: return "Original"
        case .sunrise: return "Candy"
        case .lagoon: return "Fluted Glass"
        case .night: return "Neon"
        case .paper: return "Paper"
        case .prism: return "Spectrum"
        }
    }

}

// MARK: - Rendering

/// Uses the same artwork source as the exported bundle and website assets.
public enum AppIconRenderer {
    public static func cgImage(_ choice: AppIconChoice, pixels: Int = 1024) -> CGImage? {
        AppIconArtwork.render(choice.rawValue, pixels: pixels)
    }

    /// `choice` as an image of `points` × `points` (rendered at 2×).
    public static func image(_ choice: AppIconChoice, points: CGFloat = 512) -> NSImage? {
        guard points.isFinite, points > 0, points <= 2048,
              let cg = cgImage(choice, pixels: Int(points * 2)) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: points, height: points))
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
