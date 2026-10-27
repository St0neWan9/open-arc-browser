import SwiftUI
import AppKit
import OpenArcModel

// The menu bar's items (plans B62, B72), one view per menu or group so tests can render them with
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
            .appShortcut(.newTab)
            .disabled(!hasWindow)
        Button("New Window") { openBrowserWindow(.newWindow) }
            .appShortcut(.newWindow)
        Button("Blank Window") { openBrowserWindow(.blank) }
            .appShortcut(.blankWindow)
        Button("New Incognito Window") { openBrowserWindow(.incognito) }
            .appShortcut(.newIncognitoWindow)
        Button("New Little Arc Window") {
            // Keys typed before the new window has the keyboard wait for it (B29).
            NewWindowTypeAhead.shared.begin(.littleArc)
            openWindow(id: LittleArcScene.id, value: model.controller.issueLittleArcWindowID())
        }
        .appShortcut(.newLittleArcWindow)
        Button("Restore Last Closed Tab") { model.sidebar.restoreLastClosedTab() }
            .appShortcut(.restoreLastClosedTab)
            .disabled(!hasWindow || !model.sidebar.canRestoreLastClosedTab)
        Divider()
        Button("Open Command Bar") { model.presentCommandBar(.currentTab) }
            .appShortcut(.openCommandBar)
            .disabled(!hasWindow)
        Divider()
        // The New Profile sheet ([06 §16.3] observed steps). Not in an incognito window (inferred). B72.
        Button("New Profile") { model.profileFlow.beginNewProfile() }
            .disabled(!hasWindow || model.isIncognito)
        // ⌃⇧E [02] observed. B56.
        Button("New Easel") { model.newEasel() }
            .appShortcut(.newEasel)
            .disabled(!hasWindow || !model.canCreateEasel)
        Divider()
        // Closes whichever window is key (browser, Little Arc or Settings). ⇧⌘W [02] observed.
        Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
            .appShortcut(.closeWindow)
    }

    /// Opens a browser window from the menu, on the key window's Space (inferred).
    private func openBrowserWindow(_ kind: BrowserWindowRequest.Kind) {
        // Keys typed before the new window is key wait for it (B29: ⌘N then ⌘T).
        NewWindowTypeAhead.shared.begin(.browserWindow)
        openWindow(id: BrowserWindowScene.id, value: model.issueMenuWindowRequest(kind, fromWindow: hasWindow))
    }
}

/// File ▸ Share… … Print, the last File group. [01 §File] observed; ⇧⌘2 and ⌘P [02] observed.
/// Only Save Page As has an icon (the system's download tray, set by `MenuBarAdjuster`), which
/// indents the group ([01 §菜单项图标与缩进] observed).
struct FilePageMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        // The system share picker with the page's address (B72).
        Button("Share…") { model.shareCurrentPage() }
            .disabled(!hasWindow || model.sidebar.selectedURL == nil)
        Button("Capture…") { model.beginRegionCapture() }
            .appShortcut(.capture)
            .disabled(!hasWindow || !model.canCapturePage)
        Button("Capture Full Page") { model.captureFullPage() }
            .disabled(!hasWindow || !model.canCapturePage)
        Button("Capture in Portrait Mode") { model.beginPortraitCapture() }
            .disabled(!hasWindow || !model.canCapturePage)
        Button("Save Page As") { model.savePageAs() }
            .disabled(!hasWindow || !model.canRunPageCommands)
        Button("Print") { model.printPage() }
            .appShortcut(.print)
            .disabled(!hasWindow || !model.canRunPageCommands)
    }
}

