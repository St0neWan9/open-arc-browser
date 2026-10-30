import Foundation
import OpenArcModel
import OpenArcDesign

// Browser windows (plan B14). Spec: [01 §File] observed the items New Window, Blank Window,
// New Incognito Window and Close Window; [02 §窗口与应用] observed ⌘N / ⌃⌘N / ⇧⌘N / ⇧⌘W.
// Everything about what those windows contain is inferred (the spec records no window behavior):
// - New Window opens on the Space of the window it came from, with that Space's remembered tab;
// - Blank Window opens on the same Space with no tab selected;
// - an incognito window has its own in-memory Space and tabs, never saved or synced;
// - a tab's page is on screen in one window at a time; selecting it in another window brings the
//   window that shows it to the front;
// - closing the last window keeps the app running (macOS convention).

/// What a browser window opens with. The value is the SwiftUI window's data, so every request
/// carries a fresh `id` (each one opens a new window).
public struct BrowserWindowRequest: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Reopens a window of the last session (or the first window of a first launch).
        case restore
        /// New Window (⌘N): the active window's Space and its remembered tab. inferred.
        case newWindow
        /// Blank Window (⌃⌘N): the active window's Space, no tab selected. inferred from the name.
        case blank
        /// New Incognito Window (⇧⌘N): off-the-record tabs outside the workspace. inferred.
        case incognito
    }

    public var id: UUID
    public var kind: Kind
    /// Space to open on; nil uses the active window's.
    public var spaceID: UUID?
    /// Tab a `.newWindow` window shows (a page asked for a new window, C7b); nil picks the Space's
    /// most recent tab.
    public var tabID: UUID?
    /// Page an `.incognito` window opens with instead of its command bar (the page context
    /// menu's "Open Link in Incognito Window", B124); nil for the usual empty window.
    public var url: URL?

    public init(id: UUID = UUID(), kind: Kind, spaceID: UUID? = nil, tabID: UUID? = nil, url: URL? = nil) {
        self.id = id
        self.kind = kind
        self.spaceID = spaceID
        self.tabID = tabID
        self.url = url
    }
}

/// Local tokens of the incognito window's in-memory workspace. The look itself is fixed
/// (`IncognitoTokens`, `ThemeDerivation.incognitoPalette`, [06 §20] observed, B48).
enum IncognitoLocalTokens {
    /// Color recorded in the in-memory theme. The sidebar does not derive from it (the incognito
    /// palette is fixed); it is the observed window color. [06 §20.1] observed.
    static let themeColor = IncognitoTokens.windowBackground
    /// Automatic, so the pages follow View ▸ Appearance and the system like the chrome does.
    /// inferred (B48).
    static let themeAppearance: ThemeAppearance = .automatic
    /// Name of the in-memory profile. unknown (never shown).
    static let profileName = "Incognito"
    /// The Space-name row reads "Incognito Tabs", without an icon (the name starts at x 13).
    /// [06 §20.1] observed.
    static let spaceName = "Incognito Tabs"
    static let spaceIcon: String? = nil
}

extension AppPreferences {
    static let restoreWindowsKey = "\(keyPrefix)advanced.restoreWindows"

    /// "When opening Arc, restore windows from previous session". [03 §Advanced] observed toggle,
    /// off by default. Per device (app-level setting).
    public var restoresWindowsFromPreviousSession: Bool {
        get { boolValue(Self.restoreWindowsKey) ?? false }
        set { setBool(newValue, Self.restoreWindowsKey) }
    }
}
