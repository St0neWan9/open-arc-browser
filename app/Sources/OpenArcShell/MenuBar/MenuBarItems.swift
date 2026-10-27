import SwiftUI
import AppKit

// The menu bar's items (plan B62), one view per menu or group so tests can render them with
// `NSHostingMenu` and compare against `MenuBarCatalog`. Titles [01 §menus] observed, keys [02]
// observed, groups [01 §菜单项图标与缩进] observed (E20). `Divider()` separates groups; no item has an
// icon of ours.

/// File ▸, from New Tab… to Close Window. [01 §File] observed order; keys [02 §窗口与应用] observed.
struct FileMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool
    let openWindow: OpenWindowAction

    var body: some View {
        Button("New Tab…") { model.presentCommandBar(.newTab) }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(!hasWindow)
        Button("New Window") { openBrowserWindow(.newWindow) }
            .keyboardShortcut("n", modifiers: .command)
        Button("Blank Window") { openBrowserWindow(.blank) }
            .keyboardShortcut("n", modifiers: [.control, .command])
        Button("New Incognito Window") { openBrowserWindow(.incognito) }
            .keyboardShortcut("n", modifiers: [.shift, .command])
        Button("New Little Arc Window") {
            // Keys typed before the new window has the keyboard wait for it (B29).
            NewWindowTypeAhead.shared.begin(.littleArc)
            openWindow(id: LittleArcScene.id, value: model.controller.issueLittleArcWindowID())
        }
        .keyboardShortcut("n", modifiers: [.option, .command])
        Button("Restore Last Closed Tab") { model.sidebar.restoreLastClosedTab() }
            .keyboardShortcut("t", modifiers: [.shift, .command])
            .disabled(!hasWindow || !model.sidebar.canRestoreLastClosedTab)
        Divider()
        Button("Open Command Bar") { model.presentCommandBar(.currentTab) }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasWindow)
        Divider()
        // New Profile (before New Easel in [01]) comes with its surface. ⌃⇧E [02] observed. B56.
        Button("New Easel") { model.newEasel() }
            .keyboardShortcut("e", modifiers: [.control, .shift])
            .disabled(!hasWindow || !model.canCreateEasel)
        Divider()
        // Closes whichever window is key (browser, Little Arc or Settings). ⇧⌘W [02] observed.
        Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            .keyboardShortcut("w", modifiers: [.shift, .command])
    }

    /// Opens a browser window from the menu, on the key window's Space (inferred).
    private func openBrowserWindow(_ kind: BrowserWindowRequest.Kind) {
        // Keys typed before the new window is key wait for it (B29: ⌘N then ⌘T).
        NewWindowTypeAhead.shared.begin(.browserWindow)
        openWindow(id: BrowserWindowScene.id, value: model.issueMenuWindowRequest(kind, fromWindow: hasWindow))
    }
}

/// File ▸ Capture… … Print, the last File group. [01 §File] observed; ⇧⌘2 and ⌘P [02] observed.
/// Share… (first in the group in [01]) is not built. Only Save Page As has an icon (the system's
/// download tray, set by `MenuBarAdjuster`), which indents the group ([01 §菜单项图标与缩进] observed).
struct FilePageMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Button("Capture…") { model.beginRegionCapture() }
            .keyboardShortcut("2", modifiers: [.shift, .command])
            .disabled(!hasWindow || !model.canCapturePage)
        Button("Capture Full Page") { model.captureFullPage() }
            .disabled(!hasWindow || !model.canCapturePage)
        Button("Capture in Portrait Mode") { model.beginPortraitCapture() }
            .disabled(!hasWindow || !model.canCapturePage)
        Button("Save Page As") { model.savePageAs() }
            .disabled(!hasWindow || !model.canRunPageCommands)
        Button("Print") { model.printPage() }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!hasWindow || !model.canRunPageCommands)
    }
}

