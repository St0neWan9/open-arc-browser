import Foundation
import OpenArcEngine

// The two Peek switches of Settings ▸ Links (plan B49). [03 §Links] observed: "Shift-click a link"
// and "links to other sites (only affects Favorites and Pinned tabs)"; [06 §25.1] observed the
// second one's note "This only affects Favorites and Pinned tabs". The spec records no defaults:
// both on is inferred ([06 §22] shows both behaviors with the user's values, which were not changed).

extension AppPreferences {
    static let peekShiftClickKey = "\(keyPrefix)links.peekShiftClick"
    static let peekOtherSitesKey = "\(keyPrefix)links.peekOtherSites"

    /// "Shift-click a link to open it in Peek". Per device.
    public var opensPeekOnShiftClick: Bool {
        get { boolValue(Self.peekShiftClickKey) ?? true }
        set { setBool(newValue, Self.peekShiftClickKey) }
    }

    /// "Open links to other sites in Peek" (Favorites and Pinned tabs only). Per device.
    public var opensPeekForOtherSites: Bool {
        get { boolValue(Self.peekOtherSitesKey) ?? true }
        set { setBool(newValue, Self.peekOtherSitesKey) }
    }
}

extension SettingsModel {
    /// Settings ▸ Links ▸ Peek switches (B49). Changing one updates every live tab's triggers.
    public var opensPeekOnShiftClick: Bool {
        get { preferences.opensPeekOnShiftClick }
        set {
            objectWillChange.send()
            preferences.opensPeekOnShiftClick = newValue
            shell.controller.syncLinkPreviewTriggers()
        }
    }

    public var opensPeekForOtherSites: Bool {
        get { preferences.opensPeekForOtherSites }
        set {
            objectWillChange.send()
            preferences.opensPeekForOtherSites = newValue
            shell.controller.syncLinkPreviewTriggers()
        }
    }
}
