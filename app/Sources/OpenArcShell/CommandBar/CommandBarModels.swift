import Foundation

// Value types of the command bar. No UI framework types here, so everything is unit-testable.
//
// Spec sources (docs/arc-spec/):
//   [05 §command bar]   single entry for "new tab", search and commands; the first row is selected
//                       by default; open tabs are "Switch to Tab" candidates listed first.
//   [06 §6]             result action label: "Switch to Tab", or the owning space name inside a pane;
//                       app commands have no action label.
//   [02] / [01]         ⌘T = New Tab…, ⌘L = Open Command Bar (edit the current address).
// All ranking and ordering rules in this folder are "inferred": the spec only shows the UI.

/// How the command bar was opened.
public enum CommandBarMode: Hashable, Sendable {
    /// ⌘L "Open Command Bar": edits the current address, so URLs and searches go to the current tab.
    /// [02, 01] observed shortcut and menu item; routing to the current tab is inferred.
    case currentTab
    /// ⌘T "New Tab…": URLs and searches open a new tab. [02, 01] observed.
    case newTab

    /// Where a URL or search typed in this mode is opened.
    public var openTarget: CommandBarOpenTarget {
        switch self {
        case .currentTab: return .currentTab
        case .newTab: return .newTab
        }
    }
}

/// Where the command bar is presented. [06 §6, §5, §7] observed.
public enum CommandBarPresentation: Hashable, Sendable {
    /// Centered floating panel in a browser window (ⓘ button on the right).
    case window
    /// Inside a split pane: about 400 pt wide; rows show the owning space name on the right.
    case pane
    /// Little Arc: command-bar-only window (✕ button on the right, two-segment rows).
    case littleArc
}

/// Target of an "open URL" or "search" action.
public enum CommandBarOpenTarget: Hashable, Sendable {
    case currentTab
    case newTab
}

/// Built-in app commands: every menu action that has a working implementation. Titles are the
/// menu item names of `01-menus.md`; commands whose feature does not exist yet are not listed, so
/// the bar never shows a dead row. AI features are out of scope. The ids are our own and are not
/// persisted.
public enum CommandBarCommand: String, CaseIterable, Hashable, Sendable {
    // File
    case newTab
    case newWindow
    case newIncognitoWindow
    case newLittleArcWindow
    case restoreLastClosedTab
    // Edit
    case copyURL
    // View
    case toggleSidebar
    case reload
    case addSplitView
    case closeSplitPane
    case separateFromSplit
    case expandSplit
    // Spaces
    case newSpace
    case editTheme
    case renameSpace
    case nextSpace
    case previousSpace
    case manageSpaces
    // Tabs
    case archiveTab
    case togglePin
    case newFolder
    case nextTab
    case previousTab
    case clearToday
    case collapseAllFolders
    case expandAllFolders
    // Archive
    case goBack
    case goForward
    case viewArchive
    // Window (Library)
    case openLibrary
    case viewDownloads
    case viewEasels
    case viewMedia
    case viewBoosts
    // App
    case openSettings
    case contactTheTeam

    /// Row title. [01 §menus] observed menu item names; "Archive Tab", "Collapse All Folders" and
    /// "Expand All Folders" are not in a menu and use their [02] shortcut-list names (observed).
    /// "Contact the Team" is also observed in [04 §command bar].
    public var title: String {
        switch self {
        case .newTab: return "New Tab…"
        case .newWindow: return "New Window"
        case .newIncognitoWindow: return "New Incognito Window"
        case .newLittleArcWindow: return "New Little Arc Window"
        case .restoreLastClosedTab: return "Restore Last Closed Tab"
        case .copyURL: return "Copy URL"
        case .toggleSidebar: return "Hide Sidebar"
        case .reload: return "Refresh the Page"
        case .addSplitView: return "Add Split View"
        case .closeSplitPane: return "Close this Split Pane"
        case .separateFromSplit: return "Separate Page from Split View"
        case .expandSplit: return "Expand Current Split"
        case .newSpace: return "New Space…"
        case .editTheme: return "Edit Theme…"
        case .renameSpace: return "Rename Space"
        case .nextSpace: return "Next Space"
        case .previousSpace: return "Previous Space"
        case .manageSpaces: return "Manage Spaces…"
        case .archiveTab: return "Archive Tab"
        case .togglePin: return "Pin/Unpin Tab"
        case .newFolder: return "New Folder…"
        case .nextTab: return "Next Tab"
        case .previousTab: return "Previous Tab"
        case .clearToday: return "Clear Today"
        case .collapseAllFolders: return "Collapse All Folders"
        case .expandAllFolders: return "Expand All Folders"
        case .goBack: return "Go Back"
        case .goForward: return "Go Forward"
        case .viewArchive: return "View Archive…"
        case .openLibrary: return "Open Library…"
        case .viewDownloads: return "View Downloads…"
        case .viewEasels: return "View Easels…"
        case .viewMedia: return "View Media…"
        case .viewBoosts: return "View Boosts…"
        case .openSettings: return "Settings…"
        case .contactTheTeam: return "Contact the Team"
        }
    }

