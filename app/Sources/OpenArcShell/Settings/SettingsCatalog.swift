import Foundation
import OpenArcModel

// Settings window content, as data. Source: docs/arc-spec/03-settings.md (whole file), observed
// unless a comment says otherwise. Labels that name the product say "Open Arc" instead of "Arc".
//
// Every control the spec lists is here, so the views and the tests share one list. A control
// whose feature does not exist yet is `.pending(task:)`: it is drawn disabled, and `task` names
// the plan task (docs/implementation-plan.md) that will enable it.
//
// Out of scope and therefore absent (plan, B12): the Max pane (AI), and Arc's account,
// membership card and referral items (replaced by the iCloud sync card).

/// The toolbar panes, in the order [03 §页签顺序] observed, minus Max.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case account, general, profiles, links, shortcuts, icon, advanced

    public var id: String { rawValue }

    /// Toolbar label; it also becomes the window title. [03] observed for every pane except the
    /// first, which shows Arc's account in Arc; "Account" is our label (inferred).
    public var title: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .profiles: return "Profiles"
        case .links: return "Links"
        case .shortcuts: return "Shortcuts"
        case .icon: return "Icon"
        case .advanced: return "Advanced"
        }
    }

    /// SF Symbol for the toolbar. Our own choice (icons may differ from Arc, see CLAUDE.md).
    public var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .general: return "gearshape"
        case .profiles: return "person.2"
        case .links: return "link"
        case .shortcuts: return "command"
        case .icon: return "app"
        case .advanced: return "slider.horizontal.3"
        }
    }
}

/// One control in a settings pane.
public struct SettingsControl: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case toggle(defaultValue: Bool)
        /// A dropdown; `defaultValue` is the label shown when nothing was chosen.
        case picker(defaultValue: String)
        case button
        /// A row with an arrow that opens a sub-page.
        case navigationRow
        case list
        case searchField
    }

    public enum Backing: Hashable, Sendable {
        /// Works now.
        case live
        /// Shown disabled until the named plan task lands.
        case pending(task: String)
    }

    /// Stable identifier used by the views and tests.
    public let id: String
    public let label: String
    public let kind: Kind
    public let backing: Backing

    public var isEnabled: Bool { backing == .live }

    init(_ id: String, _ label: String, _ kind: Kind, _ backing: Backing) {
        self.id = id
        self.label = label
        self.kind = kind
        self.backing = backing
    }
}

public enum SettingsCatalog {
    /// The controls of `pane`, top to bottom.
    public static func controls(in pane: SettingsPane) -> [SettingsControl] {
        switch pane {
        case .account: return account
        case .general: return general
        case .profiles: return profiles
        case .links: return links
        case .shortcuts: return shortcuts
        case .icon: return icon
        case .advanced: return advanced
        }
    }

    /// Looks a control up by id. Traps on an unknown id (a programming error in the views).
    public static func control(_ id: String) -> SettingsControl {
        for pane in SettingsPane.allCases {
            if let found = controls(in: pane).first(where: { $0.id == id }) { return found }
        }
        preconditionFailure("unknown settings control \(id)")
    }

    // MARK: Account card [03 §账号卡]

    static let account: [SettingsControl] = [
        // Banner "… isn't your default browser" + button (D2, `DefaultBrowserModel`).
        SettingsControl("account.makeDefault", "Make Open Arc your default", .button, .live),
        // Observed toggle. Live: it stores the choice and starts or stops the sync store. The view
        // disables it when no sync backend is configured (DisabledSyncStore).
        SettingsControl("account.syncSidebar", "Sync Sidebar", .toggle(defaultValue: true), .live),
    ]

    // MARK: General [03 §General]