/// Edit ▸ Copy URL · Copy URL as Markdown. [01 §Edit] observed items; ⇧⌘C and ⌥⇧⌘C [02 §复制链接]
/// observed. SwiftUI puts them after Select All; `MenuBarAdjuster` moves them right after Copy, as
/// in Arc. Copy URL as Quote needs the page's selection and is not built.
struct EditCopyURLMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Button("Copy URL") { model.copySelectedURL() }
            .keyboardShortcut("c", modifiers: [.shift, .command])
            .disabled(!hasWindow || model.sidebar.selectedURL == nil)
        Button("Copy URL as Markdown") { model.copySelectedURLAsMarkdown() }
            .keyboardShortcut("c", modifiers: [.option, .shift, .command])
            .disabled(!hasWindow || model.sidebar.selectedURL == nil)
    }
}

/// View ▸, from Appearance to Developer; Enter Full Screen is the system item after it.
/// [01 §View] observed order, groups from view-crop.png ([01 §菜单项图标与缩进] observed).
struct ViewMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        // A per-device setting: works with or without a window. B21.
        AppearanceMenu(model: model)
        Divider()
        Group {
            // ⌘S toggles the sidebar. [02 §tabs] observed 2026-10-25.
            Button(model.sidebarToggleTitle) { model.toggleSidebar() }
                .keyboardShortcut("s", modifiers: .command)
        }
        .disabled(!hasWindow)
        // ⇧⌘D, title Hide Toolbar while shown [06 §17.1] observed. Global: every window follows. B43.
        WebToolbarMenuItem(settings: model.webToolbar)
        // Collapse Pinned Tabs (last in this group in [01]) is not built.
        Divider()
        Group {
            // ⌘. [01 §菜单项图标与缩进] view-crop.png observed.
            Button("Stop Loading") { model.sidebar.reloadOrStop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(model.sidebar.reloadMode != .stop)
            Button("Refresh the Page") { model.sidebar.reloadOrStop() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.selectedTabID == nil)
            Button("Force Refresh the Page") { model.forceReload() }
                .keyboardShortcut("r", modifiers: [.shift, .command])
                .disabled(model.selectedLiveTab == nil)
            Divider()
            Button("Add Split View") { model.addSplitView() }
                .keyboardShortcut("=", modifiers: [.control, .shift])
            // Available only while a split exists. ⌃⇧- [02 §split] observed.
            Button("Close this Split Pane") { model.closeSplitPane() }
                .keyboardShortcut("-", modifiers: [.control, .shift])
                .disabled(!model.hasActiveSplit)
            Button("Separate Page from Split View") { model.separatePageFromSplitView() }
                .disabled(!model.hasActiveSplit)
            Button("Expand Current Split") { model.toggleExpandCurrentSplit() }
                .disabled(!model.hasActiveSplit)
            Divider()
            // Indented: Zoom In / Zoom Out get the system magnifier icons (`MenuBarAdjuster`);
            // Zoom to Actual Size has none ([01 §菜单项图标与缩进] observed).
            Button("Zoom to Actual Size") { model.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!model.canResetZoom)
            Button("Zoom In") { model.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!model.canZoomIn)
            Button("Zoom Out") { model.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!model.canZoomOut)
        }
        .disabled(!hasWindow)
        // Cast (its own group before Developer in [01]) is not built.
        Divider()
        DeveloperMenu(model: model, hasWindow: hasWindow)
        // The system Enter Full Screen follows in its own group.
        Divider()
    }
}

