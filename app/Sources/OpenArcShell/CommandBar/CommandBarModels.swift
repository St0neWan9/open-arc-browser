import Foundation
import OpenArcModel

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
    /// "Add Top / Left / Right / Bottom Split": a new empty pane on that side of the current tab.
    /// [06 §16.2] observed rows (no default key); the four placements are the web toolbar's split
    /// menu [06 §17.3] observed (B78).
    case addTopSplit
    case addLeftSplit
    case addRightSplit
    case addBottomSplit
    case closeSplitPane
    case separateFromSplit
    case expandSplit
    /// "Convert to Vertical Split View" while the split is side by side, "Convert to Horizontal
    /// Split View" while it is stacked; listed only with a split. [06 §16.2] observed the vertical
    /// row after a split; the horizontal one is inferred from the split row menu [06 §21.5] (B78).
    case convertToVerticalSplit
    case convertToHorizontalSplit
    /// "Clear Cookies and Refresh": clears the current site's cookies and site data, then reloads.
    /// [02 §page] observed name (no default key); the effect is inferred from the name (B78).
    case clearCookiesAndRefresh
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
    /// "Favorite Tab": the current Today tab goes to the end of the favorites. [06 §21.4] observed (B55).
    case favoriteTab
    case newFolder
    /// "Move to Today in <Space>": a pinned tab or favorite goes to the top of that Space's Today.
    /// [06 §16.2] observed row title; the effect is inferred (B78).
    case moveToToday
    /// "Replace Pin with Current Page": the pinned tab's or favorite's current page becomes its
    /// pinned URL. [06 §16.2] observed row title; the effect is the menu's "Replace Pinned URL
    /// with Current" [06 §21.5] (B78).
    case replacePinWithCurrentPage
    /// "Reset Tab to Original URL": the pinned tab or favorite goes back to its pinned URL.
    /// [02 §tabs] observed name (no default key) (B78).
    case resetTabToOriginalURL
    /// "Duplicate": a copy of the current tab opens at the top of Today. [02 §tabs] observed name
    /// (no default key); the menu item's effect [05 §context menus] (B78).
    case duplicateTab
    /// "Rename Current Item": the current tab's sidebar row turns into its rename field.
    /// [02 §tabs] observed name (no default key); the menu's "Rename…" effect (B78).
    case renameCurrentItem
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
    /// Opens Settings ▸ Links with the Air Traffic Control sheet. A help row of the incognito
    /// window's empty bar [06 §20.1] observed; the target is inferred from the name ([06 §25]).
    case airTrafficControl
    /// Our counterpart of the incognito bar's "The Browser Company" help row ([06 §20.1] observed
    /// row): the project's public page, titled with our app's name. Plan B133 (ours).
    case aboutProject
    /// "Tips for Organizing": our help page on Spaces, pins and folders. [06 §20.1] observed row
    /// title; the page is ours (B133).
    case organizingTips
    /// "Help Center": the same page as Help ▸ Visit Help Center. [06 §20.1] observed row title;
    /// [01 §Help] observed menu item (B133).
    case helpCenter
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
        case .addTopSplit: return "Add Top Split"
        case .addLeftSplit: return "Add Left Split"
        case .addRightSplit: return "Add Right Split"
        case .addBottomSplit: return "Add Bottom Split"
        case .convertToVerticalSplit: return "Convert to Vertical Split View"
        case .convertToHorizontalSplit: return "Convert to Horizontal Split View"
        case .clearCookiesAndRefresh: return "Clear Cookies and Refresh"
        case .moveToToday: return "Move to Today"
        case .replacePinWithCurrentPage: return "Replace Pin with Current Page"
        case .resetTabToOriginalURL: return "Reset Tab to Original URL"
        case .duplicateTab: return "Duplicate"
        case .renameCurrentItem: return "Rename Current Item"
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
        case .favoriteTab: return "Favorite Tab"
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
        case .airTrafficControl: return "Air Traffic Control"
        case .aboutProject: return AppIdentity.displayName
        case .organizingTips: return "Tips for Organizing"
        case .helpCenter: return "Help Center"
        }
    }

    /// Title for the current window state. Only the sidebar item changes: "Show Sidebar" while the
    /// sidebar is hidden (inferred, like the View menu item; [01 §View] only records "Hide Sidebar").
    public func title(in state: CommandBarCommandState) -> String {
        if self == .toggleSidebar, !state.isSidebarVisible { return "Show Sidebar" }
        // [06 §16.2] observed: "Unpin Tab" (⌘D) while the selected tab is pinned; "Pin Tab" for a
        // Today tab is inferred by symmetry.
        if self == .togglePin, let pinned = state.isSelectedTabPinned { return pinned ? "Unpin Tab" : "Pin Tab" }
        // [06 §16.2] observed: "Move to Today in <Space name>".
        if self == .moveToToday, let name = state.todaySpaceName { return "Move to Today in \(name)" }
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
        case .addTopSplit: return ["split", "top", "above"]
        case .addLeftSplit: return ["split", "left"]
        case .addRightSplit: return ["split", "right"]
        case .addBottomSplit: return ["split", "bottom", "below"]
        case .convertToVerticalSplit: return ["split", "vertical", "stack"]
        case .convertToHorizontalSplit: return ["split", "horizontal", "side by side"]
        case .clearCookiesAndRefresh: return ["cookies", "site data", "reload", "refresh"]
        case .moveToToday: return ["today", "unpin", "move"]
        case .replacePinWithCurrentPage: return ["pin", "pinned url", "replace", "update pin"]
        case .resetTabToOriginalURL: return ["reset", "original url", "pinned url"]
        case .duplicateTab: return ["duplicate", "copy tab", "clone"]
        case .renameCurrentItem: return ["rename", "title", "tab name"]
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
        case .favoriteTab: return ["favorite", "favorites", "add to favorites"]
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
        case .airTrafficControl: return ["links", "routes", "help"]
        case .aboutProject: return ["about", "project", "website", "help"]
        case .organizingTips: return ["tips", "organize", "help"]
        case .helpCenter: return ["help", "support", "docs"]
        }
    }

    /// Default shortcut, shown as a hint if the view wants to. [02] observed; nil = no default key.
    public var shortcutHint: String? {
        switch self {
        case .newTab: return "⌘T"
        // ⌘S, the View menu's key ([02 §tabs] observed 2026-10-25 on the real machine). B61.
        case .toggleSidebar: return "⌘S"
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
        // [02] lists no default key for these (B78): no hint. [06 §16.2] observed "Add Left Split"
        // without one.
        case .addTopSplit, .addLeftSplit, .addRightSplit, .addBottomSplit, .convertToVerticalSplit,
             .convertToHorizontalSplit, .clearCookiesAndRefresh, .moveToToday, .replacePinWithCurrentPage,
             .resetTabToOriginalURL, .duplicateTab, .renameCurrentItem:
            return nil
        case .favoriteTab, .separateFromSplit, .expandSplit, .newSpace, .editTheme, .renameSpace,
             .manageSpaces, .newFolder, .collapseAllFolders, .expandAllFolders, .viewArchive,
             .viewDownloads, .viewEasels, .viewMedia, .viewBoosts, .contactTheTeam, .airTrafficControl,
             .aboutProject, .organizingTips, .helpCenter:
            return nil
        }
    }

    /// Whether the command can run in this state. Rows of unavailable commands are left out, not
    /// dimmed. [06 §16.2] observed: with no split, "Close this Split Pane" / "Expand Current Split"
    /// are not listed (they are with a split); with no back history "Go Back" is not listed (it is,
    /// with ⌘[, after a navigation). The other state-bound items follow the same rule (inferred).
    public func isAvailable(in state: CommandBarCommandState) -> Bool {
        if state.isIncognito, Self.unavailableInIncognito.contains(self) { return false }
        switch self {
        case .archiveTab, .togglePin, .copyURL, .reload, .addSplitView, .duplicateTab,
             .addTopSplit, .addLeftSplit, .addRightSplit, .addBottomSplit:
            return state.hasSelectedTab
        case .convertToVerticalSplit:
            return state.hasActiveSplit && state.activeSplitAxis != .vertical
        case .convertToHorizontalSplit:
            // An unknown direction (`everything`) offers both rows.
            return state.hasActiveSplit && state.activeSplitAxis != .horizontal
        case .clearCookiesAndRefresh:
            return state.hasSelectedTab && state.canClearSelectedSiteCookies
        case .moveToToday:
            return state.hasSelectedTab && state.canMoveSelectedTabToToday
        case .replacePinWithCurrentPage, .resetTabToOriginalURL:
            return state.hasSelectedTab && state.hasLeftPinnedURL
        case .renameCurrentItem:
            return state.hasSelectedTab && state.canRenameSelectedItem
        case .restoreLastClosedTab:
            return state.canRestoreLastClosedTab
        case .favoriteTab:
            return state.hasSelectedTab && state.canFavoriteSelectedTab
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
             .openLibrary, .viewDownloads, .viewEasels, .viewMedia, .viewBoosts, .openSettings, .contactTheTeam,
             .airTrafficControl:
            return true
        case .aboutProject, .organizingTips, .helpCenter:
            // Rows of the incognito bar only ([06 §20.1] observed there); the normal bar was seen
            // with Contact the Team alone ([04 §command bar]), so they stay out of it. inferred.
            return state.isIncognito
        }
    }

    /// Commands an incognito window's bar leaves out. Its Spaces menu is disabled as a whole and
    /// its tab menu has no Pin ([06 §20.2] observed), so the Space commands and Pin are not
    /// offered (plan B61); folders and the pinned-page commands need the pinned area it does not
    /// have (inferred, B78).
    static let unavailableInIncognito: Set<CommandBarCommand> = [
        .newSpace, .editTheme, .renameSpace, .nextSpace, .previousSpace, .manageSpaces,
        .togglePin, .favoriteTab, .newFolder, .collapseAllFolders, .expandAllFolders,
        .moveToToday, .replacePinWithCurrentPage, .resetTabToOriginalURL,
    ]

    /// The help rows an incognito window's bar lists for an empty query, in the observed order.
    /// [06 §20.1] observed: Contact the Team · The Browser Company · Air Traffic Control · Tips for
    /// Organizing · Help Center. "The Browser Company" becomes our project page, titled with our
    /// app's name (ours, B133).
    public static let helpCommands: [CommandBarCommand] = [
        .contactTheTeam, .aboutProject, .airTrafficControl, .organizingTips, .helpCenter,
    ]
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
    /// Whether the selected tab is pinned (true) or in Today (false); nil for no tab or a favorite.
    /// Picks the "Pin Tab" / "Unpin Tab" title.
    public var isSelectedTabPinned: Bool?
    /// Whether "Favorite Tab" applies: the selected tab is a Today tab of a normal window.
    /// [06 §21.4] observed for a Today tab; pinned tabs and incognito windows inferred (B55).
    public var canFavoriteSelectedTab: Bool = true
    /// An incognito window: no Space commands, no Space rows (`unavailableInIncognito`). B61.
    public var isIncognito: Bool = false
    /// Top-level direction of the selected tab's split; nil without a split (or unknown, which
    /// offers both "Convert to …" rows). B78.
    public var activeSplitAxis: SplitAxis?
    /// The selected tab is a pinned tab or favorite that can move to a Today. B78.
    public var canMoveSelectedTabToToday: Bool = true
    /// Name of the Space whose Today "Move to Today in <Space>" moves to (title only). B78.
    public var todaySpaceName: String?
    /// The selected tab is a pinned tab or favorite whose page is no longer its pinned URL: "Replace
    /// Pin with Current Page" and "Reset Tab to Original URL" have something to do. inferred from
    /// the menu's disabled state [06 §21.5] observed (B78).
    public var hasLeftPinnedURL: Bool = true
    /// The selected tab has a row with a rename field (a Today or pinned tab outside a split). B78.
    public var canRenameSelectedItem: Bool = true
    /// The selected tab shows a web site (http or https) whose cookies can be cleared. B78.
    public var canClearSelectedSiteCookies: Bool = true

    public init(
        hasSelectedTab: Bool = true,
        hasSelectedSpace: Bool = true,
        spaceCount: Int = 2,
        canRestoreLastClosedTab: Bool = true,
        hasActiveSplit: Bool = true,
        canGoBack: Bool = true,
        canGoForward: Bool = true,
        isSidebarVisible: Bool = true,
        movableTabID: UUID? = nil,
        isSelectedTabPinned: Bool? = nil
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
        self.isSelectedTabPinned = isSelectedTabPinned
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
    /// A page of the profile's browsing history (plan B66): not open, not archived.
    case historyItem
    /// A site the bar knows (a frequently visited page) whose host starts with the typed text: the
    /// first row while the field completes inline ("Weather.com — weather.com", site favicon).
    /// [05 §命令栏] observed (2026-10-30).
    case siteCompletion
    /// The search service's navigation suggestion: a page it proposes, shown as "Title — domain"
    /// among the query suggestions ("National Weather Service — weather.gov"). [05 §命令栏] observed.
    case siteSuggestion
    /// One of the profile's most visited pages (plan B121), for an empty or short query.
    /// [05 §command bar] inferred (analysis).
    case topSite
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
    /// A browsing history page: a clock glyph. [07 §9] observed the row glyphs "globe, magnifier,
    /// clock"; the clock standing for history rows is inferred.
    case history
    /// An app command row: the command's own glyph in a rounded box
    /// (`CommandBarCommand.glyphSymbol`, [07 §5] E27 observed).
    case command
    case space
    case search
    case globe
    /// A site row drawn with the globe and never its favicon: the completing site row after
    /// Backspace took its completion back. [05 §命令栏] E30 observed (plan B133).
    case bareSite
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
    /// The empty query lists only the help commands, no tabs: the incognito window's bar.
    /// [06 §20.1] observed (B61).
    public var listsHelpOnlyWhenEmpty: Bool = false

    public init(
        text: String,
        mode: CommandBarMode,
        presentation: CommandBarPresentation = .window,
        currentSpaceID: UUID? = nil,
        currentTabID: UUID? = nil,
        listsHelpOnlyWhenEmpty: Bool = false
    ) {
        self.text = text
        self.mode = mode
        self.presentation = presentation
        self.currentSpaceID = currentSpaceID
        self.currentTabID = currentTabID
        self.listsHelpOnlyWhenEmpty = listsHelpOnlyWhenEmpty
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
    /// Default shortcut of the row's command, drawn at the row's right end. [06 §16.2] observed
    /// for command rows ([02] observed keys); the ⌃N hints of "Go to" rows are inferred.
    public var shortcutHint: String?
    /// History rows: the engine's frecency, 0...1 (`HistoryMatch.frecency`). 0 for other rows.
    public var frecency: Double = 0

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

    /// Shortcut hint the row draws: only when it has no right-hand text. [06 §16.2] observed on
    /// command rows, in the window and in a split pane.
    public func visibleShortcutHint(for presentation: CommandBarPresentation) -> String? {
        guard let shortcutHint, trailingLabel(for: presentation) == nil else { return nil }
        return shortcutHint
    }

    /// The "— subtitle" half the row draws, nil for none. A subtitle equal to the title is left
    /// out, except on the completing site row, which reads "youtube.com — youtube.com" once
    /// Backspace took its completion back ([05 §命令栏] E30 observed, plan B133).
    public var displayedSubtitle: String? {
        guard let subtitle, !subtitle.isEmpty else { return nil }
        return subtitle != title || kind == .siteCompletion ? subtitle : nil
    }

    /// Text shown on the right of the row for a presentation. [06 §6] observed: panes show the space name.
    ///
    /// In the window's bar (plan B109, F4 live E2 observed 2026-10-29 with an empty query): a tab
    /// of another Space shows that Space's name (gray, white when highlighted) instead of "Switch
    /// to Tab"; a tab of the window's own Space (or a favorite, which belongs to no Space) shows
    /// "Switch to Tab" only while it is the highlighted row, and nothing otherwise (the arrow box
    /// stays). The same rule for typed queries and the Space name on a highlighted row are
    /// inferred. `currentSpaceID` nil (unknown window Space) keeps the action label.
    public func trailingLabel(
        for presentation: CommandBarPresentation,
        isSelected: Bool = true,
        currentSpaceID: UUID? = nil
    ) -> String? {
        if presentation == .pane, let spaceName, kind.isTab || kind == .archivedItem { return spaceName }
        if presentation == .window, kind.isTab, let currentSpaceID {
            if let spaceID, spaceID != currentSpaceID, let spaceName, !spaceName.isEmpty { return spaceName }
            return isSelected ? actionLabel : nil
        }
        // [07 §5] E27 follow-up observed (2026-10-30): in the window's bar, site, search, history
        // and command rows show no action text, highlighted or not; only open tabs keep theirs.
        if presentation == .window, !kind.isTab { return nil }
        return actionLabel
    }
}

/// Leading glyph of the command bar's input row.
public enum CommandBarInputGlyph: Hashable, Sendable {
    /// No command on top. [04 §command bar] and [06 §7] observed a magnifier; F4 live E3
    /// (2026-10-29) observed it for the empty ⌘T bar (plan B109); [07 §5] E27 observed it whenever
    /// the first result is not a command.
    case magnifier
    /// The first result is an app command: its glyph (`CommandBarCommand.glyphSymbol`).
    /// [07 §5] E27 observed (settings → gear, copy url → copy, split → split, archive → box).
    case command(CommandBarCommand)
    /// The first row is a site suggestion whose host completes the typed text: the site's favicon.
    /// [07 §5] / [05 §命令栏] observed (2026-10-30): with "weather" completed to ".com" the field's
    /// glyph is the site's icon.
    case site(CommandBarResult)
    /// One character typed: the default search engine's icon (`row` stands for the engine's
    /// site; Google's "G" with Google). [05 §命令栏] E30 observed (plan B133). Draws the magnifier
    /// until the icon is cached.
    case searchEngine(CommandBarResult)

    /// The glyph for the field's text and the list's first result (nil for an empty list).
    /// [07 §5] E27 observed: a command on top shows its glyph, anything else the magnifier, and
    /// [05 §命令栏] observed the site's favicon while the field shows an inline completion (B128).
    /// [05 §命令栏] E30 observed the search engine's icon while one character is typed (B133);
    /// a command heading that list keeps its own glyph (inferred precedence, E30 saw a tab row on
    /// top). An empty field keeps the magnifier even when a help command heads the list (incognito,
    /// [06 §20.1]): F4 live E3 observed the magnifier for the empty bar (B109). The globe of the
    /// earlier [07 §5] table capture is no longer drawn: E27 saw the magnifier for every first
    /// result that is not a command (plan B127).
    public static func forField(
        text: String,
        firstResult: CommandBarResult?,
        inlineCompletion: CommandBarInlineCompletion? = nil,
        searchEngine: CommandBarResult? = nil
    ) -> CommandBarInputGlyph {
        if let inlineCompletion, let firstResult, inlineCompletion.resultID == firstResult.id {
            return .site(firstResult)
        }
        if !text.isEmpty, let firstResult, firstResult.drawsGlyphBox, let command = firstResult.command {
            return .command(command)
        }
        if text.count == 1, !text.contains(where: \.isWhitespace), let searchEngine {
            return .searchEngine(searchEngine)
        }
        return .magnifier
    }

    /// SF Symbol drawn for the glyph (a site glyph falls back to the globe placeholder, the
    /// search engine's to the magnifier, when the window's favicon cache has no image).
    public var symbolName: String {
        switch self {
        case .magnifier, .searchEngine: return "magnifyingglass"
        case .command(let command): return command.glyphSymbol
        case .site: return "globe"
        }
    }

    /// The row whose favicon the glyph draws, nil for symbol-only glyphs.
    public var iconRow: CommandBarResult? {
        switch self {
        case .site(let row), .searchEngine(let row): return row
        case .magnifier, .command: return nil
        }
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
    /// Backspace: deletes as the field decides and drops the inline completion for good.
    /// [05 §命令栏] observed (2026-10-30): Backspace removes the completion.
    case deleteBackward
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