/// Edit ▸ Copy URL · Copy URL as Markdown · Copy URL as Quote, then Paste and Match Style.
/// [01 §Edit] observed items; ⇧⌘C, ⌥⇧⌘C and ⌃⇧⌘C [02 §复制链接] observed; ⌥⇧⌘V is the macOS key
/// for Paste and Match Style ([02] lists none). SwiftUI puts them after Select All;
/// `MenuBarAdjuster` moves the copy items right after Copy and Paste and Match Style right after
/// Paste, as in Arc (`MenuBarCatalog.itemsAfter`).
struct EditCopyURLMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Button("Copy URL") { model.copySelectedURL() }
            .appShortcut(.copyURL)
            .disabled(!hasWindow || model.sidebar.selectedURL == nil)
        Button("Copy URL as Markdown") { model.copySelectedURLAsMarkdown() }
            .appShortcut(.copyURLAsMarkdown)
            .disabled(!hasWindow || model.sidebar.selectedURL == nil)
        Button("Copy URL as Quote") { model.copySelectedURLAsQuote() }
            .appShortcut(.copyURLAsQuote)
            .disabled(!hasWindow || model.sidebar.selectedURL == nil)
        // Pastes into the page as plain text. The menu bar runs our command, so it reaches the
        // page even when the engine's web view, not a text view of ours, has the keyboard.
        Button("Paste and Match Style") { model.pasteAndMatchStyle() }
            .appShortcut(.pasteAndMatchStyle)
            .disabled(!hasWindow || !model.canRunPageCommands)
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
                .appShortcut(.toggleSidebar)
        }
        .disabled(!hasWindow)
        // ⇧⌘D, title Hide Toolbar while shown [06 §17.1] observed. Global: every window follows. B43.
        // Disabled while a split is shown [06 §21.6] observed (B79).
        WebToolbarMenuItem(settings: model.webToolbar)
            .disabled(!model.canToggleWebToolbar)
        // Hides the current Space's pinned rows in this window (B72, inferred behavior).
        Button(model.collapsePinnedMenuTitle) { model.sidebar.toggleCollapsePinned() }
            .disabled(!hasWindow || !(model.sidebar.canCollapsePinned || model.sidebar.isPinnedAreaCollapsed))
        Divider()
        Group {
            // ⌘. [01 §菜单项图标与缩进] view-crop.png observed.
            Button("Stop Loading") { model.sidebar.reloadOrStop() }
                .appShortcut(.stopLoading)
                .disabled(model.sidebar.reloadMode != .stop)
            Button("Refresh the Page") { model.sidebar.reloadOrStop() }
                .appShortcut(.reload)
                .disabled(model.selectedTabID == nil)
            Button("Force Refresh the Page") { model.forceReload() }
                .appShortcut(.forceReload)
                .disabled(model.selectedLiveTab == nil)
            Divider()
            Button("Add Split View") { model.addSplitView() }
                .appShortcut(.addSplitView)
            // Available only while a split exists. ⌃⇧- [02 §split] observed.
            Button("Close this Split Pane") { model.closeSplitPane() }
                .appShortcut(.closeSplitPane)
                .disabled(!model.hasActiveSplit)
            Button("Separate Page from Split View") { model.separatePageFromSplitView() }
                .disabled(!model.hasActiveSplit)
            // Current pane maximal, the others 220 pt; again changes nothing. [06 §21.6] observed (B79).
            Button("Expand Current Split") { model.expandCurrentSplit() }
                .disabled(!model.hasActiveSplit)
            Divider()
            // Indented: Zoom In / Zoom Out get the system magnifier icons (`MenuBarAdjuster`);
            // Zoom to Actual Size has none ([01 §菜单项图标与缩进] observed).
            Button("Zoom to Actual Size") { model.resetZoom() }
                .appShortcut(.actualSize)
                .disabled(!model.canResetZoom)
            Button("Zoom In") { model.zoomIn() }
                .appShortcut(.zoomIn)
                .disabled(!model.canZoomIn)
            Button("Zoom Out") { model.zoomOut() }
                .appShortcut(.zoomOut)
                .disabled(!model.canZoomOut)
        }
        .disabled(!hasWindow)
        Divider()
        // Cast: [01 §View] observed item, no key ([02]). Casting needs Chromium's media router,
        // which the bridge does not expose (no cast API in OACTab.h), so the item stays disabled.
        Button("Cast") {}
            .disabled(true)
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
            // "Change <Space>'s Profile" sheet ([06 §16.3] observed). B72.
            Button("Change Profile") { model.changeProfileOfCurrentSpace() }
                .disabled(model.selectedSpaceID == nil)
            Divider()
            Button("Next Space") { model.sidebar.stepSpace(by: 1) }
                .appShortcut(.nextSpace)
            Button("Previous Space") { model.sidebar.stepSpace(by: -1) }
                .appShortcut(.previousSpace)
            Divider()
            // One item per Space; the current one has a check, and each shows the Space's own icon
            // before its name ([01 §菜单项图标与缩进] observed; a Space without an icon shows none).
            // Items with ⌃1…⌃9 for the first nine ([02 §Space] observed); the rest have no key.
            ForEach(Array(model.sidebar.dockSpaces.enumerated()), id: \.element.id) { index, space in
                SpaceMenuItem(space: space, isCurrent: model.selectedSpaceID == space.id, number: index + 1) {
                    model.sidebar.selectSpace(space.id)
                }
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
                .appShortcut(.newTab)
            // tabs-crop.png observed "Pin Tab"; "Unpin Tab" for a pinned tab [06 §16.2] observed.
            Button(model.pinMenuTitle) { if let id = model.selectedTabID { model.sidebar.togglePin(id) } }
                .appShortcut(.togglePin)
                .disabled(model.selectedTabID == nil)
            Button("New Folder…") { model.sidebar.requestNewFolder() }
            Divider()
            Button("Next Tab") { model.sidebar.stepTab(by: 1) }
                .appShortcut(.nextTab)
            Button("Previous Tab") { model.sidebar.stepTab(by: -1) }
                .appShortcut(.previousTab)
            // ⌃Space [02 §标签与侧边栏] observed ("Reveal Current Tab"). B72.
            Button("Reveal Tab in Sidebar") { model.revealSelectedTabInSidebar() }
                .appShortcut(.revealCurrentTab)
                .disabled(model.selectedTabID == nil)
            // The three-item split submenu of [01 §Tabs] is not built: its title and items were not
            // recorded (`MenuBarCatalog.omittedItems`).
            Divider()
            Button("Clear Today") { model.sidebar.clearToday() }
                .appShortcut(.clearToday)
            // No key ([02 §Space] observed). B72.
            Button("Reset all tabs in this Space") { model.sidebar.resetAllPinnedTabsInSpace() }
                .disabled(!model.sidebar.canResetPinnedTabs)
        }
        .disabled(!hasWindow)
    }
}

