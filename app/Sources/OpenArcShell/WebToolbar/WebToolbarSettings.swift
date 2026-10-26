import Foundation
import Combine
import OpenArcDesign

// View ▸ Show Toolbar and Settings ▸ Advanced "Show full URL when Toolbar is enabled" (plan B43).
// Both are app-level, per-device settings: [06 §17.1] observed that Show Toolbar is global (a new
// window opens with it too); [03 §Advanced] lists the full-URL switch with the app settings.

extension AppPreferences {
    static let showsWebToolbarKey = "\(keyPrefix)view.showToolbar"
    static let showsFullURLInToolbarKey = "\(keyPrefix)advanced.showFullURL"

    /// View ▸ Show Toolbar. Fresh-install default unknown ([06 §17.1]); off (`Metrics.WebToolbar.defaultIsShown`).
    public var showsWebToolbar: Bool {
        get { boolValue(Self.showsWebToolbarKey) ?? Metrics.WebToolbar.defaultIsShown }
        set { setBool(newValue, Self.showsWebToolbarKey) }
    }

    /// "Show full URL when Toolbar is enabled". [03 §Advanced] observed, off by default.
    public var showsFullURLInWebToolbar: Bool {
        get { boolValue(Self.showsFullURLInToolbarKey) ?? Metrics.WebToolbar.defaultShowsFullURL }
        set { setBool(newValue, Self.showsFullURLInToolbarKey) }
    }
}

/// The two toolbar settings as one observable object, shared by every window of the app (an
/// incognito controller uses its parent's), so toggling in one window updates all of them.
@MainActor
public final class WebToolbarSettings: ObservableObject {
    private let preferences: AppPreferences

    /// View ▸ Show Toolbar / Hide Toolbar (⇧⌘D). [06 §17.1] observed.
    @Published public var isShown: Bool {
        didSet { if isShown != oldValue { preferences.showsWebToolbar = isShown } }
    }

    /// Settings ▸ Advanced ▸ Show full URL when Toolbar is enabled. [03 §Advanced], [06 §17.2] observed.
    @Published public var showsFullURL: Bool {
        didSet { if showsFullURL != oldValue { preferences.showsFullURLInWebToolbar = showsFullURL } }
    }

    public init(preferences: AppPreferences) {
        self.preferences = preferences
        isShown = preferences.showsWebToolbar
        showsFullURL = preferences.showsFullURLInWebToolbar
    }

    /// Title of the View menu item. [06 §17.1] observed ("Show Toolbar", "Hide Toolbar" while on).
    public var menuTitle: String { isShown ? "Hide Toolbar" : "Show Toolbar" }

    public func toggle() { isShown.toggle() }
}
