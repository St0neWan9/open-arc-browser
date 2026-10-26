import Foundation
import AppKit
import UniformTypeIdentifiers
import OpenArcEngine

// File ▸ Save Page As / Print and View ▸ Developer ▸ for the window's selected tab (plan B25;
// engine side plan C15).
// Items: [01 §File] "Save Page As", "Print"; [01 §View] Developer ▸ "View Source", "Developer
// Tools", "Inspect Elements", "JavaScript Console", "Network Inspector", "Allow JavaScript from
// Apple Events" (all observed names). Keys: [02 §页面与导航] ⌘P; [02 §开发者] ⌥⌘I, ⌥⌘C, ⌥⌘J, ⌥⌘U
// (observed); Save Page As and Network Inspector have no key in [02].
// In a split the selected tab is the focused pane, so every command acts on that pane (inferred).

extension ShellModel {
    /// File ▸ Print (⌘P): the engine shows its print UI for the page.
    public func printPage() { runOnTargetPage { await $0.print() } }

    /// File ▸ Save Page As: asks where to save and in which format (a save panel;
    /// `chooseSavePageLocation` in tests), then the engine writes the page there. The formats are
    /// Chromium's (complete page, HTML only, single file); the spec records only the menu item, so
    /// the panel and its format menu are inferred.
    public func savePageAs() {
        guard let tabID = selectedTabID, selectedLiveTab != nil else { return }
        let suggested = Self.suggestedPageFileName(title: sidebar.liveState(for: tabID)?.title ?? workspace.tabs[tabID]?.title ?? "")
        let choose = chooseSavePageLocation ?? { await SavePagePanel.choose(suggestedName: $0) }
        let sidebar = self.sidebar
        controller.enqueueEngineWork {
            guard let choice = await choose(suggested), let live = sidebar.liveTab(for: tabID) else { return }
            try? await live.savePage(to: choice.url, format: choice.format)
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

/// Where and how Save Page As writes the page.
public struct SavePageChoice: Hashable, Sendable {
    public var url: URL
    public var format: SavePageFormat

    public init(url: URL, format: SavePageFormat = .complete) {
        self.url = url
        self.format = format
    }
}

/// The Save Page As panel (AppKit): a save panel with a Format menu, like the system's own
/// "Save As" panels (inferred). The file name extension follows the format.
@MainActor
enum SavePagePanel {
    /// Format menu titles. inferred (Chromium's names for its three formats).
    static func title(of format: SavePageFormat) -> String {
        switch format {
        case .complete: "Web Page, Complete"
        case .htmlOnly: "Web Page, HTML Only"
        case .singleFile: "Web Page, Single File"
        }
    }

    /// Asks for a file location and format; nil when cancelled.
    static func choose(suggestedName: String) async -> SavePageChoice? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.html]
        panel.allowsOtherFileTypes = true
        let formats = FormatMenu(panel: panel)
        panel.accessoryView = formats.view
        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }
        return SavePageChoice(url: url, format: formats.selected)
    }

    /// The accessory view's Format pop-up; switches the panel's file type with the format.
    @MainActor
    private final class FormatMenu: NSObject {
        let view: NSView
        private let popUp: NSPopUpButton
        private weak var panel: NSSavePanel?

        init(panel: NSSavePanel) {
            self.panel = panel
            popUp = NSPopUpButton(frame: .zero, pullsDown: false)
            for format in SavePageFormat.allCases {
                popUp.addItem(withTitle: SavePagePanel.title(of: format))
                popUp.lastItem?.tag = format.rawValue
            }
            let label = NSTextField(labelWithString: "Format:")
            let stack = NSStackView(views: [label, popUp])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
            view = stack
            super.init()
            popUp.target = self
            popUp.action = #selector(formatChanged)
        }

        var selected: SavePageFormat {
            SavePageFormat(rawValue: popUp.selectedTag()) ?? .complete
        }

        @objc private func formatChanged() {
            panel?.allowedContentTypes = selected == .singleFile ? [UTType(filenameExtension: "mhtml") ?? .data] : [.html]
        }
    }
}