    static let general: [SettingsControl] = [
        // Observed: a toggle whose row starts with "Info"; what it controls was not recorded
        // (unknown). No plan task covers it yet.
        SettingsControl("general.info", "Info", .toggle(defaultValue: false), .pending(task: "unknown (spec gap)")),
        // Observed, default on. Needs a quit-confirmation hook in the app target (D1 app project).
        SettingsControl("general.warnBeforeQuitting", "Warn before quitting", .toggle(defaultValue: true), .pending(task: "D1")),
        // Previews = Peek (E2 spec gap).
        SettingsControl("general.previewsSettings", "Previews Settings…", .button, .pending(task: "E2")),
        // Observed hint: search engine, auto-archive and download location live in Profile settings.
        SettingsControl("general.profileSettings", "Profile Settings…", .button, .live),
    ]

    // MARK: Profiles [03 §Profiles]

    static let profiles: [SettingsControl] = [
        SettingsControl("profiles.learnMore", "Learn more", .button, .pending(task: "D9")),
        SettingsControl("profiles.list", "Your Profiles", .list, .live),
        SettingsControl("profiles.add", "Add Profile", .button, .live),
        // Deleting needs a TreeOps profile delete (Model change, Opus) plus C11 data removal.
        SettingsControl("profiles.remove", "Remove Profile", .button, .live),
        SettingsControl("profiles.searchEngine", "Search engine", .picker(defaultValue: SearchEngine.default.displayName), .live),
        // Chromium's search engine manager.
        SettingsControl("profiles.searchSettings", "Search Settings…", .button, .pending(task: "C12")),
        // Suggestions come from the engine's suggest service.
        SettingsControl("profiles.searchSuggestions", "Include search engine suggestions", .toggle(defaultValue: true), .pending(task: "C9")),
        SettingsControl("profiles.archiveTabsAfter", "Archive tabs after", .picker(defaultValue: ArchiveLifetime.default.displayName), .live),
        // Default app for new documents (Notes/Easels are E3 gaps); default value unknown.
        SettingsControl("profiles.newDocuments", "New documents", .picker(defaultValue: "—"), .pending(task: "E3")),
        SettingsControl("profiles.downloadLocation", "Download location", .picker(defaultValue: "Downloads"), .pending(task: "C12")),
        SettingsControl("profiles.privacy", "Privacy and Security", .navigationRow, .pending(task: "C12")),
        // C13 made the password manager work in pages; the list view of saved passwords is a follow-up.
        SettingsControl("profiles.passwords", "Passwords", .navigationRow, .pending(task: "C13 follow-up")),
        SettingsControl("profiles.creditCards", "Credit Cards", .navigationRow, .pending(task: "C13 follow-up")),
        SettingsControl("profiles.notifications", "Notifications", .navigationRow, .pending(task: "C12")),
        SettingsControl("profiles.autofill", "Autofill", .navigationRow, .pending(task: "C13 follow-up")),
        SettingsControl("profiles.clearBrowsingData", "Clear Browsing Data", .navigationRow, .pending(task: "C11")),
    ]

    // MARK: Links [03 §Links]
    // The section structure and defaults are observed; the exact English wording of the toggles
    // was recorded only as a paraphrase, so these labels are inferred.

    static let links: [SettingsControl] = [
        // A system-wide hot key needs the app bundle (D1).
        SettingsControl("links.littleArcHotKey", "Press ⌥⌘N in any app to open Little Arc", .toggle(defaultValue: true), .pending(task: "D1")),
        // Modifier-clicks on page links come from the engine.
        SettingsControl("links.littleArcModifierClick", "Open Little Arc when you ⌥⌘-click a link", .toggle(defaultValue: true), .pending(task: "C9")),
        // Live (B24): web links from other apps open in a new expanded Little Arc window. The spec
        // records no default for this toggle; off is inferred (`AppPreferences.opensExternalLinksInLittleArc`).
        SettingsControl("links.littleArcExternal", "Open links from other apps in Little Arc", .toggle(defaultValue: false), .live),
        // Observed default 6 hours; Little Arc windows are not archived yet (B10 closes them).
        SettingsControl("links.archiveLittleArcsAfter", "Archive Little Arcs after", .picker(defaultValue: "6 hours"), .pending(task: "B10 follow-up")),
        SettingsControl("links.peekShiftClick", "Shift-click a link to open it in Peek", .toggle(defaultValue: true), .pending(task: "E2")),
        SettingsControl("links.peekOtherSites", "Open links to other sites in Peek (Favorites and Pinned Tabs only)", .toggle(defaultValue: true), .pending(task: "E2")),
        // Live (B52): opens the route sheet. [06 §25.1] observed.
        SettingsControl("links.airTrafficControl", "Air Traffic Control…", .button, .live),
    ]