/// One Space row of the Spaces menu: a check on the current Space, the Space's own icon
/// ([01 §菜单项图标与缩进] observed), ⌃1…⌃9 for the first nine ([02 §Space] observed).
struct SpaceMenuItem: View {
    let space: Space
    let isCurrent: Bool
    let number: Int
    let select: () -> Void

    var body: some View {
        let toggle = Toggle(isOn: Binding(get: { isCurrent }, set: { _ in select() })) {
            if let image = SpaceMenuIcon.image(for: space.icon) {
                Label { Text(space.name) } icon: { Image(nsImage: image) }
            } else {
                Text(space.name)
            }
        }
        if number <= 9 {
            toggle.appShortcut(.goToSpace, number - 1)
        } else {
            toggle
        }
    }
}

/// A Space icon as a menu image. A Space icon is an emoji or an SF Symbol name (`Space.icon`);
/// menus take images, so an emoji is drawn into one. 16 pt, the size of macOS menu icons (inferred).
enum SpaceMenuIcon {
    static let size: CGFloat = 16

    static func image(for icon: String?) -> NSImage? {
        guard let icon, !icon.isEmpty else { return nil }
        if let first = icon.unicodeScalars.first, !first.isASCII {
            let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                let text = NSAttributedString(string: icon, attributes: [.font: NSFont.systemFont(ofSize: size * 0.8)])
                let bounds = text.size()
                text.draw(at: NSPoint(x: rect.midX - bounds.width / 2, y: rect.midY - bounds.height / 2))
                return true
            }
            image.accessibilityDescription = icon
            return image
        }
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: icon)
        image?.isTemplate = true
        return image
    }
}

/// Window ▸ Stay On Top, first in the system window group ([01 §Window] observed). A toggle with
/// a check while on (inferred).
struct WindowMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Toggle("Stay On Top", isOn: Binding(get: { model.staysOnTop }, set: { _ in model.toggleStayOnTop() }))
            .disabled(!hasWindow)
    }
}

/// Help ▸ items after the system search field ([01 §Help] observed items, no icons). The groups
/// are ours (not recorded). Restore Data and Export Arc Notes are omitted
/// (`MenuBarCatalog.omittedItems`). Items that open a page need a browser window.
struct HelpMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Group {
            Button("Getting Started") { model.openGettingStarted() }
            Button("Essential Keyboard Shortcuts") { model.openKeyboardShortcutsPage() }
        }
        .disabled(!hasWindow)
        Button("Contact the Team") { model.contactTheTeam() }
        Button("Visit Help Center") { model.openHelpCenter() }
            .disabled(!hasWindow)
        Divider()
        Menu("Troubleshooting") {
            Button("Reveal Open Arc Data") { model.revealAppData() }
            Button("Copy Open Arc Info") { model.copyAppInfo() }
        }
    }
}

