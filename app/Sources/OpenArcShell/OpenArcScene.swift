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
    /// Made once per launch. A holder, not the controller itself: a scene that observed the
    /// controller would rebuild every scene and the whole main menu on each change of the
    /// workspace or of a page's live state (B103). The windows and menus observe what they show.
    @StateObject private var holder: WorkspaceControllerHolder
    private var controller: WorkspaceController { holder.controller }

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
        _holder = StateObject(wrappedValue: {
            let controller = WorkspaceController(dependencies: dependencies, workspace: workspace)
            termination?.attach(controller)
            return WorkspaceControllerHolder(controller)
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
            AppMenuCommands(controller: controller)
            MenuBarExtrasCommands(controller: controller)
            ExternalOpenCommands(inbox: externalOpenInbox, controller: controller)
        }

        // Open Arc ▸ Settings… (⌘,). [01 §Arc menu, 02 §窗口与应用] observed. [B12]
        Settings {
            SettingsRootView(shell: controller.appHost())
                .appDependencies(dependencies)
        }
        .commands { SettingsGroupCommands(controller: controller) }

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
        // Each WindowGroup brings back the system save group unless it replaces it too (B19).
        .commands { NoSystemCloseCommands() }
    }
}

/// Keeps the app's `WorkspaceController` alive for the scene without observing it: it publishes
/// nothing itself, so the scene body (and with it the main menu) is not evaluated again when the
/// controller changes. B103.
@MainActor
final class WorkspaceControllerHolder: ObservableObject {
    let controller: WorkspaceController

    init(_ controller: WorkspaceController) {
        self.controller = controller
    }
}

/// Empties the system save group. Its File ▸ Close (⌘W) and Close All (⌥⌘W) come before
/// Tabs ▸ Archive Tab in the menu bar, so ⌘W closed the whole window instead of archiving the
/// tab. [01 §File] observed has neither item; [02 §tabs] observed: ⌘W is Archive Tab. SwiftUI
/// shows the group once any print group is replaced, and every `WindowGroup` that does not
/// replace it adds it back, so the browser and Little Arc scenes both carry this. B19.
struct NoSystemCloseCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {}
    }
}

/// Menu commands for the browser window that is key. Window-bound items act on that window's
/// model (`focusedSceneObject`); with no browser window key (Little Arc, Settings, none) they are
/// disabled, and only the items that open windows stay available.
struct BrowserCommands: Commands {
    let controller: WorkspaceController
    /// The key window's menu state, not its model: the menus are rebuilt only when a value they
    /// show changed (B103).
    @FocusedObject private var focusedMenuBar: MenuBarState?
    private var focused: ShellModel? { focusedMenuBar?.model }

    var body: some Commands {
        let model = focused ?? controller.appHost()
        ShellCommands(model: model, hasWindow: focused != nil)
        LibraryCommands(model: model, hasWindow: focused != nil)
        ExtensionCommands(model: model, hasWindow: focused != nil)
    }
}

/// The menu bar's window-bound menus. Titles from [01 §menus], keys from [02], both observed.
/// Items, order and separator groups follow [01 §菜单项图标与缩进] (E20 capture), listed in
/// `MenuBarCatalog`; the item views live in `MenuBarItems.swift`. Only commands that have a working
/// implementation are listed; the rest come with their surfaces. No item gets an icon of ours:
/// macOS adds its standard ones by action, and a group is indented only when one of its items has
/// one ([01 §菜单项图标与缩进] observed), so groups are split exactly as in Arc.
struct ShellCommands: Commands {
    let model: ShellModel
    /// A browser window is key; without one the window-bound items are disabled.
    let hasWindow: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            FileMenuItems(model: model, hasWindow: hasWindow, openWindow: openWindow)
        }

        // [01 §File] observed: Capture… · Capture Full Page · Capture in Portrait Mode · Save Page
        // As · Print end the menu, one group. The system Page Setup… / Print… items are replaced
        // (the spec lists only "Print"). B25. They live in the print group: SwiftUI leaves the
        // save group (`.saveItem`) out of the menu of an app without document scenes, so an item
        // placed after it never showed (C15).
        // No system Close (⌘W) / Close All (⌥⌘W): they took ⌘W from Archive Tab (B19).
        NoSystemCloseCommands()
        CommandGroup(replacing: .importExport) {}
        CommandGroup(replacing: .printItem) {
            FilePageMenuItems(model: model, hasWindow: hasWindow)
        }

        // Edit: Copy URL … Paste and Match Style and Find ▸ follow the pasteboard group, the only
        // place SwiftUI keeps a Find of ours next to `TextEditingCommands` (in a `.textEditing`
        // group it drops ours for the system one). `MenuBarAdjuster` moves the copy items after
        // Copy, Paste and Match Style after Paste, and our Find into the hidden system Find's
        // place, before Spelling and Grammar. [01 §Edit] observed order. B25, B62, B72 (plan Q15).
        CommandGroup(after: .pasteboard) {
            EditCopyURLMenuItems(model: model, hasWindow: hasWindow)
            FindMenu(model: model, findBar: model.findBar, hasWindow: hasWindow)
        }

        // View: our groups replace the system sidebar group (its own "Show Sidebar" would add a
        // sidebar icon and indent its group) and the toolbar group (system tab-bar items). Enter
        // Full Screen stays the system item, alone in the last group. [01 §菜单项图标与缩进] observed.
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .sidebar) {
            ViewMenuItems(model: model, hasWindow: hasWindow)
        }

        SpacesAndTabsCommands(model: model, hasWindow: hasWindow)
    }
}