    /// Title for the current window state. Only the sidebar item changes: "Show Sidebar" while the
    /// sidebar is hidden (inferred, like the View menu item; [01 §View] only records "Hide Sidebar").
    public func title(in state: CommandBarCommandState) -> String {
        if self == .toggleSidebar, !state.isSidebarVisible { return "Show Sidebar" }
        return title
    }

    /// Extra search words (inferred).
    public var keywords: [String] {
        switch self {
        case .newTab: return ["tab", "open"]
        case .newWindow: return ["window", "open"]
        case .newIncognitoWindow: return ["private", "incognito", "window"]
        case .newLittleArcWindow: return ["little", "mini", "window"]
        case .restoreLastClosedTab: return ["reopen", "undo close", "restore"]
        case .copyURL: return ["copy link", "link", "url"]
        case .toggleSidebar: return ["sidebar", "show sidebar"]
        case .reload: return ["reload", "refresh"]
        case .addSplitView: return ["split", "side by side"]
        case .closeSplitPane: return ["split", "close pane"]
        case .separateFromSplit: return ["split", "separate"]
        case .expandSplit: return ["split", "expand"]
        case .newSpace: return ["space", "create space"]
        case .editTheme: return ["theme", "color", "space"]
        case .renameSpace: return ["space", "rename"]
        case .nextSpace: return ["space", "next"]
        case .previousSpace: return ["space", "previous"]
        case .manageSpaces: return ["spaces", "library"]
        case .archiveTab: return ["close tab", "archive"]
        case .togglePin: return ["pin", "unpin", "favorite"]
        case .newFolder: return ["folder", "organize"]
        case .nextTab: return ["tab", "next"]
        case .previousTab: return ["tab", "previous"]
        case .clearToday: return ["clear", "today", "clear unpinned tabs", "close tabs"]
        case .collapseAllFolders: return ["folders", "collapse"]
        case .expandAllFolders: return ["folders", "expand"]
        case .goBack: return ["back", "previous page"]
        case .goForward: return ["forward", "next page"]
        case .viewArchive: return ["archive", "history", "archived tabs"]
        case .openLibrary: return ["library"]
        case .viewDownloads: return ["downloads", "files"]
        case .viewEasels: return ["easels"]
        case .viewMedia: return ["media", "photos"]
        case .viewBoosts: return ["boosts"]
        case .openSettings: return ["preferences", "settings"]
        case .contactTheTeam: return ["help", "feedback", "support"]
        }
    }

    /// Default shortcut, shown as a hint if the view wants to. [02] observed; nil = no default key.
    public var shortcutHint: String? {
        switch self {
        case .newTab: return "⌘T"
        case .newWindow: return "⌘N"
        case .newIncognitoWindow: return "⇧⌘N"
        case .newLittleArcWindow: return "⌥⌘N"
        case .restoreLastClosedTab: return "⇧⌘T"
        case .copyURL: return "⇧⌘C"
        case .reload: return "⌘R"
        case .addSplitView: return "⌃⇧="
        case .closeSplitPane: return "⌃⇧-"
        case .nextSpace: return "⌥⌘→"
        case .previousSpace: return "⌥⌘←"
        case .archiveTab: return "⌘W"
        case .togglePin: return "⌘D"
        case .nextTab: return "⌥⌘↓"
        case .previousTab: return "⌥⌘↑"
        case .clearToday: return "⇧⌘K"
        case .goBack: return "⌘["
        case .goForward: return "⌘]"
        case .openLibrary: return "⇧⌘L"
        case .openSettings: return "⌘,"
        case .toggleSidebar, .separateFromSplit, .expandSplit, .newSpace, .editTheme, .renameSpace,
             .manageSpaces, .newFolder, .collapseAllFolders, .expandAllFolders, .viewArchive,
             .viewDownloads, .viewEasels, .viewMedia, .viewBoosts, .contactTheTeam:
            return nil
        }
    }

