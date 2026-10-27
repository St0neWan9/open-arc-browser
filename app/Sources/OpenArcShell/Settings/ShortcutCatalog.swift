import SwiftUI
import OpenArcModel

// Every key Open Arc binds, in one table (plan B85). Acceptance: docs/arc-spec/02-shortcuts.md,
// all sections (observed keys). The menus take their keys from it (`View.appShortcut`), and the
// Settings ▸ Shortcuts pane and Help ▸ Essential Keyboard Shortcuts are generated from it, so the
// list cannot drift from what the app binds; `ShortcutTableTests` checks the menus against it in
// both directions.
//
// Groups follow the `02` sections (English renderings of the headings, inferred wording). Keys
// that `02` does not list but our menus bind carry their own source: ⌘. Stop Loading ([01 §菜单项
// 图标与缩进] view-crop.png observed), ⇧⌘D Show Toolbar ([06 §17.1] observed), ⌥⇧⌘V Paste and Match
// Style (the macOS key). The standard macOS Edit keys (Undo, Cut, Copy, Paste, Select All, spelling)
// are the system's and, as in `02`, not listed. `02` entries without a key we bind (Join Meeting,
// New ChatGPT Message, Network Inspector) are not listed either. Fixed keys only: no custom
// shortcuts in v1 (plan Q17).

/// A key and its modifiers.
public struct ShortcutKey: Hashable, Sendable {
    public let character: Character
    public let modifiers: EventModifiers

    public init(_ character: Character, _ modifiers: EventModifiers = []) {
        self.character = character
        self.modifiers = modifiers
    }

    public var keyEquivalent: KeyEquivalent { KeyEquivalent(character) }

    /// The key as macOS menus write it: ⌃⌥⇧⌘, then the key.
    public var symbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.keyNames[character] ?? String(character).uppercased())
    }

    /// F12 as a key equivalent (`NSF12FunctionKey`).
    public static let f12: Character = "\u{F70F}"

    private static let keyNames: [Character: String] = [
        KeyEquivalent.upArrow.character: "↑", KeyEquivalent.downArrow.character: "↓",
        KeyEquivalent.leftArrow.character: "←", KeyEquivalent.rightArrow.character: "→",
        KeyEquivalent.space.character: "Space", KeyEquivalent.escape.character: "⎋",
        f12: "F12",
    ]

    public static func == (lhs: ShortcutKey, rhs: ShortcutKey) -> Bool {
        lhs.character == rhs.character && lhs.modifiers.rawValue == rhs.modifiers.rawValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(character)
        hasher.combine(modifiers.rawValue)
    }
}

/// Who takes a key.
public enum ShortcutBinding: Sendable {
    /// A menu item of ours, visible or in the hidden key-only menu (`KeyOnlyMenuItems`).
    case menu
    /// A standard macOS menu item (Settings…, Hide, Hide Others, Minimize, Quit, Full Screen).
    case system
    /// A view inside a window (⎋ closes the surface in front; ⌘O in Little Arc).
    case window
}

/// How an entry's keys read in the list.
public enum ShortcutKeyList: Sendable {
    /// One action, several keys ("⌥⌘↓ or ⌘}"): the first is the menu's, the rest are aliases.
    case alternatives
    /// One key per numbered item ("⌘1…⌘8").
    case range
}

/// The actions with a key. Our own names.
public enum AppShortcut: String, CaseIterable, Sendable {
    // [02 §标签与侧边栏]
    case newTab, openCommandBar, archiveTab, restoreLastClosedTab, togglePin, clearToday
    case nextTab, previousTab, goToSidebarItem, goToLastSidebarItem, revealCurrentTab
    case toggleSidebar, toggleToolbar, openLittleArcIn
    // [02 §Space]
    case goToSpace, nextSpace, previousSpace
    // [02 §分屏]
    case addSplitView, closeSplitPane, newEasel
    // [02 §页面与导航]
    case goBack, goForward, stopLoading, reload, forceReload
    case find, findNext, findPrevious, findAndReplace, jumpToSelection, pasteAndMatchStyle
    case zoomIn, zoomOut, actualSize, print, capture, openExtensions, openLibrary
    // [02 §复制链接]
    case copyURL, copyURLAsMarkdown, copyURLAsQuote
    // [02 §窗口与应用]
    case newWindow, newIncognitoWindow, blankWindow, newLittleArcWindow, closeWindow
    case fullScreen, settings, hideApp, hideOthers, minimize, quit, exit
    // [02 §开发者]
    case developerTools, inspectElements, javaScriptConsole, viewSource