/// Spaces ▸ and Tabs ▸ ([01 §Spaces], [01 §Tabs] observed), then the hidden menu with the [02]
/// shortcuts that no [01] menu lists (`MenuBarAdjuster` hides it). Apart from `ShellCommands`
/// because a `Commands` body takes at most ten groups.
struct SpacesAndTabsCommands: Commands {
    let model: ShellModel
    let hasWindow: Bool

    var body: some Commands {
        CommandMenu("Spaces") {
            SpacesMenuItems(model: model, hasWindow: hasWindow)
        }
        CommandMenu("Tabs") {
            TabsMenuItems(model: model, hasWindow: hasWindow)
        }
        CommandMenu(MenuBarCatalog.keyOnlyMenuTitle) {
            KeyOnlyMenuItems(model: model, hasWindow: hasWindow)
        }
    }
}

/// Edit ▸ Find ▸. B25. Items [01 §Edit] observed; keys [02 §页面与导航] observed: ⌘F, ⌘G, ⇧⌘G,
/// ⌘J (Jump to Selection). Find and Replace (⌥⌘F) is not shown: the find bar has no replace step
/// and Arc's item was not recorded doing one (B122, `MenuBarCatalog.omittedItems`); its key stays
/// in the hidden key-only menu and opens the find bar.
struct FindMenu: View {
    let model: ShellModel
    /// Rebuilds these items only when a value they show changed (`MenuBarState`, B103).
    @ObservedObject private var menuBar: MenuBarState
    /// Read by the actions only: the items show nothing of the find bar's state.
    let findBar: FindBarModel
    let hasWindow: Bool

    init(model: ShellModel, findBar: FindBarModel, hasWindow: Bool) {
        self.model = model
        self.findBar = findBar
        self.hasWindow = hasWindow
        _menuBar = ObservedObject(wrappedValue: model.menuBar)
    }

    var body: some View {
        Menu("Find") {
            Button("Find…") { findBar.show() }
                .appShortcut(.find)
            Button("Find Next") { findBar.findNext() }
                .appShortcut(.findNext)
            Button("Find Previous") { findBar.findPrevious() }
                .appShortcut(.findPrevious)
            Button("Use Selection to Find") { findBar.useSelectionToFind() }
            Button("Jump to Selection") { model.jumpToSelection() }
                .appShortcut(.jumpToSelection)
        }
        .disabled(!hasWindow || !model.canRunPageCommands)
    }
}

/// View ▸ Appearance ▸: a disabled explanatory line, then Automatic / Light / Dark with a check on
/// the current choice. [01 §View] observed title, line and items. Works with or without a window
/// (a per-device setting). B21.
struct AppearanceMenu: View {
    let model: ShellModel
    /// Rebuilds these items only when a value they show changed (`MenuBarState`, B103).
    @ObservedObject private var menuBar: MenuBarState

    init(model: ShellModel) {
        self.model = model
        _menuBar = ObservedObject(wrappedValue: model.menuBar)
    }

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
/// carries one key, so F12 is a hidden alias in `KeyOnlyMenuItems` (B85). B25.
struct DeveloperMenu: View {
    let model: ShellModel
    /// Rebuilds these items only when a value they show changed (`MenuBarState`, B103).
    @ObservedObject private var menuBar: MenuBarState
    let hasWindow: Bool

    init(model: ShellModel, hasWindow: Bool) {
        self.model = model
        self.hasWindow = hasWindow
        _menuBar = ObservedObject(wrappedValue: model.menuBar)
    }

    var body: some View {
        Menu("Developer") {
            Group {
                Button("View Source") { model.viewPageSource() }
                    .appShortcut(.viewSource)
                Button("Developer Tools") { model.showDeveloperTools() }
                    .appShortcut(.developerTools)
                Button("Inspect Elements") { model.inspectElements() }
                    .appShortcut(.inspectElements)
                Button("JavaScript Console") { model.showJavaScriptConsole() }
                    .appShortcut(.javaScriptConsole)
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

/// View ▸ Show Toolbar / Hide Toolbar (⇧⌘D). Observes the shared settings so the title follows.
/// [06 §17.1] observed. B43.
struct WebToolbarMenuItem: View {
    @ObservedObject var settings: WebToolbarSettings

    var body: some View {
        Button(settings.menuTitle) { settings.toggle() }
            .keyboardShortcut("d", modifiers: [.shift, .command])
    }
}
