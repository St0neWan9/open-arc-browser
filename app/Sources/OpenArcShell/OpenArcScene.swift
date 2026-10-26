import SwiftUI
import AppKit
import OpenArcModel

/// The app's main scene. The executable only wraps this in `@main`, so everything testable
/// lives in this library.
///
/// One `WorkspaceController` for the app; every browser window is a `WindowGroup` window with its
/// own `ShellModel` (B14). The window's value says what it opens with (`BrowserWindowRequest`);
/// a window the app opens by itself (launch, Dock click) restores the last session.
public struct OpenArcScene: Scene {
    private let dependencies: AppDependencies
    /// Links and files from other apps, from the app delegate (D2). nil: none are received.
    private let externalOpenInbox: ExternalOpenInbox?
    @StateObject private var controller: WorkspaceController

    /// - Parameters:
    ///   - dependencies: engine + sync store. Defaults to FakeEngine with sync disabled.
    ///   - externalOpenInbox: the app delegate's inbox (`OpenArcAppDelegate.inbox`); the first
    ///     browser window connects it to the controller.
    ///   - termination: the app delegate's quit sequence (`OpenArcAppDelegate.termination`, B27);
    ///     it gets the controller once SwiftUI makes it.
    @MainActor
    public init(
        dependencies: AppDependencies = .fake(),
        workspace: WorkspaceState = .demo(),
        externalOpenInbox: ExternalOpenInbox? = nil,
        termination: AppTermination? = nil
    ) {
        self.dependencies = dependencies
        self.externalOpenInbox = externalOpenInbox
        // Evaluated once, when SwiftUI creates the state object.
        _controller = StateObject(wrappedValue: {
            let controller = WorkspaceController(dependencies: dependencies, workspace: workspace)
            termination?.attach(controller)
            return controller
        }())
    }

    public var body: some Scene {
        WindowGroup(AppIdentity.displayName, id: BrowserWindowScene.id, for: BrowserWindowRequest.self) { $request in
            BrowserWindowRoot(controller: controller, request: request, externalOpenInbox: externalOpenInbox)
                .appDependencies(dependencies)
        } defaultValue: {
            BrowserWindowRequest(kind: .restore)
        }
        // No separate title bar: traffic lights sit on the themed background. [04 §window structure]
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        // Links and files from other apps go to the app delegate, which routes them into an
        // existing window (D2); SwiftUI must not open a window per external event.
        .handlesExternalEvents(matching: [])
        .commands {
            BrowserCommands(controller: controller)
            DefaultBrowserCommands(model: controller.defaultBrowser)
            BookmarkImportCommands(controller: controller)
            UpdateCommands(model: controller.updates)
            ExternalOpenCommands(inbox: externalOpenInbox, controller: controller)
            OnboardingCommands(controller: controller)
        }

        // Open Arc ▸ Settings… (⌘,). [01 §Arc menu, 02 §窗口与应用] observed. [B12]
        Settings {
            SettingsRootView(shell: controller.appHost())
                .appDependencies(dependencies)
        }

        // Little Arc: a command-bar-only floating window without title bar or sidebar. [06 §7]
        // observed. Each window gets a fresh id, so every ⌥⌘N opens a new one (inferred). It acts
        // on the browser window used last.
        // Never restored on relaunch (B30): the configurator turns `NSWindow.isRestorable` off
        // (`restorationBehavior(.disabled)` needs macOS 15, and `SceneBuilder` cannot branch on
        // availability without dropping the scene on 14), and a window whose id this run did not
        // issue closes at once.
        WindowGroup(LittleArcTokens.windowTitle, id: LittleArcScene.id, for: UUID.self) { $id in
            LittleArcWindowView(windowID: id, controller: controller)
                .appDependencies(dependencies)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .handlesExternalEvents(matching: [])
        .defaultPosition(.center)
    }
}

/// Menu commands for the browser window that is key. Window-bound items act on that window's
/// model (`focusedSceneObject`); with no browser window key (Little Arc, Settings, none) they are
/// disabled, and only the items that open windows stay available.
struct BrowserCommands: Commands {
    let controller: WorkspaceController
    @FocusedObject private var focused: ShellModel?

