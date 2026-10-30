import Foundation
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence

/// Per-window coordinator (B14): one per browser window. The window's `SidebarViewModel` holds its
/// selection; the shared workspace, persistence, sync, live engine tabs and auto-archive belong to
/// the app-level `WorkspaceController`. This type wires the window's sidebar to its command bar
/// and the window-owned surfaces (command bar presentation, sidebar visibility, Library mode,
/// split focus, site controls).
@MainActor
public final class ShellModel: ObservableObject {
    /// The app-level owner of the workspace (an incognito window has its own, in memory).
    public let controller: WorkspaceController
    public var dependencies: AppDependencies { controller.dependencies }
    public let sidebar: SidebarViewModel
    public let commandBar: CommandBarViewModel
    /// The command bar shown inside a split pane (400 pt, lower right). [06 §5] observed.
    public let paneCommandBar: CommandBarViewModel
    /// Create Space, Rename Space and Change Space Icon surfaces. [06 §1] observed.
    public let spaceFlow: SpaceFlowModel
    /// New Profile and Change Profile sheets (File ▸ New Profile, Spaces ▸ Change Profile).
    /// [06 §16.3] observed. B72.
    public let profileFlow: ProfileFlowModel
    /// The Library mode of this window (rail, list column, web panel). [06 §8] observed.
    public let library: LibraryModel
    /// Site Control Center bubble and URL box copy link. [06 §12] observed.
    public let siteControls: SiteControlsModel
    /// Find in page for the selected tab (the focused pane in a split). B25.
    public let findBar: FindBarModel
    /// Region, full page and portrait capture of the selected page. [06 §24] observed. B51.
    public let pageCapture: PageCaptureModel
    /// Page translation surfaces (B47, [06 §19]).
    public let translation: TranslationModel
    /// The Easel canvas shown when the selected tab is an Easel's row. [06 §9] observed. B56.
    public let easelCanvas: EaselCanvasModel
    /// Hidden-sidebar peek: pinned / hidden / floating. Follows `isSidebarVisible`. [06 §14] B34.
    let sidebarPeek: SidebarPeekController
    /// Link Peek, the floating preview of a link (B49, [06 §22]).
    public let linkPeek: LinkPeekModel
    /// Picture in Picture when the user leaves a video tab (C15).
    private var autoPictureInPicture: AutoPictureInPicture?
    /// Asks where and how Save Page As writes (suggested file name → location and format; nil
    /// cancels). nil uses the system save panel; tests install their own. B25, C15.
    public var chooseSavePageLocation: (@MainActor (String) async -> SavePageChoice?)?

    /// Whether the command bar panel is showing. [05 §command bar] observed: floating, no scrim.
    /// Also true while the bar is shown inside a split pane.
    @Published public private(set) var isCommandBarPresented = false
    /// The split pane (its tab id) that hosts the command bar; nil when the bar floats over the
    /// window. [06 §5, §6] observed.
    @Published public internal(set) var commandBarPaneTabID: UUID?
    /// View ▸ Expand Current Split is in effect (B79, [06 §21.6] observed): the expanded pane is
    /// drawn maximal and the others at the 220 pt minimum. Window-local, not stored.
    @Published public internal(set) var splitExpansion: SplitExpansion?
    /// The split tree while a divider is being dragged; stored on release. B58.
    @Published public internal(set) var splitResizePreview: SplitResizePreview?
    /// Sidebar visibility (View ▸ Hide Sidebar). [01 §View] observed.
    @Published public private(set) var isSidebarVisible = true
    /// Last command the shell could not run itself (no surface for it yet). For tests/diagnostics.
    @Published public private(set) var lastUnhandledCommand: CommandBarCommand?
    /// One-time alert after launch, e.g. the workspace file was refused and nothing is saved.
    @Published public internal(set) var launchNotice: LaunchNotice?
    /// Opens a new Little Arc window. Installed by the main window's view, where SwiftUI's
    /// `openWindow` is available; nil in tests and previews. [02] ⌥⌘N observed.
    public var openLittleArcWindow: (() -> Void)?
    /// Opens the Settings window. Installed by the main window's view (SwiftUI's `openSettings`);
    /// nil in tests and previews. [01 §Arc] Settings…, [02] ⌘, observed.
    public var openSettingsWindow: (() -> Void)?
    /// Brings this window to the front. Installed by the window's view; nil in tests.
    public var focusWindow: (() -> Void)?
    /// Window ▸ Stay On Top is on for this window ([01 §Window] observed item; B72).
    @Published public internal(set) var staysOnTop = false
    /// Sets the window's level (floating or normal). Installed by the window's view; nil in tests.
    public var applyWindowLevel: ((_ floating: Bool) -> Void)?
    /// How often another window asked this one to come to the front (one-window-per-tab rule).
    /// For tests and diagnostics.
    public private(set) var focusRequestCount = 0
    /// How often a tab was revealed in this window (`revealTab`, B29). For tests and diagnostics.
    public private(set) var revealRequestCount = 0
    /// `revealTab` ran before the window's view installed `focusWindow`.
    private var wantsFocusOnAttach = false
    /// The window's identity for the engine's extensions (plan B126).
    let windowID = UUID()
    /// The window's frame (AppKit screen coordinates), set by the window's view (plan B126).
    private(set) var windowFrame = EngineWindowFrame()
    /// Frame the AppKit window takes when it appears: an incognito window lies over the window it
    /// was opened from ([06 §20.1] observed, F5-41). Consumed by `takeOpeningFrame()`.
    private(set) var openingFrame: CGRect?
    /// Reports the window again when its Space, selection or tabs change (plan B126).
    private var engineWindowChanges: AnyCancellable?