/// Arc ▸ Share Open Arc, after Settings… ([01 §Arc] observed "Share Arc"; no key in [02]).
struct ShareOpenArcMenuItem: View {
    let desktop: any DesktopServices

    var body: some View {
        Button("Share Open Arc") { desktop.share([OpenArcLinks.homepage]) }
    }
}

/// Arc ▸ Privacy Policy, after Services ([01 §Arc] observed). Opens a tab, so it needs a window.
struct PrivacyPolicyMenuItem: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Button("Privacy Policy") { model.openPrivacyPolicy() }
            .disabled(!hasWindow)
    }
}

/// Shortcuts in [02] that no [01] menu lists (plan Q16: keyboard-only, like Arc): Archive Tab ⌘W,
/// Go to Sidebar Item ⌘1…⌘9, Open Extensions ⌘E, and the [02] aliases of visible items (plan B85):
/// ⌘} / ⌘{ Next / Previous Tab, ⌘← / ⌘→ Go Back / Go Forward, F12 Developer Tools. They sit in a
/// menu the menu bar hides (`MenuBarAdjuster`); the keys still work. Keys from `ShortcutCatalog`.
struct KeyOnlyMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Group {
            Button("Archive Tab") { if let id = model.selectedTabID { model.sidebar.closeOrUnloadTab(id) } }
                .appShortcut(.archiveTab)
                .disabled(model.selectedTabID == nil)
            ForEach(1...8, id: \.self) { number in
                Button("Go to Sidebar Item \(number)") { model.sidebar.goToSidebarItem(number: number) }
                    .appShortcut(.goToSidebarItem, number - 1)
            }
            Button("Go to Last Sidebar Item") { model.sidebar.goToSidebarItem(number: 9) }
                .appShortcut(.goToLastSidebarItem)
            Button("Open Extensions") { model.openExtensions() }
                .appShortcut(.openExtensions)
                .disabled(model.selectedTabID == nil || model.isIncognito)
            // Aliases: the visible items' commands under the [02] alternative keys.
            Button("Next Tab") { model.sidebar.stepTab(by: 1) }
                .appShortcut(.nextTab, 1)
            Button("Previous Tab") { model.sidebar.stepTab(by: -1) }
                .appShortcut(.previousTab, 1)
            // Enabled whenever a window is, so the key always reaches `PageKeyAlias`, which leaves
            // it to a focused text field of ours.
            Button("Go Back") { PageKeyAlias.perform(.back, model: model) }
                .appShortcut(.goBack, 1)
            Button("Go Forward") { PageKeyAlias.perform(.forward, model: model) }
                .appShortcut(.goForward, 1)
            Button("Developer Tools") { model.showDeveloperTools() }
                .appShortcut(.developerTools, 1)
                .disabled(!model.canRunPageCommands)
        }
        .disabled(!hasWindow)
    }
}

/// ⌘← / ⌘→ as Go Back / Go Forward, only when the focused element does not take the key ([02
/// §页面与导航] observed keys; plan B85). In the page: Chromium offers a key to the menu only when the
/// page left it unhandled, so an editable field in the page keeps ⌘← / ⌘→ for its caret. In our own
/// text fields (command bar, find bar, rename) the menu's key equivalent would come first, so the
/// alias hands the key back to the field: it moves the caret to the line's start or end, as
/// everywhere on macOS (inferred).
@MainActor
enum PageKeyAlias {
    enum Direction { case back, forward }

    /// The editable text view of ours that has the keyboard (a text field's field editor or a text
    /// view), or nil.
    static func editableText(_ responder: NSResponder?) -> NSTextView? {
        guard let text = responder as? NSTextView, text.isEditable else { return nil }
        return text
    }

    /// Navigates `model`'s current tab, or gives the key to the focused text view of ours.
    /// (`NSApplication.shared` rather than `NSApp`, which is nil until the app object exists.)
    static func perform(
        _ direction: Direction, model: ShellModel,
        responder: NSResponder? = NSApplication.shared.keyWindow?.firstResponder,
        event: NSEvent? = NSApplication.shared.currentEvent
    ) {
        if let text = editableText(responder) {
            if let event, event.type == .keyDown {
                // The text view's own key bindings (the user's too), as without the menu item.
                text.interpretKeyEvents([event])
            } else if direction == .back {
                text.moveToLeftEndOfLine(nil)
            } else {
                text.moveToRightEndOfLine(nil)
            }
            return
        }
        switch direction {
        case .back: model.sidebar.goBack()
        case .forward: model.sidebar.goForward()
        }
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