    // MARK: Shortcuts [02 §其他]

    static let shortcuts: [SettingsControl] = [
        SettingsControl("shortcuts.search", "Search shortcuts", .searchField, .live),
        SettingsControl("shortcuts.defaults", "Default Shortcuts", .list, .live),
        // Customization is out of scope for now (plan B12): the list is read-only (inferred).
        SettingsControl("shortcuts.custom", "Custom Shortcuts", .button, .pending(task: "after v1")),
        SettingsControl("shortcuts.priority", "Shortcut priority", .picker(defaultValue: "Open Arc first"), .pending(task: "after v1")),
        SettingsControl("shortcuts.reset", "Reset All Shortcuts", .button, .pending(task: "after v1")),
        // Opens a help page; we have no help site yet.
        SettingsControl("shortcuts.basics", "Start with the basics", .button, .pending(task: "D9")),
    ]

    // MARK: Icon [03 §Icon]

    static let icon: [SettingsControl] = [
        // Observed: a list of six icons with a CURRENT ICON marker. Our variants are not designed
        // yet, so the grid holds one default icon (document).
        SettingsControl("icon.grid", "App icon", .list, .live),
    ]

    // MARK: Advanced [03 §Advanced]

    static let advanced: [SettingsControl] = [
        SettingsControl("advanced.soundEffects", "Play Open Arc sound effects", .toggle(defaultValue: true), .pending(task: "B16")),
        SettingsControl("advanced.reorderHaptics", "Haptic feedback when reordering tabs", .toggle(defaultValue: true), .pending(task: "B19")),
        SettingsControl("advanced.restoreWindows", "When opening Open Arc, restore windows from previous session", .toggle(defaultValue: false), .live),
        SettingsControl("advanced.windowDragging", "Allow window dragging from the top of webpages", .toggle(defaultValue: true), .pending(task: "C8")),
        SettingsControl("advanced.showFullURL", "Show full URL when Toolbar is enabled", .toggle(defaultValue: false), .live),
        SettingsControl("advanced.pictureInPicture", "Enable Picture in Picture when you leave a video tab", .toggle(defaultValue: true), .live),
        SettingsControl("advanced.themeData", "Allow websites to get your theme data", .toggle(defaultValue: true), .pending(task: "C17")),
        SettingsControl("advanced.boosts", "Enable Boosts on websites you visit", .toggle(defaultValue: true), .pending(task: "E1")),
        // Chromium's own settings pages.
        SettingsControl("advanced.moreSettings", "More Settings…", .button, .pending(task: "C12")),
        SettingsControl("advanced.resetTranslatePrompts", "Reset Translated-site Prompts", .button, .pending(task: "C12")),
        SettingsControl("advanced.exportData", "Export Data", .button, .pending(task: "D3")),
        // Plan C16: the engine's built-in ad blocker (EasyList + EasyPrivacy). [00 §A] records an ad
        // blocking switch in Arc's settings but 03 does not record its label or pane: "Block ads and
        // trackers" under Advanced, default on, is inferred. Shown only when the engine has a ruleset.
        SettingsControl("advanced.adBlocking", "Block ads and trackers", .toggle(defaultValue: true), .live),
        // Plan decision Q8: crash reports are stored locally only. The folder may not exist until
        // D8 writes the first report; the button creates it so Finder has something to show.
        SettingsControl("advanced.showCrashReports", "Show Crash Reports in Finder", .button, .live),
    ]
}
