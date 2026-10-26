import Foundation
import AppKit
import OpenArcEngine

// File ▸ Save Page As / Print and View ▸ Developer ▸ for the window's selected tab (plan B25).
// Items: [01 §File] "Save Page As", "Print"; [01 §View] Developer ▸ "View Source", "Developer
// Tools", "Inspect Elements", "JavaScript Console", "Network Inspector", "Allow JavaScript from
// Apple Events" (all observed names). Keys: [02 §页面与导航] ⌘P; [02 §开发者] ⌥⌘I, ⌥⌘C, ⌥⌘J, ⌥⌘U
// (observed); Save Page As and Network Inspector have no key in [02].
// In a split the selected tab is the focused pane, so every command acts on that pane (inferred).

extension ShellModel {
    /// File ▸ Print (⌘P): the engine shows its print UI for the page.
    public func printPage() { runOnTargetPage { await $0.print() } }

    /// File ▸ Save Page As: asks where to save (a save panel; `chooseSavePageLocation` in tests),
    /// then the engine writes the page there.
    public func savePageAs() {
        guard let tabID = selectedTabID, selectedLiveTab != nil else { return }
        let suggested = Self.suggestedPageFileName(title: sidebar.liveState(for: tabID)?.title ?? workspace.tabs[tabID]?.title ?? "")
        let choose = chooseSavePageLocation ?? { await SavePagePanel.choose(suggestedName: $0) }
        let sidebar = self.sidebar
        controller.enqueueEngineWork {
            guard let url = await choose(suggested), let live = sidebar.liveTab(for: tabID) else { return }
            try? await live.savePage(to: url)
        }
    }

    /// View ▸ Developer ▸ View Source (⌥⌘U): the engine asks for a `view-source:` tab, which opens
    /// next to the page like any page-opened tab.
    public func viewPageSource() { runOnTargetPage { await $0.viewSource() } }

    /// View ▸ Developer ▸ Developer Tools (⌥⌘I; [02] also lists F12): the last panel used.
    public func showDeveloperTools() { runOnTargetPage { await $0.showDevTools(nil) } }

    /// View ▸ Developer ▸ Inspect Elements (⌥⌘C).
    public func inspectElements() { runOnTargetPage { await $0.showDevTools(.elements) } }

    /// View ▸ Developer ▸ JavaScript Console (⌥⌘J).
    public func showJavaScriptConsole() { runOnTargetPage { await $0.showDevTools(.console) } }

    /// View ▸ Developer ▸ Network Inspector (no key in [02]).
    public func showNetworkInspector() { runOnTargetPage { await $0.showDevTools(.network) } }

    /// View ▸ Developer ▸ Allow JavaScript from Apple Events. A per-device toggle, off by default
    /// (inferred). It only gates our future AppleScript support; nothing reads it yet.
    public var allowsJavaScriptFromAppleEvents: Bool {
        get { dependencies.preferences.allowsJavaScriptFromAppleEvents }
        set {
            objectWillChange.send()
            dependencies.preferences.allowsJavaScriptFromAppleEvents = newValue
        }
    }

    /// Page commands need a live page in the selected tab (pane).
    var canRunPageCommands: Bool { selectedLiveTab != nil }

    /// A file name for Save Page As: the page title without path separators, else "Untitled".
    static func suggestedPageFileName(title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? "Untitled" : cleaned) + ".html"
    }

    /// Runs `body` on the selected tab's engine tab. Commands for one tab reach the engine in the
    /// order they were issued (`enqueueTabCommand`).
    private func runOnTargetPage(_ body: @escaping @Sendable (any BrowserTab) async -> Void) {
        guard let live = selectedLiveTab else { return }
        controller.enqueueTabCommand(live) { await body($0) }
    }
}

/// The Save Page As panel (AppKit).
@MainActor
enum SavePagePanel {
    /// Asks for a file location; nil when cancelled.
    static func choose(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}
