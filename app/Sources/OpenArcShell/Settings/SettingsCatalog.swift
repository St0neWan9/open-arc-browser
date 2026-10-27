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
        SettingsControl("account.syncSidebar", "Sync Sidebar", .toggle(defaultValue: false), .live),
    ]

    // MARK: General [03 §General]

    static let general: [SettingsControl] = [
        // Observed: a toggle whose row starts with "Info"; what it controls was not recorded
        // (unknown). No plan task covers it yet.
        SettingsControl("general.info", "Info", .toggle(defaultValue: false), .pending(task: "unknown (spec gap)")),
        // Observed, default on. Live (B68): ⌘Q asks first (`AppTermination`, `QuitConfirmationAlert`).
        SettingsControl("general.warnBeforeQuitting", "Warn before quitting", .toggle(defaultValue: true), .live),
        // Live (B84): Previews are Peek link previews; the button opens Links, where the Peek
        // switches are (inferred target, [03 §Links] observed Peek section).
        SettingsControl("general.previewsSettings", "Previews Settings…", .button, .live),
        // Observed hint: search engine, auto-archive and download location live in Profile settings.
        SettingsControl("general.profileSettings", "Profile Settings…", .button, .live),
    ]

    // MARK: Profiles [03 §Profiles]

    static let profiles: [SettingsControl] = [
        // Live (B83): our help page in a tab (`OpenArcLinks.profilesHelp`). inferred target.
        SettingsControl("profiles.learnMore", "Learn more", .button, .live),
        SettingsControl("profiles.list", "Your Profiles", .list, .live),
        SettingsControl("profiles.add", "Add Profile", .button, .live),
        // Deleting needs a TreeOps profile delete (Model change, Opus) plus C11 data removal.
        SettingsControl("profiles.remove", "Remove Profile", .button, .live),
        SettingsControl("profiles.searchEngine", "Search engine", .picker(defaultValue: SearchEngine.default.displayName), .live),
        // Live (B83): Chromium's search engine manager for the profile, in a tab (inferred target,
        // `ProfileEnginePage`).
        SettingsControl("profiles.searchSettings", "Search Settings…", .button, .live),
        // Per-profile `ProfileSettings.includesSearchSuggestions`; the command bar asks the engine (B66).
        SettingsControl("profiles.searchSuggestions", "Include search engine suggestions", .toggle(defaultValue: true), .live),
        SettingsControl("profiles.archiveTabsAfter", "Archive tabs after", .picker(defaultValue: ArchiveLifetime.default.displayName), .live),
        // Default app for new documents (Notes/Easels are E3 gaps); default value unknown.
        SettingsControl("profiles.newDocuments", "New documents", .picker(defaultValue: "—"), .pending(task: "E3")),
        // Live (B83): the engine keeps the folder per profile (`EngineDownloads.setDefaultDirectory`).
        SettingsControl("profiles.downloadLocation", "Download location", .picker(defaultValue: "Downloads"), .live),
        // Live (B83): each row opens the engine's page for the profile in a tab (inferred targets,
        // `ProfileEnginePage`).
        SettingsControl("profiles.privacy", "Privacy and Security", .navigationRow, .live),
        SettingsControl("profiles.passwords", "Passwords", .navigationRow, .live),
        SettingsControl("profiles.creditCards", "Credit Cards", .navigationRow, .live),
        SettingsControl("profiles.notifications", "Notifications", .navigationRow, .live),
        SettingsControl("profiles.autofill", "Autofill", .navigationRow, .live),
        // Live (B83): our sheet (time range + kinds) → `BrowserEngine.clearBrowsingData`.
        SettingsControl("profiles.clearBrowsingData", "Clear Browsing Data", .navigationRow, .live),
    ]

    // MARK: Links [03 §Links]
    // The section structure and defaults are observed; the exact English wording of the toggles
    // was recorded only as a paraphrase, so these labels are inferred.

    static let links: [SettingsControl] = [
        // Live (B82): a system-wide hot key while the app runs (`LittleArcHotKey.swift`). The spec
        // records no default; on is inferred.
        SettingsControl("links.littleArcHotKey", "Press ⌥⌘N in any app to open Little Arc", .toggle(defaultValue: true), .live),
        // Live (B82): the engine reports ⌥⌘-clicks as `NewTabDisposition.littleArc`. Default on, inferred.
        SettingsControl("links.littleArcModifierClick", "Open Little Arc when you ⌥⌘-click a link", .toggle(defaultValue: true), .live),
        // Live (B24): web links from other apps open in a new expanded Little Arc window. The spec
        // records no default for this toggle; off is inferred (`AppPreferences.opensExternalLinksInLittleArc`).
        SettingsControl("links.littleArcExternal", "Open links from other apps in Little Arc", .toggle(defaultValue: false), .live),
        // Live (B82): observed default 6 hours; idle Little Arc windows close and their pages are
        // archived (`LittleArcArchive.swift`).
        SettingsControl("links.archiveLittleArcsAfter", "Archive Little Arcs after", .picker(defaultValue: LittleArcArchiveLifetime.default.displayName), .live),
        // Live (B49): `AppPreferences.opensPeekOnShiftClick` / `opensPeekForOtherSites`. Defaults
        // inferred (the spec records none). [06 §22.1] observed behavior.
        SettingsControl("links.peekShiftClick", "Shift-click a link to open it in Peek", .toggle(defaultValue: true), .live),
        SettingsControl("links.peekOtherSites", "Open links to other sites in Peek (Favorites and Pinned Tabs only)", .toggle(defaultValue: true), .live),
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
        // Observed: a list of six icons with a CURRENT ICON marker. Live (B84): six of our own
        // color variants (`AppIconChoice`), none locked.
        SettingsControl("icon.grid", "App icon", .list, .live),
    ]

    // MARK: Advanced [03 §Advanced]

    static let advanced: [SettingsControl] = [
        // Live (B84): our own synthesized sounds (`FeedbackSound`) and a haptic tap on a sidebar drop.
        SettingsControl("advanced.soundEffects", "Play Open Arc sound effects", .toggle(defaultValue: true), .live),
        SettingsControl("advanced.reorderHaptics", "Haptic feedback when reordering tabs", .toggle(defaultValue: true), .live),
        SettingsControl("advanced.restoreWindows", "When opening Open Arc, restore windows from previous session", .toggle(defaultValue: false), .live),
        // Live (B84): the drag strip at the top of the page area ([06 §13] observed).
        SettingsControl("advanced.windowDragging", "Allow window dragging from the top of webpages", .toggle(defaultValue: true), .live),
        SettingsControl("advanced.showFullURL", "Show full URL when Toolbar is enabled", .toggle(defaultValue: false), .live),
        SettingsControl("advanced.pictureInPicture", "Enable Picture in Picture when you leave a video tab", .toggle(defaultValue: true), .live),
        // What websites receive is unknown ([04] observed setting, mechanism not recorded); C17 (page
        // colors → window tint) was the opposite direction and is closed "not needed".
        SettingsControl("advanced.themeData", "Allow websites to get your theme data", .toggle(defaultValue: true), .pending(task: "unknown (spec gap)")),
        SettingsControl("advanced.boosts", "Enable Boosts on websites you visit", .toggle(defaultValue: true), .pending(task: "E1")),
        // Live (B83): Chromium's settings pages for the current profile, in a tab
        // (`SettingsModel.openMoreSettings`).
        SettingsControl("advanced.moreSettings", "More Settings…", .button, .live),
        SettingsControl("advanced.resetTranslatePrompts", "Reset Translated-site Prompts", .button, .live),
        // Live (B84): our own JSON export of the sidebar (`WorkspaceExport`); Arc's format is unknown.
        SettingsControl("advanced.exportData", "Export Data", .button, .live),
        // Plan C16: the engine's built-in ad blocker (EasyList + EasyPrivacy). [00 §A] records an ad
        // blocking switch in Arc's settings but 03 does not record its label or pane: "Block ads and
        // trackers" under Advanced, default on, is inferred. Shown only when the engine has a ruleset.
        SettingsControl("advanced.adBlocking", "Block ads and trackers", .toggle(defaultValue: true), .live),
        // Plan decision Q8: crash reports are stored locally only. The folder may not exist until
        // D8 writes the first report; the button creates it so Finder has something to show.
        SettingsControl("advanced.showCrashReports", "Show Crash Reports in Finder", .button, .live),
    ]
}