    /// Whether the command can run in this state. Rows of unavailable commands are left out, the
    /// way the menus disable them (inferred: [01 §View] observed that the split items are only
    /// available while a split exists; the same rule is applied to the other state-bound items).
    public func isAvailable(in state: CommandBarCommandState) -> Bool {
        switch self {
        case .archiveTab, .togglePin, .copyURL, .reload, .addSplitView:
            return state.hasSelectedTab
        case .restoreLastClosedTab:
            return state.canRestoreLastClosedTab
        case .closeSplitPane, .separateFromSplit, .expandSplit:
            return state.hasActiveSplit
        case .goBack:
            return state.canGoBack
        case .goForward:
            return state.canGoForward
        case .nextSpace, .previousSpace:
            return state.spaceCount > 1
        case .editTheme, .renameSpace, .newFolder, .clearToday, .collapseAllFolders, .expandAllFolders,
             .nextTab, .previousTab:
            return state.hasSelectedSpace
        case .newTab, .newWindow, .newIncognitoWindow, .newLittleArcWindow, .toggleSidebar, .newSpace, .manageSpaces, .viewArchive,
             .openLibrary, .viewDownloads, .viewEasels, .viewMedia, .viewBoosts, .openSettings, .contactTheTeam:
            return true
        }
    }
}

/// The window state the command rows depend on (availability and the sidebar title). A plain
/// value, read when the bar queries its sources.
public struct CommandBarCommandState: Hashable, Sendable {
    public var hasSelectedTab: Bool
    public var hasSelectedSpace: Bool
    public var spaceCount: Int
    public var canRestoreLastClosedTab: Bool
    public var hasActiveSplit: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var isSidebarVisible: Bool
    /// The tab "Move Tab to <Space>" rows act on; nil offers no move rows.
    public var movableTabID: UUID?

    public init(
        hasSelectedTab: Bool = true,
        hasSelectedSpace: Bool = true,
        spaceCount: Int = 2,
        canRestoreLastClosedTab: Bool = true,
        hasActiveSplit: Bool = true,
        canGoBack: Bool = true,
        canGoForward: Bool = true,
        isSidebarVisible: Bool = true,
        movableTabID: UUID? = nil
    ) {
        self.hasSelectedTab = hasSelectedTab
        self.hasSelectedSpace = hasSelectedSpace
        self.spaceCount = spaceCount
        self.canRestoreLastClosedTab = canRestoreLastClosedTab
        self.hasActiveSplit = hasActiveSplit
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isSidebarVisible = isSidebarVisible
        self.movableTabID = movableTabID
    }

    /// Every command available, no move rows. For previews, tests and sources without a window.
    public static let everything = CommandBarCommandState()
}

/// What the caller must execute after the user picked a row (or pressed Enter).
public enum CommandBarAction: Hashable, Sendable {
    /// Select an existing tab. Carries the model `TabNode.id`, the id `ShellModel.activate(tabID:)` takes.
    case switchToTab(tabID: UUID)
    /// Open a URL in the current tab or in a new tab.
    case openURL(URL, target: CommandBarOpenTarget)
    /// Run a built-in command.
    case runCommand(CommandBarCommand)
    /// Search the web. The caller builds the search URL from its configured search engine.
    case searchWeb(query: String, target: CommandBarOpenTarget)
    /// Restore an archived item as a new tab. Carries the `ArchiveItem.id`.
    case restoreArchived(itemID: UUID)
    /// Switch the window to a space ("Go to “<Space>”"). inferred.
    case goToSpace(spaceID: UUID)
    /// Move a tab to another space ("Move Tab to “<Space>”"), the sidebar's Move to ▸ intent. inferred.
    case moveTab(tabID: UUID, toSpaceID: UUID)
}

/// Kind of a result row; drives icon, ranking bias and de-duplication.
public enum CommandBarResultKind: Hashable, Sendable {
    case todayTab
    case pinnedTab
    case favoriteTab
    case archivedItem
    case command
    /// "Go to “<Space>”". inferred.
    case space
    /// "Move Tab to “<Space>”". inferred.
    case moveTabToSpace
    /// The text typed so far, understood as a URL.
    case typedURL
    /// "Search the web for what I typed".
    case webSearch
    /// A suggestion from the injected web-suggestion provider.
    case searchSuggestion