    public var definition: ShortcutDefinition { ShortcutCatalog.definition(self) }
    /// Every key of the action; `keys[0]` is the one the visible menu item shows.
    public var keys: [ShortcutKey] { definition.keys }
}

/// One action of the table.
public struct ShortcutDefinition: Identifiable, Sendable {
    public let id: AppShortcut
    /// The name in the Shortcuts pane ([02] wording where it lists one).
    public let title: String
    public let keys: [ShortcutKey]
    public let list: ShortcutKeyList
    public let binding: ShortcutBinding

    /// "⌥⌘↓ or ⌘}", "⌘1…⌘8", "⌘T".
    public var keyText: String {
        switch list {
        case .alternatives: return keys.map(\.symbols).joined(separator: " or ")
        case .range: return keys.count > 1 ? "\(keys[0].symbols)…\(keys[keys.count - 1].symbols)" : keys.map(\.symbols).joined()
        }
    }
}

/// A titled group of the table.
public struct ShortcutDefinitionGroup: Identifiable, Sendable {
    public let title: String
    public let definitions: [ShortcutDefinition]
    public var id: String { title }
}

/// One row of the Shortcuts pane: an action and its key.
public struct ShortcutEntry: Identifiable, Hashable, Sendable {
    public let action: String
    public let keys: String
    /// Each key on its own, for the search field ("⌘5" finds "⌘1…⌘8").
    let searchKeys: [String]
    public var id: String { action }
}

/// A titled group of shortcuts, as `02` groups them.
public struct ShortcutGroup: Identifiable, Hashable, Sendable {
    public let title: String
    public let entries: [ShortcutEntry]
    public var id: String { title }
}

/// The Shortcuts pane list, generated from `table`.
public enum ShortcutCatalog {
    private static func entry(
        _ id: AppShortcut, _ title: String, _ keys: ShortcutKey...,
        list: ShortcutKeyList = .alternatives, binding: ShortcutBinding = .menu
    ) -> ShortcutDefinition {
        ShortcutDefinition(id: id, title: title, keys: keys, list: list, binding: binding)
    }

    private static func numbered(_ id: AppShortcut, _ title: String, _ numbers: ClosedRange<Int>, _ modifiers: EventModifiers) -> ShortcutDefinition {
        ShortcutDefinition(id: id, title: title, keys: numbers.map { ShortcutKey(Character("\($0)"), modifiers) }, list: .range, binding: .menu)
    }

    private static let up = KeyEquivalent.upArrow.character
    private static let down = KeyEquivalent.downArrow.character
    private static let left = KeyEquivalent.leftArrow.character
    private static let right = KeyEquivalent.rightArrow.character