/// Spaces ▸. [01 §Spaces] observed order; [02] lists no shortcut for New Space… / Edit Theme… /
/// Rename Space, ⌥⌘→ / ⌥⌘← for Next / Previous Space and ⌃1…⌃9 for the Space items. An incognito
/// window disables the whole menu ([06 §20.2] observed).
struct SpacesMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Group {
            Button("New Space…") { model.spaceFlow.beginCreate() }
            // The bubble opens at the window's lower left. [06 §2]
            Button("Edit Theme…") { if let id = model.selectedSpaceID { model.spaceFlow.beginEditTheme(spaceID: id) } }
                .disabled(model.selectedSpaceID == nil || model.spaceFlow.isCreating)
            Button("Rename Space") { if let id = model.selectedSpaceID { model.spaceFlow.beginRename(spaceID: id) } }
                .disabled(model.selectedSpaceID == nil)
            // Change Profile (after Rename Space in [01]) is not built.
            Divider()
            Button("Next Space") { model.sidebar.stepSpace(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
            Button("Previous Space") { model.sidebar.stepSpace(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
            Divider()
            // One item per Space; the current one has a check ([01 §菜单项图标与缩进] observed). Arc
            // shows each Space's own icon before its name; ours has none (a Space icon is an emoji
            // or symbol name, not an image), so the list is not indented.
            ForEach(Array(model.sidebar.dockSpaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                Toggle(space.name, isOn: Binding(
                    get: { model.selectedSpaceID == space.id },
                    set: { _ in model.sidebar.goToSpace(number: index + 1) }
                ))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
            }
            Divider()
            // The Library's Spaces board is the Manage Spaces… surface ([06 §8] observed).
            Button("Manage Spaces…") { model.openLibrary(.spaces) }
        }
        .disabled(!hasWindow || model.isIncognito)
    }
}

/// Tabs ▸. [01 §Tabs] observed order, groups from tabs-crop.png ([01 §菜单项图标与缩进] observed).
struct TabsMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Group {
            Button("New Tab…") { model.presentCommandBar(.newTab) }
                .keyboardShortcut("t", modifiers: .command)
            // tabs-crop.png observed "Pin Tab"; "Unpin Tab" for a pinned tab [06 §16.2] observed.
            Button(model.pinMenuTitle) { if let id = model.selectedTabID { model.sidebar.togglePin(id) } }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.selectedTabID == nil)
            Button("New Folder…") { model.sidebar.requestNewFolder() }
            Divider()
            Button("Next Tab") { model.sidebar.stepTab(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Button("Previous Tab") { model.sidebar.stepTab(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            // Reveal Tab in Sidebar (⌃Space in [02]) is not built.
            Divider()
            Button("Clear Today") { model.sidebar.clearToday() }
                .keyboardShortcut("k", modifiers: [.shift, .command])
            // Reset all tabs in this Space is not built.
        }
        .disabled(!hasWindow)
    }
}

/// Shortcuts in [02] that no [01] menu lists: Archive Tab ⌘W, Go to Sidebar Item ⌘1…⌘9, Open
/// Extensions ⌘E. They sit in a menu the menu bar hides (`MenuBarAdjuster`); the keys still work.
struct KeyOnlyMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Group {
            Button("Archive Tab") { if let id = model.selectedTabID { model.sidebar.closeOrUnloadTab(id) } }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.selectedTabID == nil)
            ForEach(1...9, id: \.self) { number in
                Button(number == 9 ? "Go to Last Sidebar Item" : "Go to Sidebar Item \(number)") {
                    model.sidebar.goToSidebarItem(number: number)
                }
                .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
            Button("Open Extensions") { model.openExtensions() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.selectedTabID == nil || model.isIncognito)
        }
        .disabled(!hasWindow)
    }
}

extension ShellModel {
    /// Tabs ▸ Pin Tab / Unpin Tab. "Pin Tab" with no tab or a Today tab (tabs-crop.png observed),
    /// "Unpin Tab" for a pinned one ([06 §16.2] observed). A favorite keeps "Pin Tab" (inferred).
    var pinMenuTitle: String {
        CommandBarCommand.togglePin.title(in: commandBarCommandState) == "Unpin Tab" ? "Unpin Tab" : "Pin Tab"
    }

    /// Edit ▸ Copy URL (⇧⌘C): the selected tab's address. [01 §Edit], [02 §复制链接] observed.
    public func copySelectedURL() {
        guard let url = sidebar.selectedURL else { return }
        siteControls.pasteboard.writeURL(url)
        // Our own copy sound when "Play Open Arc sound effects" is on (B84, [03 §Advanced]).
        controller.feedback.play(.copy)
    }

    /// Edit ▸ Copy URL as Markdown (⌥⇧⌘C): `[title](url)` of the selected tab. [01 §Edit],
    /// [02 §复制链接] observed item and key; the format is inferred (same as the tab menu's).
    public func copySelectedURLAsMarkdown() {
        guard let id = selectedTabID, let text = sidebar.markdownLink(for: id) else { return }
        siteControls.pasteboard.writeText(text)
    }
}