    /// Rows that stand for an already open tab. [05 §command bar] observed ("Switch to Tab").
    public var isTab: Bool {
        switch self {
        case .todayTab, .pinnedTab, .favoriteTab: return true
        default: return false
        }
    }
}

/// Icon family for a row. `.site` rows draw the page's favicon when the window's favicon cache
/// has one (`CommandBarViewModel.faviconProvider`, C9), else a placeholder glyph.
public enum CommandBarIconHint: Hashable, Sendable {
    case site(faviconURL: URL?)
    case pinned
    case archive
    case command
    case space
    case search
    case globe
}

/// Everything a source needs to know about the current query.
public struct CommandBarQueryContext: Hashable, Sendable {
    /// Raw text of the field (not trimmed). Empty while the field shows an unedited prefill.
    public var text: String
    public var mode: CommandBarMode
    public var presentation: CommandBarPresentation
    /// Space of the window the bar is opened in; its tabs rank slightly higher (inferred).
    public var currentSpaceID: UUID?
    /// The tab being viewed; it never shows up in the empty-query list (inferred).
    public var currentTabID: UUID?

    public init(
        text: String,
        mode: CommandBarMode,
        presentation: CommandBarPresentation = .window,
        currentSpaceID: UUID? = nil,
        currentTabID: UUID? = nil
    ) {
        self.text = text
        self.mode = mode
        self.presentation = presentation
        self.currentSpaceID = currentSpaceID
        self.currentTabID = currentTabID
    }

    /// Query with surrounding whitespace removed.
    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// One row of the result list.
public struct CommandBarResult: Identifiable, Hashable, Sendable {
    /// Stable id, unique per source object (for example `tab:<uuid>`).
    public var id: String
    public var kind: CommandBarResultKind
    public var title: String
    /// Secondary text: host for sites (shown after the title in Little Arc, [06 §7] observed).
    public var subtitle: String?
    public var url: URL?
    public var iconHint: CommandBarIconHint
    /// Owning space; shown instead of the action label in panes. [06 §6] observed.
    public var spaceID: UUID?
    public var spaceName: String?
    /// Right-hand action text. nil for app commands. [06 §6] observed.
    public var actionLabel: String?
    public var action: CommandBarAction
    /// Text that Tab puts into the field (inferred).
    public var completion: String
    /// Recency for ordering ties.
    public var lastActiveAt: Date?
    /// Position inside the producing source (for example the suggestion index).
    public var sourceOrder: Int
    /// Extra texts the ranker matches besides the title (for example the bare space name of a
    /// "Go to “Work”" row). Not shown.
    public var matchTexts: [String]
    /// Default shortcut of an app command. [02] observed; not drawn by the row (the spec shows no
    /// hint on command rows), kept for the view and tests.
    public var shortcutHint: String?

    public init(
        id: String,
        kind: CommandBarResultKind,
        title: String,
        subtitle: String? = nil,
        url: URL? = nil,
        iconHint: CommandBarIconHint,
        spaceID: UUID? = nil,
        spaceName: String? = nil,
        actionLabel: String?,
        action: CommandBarAction,
        completion: String? = nil,
        lastActiveAt: Date? = nil,
        sourceOrder: Int = 0,
        matchTexts: [String] = [],
        shortcutHint: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.iconHint = iconHint
        self.spaceID = spaceID
        self.spaceName = spaceName
        self.actionLabel = actionLabel
        self.action = action
        self.completion = completion ?? title
        self.lastActiveAt = lastActiveAt
        self.sourceOrder = sourceOrder
        self.matchTexts = matchTexts
        self.shortcutHint = shortcutHint
    }

    /// Text shown on the right of the row for a presentation. [06 §6] observed: panes show the space name.
    public func trailingLabel(for presentation: CommandBarPresentation) -> String? {
        if presentation == .pane, let spaceName, kind.isTab || kind == .archivedItem { return spaceName }
        return actionLabel
    }
}

/// Keys the command bar reacts to.
public enum CommandBarKey: Hashable, Sendable {
    case up
    case down
    case tab
    case shiftTab
    case returnKey
    case escape
}

/// Result of feeding a key to the view model.
public enum CommandBarKeyOutcome: Equatable, Sendable {
    /// Not consumed.
    case ignored
    /// Consumed; state may have changed.
    case handled
    /// Enter: the caller must execute the action and close the bar.
    case activate(CommandBarAction)
    /// Escape: the caller must close the bar. [05 §command bar] observed.
    case dismiss
}