    /// Every key the app binds, grouped as `02`. Keys [02] observed unless noted.
    public static let table: [ShortcutDefinitionGroup] = [
        ShortcutDefinitionGroup(title: "Tabs and Sidebar", definitions: [
            entry(.newTab, "New Tab…", ShortcutKey("t", .command)),
            entry(.openCommandBar, "Open Command Bar", ShortcutKey("l", .command)),
            entry(.archiveTab, "Archive Tab", ShortcutKey("w", .command)),
            entry(.restoreLastClosedTab, "Restore Last Closed Tab", ShortcutKey("t", [.shift, .command])),
            entry(.togglePin, "Pin/Unpin Tab", ShortcutKey("d", .command)),
            entry(.clearToday, "Clear Unpinned Tabs", ShortcutKey("k", [.shift, .command])),
            // ⌘} / ⌘{ [02 §标签与侧边栏] observed aliases (hidden key-only items, plan Q16).
            entry(.nextTab, "Next Tab", ShortcutKey(down, [.option, .command]), ShortcutKey("}", .command)),
            entry(.previousTab, "Previous Tab", ShortcutKey(up, [.option, .command]), ShortcutKey("{", .command)),
            numbered(.goToSidebarItem, "Go to Sidebar Item 1–8", 1...8, .command),
            entry(.goToLastSidebarItem, "Go to Last Sidebar Item", ShortcutKey("9", .command)),
            entry(.revealCurrentTab, "Reveal Current Tab", ShortcutKey(KeyEquivalent.space.character, .control)),
            // Observed on the real machine 2026-10-25 ([02 §标签与侧边栏]).
            entry(.toggleSidebar, "Hide / Show Sidebar", ShortcutKey("s", .command)),
            // [06 §17.1] observed.
            entry(.toggleToolbar, "Hide / Show Toolbar", ShortcutKey("d", [.shift, .command])),
            // [02] "Open Little Arc or Peek in…"; Little Arc's button takes it ([06 §21.7] observed).
            entry(.openLittleArcIn, "Open Little Arc in…", ShortcutKey("o", .command), binding: .window),
        ]),
        ShortcutDefinitionGroup(title: "Spaces", definitions: [
            numbered(.goToSpace, "Go to Space 1–9", 1...9, .control),
            entry(.nextSpace, "Next Space", ShortcutKey(right, [.option, .command])),
            entry(.previousSpace, "Previous Space", ShortcutKey(left, [.option, .command])),
        ]),
        ShortcutDefinitionGroup(title: "Split View", definitions: [
            entry(.addSplitView, "Add Split View", ShortcutKey("=", [.control, .shift])),
            entry(.closeSplitPane, "Close this Split Pane", ShortcutKey("-", [.control, .shift])),
            entry(.newEasel, "New Easel", ShortcutKey("e", [.control, .shift])),
        ]),
        ShortcutDefinitionGroup(title: "Page and Navigation", definitions: [
            // ⌘← / ⌘→ [02 §页面与导航] observed aliases; they navigate only when the page and our
            // text fields do not take the key (`PageKeyAlias`).
            entry(.goBack, "Go Back", ShortcutKey("[", .command), ShortcutKey(left, .command)),
            entry(.goForward, "Go Forward", ShortcutKey("]", .command), ShortcutKey(right, .command)),
            // [01 §菜单项图标与缩进] view-crop.png observed.
            entry(.stopLoading, "Stop Loading", ShortcutKey(".", .command)),
            entry(.reload, "Refresh the Page", ShortcutKey("r", .command)),
            entry(.forceReload, "Force Refresh", ShortcutKey("r", [.shift, .command])),
            entry(.find, "Find…", ShortcutKey("f", .command)),
            entry(.findNext, "Find Next", ShortcutKey("g", .command)),
            entry(.findPrevious, "Find Previous", ShortcutKey("g", [.shift, .command])),
            entry(.findAndReplace, "Find and Replace", ShortcutKey("f", [.option, .command])),
            entry(.jumpToSelection, "Jump to Selection", ShortcutKey("j", .command)),
            // The macOS key; [02] lists none.
            entry(.pasteAndMatchStyle, "Paste and Match Style", ShortcutKey("v", [.option, .shift, .command])),
            entry(.zoomIn, "Zoom In", ShortcutKey("+", .command)),
            entry(.zoomOut, "Zoom Out", ShortcutKey("-", .command)),
            entry(.actualSize, "Actual Size", ShortcutKey("0", .command)),
            entry(.print, "Print", ShortcutKey("p", .command)),
            entry(.capture, "Capture…", ShortcutKey("2", [.shift, .command])),
            entry(.openExtensions, "Open Extensions", ShortcutKey("e", .command)),
            entry(.openLibrary, "View Library", ShortcutKey("l", [.shift, .command])),
        ]),
        ShortcutDefinitionGroup(title: "Copy Links", definitions: [
            entry(.copyURL, "Copy URL", ShortcutKey("c", [.shift, .command])),
            entry(.copyURLAsMarkdown, "Copy URL as Markdown", ShortcutKey("c", [.option, .shift, .command])),
            entry(.copyURLAsQuote, "Copy URL as Quote", ShortcutKey("c", [.control, .shift, .command])),
        ]),
        ShortcutDefinitionGroup(title: "Windows and App", definitions: [
            entry(.newWindow, "New Window", ShortcutKey("n", .command)),
            entry(.newIncognitoWindow, "New Incognito Window", ShortcutKey("n", [.shift, .command])),
            entry(.blankWindow, "Blank Window", ShortcutKey("n", [.control, .command])),
            // The File menu item; the same key also works from other apps (global hot key, plan B82).
            entry(.newLittleArcWindow, "New Little Arc Window", ShortcutKey("n", [.option, .command])),
            entry(.closeWindow, "Close Window", ShortcutKey("w", [.shift, .command])),
            entry(.fullScreen, "Enter/Exit Full Screen", ShortcutKey("f", [.control, .command]), binding: .system),
            entry(.settings, "Settings…", ShortcutKey(",", .command), binding: .system),
            entry(.hideApp, "Hide \(AppIdentity.displayName)", ShortcutKey("h", .command), binding: .system),
            entry(.hideOthers, "Hide Other Windows", ShortcutKey("h", [.option, .command]), binding: .system),
            entry(.minimize, "Minimize Window", ShortcutKey("m", .command), binding: .system),
            entry(.quit, "Quit \(AppIdentity.displayName)", ShortcutKey("q", .command), binding: .system),
            entry(.exit, "Exit", ShortcutKey(KeyEquivalent.escape.character), binding: .window),
        ]),
        ShortcutDefinitionGroup(title: "Developer", definitions: [
            // F12 [02 §开发者] observed alias (hidden key-only item).
            entry(.developerTools, "Developer Tools", ShortcutKey("i", [.option, .command]), ShortcutKey(ShortcutKey.f12)),
            entry(.inspectElements, "Inspect Elements", ShortcutKey("c", [.option, .command])),
            entry(.javaScriptConsole, "JavaScript Console", ShortcutKey("j", [.option, .command])),
            entry(.viewSource, "View Source", ShortcutKey("u", [.option, .command])),
        ]),
    ]