    var body: some Commands {
        let model = focused ?? controller.appHost()
        ShellCommands(model: model, hasWindow: focused != nil)
        LibraryCommands(model: model, hasWindow: focused != nil)
    }
}

/// Menu items with their default shortcuts. Titles from [01 §menus], keys from [02], both observed.
/// Only commands that have a working implementation are listed; the rest come with their surfaces.
struct ShellCommands: Commands {
    @ObservedObject var model: ShellModel
    /// A browser window is key; without one the window-bound items are disabled.
    let hasWindow: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // [01 §File] observed order; keys [02 §窗口与应用] observed.
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
            // [01 §File] observed: Restore Last Closed Tab precedes Open Command Bar.
            Button("Restore Last Closed Tab") { model.sidebar.restoreLastClosedTab() }
                .keyboardShortcut("t", modifiers: [.shift, .command])
                .disabled(!hasWindow || !model.sidebar.canRestoreLastClosedTab)
            Button("Open Command Bar") { model.presentCommandBar(.currentTab) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!hasWindow)
            // New Profile and New Easel come with their surfaces. Close Window closes whichever
            // window is key (browser, Little Arc or Settings). [01 §File, 02] observed.
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.shift, .command])
        }

        // [01 §File] observed: Save Page As, then Print, at the end of the menu. ⌘P [02 §页面与导航]
        // observed; Save Page As has no key in [02]. The system Page Setup… / Print… items are
        // replaced (the spec lists only "Print"). B25.
        CommandGroup(after: .saveItem) {
            Button("Save Page As") { model.savePageAs() }
                .disabled(!hasWindow || !model.canRunPageCommands)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print") { model.printPage() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasWindow || !model.canRunPageCommands)
        }

        // Edit ▸ Find ▸ after Select All. [01 §Edit] observed items; keys [02 §页面与导航] observed
        // ⌘F / ⌘G / ⇧⌘G. Use Selection to Find has no key in [02]. Find and Replace and Jump to
        // Selection come when the page can do them. B25.
        CommandGroup(after: .pasteboard) {
            FindMenu(model: model, findBar: model.findBar, hasWindow: hasWindow)
        }

        // [01 §View] observed: Appearance ▸ is the first View item, before Hide Sidebar. B21.
        CommandGroup(before: .sidebar) {
            AppearanceMenu(model: model)
        }

        CommandGroup(after: .sidebar) {
            Group {
                // ⌘S toggles the sidebar. [02 §tabs] observed 2026-10-25. Stop Loading has no key in [02].
                Button(model.sidebarToggleTitle) { model.toggleSidebar() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Stop Loading") { model.sidebar.reloadOrStop() }
                    .disabled(model.sidebar.reloadMode != .stop)
                Button("Refresh the Page") { model.sidebar.reloadOrStop() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.selectedTabID == nil)
                // [01 §View] observed after Refresh the Page; ⇧⌘R [02] observed.
                Button("Force Refresh the Page") { model.forceReload() }
                    .keyboardShortcut("r", modifiers: [.shift, .command])
                    .disabled(model.selectedLiveTab == nil)
                Button("Add Split View") { model.addSplitView() }
                    .keyboardShortcut("=", modifiers: [.control, .shift])
                // [01 §View] observed: the split items are available only while a split exists.
                // ⌃⇧- is listed in [02 §split]; the other two have no recorded key.
                Button("Close this Split Pane") { model.closeSplitPane() }
                    .keyboardShortcut("-", modifiers: [.control, .shift])
                    .disabled(!model.hasActiveSplit)
                Button("Separate Page from Split View") { model.separatePageFromSplitView() }
                    .disabled(!model.hasActiveSplit)
                Button("Expand Current Split") { model.toggleExpandCurrentSplit() }
                    .disabled(!model.hasActiveSplit)
                // [01 §View] observed order after the split items; ⌘0 / ⌘+ / ⌘- [02] observed.
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
            // [01 §View] observed: Developer ▸ after the zoom items (Cast comes with its surface). B25.
            DeveloperMenu(model: model, hasWindow: hasWindow)
        }

        CommandMenu("Spaces") {
            // An incognito window has no Spaces to edit or switch. inferred.
            Group {
                // [01 §Spaces] observed. [02] lists no shortcut for these, so none is invented.
                Button("New Space…") { model.spaceFlow.beginCreate() }
                // [01 §Spaces] observed: Edit Theme… precedes Rename Space. The bubble opens at the window's lower left. [06 §2]
                Button("Edit Theme…") { if let id = model.selectedSpaceID { model.spaceFlow.beginEditTheme(spaceID: id) } }
                    .disabled(model.selectedSpaceID == nil || model.spaceFlow.isCreating)
                Button("Rename Space") { if let id = model.selectedSpaceID { model.spaceFlow.beginRename(spaceID: id) } }
                    .disabled(model.selectedSpaceID == nil)
                Divider()
                Button("Next Space") { model.sidebar.stepSpace(by: 1) }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                Button("Previous Space") { model.sidebar.stepSpace(by: -1) }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                Divider()
                ForEach(Array(model.sidebar.dockSpaces.prefix(9).enumerated()), id: \.element.id) { index, space in
                    Button("Go to “\(space.name)”") { model.sidebar.goToSpace(number: index + 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                }
            }
            .disabled(!hasWindow || model.isIncognito)
        }

        CommandMenu("Tabs") {
            Group {
                Button("Archive Tab") { if let id = model.selectedTabID { model.sidebar.closeOrUnloadTab(id) } }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.selectedTabID == nil)
                Button("Pin/Unpin Tab") { if let id = model.selectedTabID { model.sidebar.togglePin(id) } }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(model.selectedTabID == nil)
                Button("New Folder…") { model.sidebar.requestNewFolder() }
                Divider()
                Button("Next Tab") { model.sidebar.stepTab(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .command])
                Button("Previous Tab") { model.sidebar.stepTab(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .command])
                Divider()
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Go to Last Sidebar Item" : "Go to Sidebar Item \(number)") {
                        model.sidebar.goToSidebarItem(number: number)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
                Divider()
                Button("Clear Today") { model.sidebar.clearToday() }
                    .keyboardShortcut("k", modifiers: [.shift, .command])
                Button("Collapse All Folders") { model.sidebar.setAllFoldersExpanded(false) }
                Button("Expand All Folders") { model.sidebar.setAllFoldersExpanded(true) }
            }
            .disabled(!hasWindow)
        }

        CommandGroup(before: .toolbar) {
            Group {
                Button("Back") { model.sidebar.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.sidebar.canGoBack)
                Button("Forward") { model.sidebar.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.sidebar.canGoForward)
            }
            .disabled(!hasWindow)
        }
    }

    /// Opens a browser window from the menu, on the key window's Space (inferred).
    private func openBrowserWindow(_ kind: BrowserWindowRequest.Kind) {
        // Keys typed before the new window is key wait for it (B29: ⌘N then ⌘T).
        NewWindowTypeAhead.shared.begin(.browserWindow)
        openWindow(id: BrowserWindowScene.id, value: model.issueMenuWindowRequest(kind, fromWindow: hasWindow))
    }
}

/// Edit ▸ Find ▸. Observes the find bar so Find Next / Previous follow its state. B25.
struct FindMenu: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var findBar: FindBarModel
    let hasWindow: Bool

    var body: some View {
        Menu("Find") {
            Button("Find…") { findBar.show() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Find Next") { findBar.findNext() }
                .keyboardShortcut("g", modifiers: .command)
            Button("Find Previous") { findBar.findPrevious() }
                .keyboardShortcut("g", modifiers: [.shift, .command])
            Button("Use Selection to Find") { findBar.useSelectionToFind() }
        }
        .disabled(!hasWindow || !model.canRunPageCommands)
    }
}

/// View ▸ Appearance ▸: a disabled explanatory line, then Automatic / Light / Dark with a check on
/// the current choice. [01 §View] observed title, line and items. Works with or without a window
/// (a per-device setting). B21.
struct AppearanceMenu: View {
    @ObservedObject var model: ShellModel

    var body: some View {
        Menu(WebAppearance.menuTitle) {
            Button(WebAppearance.menuExplanation) {}
                .disabled(true)
            ForEach(WebAppearance.allCases) { choice in
                Toggle(choice.title, isOn: Binding(
                    get: { model.webAppearance == choice },
                    set: { if $0 { model.webAppearance = choice } }
                ))
            }
        }
    }
}

/// View ▸ Developer ▸. [01 §View] observed items and order; keys [02 §开发者] observed: ⌥⌘U, ⌥⌘I,
/// ⌥⌘C, ⌥⌘J; Network Inspector has none. [02] also lists F12 for Developer Tools; a menu item
/// carries one key, so F12 is not bound yet. B25.
struct DeveloperMenu: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Menu("Developer") {
            Group {
                Button("View Source") { model.viewPageSource() }
                    .keyboardShortcut("u", modifiers: [.option, .command])
                Button("Developer Tools") { model.showDeveloperTools() }
                    .keyboardShortcut("i", modifiers: [.option, .command])
                Button("Inspect Elements") { model.inspectElements() }
                    .keyboardShortcut("c", modifiers: [.option, .command])
                Button("JavaScript Console") { model.showJavaScriptConsole() }
                    .keyboardShortcut("j", modifiers: [.option, .command])
                Button("Network Inspector") { model.showNetworkInspector() }
            }
            .disabled(!hasWindow || !model.canRunPageCommands)
            Divider()
            // A per-device setting: available with or without a page.
            Toggle("Allow JavaScript from Apple Events", isOn: Binding(
                get: { model.allowsJavaScriptFromAppleEvents },
                set: { model.allowsJavaScriptFromAppleEvents = $0 }
            ))
        }
    }
}

extension ShellModel {
    /// The request a File menu item opens: from the key browser window on its Space, else on the
    /// active Space. Recorded as issued by this run; otherwise the window root takes the value for
    /// one macOS restored on its own and opens a `.restore` window instead (⇧⌘N would open a
    /// regular window, ⌘N the last session's). [A19]
    func issueMenuWindowRequest(_ kind: BrowserWindowRequest.Kind, fromWindow: Bool) -> BrowserWindowRequest {
        let request = fromWindow ? windowRequest(kind) : BrowserWindowRequest(kind: kind)
        controller.noteIssued(request)
        return request
    }
}
