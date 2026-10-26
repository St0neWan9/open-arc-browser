import Foundation

/// One row of the Shortcuts pane: an action and its key.
public struct ShortcutEntry: Identifiable, Hashable, Sendable {
    public let action: String
    public let keys: String
    public var id: String { action }
}

/// A titled group of shortcuts, as `02` groups them.
public struct ShortcutGroup: Identifiable, Hashable, Sendable {
    public let title: String
    public let entries: [ShortcutEntry]
    public var id: String { title }
}

/// The Shortcuts pane list. Source: docs/arc-spec/02-shortcuts.md, observed keys.
///
/// Only shortcuts that work in Open Arc today are listed (the menu commands in `OpenArcScene` and
/// the standard app menu); the rest of `02` appears as its features land. The list is read-only:
/// customization ("Custom Shortcuts", priority, "Reset All Shortcuts") is out of scope for now
/// (plan B12, inferred). Group titles are English renderings of the `02` section headings
/// (inferred wording).
public enum ShortcutCatalog {
    public static let groups: [ShortcutGroup] = [
        // [02 §标签与侧边栏]
        ShortcutGroup(title: "Tabs and Sidebar", entries: [
            ShortcutEntry(action: "New Tab…", keys: "⌘T"),
            ShortcutEntry(action: "Open Command Bar", keys: "⌘L"),
            ShortcutEntry(action: "Archive Tab", keys: "⌘W"),
            ShortcutEntry(action: "Restore Last Closed Tab", keys: "⇧⌘T"),
            ShortcutEntry(action: "Pin/Unpin Tab", keys: "⌘D"),
            ShortcutEntry(action: "Clear Unpinned Tabs", keys: "⇧⌘K"),
            ShortcutEntry(action: "Next Tab", keys: "⌥⌘↓"),
            ShortcutEntry(action: "Previous Tab", keys: "⌥⌘↑"),
            ShortcutEntry(action: "Go to Sidebar Item 1–8", keys: "⌘1…⌘8"),
            ShortcutEntry(action: "Go to Last Sidebar Item", keys: "⌘9"),
        ]),
        // [02 §Space]
        ShortcutGroup(title: "Spaces", entries: [
            ShortcutEntry(action: "Go to Space 1–9", keys: "⌃1…⌃9"),
            ShortcutEntry(action: "Next Space", keys: "⌥⌘→"),
            ShortcutEntry(action: "Previous Space", keys: "⌥⌘←"),
        ]),
        // [02 §分屏]
        ShortcutGroup(title: "Split View", entries: [
            ShortcutEntry(action: "Add Split View", keys: "⌃⇧="),
            ShortcutEntry(action: "Close this Split Pane", keys: "⌃⇧-"),
        ]),
        // [02 §页面与导航] ⌘[ / ⌘] are the bound keys; ⌘← / ⌘→ come with the engine.
        ShortcutGroup(title: "Page and Navigation", entries: [
            ShortcutEntry(action: "Go Back", keys: "⌘["),
            ShortcutEntry(action: "Go Forward", keys: "⌘]"),
            ShortcutEntry(action: "Refresh the Page", keys: "⌘R"),
            ShortcutEntry(action: "Find…", keys: "⌘F"),
            ShortcutEntry(action: "Find Next", keys: "⌘G"),
            ShortcutEntry(action: "Find Previous", keys: "⇧⌘G"),
            ShortcutEntry(action: "Print", keys: "⌘P"),
        ]),
        // [02 §窗口与应用] Hide / Hide Others / Minimize / Quit / Full Screen come from the
        // standard macOS app and window menus.
        ShortcutGroup(title: "Windows and App", entries: [
            ShortcutEntry(action: "New Little Arc Window", keys: "⌥⌘N"),
            ShortcutEntry(action: "Enter/Exit Full Screen", keys: "⌃⌘F"),
            ShortcutEntry(action: "Settings…", keys: "⌘,"),
            ShortcutEntry(action: "Hide Open Arc", keys: "⌘H"),
            ShortcutEntry(action: "Hide Other Windows", keys: "⌥⌘H"),
            ShortcutEntry(action: "Minimize Window", keys: "⌘M"),
            ShortcutEntry(action: "Quit Open Arc", keys: "⌘Q"),
            ShortcutEntry(action: "Exit", keys: "⎋"),
        ]),
        // [02 §开发者] (B25). F12 for Developer Tools is not bound yet.
        ShortcutGroup(title: "Developer", entries: [
            ShortcutEntry(action: "Developer Tools", keys: "⌥⌘I"),
            ShortcutEntry(action: "Inspect Elements", keys: "⌥⌘C"),
            ShortcutEntry(action: "JavaScript Console", keys: "⌥⌘J"),
            ShortcutEntry(action: "View Source", keys: "⌥⌘U"),
        ]),
    ]

    /// Groups whose entries match `query` in the action name or the keys ([02 §其他] observed: the
    /// search field accepts a feature name or a shortcut). Empty groups are dropped.
    public static func filtered(_ groups: [ShortcutGroup], query: String) -> [ShortcutGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return groups }
        return groups.compactMap { group in
            let hits = group.entries.filter {
                $0.action.localizedCaseInsensitiveContains(needle) || $0.keys.contains(needle)
            }
            return hits.isEmpty ? nil : ShortcutGroup(title: group.title, entries: hits)
        }
    }
}