    /// When this window's menu bar items must be rebuilt (B103): they observe it instead of this
    /// model, which publishes on every change of the workspace and of its pages.
    public private(set) lazy var menuBar = MenuBarState(model: self)

    /// Saved in `ui-state.json` and counted as an open window (false for the hidden host Little
    /// Arc uses when no window is open).
    let isBrowserWindow: Bool
    /// True when this model made its controller (convenience init, incognito): `stop()` stops it.
    private let ownsController: Bool
    private var isStopped = false
    private var sidebarChanges: AnyCancellable?
    private var spaceFlowChanges: AnyCancellable?
    private var profileFlowChanges: AnyCancellable?
    private var libraryChanges: AnyCancellable?
    private var libraryFlagChanges: AnyCancellable?
    private var peekChanges: AnyCancellable?
    private var linkPeekChanges: AnyCancellable?

    /// A window on `controller` that opens with `window`'s selection. A stale Space id falls back to
    /// the first Space, a stale or foreign tab id to no selection.
    init(controller: WorkspaceController, window: WindowUIState, isBrowserWindow: Bool = true, ownsController: Bool = false) {
        self.controller = controller
        self.isBrowserWindow = isBrowserWindow
        self.ownsController = ownsController
        let sidebar = SidebarViewModel(controller: controller, selectedSpaceID: window.selectedSpaceID)
        sidebar.countsAsVisibleWindow = isBrowserWindow
        self.sidebar = sidebar
        // Sources read the shared workspace at query time, so results always reflect the current
        // state (`installCommandBarSources` replaces these with window-aware ones).
        self.commandBar = CommandBarViewModel(
            sources: commandBarDefaultSources(workspace: { @MainActor in controller.workspace })
        )
        self.paneCommandBar = CommandBarViewModel(
            sources: commandBarDefaultSources(workspace: { @MainActor in controller.workspace }),
            mode: .currentTab,
            presentation: .pane
        )
        self.spaceFlow = SpaceFlowModel(sidebar: sidebar, now: controller.now, makeID: controller.makeID)
        self.profileFlow = ProfileFlowModel(sidebar: sidebar)
        self.library = LibraryModel(sidebar: sidebar, now: controller.now)
        // The engine's ad blocker (C16) over fake site settings until the bridge provides the
        // rest (plan C12 / C14).
        // The engine's ad blocker (C16) and extensions (C14) over fake site settings until the
        // bridge provides the rest (plan C12).
        let engine = controller.dependencies.engine
        self.siteControls = SiteControlsModel(
            sidebar: sidebar,
            provider: EngineSiteSettingsProvider(
                adBlocking: engine.adBlocking, extensions: engine.extensions,
                engineTab: { [weak controller] id in controller?.liveTab(for: id)?.id },
                base: FakeSiteSettingsProvider()
            ),
            pasteboard: SystemPasteboardWriter()
        )
        siteControls.engineExtensions = engine.extensions
        self.findBar = FindBarModel(sidebar: sidebar)
        self.pageCapture = PageCaptureModel(sidebar: sidebar, preferences: controller.dependencies.preferences,
                                            pasteboard: SystemCaptureImagePasteboard(), now: controller.now)
        self.translation = TranslationModel(sidebar: sidebar, engine: engine.translation)
        self.easelCanvas = EaselCanvasModel(sidebar: sidebar)
        self.sidebarPeek = SidebarPeekController(isPinned: window.isSidebarVisible)
        self.linkPeek = LinkPeekModel(sidebar: sidebar)
        sidebar.requestHandler = { [weak self] request in self?.handle(request) }
        sidebar.onFocusRequest = { [weak self] in self?.requestFocus() }
        installCommandBarSources()
        commandBar.onAction = { [weak self] action in self?.perform(action) }
        commandBar.onDismiss = { [weak self] in self?.dismissCommandBar() }
        paneCommandBar.onAction = { [weak self] action in self?.perform(action) }
        paneCommandBar.onDismiss = { [weak self] in self?.dismissCommandBar() }
        let favicons: (CommandBarResult) -> Data? = { [weak controller] result in controller?.commandBarFavicon(for: result) }
        commandBar.faviconProvider = favicons
        paneCommandBar.faviconProvider = favicons
        // Menu enablement (split items, back/forward) reads sidebar state through this model.
        sidebarChanges = sidebar.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        spaceFlowChanges = spaceFlow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        profileFlowChanges = profileFlow.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        libraryChanges = library.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        peekChanges = sidebarPeek.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        linkPeekChanges = linkPeek.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        isSidebarVisible = window.isSidebarVisible
        if let tabID = window.selectedTabID { restoreSelectedTab(tabID) }
        connectLibraryFlags()
        let preferences = controller.dependencies.preferences
        autoPictureInPicture = AutoPictureInPicture(sidebar: sidebar) { preferences.entersPictureInPictureOnLeavingVideoTab }
        installExtensionHandlers()
        installCaptureHandlers()
        translation.openURL = { [weak sidebar] url in _ = sidebar?.newTab(url: url, title: url.host ?? "Settings") }
        if isBrowserWindow {
            launchNotice = controller.takeLaunchNotice()
            // Starts auto-archive with the first window, after its selection is restored. [B3]
            controller.registerWindow(self)
            // Extensions see the window (plan B126).
            let reporter = controller.engineWindows
            reporter.register(self)
            engineWindowChanges = sidebar.objectWillChange.sink { [weak reporter] _ in reporter?.setNeedsReport() }
        }
    }