    private static let byID: [AppShortcut: ShortcutDefinition] = Dictionary(
        table.flatMap(\.definitions).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }
    )

    /// The table's entry for `id`. Every case has one (`ShortcutTableTests`).
    public static func definition(_ id: AppShortcut) -> ShortcutDefinition {
        guard let definition = byID[id] else { preconditionFailure("\(id) is missing from ShortcutCatalog.table") }
        return definition
    }

    /// The pane's rows, one per action.
    public static let groups: [ShortcutGroup] = table.map { group in
        ShortcutGroup(title: group.title, entries: group.definitions.map {
            ShortcutEntry(action: $0.title, keys: $0.keyText, searchKeys: $0.keys.map(\.symbols))
        })
    }

    /// Groups whose entries match `query` in the action name or the keys ([02 §其他] observed: the
    /// search field accepts a feature name or a shortcut). Empty groups are dropped.
    public static func filtered(_ groups: [ShortcutGroup], query: String) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.entries.filter { entry in
                entry.action.localizedCaseInsensitiveContains(needle) || entry.keys.contains(needle)
                    || entry.searchKeys.contains { $0.localizedCaseInsensitiveContains(needle) }
            }
            return hits.isEmpty ? nil : ShortcutGroup(title: group.title, entries: hits)
        }
    }
}

extension View {
    /// Binds `shortcut`'s key at `index` from `ShortcutCatalog.table`: 0 is the visible menu
    /// item's key, higher indexes an alias or, for a numbered range, that item's key.
    func appShortcut(_ shortcut: AppShortcut, _ index: Int = 0) -> some View {
        let key = shortcut.keys[index]
        return keyboardShortcut(key.keyEquivalent, modifiers: key.modifiers)
    }
}

extension SettingsModel {
    /// Shortcuts ▸ "Start with the basics": Help ▸ Essential Keyboard Shortcuts in a tab of the
    /// browser window used last ([02 §其他] observed target; a new window opens when none is).
    /// Returns the tab id.
    @discardableResult
    public func startWithTheBasics() -> UUID? {
        let controller = shell.controller
        let page = HelpPages.Page.keyboardShortcuts
        guard let spaceID = controller.activeWindow?.selectedSpaceID ?? controller.workspace.allLiveSpaces.first?.id,
              let url = try? HelpPages.write(page, into: shell.helpPagesDirectory) else { return nil }
        return openInTab(url, title: page.title, spaceID: spaceID)
    }
}