    /// A window for `request` on the app's controller: New Window, Blank Window, an incognito
    /// window (with its own in-memory controller) or a window of the last session.
    public static func window(for request: BrowserWindowRequest, on controller: WorkspaceController) -> ShellModel {
        switch request.kind {
        case .incognito:
            let incognito = controller.makeIncognito()
            let model = ShellModel(controller: incognito, window: WindowUIState(), ownsController: true)
            // Same size and position as the window it came from. [06 §20.1] observed (F5-41).
            model.openingFrame = request.frame
            if let url = request.url {
                // Open Link in Incognito Window (B124): the window shows the link.
                model.sidebar.newTab(url: url, title: url.host ?? url.absoluteString)
            } else {
                // The window opens with the command bar showing its help rows. [06 §20.1] observed (B61).
                model.presentCommandBar(.newTab)
            }
            return model
        case .restore:
            let saved = controller.takePendingRestore() ?? controller.reopenState()
            return ShellModel(controller: controller, window: saved)
        case .newWindow:
            let spaceID = request.spaceID ?? controller.activeSpaceID
            let tabID = request.tabID ?? spaceID.flatMap { controller.mostRecentTabNotOnScreen(inSpace: $0) }
            return ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: spaceID, selectedTabID: tabID))
        case .blank:
            return ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: request.spaceID ?? controller.activeSpaceID))
        }
    }

    /// One window with its own controller: loads the workspace from the persistence store (or uses
    /// `workspace` on first launch), restores the first saved window, starts sync forwarding and
    /// auto-archive. Kept for tests and single-window tools; the app shares one controller across
    /// windows (`OpenArcScene`).
    public convenience init(
        dependencies: AppDependencies,
        workspace: WorkspaceState,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init,
        notificationCenter: NotificationCenter = .default
    ) {
        let controller = WorkspaceController(
            dependencies: dependencies,
            workspace: workspace,
            now: now,
            makeID: makeID,
            notificationCenter: notificationCenter
        )
        let saved = controller.takePendingRestore() ?? WindowUIState()
        controller.discardPendingRestores()
        self.init(controller: controller, window: saved, ownsController: true)
    }

    /// Whether this is an incognito window. inferred (B14).
    public var isIncognito: Bool { controller.isOffTheRecord }

    /// This window's entry in `ui-state.json`.
    var windowUIState: WindowUIState {
        WindowUIState(selectedSpaceID: selectedSpaceID, selectedTabID: selectedTabID, isSidebarVisible: isSidebarVisible)
    }

    /// Another window asked for a tab this window shows: bring this window to the front.
    private func requestFocus() {
        focusRequestCount += 1
        focusWindow?()
    }

    /// The window became the key window: New Window opens on its Space from now on.
    public func windowDidBecomeKey() {
        controller.windowDidBecomeActive(self)
        if isBrowserWindow { controller.engineWindows.windowKeyStateChanged(self, isKey: true) }
    }

    /// The window stopped being the key window (plan B126: extensions see it unfocused).
    public func windowDidResignKey() {
        if isBrowserWindow { controller.engineWindows.windowKeyStateChanged(self, isKey: false) }
    }

    /// The window moved or resized; `x`, `y`, `width`, `height` are its `NSWindow.frame` (plan
    /// B126: extensions read it as the window's bounds).
    public func windowFrameDidChange(x: Double, y: Double, width: Double, height: Double) {
        let frame = EngineWindowFrame(x: x, y: y, width: width, height: height)
        guard frame != windowFrame else { return }
        windowFrame = frame
        if isBrowserWindow { controller.engineWindows.setNeedsReport() }
    }

    /// The window closed (close button, Close Window ⇧⌘W). Its state leaves the saved UI state and
    /// its background work stops. An incognito window's tabs are discarded. inferred.
    public func windowDidClose() {
        guard !isStopped else { return }
        if isBrowserWindow { controller.unregisterWindow(self, save: true) }
        stop()
    }

    /// Keeps the Library flags (B22) app-wide: this window starts from the shared values, saves its
    /// changes through the controller and follows changes made in other windows.
    private func connectLibraryFlags() {
        let flags = controller.libraryFlags
        library.restorePersistentState(mediaIntroDismissed: flags.mediaIntroDismissed, lastSectionName: flags.lastSection)
        library.onPersistentStateChange = { [weak self] in
            guard let self else { return }
            self.controller.setLibraryFlags(LibraryUIFlags(
                mediaIntroDismissed: !self.library.isMediaIntroVisible,
                lastSection: self.library.lastSection?.rawValue
            ))
        }
        libraryFlagChanges = controller.$libraryFlags.dropFirst().sink { [weak self] flags in
            self?.library.restorePersistentState(mediaIntroDismissed: flags.mediaIntroDismissed, lastSectionName: flags.lastSection)
        }
    }

    // MARK: Forwarded state (kept for callers and tests that predate the sidebar view model)

    public var workspace: WorkspaceState { sidebar.workspace }
    public var selectedSpaceID: UUID? { sidebar.selectedSpaceID }
    public var selectedTabID: UUID? { sidebar.selectedTabID }
    public var selectedSpace: Space? { sidebar.selectedSpace }
    public var selectedTheme: Theme? { sidebar.theme }
    public var selectedLiveTab: (any BrowserTab)? { selectedTabID.flatMap { sidebar.liveTab(for: $0) } }

    /// Selects a tab and waits until its engine tab exists.
    public func activate(tabID: UUID) async throws {
        sidebar.selectTab(tabID)
        await sidebar.settleEngineWork()
        if let error = sidebar.lastError { throw error }
    }

    /// Opens a new tab at the top of Today in the current space and waits for its engine tab.
    @discardableResult
    public func openNewTab(url: URL?) async throws -> UUID? {
        let id = sidebar.newTab(url: url, title: url?.host ?? "New Tab")
        await sidebar.settleEngineWork()
        if let error = sidebar.lastError { throw error }
        return id
    }

    public func selectSpace(_ id: UUID) { sidebar.selectSpace(id) }

    // MARK: Window title (B74)

    /// Title of an incognito window before it shows a page. [06 §20.1] observed: "Space 1" (the
    /// sidebar row reads "Incognito Tabs" all the same).
    static let incognitoWindowTitle = "Space 1"

    /// The window's title (Window menu, Mission Control, AppleScript `name`): the selected tab's
    /// page title, else the Space's name. [06 §1] observed: after Create Space the title is the
    /// Space name; [06 §20.1] observed: an incognito window reads "Space 1", then the page title.
    /// inferred: the page title, not a tab's custom name (a rename only changes the sidebar row);
    /// a tab without a title yet falls back to the Space name.
    public var windowTitle: String {
        if let tabID = selectedTabID, let tab = workspace.tabs[tabID], !tab.meta.isTombstone {
            if let live = sidebar.liveState(for: tabID)?.title, !live.isEmpty { return live }
            if !tab.title.isEmpty { return tab.title }
        }
        if isIncognito { return Self.incognitoWindowTitle }
        if let name = selectedSpace?.name, !name.isEmpty { return name }
        return AppIdentity.displayName
    }

    // MARK: Command bar

    /// ⌘T opens an empty bar for a new tab; ⌘L prefills the current address. [02] observed.
    public func presentCommandBar(_ mode: CommandBarMode) {
        if commandBarPaneTabID != nil {
            commandBarPaneTabID = nil
            paneCommandBar.dismiss()
        }
        let url = mode == .currentTab ? sidebar.selectedURL : nil
        commandBar.open(
            mode: mode,
            currentURL: url,
            currentTabID: mode == .currentTab ? selectedTabID : nil,
            currentSpaceID: selectedSpaceID
        )
        isCommandBarPresented = true
    }

    public func dismissCommandBar() {
        guard isCommandBarPresented else { return }
        isCommandBarPresented = false
        if commandBarPaneTabID != nil {
            commandBarPaneTabID = nil
            paneCommandBar.dismiss()
        } else {
            commandBar.dismiss()
        }
    }

    /// Opens the command bar inside the split pane of `tabID`: lower right, 400 pt wide.
    /// URLs and searches load into that pane's tab. [06 §5] observed. `currentURL` prefills the
    /// bar like ⌘L (the pane top bar's domain pill, B18); nil opens it empty.
    public func presentCommandBarInPane(_ tabID: UUID, currentURL: URL? = nil) {
        if isCommandBarPresented && commandBarPaneTabID == nil { commandBar.dismiss() }
        paneCommandBar.open(mode: .currentTab, currentURL: currentURL, currentTabID: tabID, currentSpaceID: selectedSpaceID)
        commandBarPaneTabID = tabID
        isCommandBarPresented = true
    }

    /// Executes what the command bar returned.
    func perform(_ action: CommandBarAction) {
        // A pane bar loads into its own pane's tab, so make that pane the selected tab first.
        let pane = commandBarPaneTabID
        dismissCommandBar()
        switch action {
        case .openURL(_, .currentTab), .searchWeb(_, .currentTab):
            if let pane, selectedTabID != pane { sidebar.selectTab(pane) }
        default:
            break
        }
        switch action {
        case .switchToTab(let id):
            // A tab another window shows brings that window to the front instead. inferred (B14).
            if controller.sidebar(showing: id, except: sidebar) != nil {
                sidebar.selectTab(id)
                return
            }
            // From an empty split pane's bar the chosen tab fills that pane (B19).
            if let pane, sidebar.fillEmptyPane(pane, with: id) { return }
            if let spaceID = workspace.tabs[id]?.location.spaceID, spaceID != selectedSpaceID {
                sidebar.selectSpace(spaceID)
            }
            sidebar.selectTab(id)
        case .openURL(let url, let target):
            open(url, target: target)
        case .searchWeb(let query, let target):
            if let url = searchURL(for: query) { open(url, target: target) }
        case .runCommand(let command):
            run(command)
        case .restoreArchived(let itemID):
            sidebar.restoreArchived(itemID)
        case .goToSpace(let spaceID):
            sidebar.selectSpace(spaceID)
        case .moveTab(let tabID, let spaceID):
            // The sidebar's Move to ▸ <Space> intent; the window stays in its space. inferred.
            sidebar.moveTab(tabID, toSpace: spaceID)
        }
    }

    private func open(_ url: URL, target: CommandBarOpenTarget) {
        switch target {
        case .newTab: sidebar.newTab(url: url, title: url.host ?? url.absoluteString)
        case .currentTab: sidebar.navigateSelectedTab(to: url)
        }
    }

    func searchURL(for query: String) -> URL? {
        guard let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: searchURLTemplate.replacingOccurrences(of: "%@", with: escaped))
    }

    /// Runs an app command. Each one does what its menu item does (see `ShellCommands`,
    /// `LibraryCommands`); rows of commands that cannot run are not offered (`isAvailable`).
    func run(_ command: CommandBarCommand) {
        // An incognito window has no Spaces to create, edit or manage. inferred (B14).
        if isIncognito, [.newSpace, .editTheme, .renameSpace, .manageSpaces].contains(command) {
            lastUnhandledCommand = command
            return
        }
        switch command {
        // File
        case .newTab: presentCommandBar(.newTab)
        case .newWindow: openBrowserWindow(.newWindow, for: command)
        case .newIncognitoWindow: openBrowserWindow(.incognito, for: command)
        case .newLittleArcWindow:
            if let open = openLittleArcWindow { open() } else { lastUnhandledCommand = command }
        case .restoreLastClosedTab: sidebar.restoreLastClosedTab()
        // Edit
        case .copyURL: copySelectedURL()
        // View
        case .toggleSidebar: toggleSidebar()
        case .reload: reload()
        case .addSplitView: addSplitView()
        case .addTopSplit: addSplit(.top)
        case .addLeftSplit: addSplit(.left)
        case .addRightSplit: addSplit(.right)
        case .addBottomSplit: addSplit(.bottom)
        case .convertToVerticalSplit: convertActiveSplit(to: .vertical)
        case .convertToHorizontalSplit: convertActiveSplit(to: .horizontal)
        case .clearCookiesAndRefresh: clearCookiesAndRefresh()
        case .closeSplitPane: closeSplitPane()
        case .separateFromSplit: separatePageFromSplitView()
        case .expandSplit: expandCurrentSplit()
        // Spaces
        case .newSpace: spaceFlow.beginCreate()
        case .editTheme: if let id = selectedSpaceID { spaceFlow.beginEditTheme(spaceID: id) }
        case .renameSpace: if let id = selectedSpaceID { spaceFlow.beginRename(spaceID: id) }
        case .nextSpace: sidebar.stepSpace(by: 1)
        case .previousSpace: sidebar.stepSpace(by: -1)
        case .manageSpaces: openLibrary(.spaces)
        // Tabs
        case .archiveTab: if let id = selectedTabID { sidebar.closeOrUnloadTab(id) }
        case .togglePin: if let id = selectedTabID { sidebar.togglePin(id) }
        case .favoriteTab: if let id = selectedTabID { sidebar.addFavorite(id) }
        case .newFolder: sidebar.requestNewFolder()
        case .moveToToday: moveSelectedTabToToday()
        case .replacePinWithCurrentPage: if let id = selectedTabID { sidebar.replacePinnedURLWithCurrent(id) }
        case .resetTabToOriginalURL: if let id = selectedTabID { sidebar.resetTabToPinnedURL(id) }
        case .duplicateTab: if let id = selectedTabID { sidebar.duplicateTab(id) }
        case .renameCurrentItem: renameCurrentItem()
        case .nextTab: sidebar.stepTab(by: 1)
        case .previousTab: sidebar.stepTab(by: -1)
        case .clearToday: sidebar.clearToday()
        case .collapseAllFolders: sidebar.setAllFoldersExpanded(false)
        case .expandAllFolders: sidebar.setAllFoldersExpanded(true)
        // Archive
        case .goBack: sidebar.goBack()
        case .goForward: sidebar.goForward()
        case .viewArchive: openLibrary(.archivedTabs)
        // Window
        case .openLibrary: openLibrary()
        case .viewDownloads: openLibrary(.downloads)
        case .viewEasels: openLibrary(.easels)
        case .viewMedia: openLibrary(.media)
        case .viewBoosts: openLibrary(.boosts)
        // App
        case .openSettings:
            if let open = openSettingsWindow { open() } else { lastUnhandledCommand = command }
        case .contactTheTeam:
            // Same as Help ▸ Contact the Team (B72). The row closes the empty-query list ([04 §command bar] observed).
            contactTheTeam()
        case .airTrafficControl:
            // Settings ▸ Links with the Air Traffic Control sheet ([06 §25] observed sheet). B61.
            controller.requestAirTrafficControl()
            if let open = openSettingsWindow { open() } else { lastUnhandledCommand = command }
        }
    }

    /// Opens a browser window through the scene's opener; recorded as unhandled without one.
    private func openBrowserWindow(_ kind: BrowserWindowRequest.Kind, for command: CommandBarCommand) {
        guard let open = controller.openBrowserWindow else {
            lastUnhandledCommand = command
            return
        }
        open(windowRequest(kind))
    }

    /// A request for a new window opened from this one: New Window and Blank Window open on this
    /// window's Space (inferred); an incognito window, or any window opened from one, uses the
    /// app's active Space.
    func windowRequest(_ kind: BrowserWindowRequest.Kind) -> BrowserWindowRequest {
        BrowserWindowRequest(kind: kind, spaceID: kind == .incognito || isIncognito ? nil : selectedSpaceID,
                             frame: kind == .incognito ? knownWindowFrame : nil)
    }

    /// This window's frame once its AppKit window reported one; nil before.
    var knownWindowFrame: CGRect? {
        let frame = windowFrame
        guard frame.width > 0, frame.height > 0 else { return nil }
        return CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
    }

    /// The frame the AppKit window takes when it appears (`BrowserWindowRequest.frame`). Consumed.
    func takeOpeningFrame() -> CGRect? {
        defer { openingFrame = nil }
        return openingFrame
    }

    // MARK: Little Arc

    /// "Open in Open Arc" from a Little Arc window: opens the page as a new Today tab in the
    /// current space (via `TreeOps.openTab`) and selects it. The Little Arc page had no model tab
    /// before this. [06 §7] inferred. Returns the new tab id.
    /// B60: `spaceID` is the Space chosen with "Open in <Space>"; the window switches to it first,
    /// so the page becomes the selected top Today tab there. [06 §21.7] observed.
    @discardableResult
    public func adoptLittleArcTab(url: URL, title: String, spaceID: UUID? = nil) -> UUID? {
        // The window this Little Arc was opened from has closed since: use the window used last
        // (or the hidden host, which opens a new window). inferred.
        if isStopped, !isIncognito {
            let host = controller.littleArcHost()
            if host !== self { return host.adoptLittleArcTab(url: url, title: title, spaceID: spaceID) }
        }
        if isCommandBarPresented { dismissCommandBar() }
        if let spaceID, spaceID != selectedSpaceID { sidebar.selectSpace(spaceID) }
        guard let id = sidebar.newTab(url: url, title: title) else { return nil }
        if isBrowserWindow {
            // The window may be behind other windows or minimized: bring it forward (B29).
            revealTab(id)
        } else {
            // No browser window is open (this is the hidden host): one opens and shows the tab (B29).
            controller.revealInBrowserWindow(id, spaceID: selectedSpaceID)
        }
        return id
    }

    /// Shows `tabID` in this window and brings the window to the front: leaves the Library,
    /// switches to the tab's Space, selects the tab. A window that has no AppKit window yet comes
    /// forward once it has one (`takeFocusOnAttach`). inferred (B29).
    func revealTab(_ tabID: UUID) {
        library.exit()
        if let spaceID = workspace.tabs[tabID]?.location.spaceID, spaceID != selectedSpaceID {
            sidebar.selectSpace(spaceID)
        }
        if selectedTabID != tabID { sidebar.selectTab(tabID, focusingOtherWindow: false) }
        revealRequestCount += 1
        if let focusWindow { focusWindow() } else { wantsFocusOnAttach = true }
    }

    /// Whether the window must come to the front as soon as its AppKit window is known. Consumed.
    func takeFocusOnAttach() -> Bool {
        defer { wantsFocusOnAttach = false }
        return wantsFocusOnAttach
    }

    // MARK: Sidebar requests

    /// Hides or shows the sidebar. From the floating overlay this is "Lock sidebar": it pins the
    /// sidebar back. [06 §14] observed.
    public func toggleSidebar() {
        isSidebarVisible.toggle()
        sidebarPeek.setPinned(isSidebarVisible)
    }

    func handle(_ request: SidebarRequest) {
        // An incognito window has no Spaces to create, edit or manage. inferred.
        if isIncognito {
            switch request {
            case .newSpace, .newSpaceWithItem, .renameSpace, .changeSpaceIcon, .editSpaceTheme, .manageSpaces, .newProfile: return
            default: break
            }
        }
        switch request {
        case .openCommandBar(.currentTab): presentCommandBar(.currentTab)
        case .openCommandBar(.newTab): presentCommandBar(.newTab)
        case .openCommandBar(.splitPane):
            if let id = selectedTabID { presentCommandBarInPane(id) } else { presentCommandBar(.newTab) }
        case .toggleSidebar: toggleSidebar()
        case .newSpace: spaceFlow.beginCreate()
        // Move to ▸ New Space…: the item moves into the Space once it is created. [06 §21.5] B77.
        case .newSpaceWithItem(let itemID): spaceFlow.beginCreate(moving: itemID)
        case .renameSpace(let spaceID): spaceFlow.beginRename(spaceID: spaceID)
        case .changeSpaceIcon(let spaceID): spaceFlow.beginChangeIcon(spaceID: spaceID)
        case .editSpaceTheme(let spaceID): spaceFlow.beginEditTheme(spaceID: spaceID)
        case .manageSpaces: openLibrary(.spaces)
        case .openLibrary: openLibrary()
        case .showSiteControls: siteControls.present()
        case .newProfile(let spaceID): profileFlow.beginNewProfile(forSpace: spaceID)
        // Tab menu Share: the system share picker for the tab's link. [06 §20.2], [06 §21.5] B77.
        case .share(let tabID): sidebar.beginShare(tabID)
        case .changeIcon(let tabID): sidebar.beginChangeIcon(tabID)
        case .toggleUnreadBadge(let tabID): sidebar.toggleUnreadBadge(tabID)
        case .editPinnedPage(let tabID): sidebar.beginEditPinnedPage(tabID)
        case .moveTab(let tabID, let profileID): sidebar.moveTabToProfile(tabID, profileID: profileID)
        case .exportSpace(let spaceID, let intoSpaceID): sidebar.exportSpace(spaceID, intoSpace: intoSpaceID)
        case .setSpaceProfile(let spaceID, let profileID): sidebar.setSpaceProfile(spaceID, profileID: profileID)
        case .shareSpace, .showLiveFolders:
            // Not observed in the spec: the items stay disabled (plan Q19).
            break
        }
    }

    /// Writes pending workspace changes and the UI state to disk now.
    public func flushPersistence() async throws {
        try await controller.flushPersistence()
    }

    /// Cancels this window's background work and leaves the controller (without saving the UI
    /// state; `windowDidClose` does that). A model that made its own controller stops it too.
    public func stop() {
        guard !isStopped else { return }
        isStopped = true
        if isBrowserWindow { controller.unregisterWindow(self, save: false) }
        engineWindowChanges = nil
        if isBrowserWindow { controller.engineWindows.unregister(self) }
        libraryFlagChanges = nil
        autoPictureInPicture?.stop()
        siteControls.stop()
        pageCapture.stop()
        translation.stop()
        linkPeek.stop()
        sidebar.stop()
        if ownsController { controller.stop() }
    }
}

extension WorkspaceState {
    /// A small demo workspace for running the shell with FakeEngine.
    public static func demo(now: Date = Date()) -> WorkspaceState {
        let profile = UUID(), space = UUID(), theme = UUID(), folder = UUID()
        var s = WorkspaceState()
        s.profiles[profile] = Profile(id: profile, name: "Default", now: now)
        s.themes[theme] = Theme(id: theme, colors: [RGBAColor(hex: 0x6E5BD6)], now: now)
        do {
            s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "Home", themeID: theme, now: now)
            s = try TreeOps.createFolder(s, id: folder, spaceID: space, title: "Reading", now: now)
            for (index, host) in ["example.com", "example.org", "example.net"].enumerated() {
                let id = UUID()
                s = try TreeOps.openTab(s, id: id, spaceID: space, url: URL(string: "https://\(host)"), title: host, now: now)
                if index == 0 {
                    s = try TreeOps.moveTab(s, id: id, to: .pinned(spaceID: space, folderID: folder), position: .first, now: now)
                }
            }
        } catch {
            assertionFailure("demo workspace is invalid: \(error)")
        }
        return s
    }
}
