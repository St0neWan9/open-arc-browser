import Foundation
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcDesign

// The sidebar's view model, one per browser window: no UI types. It holds the window's selection
// (Space, tab, per-Space memory, split focus) and exposes intents that mutate the shared workspace
// only through the pure `TreeOps` functions, committed by the app-level `WorkspaceController`
// (which also owns the live engine tabs). Ids and time come from the controller's injected
// closures so tests are deterministic (TreeOps never calls `Date()` / `UUID()` itself).

/// Where a command bar request comes from. The sidebar never shows the command bar itself.
public enum SidebarCommandBarContext: Equatable, Sendable {
    /// "+ New Tab" row: open the command bar to create a tab. [05 §command bar] observed.
    case newTab
    /// URL box click: the box is a placeholder that opens the command bar. [05 §window hierarchy] observed.
    case currentTab
    /// A new split pane was added; the bar opens inside that pane. [06 §5] observed.
    case splitPane
}

/// Things the sidebar asks the shell to do because they open surfaces or need services that are
/// not part of the sidebar (dialogs, share sheet, theme editor...). When no handler is set the
/// matching menu items are disabled.
public enum SidebarRequest: Equatable, Sendable {
    case openCommandBar(SidebarCommandBarContext)
    case toggleSidebar
    case showSiteControls
    case share(tabID: UUID)
    case changeIcon(tabID: UUID)
    case toggleUnreadBadge(tabID: UUID)
    case editPinnedPage(tabID: UUID)
    case moveTab(tabID: UUID, toProfile: UUID)
    case newSpace
    case changeSpaceIcon(spaceID: UUID)
    case renameSpace(spaceID: UUID)
    case editSpaceTheme(spaceID: UUID)
    case setSpaceProfile(spaceID: UUID, profileID: UUID)
    case shareSpace(spaceID: UUID)
    case showLiveFolders(spaceID: UUID)
    case exportSpace(spaceID: UUID, intoSpaceID: UUID)
    case manageSpaces
    /// The dock's leftmost button (the Home button of [05 §window hierarchy], [07 §4] observed):
    /// opens the Library. inferred (its action was not recorded).
    case openLibrary
}

@MainActor
public final class SidebarViewModel: ObservableObject {

    // MARK: Published state

    /// The shared workspace (owned by `WorkspaceController`). Changes reach this view model's
    /// observers through the controller.
    public var workspace: WorkspaceState { controller.workspace }
    @Published public private(set) var selectedSpaceID: UUID? {
        // Favorites follow the window's Space for their pages' color scheme (B21).
        didSet {
            guard oldValue != selectedSpaceID else { return }
            controller.syncWebColorSchemes()
            spacePager.show(selectedSpaceID, order: dockSpaces.map(\.id))
        }
    }
    /// Direction of the latest Space switch, for the sidebar's paging transition. [07 §11] B40.
    let spacePager = SpacePagerState()
    @Published public private(set) var selectedTabID: UUID?
    /// The open Peek page's URL and its source tab (B49, set by `LinkPeekModel`).
    @Published var linkPeekURL: URL?
    @Published var linkPeekSourceTabID: UUID?
    /// Item being renamed inline (tab or folder).
    @Published public internal(set) var renamingItemID: UUID?
    @Published public var isNewFolderSheetPresented = false
    /// Parent for the folder the sheet creates (nil = top level).
    @Published var newFolderParentID: UUID?
    /// Space the user asked to delete (drives the confirmation).
    @Published public internal(set) var pendingSpaceDeletionID: UUID?
    /// Archive ▸ Clear Archive is waiting for the user's confirmation (B69).
    @Published public internal(set) var isClearArchiveConfirmationPresented = false
    /// Tab whose hover card is showing.
    @Published private(set) var hoverCardTabID: UUID?
    @Published private(set) var draggingItem: SidebarDragItem?
    /// A link from another app is being dragged over the sidebar.
    @Published private(set) var isDraggingExternalURL = false
    /// Current drop target, only set while a valid plan exists for it.
    @Published private(set) var dropTarget: SidebarDropTarget?
    /// Last error from a rejected operation (for tests and diagnostics).
    @Published public private(set) var lastError: Error?
    /// Pinned tab that shows the faint "Double-click to rename" line under its title: the first
    /// tab pinned on this device. [06 §4] observed (once). B76.
    @Published private(set) var pinRenameHintTabID: UUID?
    /// Folder whose hover quick list is showing. [06 §14] observed. B76.
    @Published private(set) var quickListFolderID: UUID?
    /// Text in the quick list's "Search <folder>…" field. [06 §14] observed field; filtering inferred.
    @Published var quickListQuery = ""

    // MARK: Hooks for the shell

    /// Called after every change this window makes to the workspace (persistence is done by the
    /// controller; this hook is for observers and tests).
    public var onWorkspaceChange: ((WorkspaceState) -> Void)?
    /// Shell-owned surfaces; see `SidebarRequest`.
    public var requestHandler: ((SidebarRequest) -> Void)?
    /// Asks the window to come to the front: the user selected a tab here that this window
    /// already shows (see `selectTab`). Set by `ShellModel`.
    public var onFocusRequest: (() -> Void)?
    /// False for a model that is not a visible browser window (the Little Arc host when no window
    /// is open): its selection does not hold tabs away from real windows.
    var countsAsVisibleWindow = true
    /// Seconds before the hover card shows. [06 §12] observed ≈ 0.5.
    var hoverDelay: Double = Motion.hoverCardDelay
    /// Seconds a drag must hover over a dock icon before the sidebar switches to that Space.
    /// [06 §15.6] observed: within 1 s.
    var dockSwitchDelay: Double = SidebarLocalTokens.dockSwitchDelay
    /// Seconds a drag must rest at the sidebar's left / right edge before the previous / next
    /// Space is shown. [06 §15.6] observed (≈ 0.5–1.5 s / ≈ 0.8 s).
    var edgeSwitchLeftDelay: Double = SidebarLocalTokens.edgeSwitchLeftDelay
    var edgeSwitchRightDelay: Double = SidebarLocalTokens.edgeSwitchRightDelay
    /// Seconds a drag must stay in an auto-scroll band before the list scrolls. [06 §15.8] observed.
    var autoScrollDwell: Double = SidebarLocalTokens.autoScrollDwell
    /// Plays the reorder haptic: a tap on the trackpad each time an in-app drag moves to a new drop
    /// position, while "Haptic feedback when reordering tabs" is on ([03 §Advanced] observed toggle,
    /// default on; when it fires is inferred). Tests replace it. B68.
    lazy var playReorderHaptic: @MainActor () -> Void = { [weak self] in self?.controller.feedback.reorderHaptic() }
    /// Poll interval of the drag watchdog (see `beginDrag`).
    var dragWatchInterval: Double = SidebarLocalTokens.dragWatchInterval
    /// Seconds between two auto-scroll steps while a drag hovers an edge band of the list. inferred.
    var autoScrollTickInterval: Double = SidebarLocalTokens.autoScrollTickInterval
    /// Scroll hook of the list on screen (set by the list view, a fake in tests). Weak: the view owns it.
    weak var listScroller: (any SidebarListScrolling)?
    /// Signed auto-scroll velocity of the last step (points per second, 0 = not scrolling).
    private(set) var autoScrollVelocity: CGFloat = 0
    /// Last pointer position of the running drag (sidebar root space), so the target can be
    /// re-hit-tested after the list scrolled under a pointer that did not move.
    private(set) var lastDragPointer: CGPoint?
    /// True while the auto-scroll loop runs.
    var isAutoScrolling: Bool { autoScrollTask != nil }
    /// Seconds a folder must be hovered before its quick list shows. inferred (B76).
    var quickListDelay: Double = FolderQuickListTokens.showDelay
    /// Seconds the quick list stays after the pointer left both the folder row and the list, so
    /// the pointer can cross the gap between them. inferred (B76).
    var quickListDismissDelay: Double = FolderQuickListTokens.dismissDelay
    /// Whether the pointer is over the quick list's panel right now (set by the presenter; nil in
    /// tests). Hover events may not reach a child panel that is not key.
    var quickListPointerProbe: (@MainActor () -> Bool)?

    // MARK: Dependencies and internals

    /// The app-level owner of the workspace and the live engine tabs.
    public let controller: WorkspaceController
    /// True when this view model made its own controller (convenience init): `stop()` stops it.
    private let ownsController: Bool
    private var controllerChanges: AnyCancellable?
    private var now: () -> Date { controller.now }
    private var makeID: () -> UUID { controller.makeID }
    private(set) var hoverTask: Task<Void, Never>?
    private var hoveredTabID: UUID?
    /// Last selected tab per space, restored when switching back. inferred.
    private var lastSelectedTab: [UUID: UUID] = [:]
    /// Last selected member per split layout, so selecting the group row returns to the pane that
    /// had focus. inferred: `SplitLayout` stores no focus; the selected tab is the focused pane.
    private var lastFocusedPane: [UUID: UUID] = [:]
    private var dragWatchTask: Task<Void, Never>?
    /// The tab that was selected before a press selected another one ([06 §15.1]). A drag from
    /// that press dropped on the web panel forms the split with this page (B19).
    private(set) var selectionBeforePress: UUID?
    private var autoScrollTask: Task<Void, Never>?
    /// Visible list area of the last drag update (sidebar root space).
    private var autoScrollViewport: CGRect = .null
    /// Seconds the pointer has been in the current auto-scroll band.
    private var autoScrollTimeInBand: Double = 0
    private var dockHoverTask: Task<Void, Never>?
    private var dockHoverSpaceID: UUID?
    private var edgeSwitchTask: Task<Void, Never>?
    /// Edge (-1 left, +1 right) the drag pointer rests at; it stays set after the switch fired, so
    /// one stay at the edge switches once. inferred.
    private(set) var edgeSwitchDirection: Int?
    /// Pending show or dismiss of the folder quick list.
    private(set) var quickListTask: Task<Void, Never>?
    /// Folder row under the pointer; whether the pointer is inside the quick list; whether the
    /// quick list has the keyboard (its search field was clicked).
    private var quickListHoveredFolderID: UUID?
    private var isPointerInQuickList = false
    private var isQuickListFocused = false

    /// A window's sidebar on the shared controller. A stale or missing Space id falls back to the
    /// first live Space.
    public init(controller: WorkspaceController, selectedSpaceID: UUID? = nil) {
        self.controller = controller
        self.ownsController = false
        self.selectedSpaceID = Self.liveSpaceID(selectedSpaceID, in: controller.workspace)
        attach()
    }

    /// A sidebar with its own in-memory controller (no persistence, sync disabled). For tests,
    /// previews and single-window tools.
    public init(
        engine: any BrowserEngine,
        workspace: WorkspaceState,
        selectedSpaceID: UUID? = nil,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        self.controller = WorkspaceController(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: workspace,
            now: now,
            makeID: makeID
        )
        self.ownsController = true
        self.selectedSpaceID = Self.liveSpaceID(selectedSpaceID, in: workspace)
        attach()
    }

    private static func liveSpaceID(_ id: UUID?, in workspace: WorkspaceState) -> UUID? {
        let initial = id.flatMap { workspace.spaces[$0] }.flatMap { $0.meta.isTombstone ? nil : $0.id }
        return initial ?? workspace.allLiveSpaces.first?.id
    }

    /// Registers with the controller and redraws when the shared workspace or live tabs change.
    private func attach() {
        controller.register(self)
        controllerChanges = controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Cancels this window's background tasks (hover, drag) and leaves the controller. Call when
    /// the window closes. A view model that made its own controller stops it too (engine tasks,
    /// the scheduler).
    public func stop() {
        hoverTask?.cancel()
        quickListTask?.cancel()
        endDrag()
        controllerChanges = nil
        controller.unregister(self)
        if ownsController { controller.stop() }
    }

    // MARK: - Derived state

    public var selectedSpace: Space? {
        selectedSpaceID.flatMap { workspace.spaces[$0] }.flatMap { $0.meta.isTombstone ? nil : $0 }
    }

    /// The selected Space's profile, else the Default profile (oldest live one).
    /// A Space whose profile is unknown on this device uses the Default profile (B73).
    var currentProfileID: UUID? { selectedSpace.flatMap { workspace.localProfileID(for: $0.profileID) } ?? workspace.defaultProfileID }

    var theme: Theme? { selectedSpace?.themeID.flatMap { workspace.themes[$0] } }

    /// The selected Space's palette; Automatic themes follow the system appearance (B21).
    var palette: ThemePalette {
        // An incognito window has no Space theme: fixed neutral colors. [06 §20.1] observed (B48).
        if isIncognito { return incognitoPalette }
        return ThemeDerivation.palette(for: theme, systemAppearance: controller.systemAppearance)
    }

    var snapshot: SidebarSnapshot {
        var snapshot = SidebarSnapshot.make(workspace: workspace, spaceID: selectedSpaceID, profileID: currentProfileID)
        snapshot.hidesPinnedArea = isIncognito
        return snapshot
    }

    /// Spaces in dock order. The dock shows every profile's spaces. [05 §window hierarchy] observed.
    /// An incognito window's dock shows no Space icons. [06 §20.2] observed (B48).
    var dockSpaces: [Space] { isIncognito ? [] : workspace.allLiveSpaces }

    var selectedLiveState: SidebarTabLiveState? { selectedTabID.flatMap { liveState(for: $0) } }

    /// Tab shown in the URL box: its live URL if loaded, else the stored one.
    var selectedURL: URL? {
        // While Peek is open the address shows the Peek page. [06 §22.2] observed (B49).
        if let linkPeekURL { return linkPeekURL }
        guard let id = selectedTabID else { return nil }
        return liveState(for: id)?.url ?? workspace.tabs[id]?.url
    }

    var urlBoxContent: SidebarURLBoxContent { SidebarURLBoxContent.make(url: selectedURL) }

    /// The URL box shows the red struck-through lock before the domain (http). [06 §17.7] observed.
    var urlBoxShowsInsecureLock: Bool {
        guard case .domain = urlBoxContent else { return false }
        return SidebarURLBoxContent.showsInsecureLock(url: selectedURL)
    }

    var reloadMode: SidebarReloadMode { SidebarReloadMode.make(isLoading: selectedLiveState?.isLoading ?? false) }

    var canGoBack: Bool { selectedLiveState?.canGoBack ?? false }
    var canGoForward: Bool { selectedLiveState?.canGoForward ?? false }

    var canRequest: Bool { requestHandler != nil }

    /// A space can be deleted unless it is the last one. inferred (the window needs a space).
    var canDeleteSpace: Bool { dockSpaces.count > 1 }

    func liveState(for id: UUID) -> SidebarTabLiveState? { controller.liveState(for: id) }

    /// PNG bytes of tab `id`'s favicon (live or cached), nil for the placeholder. C9.
    func faviconImage(for id: UUID) -> Data? { controller.faviconImage(for: id) }

    /// An incognito window's sidebar: no favorites, dock or Space menus. inferred.
    var isIncognito: Bool { controller.isOffTheRecord }

    /// Tabs this window has on screen: the selected tab and its split partners. They are kept from
    /// auto-archive and cannot be shown in another window at the same time. inferred.
    var onScreenTabIDs: Set<UUID> { onScreenTabIDs(selecting: selectedTabID) }

    /// The tabs on screen when `selected` is the selected tab: it and its split partners.
    func onScreenTabIDs(selecting selected: UUID?) -> Set<UUID> {
        guard let selected else { return [] }
        var ids: Set<UUID> = [selected]
        if let layout = SplitPaneLayout.activeLayout(in: workspace, containing: selected) {
            ids.formUnion(layout.root.tabIDs)
        }
        return ids
    }

    func isSelected(_ id: UUID) -> Bool { selectedTabID == id }

    /// Link to copy for a tab. Copy Link in the tab menu and in the URL box. [05 §context menus] observed.
    func linkURL(for id: UUID) -> URL? {
        liveState(for: id)?.url ?? workspace.tabs[id]?.url
    }

    // MARK: - Workspace plumbing

    /// Replaces the shared workspace without saving it (a value already stored elsewhere, e.g.
    /// merged from sync, or test setup). Every window repairs its selection.
    public func replaceWorkspace(_ new: WorkspaceState) {
        controller.replaceWorkspace(new)
    }

    /// Commits a workspace value built by a flow of this window (Space edits, Library board): it
    /// is saved, every window repairs its selection and `onWorkspaceChange` fires.
    func commitWorkspace(_ new: WorkspaceState) {
        controller.commit(new, origin: nil)
        onWorkspaceChange?(new)
    }

    /// The shared workspace changed elsewhere (another window, auto-archive, sync).
    func workspaceDidChange() {
        repairSelection()
    }

    @discardableResult
    private func mutate(_ body: (WorkspaceState) throws -> WorkspaceState) -> Bool {
        do {
            try controller.mutate(origin: self, body)
            lastError = nil
            onWorkspaceChange?(workspace)
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// Queues engine work on the controller, so `settleEngineWork` can wait for it.
    private func engineTask(_ work: @escaping @MainActor () async -> Void) {
        controller.enqueueEngineWork(work)
    }

    private func repairSelection() {
        if selectedSpace == nil { selectedSpaceID = workspace.allLiveSpaces.first?.id }
        if let id = selectedTabID, workspace.tabs[id].map({ $0.meta.isTombstone }) ?? true {
            selectedTabID = nil
        }
    }

    private func request(_ r: SidebarRequest) { requestHandler?(r) }

    // MARK: - Selection and engine

    /// Selects a tab (row click, favorite click, ⌘1…⌘9). The engine tab is created lazily.
    /// A favorite opens in the current space. [06 §12] observed.
    ///
    /// A tab's page can be on screen in one window only (one engine surface). When another window
    /// already shows the tab, that window comes to the front and this window's selection stays as
    /// it is. inferred (B14; the spec records nothing about tabs across windows).
    public func selectTab(_ id: UUID) {
        selectTab(id, focusingOtherWindow: true)
    }

    /// See `selectTab(_:)`. With `focusingOtherWindow` false a tab shown elsewhere is just not
    /// selected (used when a Space switch restores its remembered tab). Returns whether it was selected.
    @discardableResult
    func selectTab(_ id: UUID, focusingOtherWindow: Bool) -> Bool {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return false }
        if let other = controller.sidebar(showing: id, except: self) {
            if focusingOtherWindow { other.onFocusRequest?() }
            return false
        }
        selectedTabID = id
        if let spaceID = tab.location.spaceID ?? selectedSpaceID { lastSelectedTab[spaceID] = id }
        if let layout = SplitPaneLayout.activeLayout(in: workspace, containing: id) { lastFocusedPane[layout.id] = id }
        mutate { try TreeOps.markTabActive($0, id: id, now: now()) }
        let controller = self.controller, fallback = currentProfileID
        engineTask { [weak self] in
            do { try await controller.ensureLive(id, fallbackProfileID: fallback) } catch { self?.lastError = error }
        }
        return true
    }

    /// Creates the engine tab for `id` if needed (split panes other than the selected tab).
    func ensureLive(_ id: UUID) async {
        do { try await controller.ensureLive(id, fallbackProfileID: currentProfileID) } catch { lastError = error }
    }

    /// Applies an engine event to the live state (forwarded to the controller, which owns it).
    func apply(_ event: TabEvent, to id: UUID) {
        controller.apply(event, to: id)
    }

    private func syncContent(_ id: UUID) {
        controller.syncContent(id)
    }

    /// Live engine tab for a model tab id, if one has been created.
    func liveTab(for id: UUID) -> (any BrowserTab)? { controller.liveTab(for: id) }

    /// Loads `url` in the selected tab (⌘L then Enter). With no selected tab, opens a new tab.
    /// A tab without an engine tab yet gets the URL stored and is then loaded. [02] observed
    /// ("edit the current address"); the no-selection fallback is inferred.
    public func navigateSelectedTab(to url: URL) {
        guard let id = selectedTabID, workspace.tabs[id].map({ !$0.meta.isTombstone }) == true else {
            newTab(url: url, title: url.host ?? url.absoluteString)
            return
        }
        if let live = liveTab(for: id) {
            engineTask { try? await live.load(url) }
        } else {
            mutate { ws in
                let title = ws.tabs[id]?.title ?? ""
                return try TreeOps.updateTabContent(ws, id: id, url: url, title: title, faviconURL: nil, now: now())
            }
            selectTab(id)
        }
    }

    /// Tabs in keyboard order: favorites, then pinned rows, then Today. Favorites counting as
    /// sidebar items is inferred. A split group is ONE item (inferred, [06 §5] only says the group
    /// is one unit); it stands for its focused pane tab, so selecting it keeps the focused pane.
    var keyboardTabOrder: [UUID] {
        let snap = snapshot
        let rows = snap.visibleTabEntries.map { entry -> UUID in
            switch entry {
            case .tab(let id): return id
            case .group(let group): return focusedPaneTab(of: group)
            }
        }
        return snap.favorites.map(\.id) + rows
    }

    // MARK: Split groups

    /// The pane a split-group row selects: the selected tab if it is a member, else the member
    /// that was focused last, else the first member by sidebar order. [06 §5] gives no rule; inferred.
    func focusedPaneTab(of group: SidebarSplitGroup) -> UUID {
        if let selected = selectedTabID, group.contains(selected) { return selected }
        if let last = lastFocusedPane[group.layoutID], group.contains(last) { return last }
        return group.anchorID
    }

    /// Whether the group row is the selected row (one of its members is the selected tab).
    func isGroupSelected(_ group: SidebarSplitGroup) -> Bool {
        selectedTabID.map(group.contains) ?? false
    }

    /// Click on a split-group row: selects the group's focused pane tab.
    public func selectSplitGroup(_ layoutID: UUID) {
        guard let group = snapshot.splitGroup(layoutID: layoutID) else { return }
        selectTab(focusedPaneTab(of: group))
    }

    /// ✕ on a split-group row in Today: archives every member (the whole split goes away at once).
    /// inferred: [06 §5] does not say what the group's close button does; closing the group as the
    /// one unit it is in the sidebar is the reading that matches "one group". Selection moves to the
    /// next row, else the previous one.
    public func closeSplitGroup(_ layoutID: UUID) {
        guard let group = snapshot.splitGroup(layoutID: layoutID) else { return }
        let ids = group.sidebarOrder
        let next = isGroupSelected(group) ? neighborRow(of: group) : nil
        let stamp = now()
        guard mutate({ state in
            try ids.reduce(state) { try TreeOps.archiveTab($0, id: $1, reason: .closed, now: stamp) }
        }) else { return }
        ids.forEach(closeLive)
        if let selected = selectedTabID, ids.contains(selected) {
            selectedTabID = nil
            if let next { selectTab(next, focusingOtherWindow: false) }
        }
    }

    /// "—" on a split-group row in the pinned area: unloads every member's page and resets it to
    /// its pinned URL, as the single pinned row does ([06 §16.1] observed for a single row; the
    /// group case is inferred).
    public func unloadPinnedSplitGroup(_ layoutID: UUID) {
        guard let group = snapshot.splitGroup(layoutID: layoutID) else { return }
        let next = isGroupSelected(group) ? neighborRow(of: group) : nil
        let wasSelected = isGroupSelected(group)
        let stamp = now()
        mutate { state in
            try group.sidebarOrder.reduce(state) { try TreeOps.resetTabToPinnedURL($0, id: $1, now: stamp) }
        }
        group.sidebarOrder.forEach(closeLive)
        if wasSelected {
            selectedTabID = nil
            if let next { selectTab(next, focusingOtherWindow: false) }
        }
    }

    /// The tab to select when a whole group row leaves: the next row, else the previous one.
    private func neighborRow(of group: SidebarSplitGroup) -> UUID? {
        let entries = snapshot.visibleTabEntries
        guard let index = entries.firstIndex(where: { entry in
            if case .group(let g) = entry { return g.layoutID == group.layoutID }
            return false
        }) else { return nil }
        func tab(_ entry: SidebarSnapshot.TabEntry) -> UUID {
            switch entry {
            case .tab(let id): return id
            case .group(let g): return focusedPaneTab(of: g)
            }
        }
        if index + 1 < entries.count { return tab(entries[index + 1]) }
        return index > 0 ? tab(entries[index - 1]) : nil
    }

    /// Next Tab / Previous Tab (⌥⌘↓ / ⌥⌘↑), wrapping. [02 §tabs] observed keys; wrapping inferred.
    public func stepTab(by delta: Int) {
        let order = keyboardTabOrder
        guard !order.isEmpty else { return }
        guard let id = selectedTabID, let index = order.firstIndex(of: id) else {
            selectTab(delta >= 0 ? order[0] : order[order.count - 1])
            return
        }
        selectTab(order[((index + delta) % order.count + order.count) % order.count])
    }

    /// Go to Sidebar Item 1–8 (⌘1…⌘8); 9 is the last item (⌘9). [02 §tabs] observed.
    public func goToSidebarItem(number: Int) {
        let order = keyboardTabOrder
        guard !order.isEmpty, number >= 1 else { return }
        if number == 9 { selectTab(order[order.count - 1]); return }
        guard number <= order.count else { return }
        selectTab(order[number - 1])
    }

    /// Mute / Unmute from the tab menu. [05 §context menus] observed "Mute".
    public func toggleMute(_ id: UUID) {
        guard let live = liveTab(for: id) else { return }
        let muted = !(liveState(for: id)?.isMuted ?? false)
        engineTask { await live.setMuted(muted) }
    }

    /// Edit Pinned Page ▸ Replace Pinned URL with Current. [05 §context menus] observed.
    public func replacePinnedURLWithCurrent(_ id: UUID) {
        if let live = liveState(for: id)?.url, workspace.tabs[id]?.url != live { syncContent(id) }
        mutate { try TreeOps.replacePinnedURLWithCurrent($0, id: id, now: now()) }
    }

    /// Reset Tab to Original URL. [02 §tabs] observed command name.
    public func resetTabToPinnedURL(_ id: UUID) {
        guard let pinned = workspace.tabs[id]?.pinnedURL else { return }
        guard mutate({ try TreeOps.resetTabToPinnedURL($0, id: id, now: now()) }) else { return }
        if let live = liveTab(for: id) { engineTask { try? await live.load(pinned) } }
    }

    /// New Profile… (Set Profile ▸ / Move to ▸ Profile). Returns the new profile id.
    /// [01, 05 §context menus] observed menu items.
    @discardableResult
    public func createProfile(name: String) -> UUID {
        controller.createProfile(name: name)
    }

    /// Replaces a profile's synced settings (search engine, Today lifetime) through
    /// `TreeOps.updateProfileSettings`. [03 §Profiles] observed. Returns false if refused.
    @discardableResult
    public func updateProfileSettings(_ profileID: UUID, _ settings: ProfileSettings) -> Bool {
        controller.updateProfileSettings(profileID, settings)
    }

    /// Deletes a profile through `TreeOps.deleteProfile` (refused for the Default profile and
    /// while Spaces use it). Archived favorites lose their live engine tabs. Returns false if refused.
    @discardableResult
    public func deleteProfile(_ profileID: UUID) -> Bool {
        controller.deleteProfile(profileID)
    }

    /// Waits until queued engine work (tab creation, closing, navigation) has finished. For tests.
    func settleEngineWork() async {
        await controller.settleEngineWork()
    }

    private func closeLive(_ id: UUID) {
        controller.closeLive(id)
    }

    /// Picks the tab to select after `id` leaves the visible list: the one below, else above.
    private func neighbor(of id: UUID) -> UUID? {
        let snap = snapshot
        // A member of a split group: the sibling pane takes over, as it did when the panes were
        // separate rows (`ShellModel.closeSplitPane` relies on this).
        if let group = snap.splitGroup(containing: id), let layout = workspace.splits[group.layoutID],
           let pane = SplitPaneLayout.neighborPane(of: id, in: layout.root), group.contains(pane) {
            return pane
        }
        let order = snap.visibleTabOrder
        guard let index = order.firstIndex(of: id) else { return nil }
        if index + 1 < order.count { return order[index + 1] }
        return index > 0 ? order[index - 1] : nil
    }

    // MARK: - Toolbar intents

    public func goBack() {
        guard let live = selectedTabID.flatMap({ liveTab(for: $0) }) else { return }
        engineTask { try? await live.goBack() }
    }

    public func goForward() {
        guard let live = selectedTabID.flatMap({ liveTab(for: $0) }) else { return }
        engineTask { try? await live.goForward() }
    }

    /// Reload, or stop while loading. [06 §13] observed.
    public func reloadOrStop() {
        guard let live = selectedTabID.flatMap({ liveTab(for: $0) }) else { return }
        let stop = reloadMode == .stop
        engineTask { if stop { try? await live.stopLoading() } else { try? await live.reload() } }
    }

    public func openCommandBar(_ context: SidebarCommandBarContext) { request(.openCommandBar(context)) }

    public func toggleSidebar() { request(.toggleSidebar) }

    // MARK: - Tab intents

    /// Opens a tab at the top of Today in the current space and selects it. [06 §13] observed.
    @discardableResult
    public func newTab(url: URL? = nil, title: String = "New Tab") -> UUID? {
        guard let spaceID = selectedSpaceID else { return nil }
        let id = makeID()
        guard mutate({ try TreeOps.openTab($0, id: id, spaceID: spaceID, url: url, title: title, now: now()) }) else { return nil }
        selectTab(id)
        return id
    }

    /// Click on the "+ New Tab" row: opens the command bar when a shell is attached, otherwise
    /// creates a blank tab directly (previews, tests). inferred.
    public func newTabRowClicked() {
        if requestHandler != nil { request(.openCommandBar(.newTab)) } else { newTab() }
    }

    /// ⌘W / "Archive Tab" on the selected tab: archives a Today tab, unloads a pinned tab or a
    /// favorite and keeps it ([06 §16.1] observed for pinned tabs: same result as "—").
    public func closeOrUnloadTab(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        if case .today = tab.location { closeTab(id) } else { unloadPinnedTab(id) }
    }

    /// Archives a tab (⌘W / ✕ on a Today row). [05 §window and app entry points] observed.
    public func closeTab(_ id: UUID) {
        guard workspace.tabs[id].map({ !$0.meta.isTombstone }) == true else { return }
        let next = selectedTabID == id ? neighbor(of: id) : nil
        guard mutate({ try TreeOps.archiveTab($0, id: id, reason: .closed, now: now()) }) else { return }
        closeLive(id)
        if selectedTabID == id {
            selectedTabID = nil
            if let next { selectTab(next, focusingOtherWindow: false) }
        }
    }

    /// The newest archived item that ⇧⌘T would restore: reason `.closed` only. inferred: items the
    /// app archived on its own (idle timeout, Clear, deleted space) were not "closed" by the user.
    /// [02 §tabs and sidebar] observed lists "Restore Last Closed Tab" (⇧⌘T) without further detail.
    var lastClosedArchiveItem: ArchiveItem? {
        workspace.archiveNewestFirst.first { $0.reason == .closed }
    }

    var canRestoreLastClosedTab: Bool { lastClosedArchiveItem != nil }

    /// Restores an archived item as a new tab at the top of Today and selects it. The archive item
    /// is tombstoned by `TreeOps.restoreFromArchive`. Unknown or already restored ids are a no-op.
    /// Target space: inferred, the space the item came from when it is still live (the sidebar
    /// switches to it so the tab is visible), otherwise the current space. Favorites and items
    /// with a deleted source space land in the current space. [06 §8] observed: the Library
    /// "Archived Tabs" list; the destination of a restored tab is not specified.
    @discardableResult
    public func restoreArchived(_ itemID: UUID) -> UUID? {
        guard let item = workspace.archive[itemID], !item.meta.isTombstone else { return nil }
        let sourceSpace = item.spaceID.flatMap { id in workspace.spaces[id].flatMap { $0.meta.isTombstone ? nil : id } }
        guard let spaceID = sourceSpace ?? selectedSpaceID else { return nil }
        let newID = makeID()
        guard mutate({ try TreeOps.restoreFromArchive($0, itemID: itemID, newTabID: newID, spaceID: spaceID, now: now()) }) else { return nil }
        if spaceID != selectedSpaceID { selectedSpaceID = spaceID }
        selectTab(newID)
        return newID
    }

    /// Restore Last Closed Tab (⇧⌘T). [02 §tabs and sidebar] observed. Repeated calls walk back through
    /// older closed items because each restore tombstones its archive item. No-op when nothing
    /// qualifies.
    @discardableResult
    public func restoreLastClosedTab() -> UUID? {
        guard let item = lastClosedArchiveItem else { return nil }
        return restoreArchived(item.id)
    }

    /// "—" on a pinned row, and ⌘W on a pinned tab. [06 §16.1] observed: the pin stays in place,
    /// the page is unloaded (back history gone) and the tab goes back to its pinned URL, so the
    /// next click opens the pinned page again; selection moves to a neighbor row. Unpinning is a
    /// menu item ("Remove Pin"). Favorites use the same path (inferred, not observed).
    public func unloadPinnedTab(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        // Back to the pinned URL (no-op when already there or when there is none).
        if tab.pinnedURL != nil { mutate { try TreeOps.resetTabToPinnedURL($0, id: id, now: now()) } }
        guard liveTab(for: id) != nil || selectedTabID == id else { return }
        let next = selectedTabID == id ? neighbor(of: id) : nil
        closeLive(id)
        if selectedTabID == id {
            selectedTabID = nil
            if let next { selectTab(next, focusingOtherWindow: false) }
        }
    }

    /// Pin (⌘D): the tab goes to the end of the pinned area. [06 §4] observed.
    public func pinTab(_ id: UUID) {
        // An incognito window has no pinned area. [06 §20.2] observed (B48).
        guard !isIncognito else { return }
        let before = workspace
        if mutate({ try TreeOps.pinTab($0, id: id, now: now()) }) { notePins(since: before) }
    }

    /// Unpin ("Remove Pin"): the tab returns to the top of Today. The target position is
    /// inferred ([06 §13] says new tabs go to the top; unpinning is unobserved).
    public func unpinTab(_ id: UUID) {
        if pinRenameHintTabID == id { pinRenameHintTabID = nil }
        guard let spaceID = workspace.tabs[id]?.location.spaceID ?? selectedSpaceID else { return }
        mutate { try TreeOps.moveTab($0, id: id, to: .today(spaceID: spaceID), position: .first, now: now()) }
    }

    /// ⌘D toggles pinned state.
    public func togglePin(_ id: UUID) {
        guard let tab = workspace.tabs[id] else { return }
        switch tab.location {
        case .today: pinTab(id)
        case .pinned: unpinTab(id)
        case .favorite:
            // ⌘D on a favorite is not captured ([06 §21.8]); it goes back to the top of Today. inferred.
            guard let spaceID = selectedSpaceID else { return }
            mutate { try TreeOps.moveTab($0, id: id, to: .today(spaceID: spaceID), position: .first, now: now()) }
        }
    }

    public func addFavorite(_ id: UUID) {
        // An incognito window has no favorites. inferred (B14).
        guard !isIncognito, let profileID = currentProfileID else { return }
        mutate { try TreeOps.moveTab($0, id: id, to: .favorite(profileID: profileID), position: .last, now: now()) }
    }

    /// "Remove Favorite": the tile goes away and its page closes; it does not move back to Today,
    /// and there is no confirmation. [06 §21.4] observed. The tab is archived (closed by the user).
    public func removeFavorite(_ id: UUID) {
        guard let tab = workspace.tabs[id], case .favorite = tab.location else { return }
        closeTab(id)
    }

    /// Move to ▸ <Space>. [05 §context menus] observed. Pinned tabs stay pinned (top level of
    /// the target space), Today tabs go to the top of the target Today. inferred.
    public func moveTab(_ id: UUID, toSpace spaceID: UUID) {
        guard let tab = workspace.tabs[id] else { return }
        let location: TabLocation
        let position: InsertPosition
        if case .pinned = tab.location {
            location = .pinned(spaceID: spaceID, folderID: nil)
            position = .last
        } else {
            location = .today(spaceID: spaceID)
            position = .first
        }
        mutate { try TreeOps.moveTab($0, id: id, to: location, position: position, now: now()) }
    }

    /// Duplicate. [05 §context menus] observed. The copy opens at the top of Today. inferred.
    @discardableResult
    public func duplicateTab(_ id: UUID) -> UUID? {
        guard let tab = workspace.tabs[id], let spaceID = selectedSpaceID else { return nil }
        let copy = makeID()
        let url = liveState(for: id)?.url ?? tab.url
        guard mutate({ try TreeOps.openTab($0, id: copy, spaceID: spaceID, url: url, title: tab.displayTitle, now: now()) }) else { return nil }
        selectTab(copy)
        return copy
    }

    /// "↓ Clear" / ⇧⌘K: archives every Today tab. [05 §window and app entry points] observed.
    public func clearToday() {
        guard let spaceID = selectedSpaceID else { return }
        let ids = workspace.today(spaceID: spaceID).map(\.id)
        guard mutate({ try TreeOps.clearToday($0, spaceID: spaceID, now: now()) }) else { return }
        // Our own clear sound when "Play Open Arc sound effects" is on (B84, [03 §Advanced]).
        if !ids.isEmpty { controller.feedback.play(.clear) }
        ids.forEach(closeLive)
        if let selected = selectedTabID, ids.contains(selected) { selectedTabID = nil }
    }

    /// Auto-archive: archives Today tabs idle for their profile's "Archive tabs after" setting
    /// (`ProfileSettings.todayLifetime`, [03 §Profiles] observed per profile; `lifetimeOverride`
    /// replaces it for every tab), closes their live engine tabs and repairs the selection of
    /// every window. [05 §window and app entry points] observed ("auto archive after 12 hours by
    /// default"). Pinned tabs and favorites are never touched (enforced by `TreeOps.autoArchive`).
    /// The tabs on screen in any window (selected tab and its split partners) are kept: inferred.
    /// Runs on the shared controller. Returns the ids that were archived.
    @discardableResult
    public func runAutoArchive(lifetimeOverride: TimeInterval? = nil) -> [UUID] {
        controller.runAutoArchive(lifetimeOverride: lifetimeOverride)
    }

    // MARK: Rename

    public func beginRename(_ id: UUID) {
        hoverEnded(id)
        dismissQuickList()
        // The hint has done its job once the user renames the tab. inferred (B76).
        if pinRenameHintTabID == id { pinRenameHintTabID = nil }
        renamingItemID = id
    }

    public func cancelRename() { renamingItemID = nil }

    /// Commits a rename. An empty (or whitespace) title resets a tab to its page title (inferred)
    /// and is ignored for folders.
    public func commitRename(_ id: UUID, text: String) {
        defer { renamingItemID = nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let easelID = workspace.easelID(ofTab: id), workspace.liveEasel(easelID) != nil {
            // Renaming an Easel's row renames the Easel (canvas title and every row). B56, inferred.
            mutate { try TreeOps.renameEasel($0, id: easelID, title: trimmed, now: now()) }
        } else if workspace.tabs[id] != nil {
            mutate { try TreeOps.renameTab($0, id: id, customTitle: trimmed.isEmpty ? nil : trimmed, now: now()) }
        } else if workspace.folders[id] != nil, !trimmed.isEmpty {
            mutate { try TreeOps.renameFolder($0, id: id, title: trimmed, now: now()) }
        }
    }

    // MARK: Folders

    public func requestNewFolder(parent: UUID? = nil) {
        newFolderParentID = parent
        isNewFolderSheetPresented = true
    }

    /// Creates a folder at the top of the pinned area, expanded. [06 §3] observed.
    @discardableResult
    public func createFolder(title: String, parent: UUID? = nil) -> UUID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Folders live in the pinned area, which an incognito window lacks. [06 §20.2] observed (B48).
        guard !trimmed.isEmpty, !isIncognito, let spaceID = selectedSpaceID else { return nil }
        let id = makeID()
        guard mutate({ try TreeOps.createFolder($0, id: id, spaceID: spaceID, parentFolderID: parent, title: trimmed, now: now()) }) else { return nil }
        isNewFolderSheetPresented = false
        return id
    }

    public func toggleFolder(_ id: UUID) {
        guard let folder = workspace.folders[id] else { return }
        // The folder opens in place: its quick list is no longer needed. inferred (B76).
        dismissQuickList()
        mutate { try TreeOps.setFolderExpanded($0, id: id, isExpanded: !folder.isExpanded, now: now()) }
    }

    /// Collapse All Folders / Expand All Folders. [02 §tabs and sidebar] observed (no default key).
    public func setAllFoldersExpanded(_ expanded: Bool) {
        guard let spaceID = selectedSpaceID else { return }
        let ids = workspace.folders.values.filter { !$0.meta.isTombstone && $0.spaceID == spaceID && $0.isExpanded != expanded }.map(\.id)
        mutate { state in
            try ids.reduce(state) { try TreeOps.setFolderExpanded($0, id: $1, isExpanded: expanded, now: now()) }
        }
    }

    // MARK: Spaces

    public func selectSpace(_ id: UUID) {
        guard workspace.spaces[id].map({ !$0.meta.isTombstone }) == true, id != selectedSpaceID else { return }
        dismissQuickList()
        selectedSpaceID = id
        // The remembered tab stays unselected while another window shows it. inferred.
        if let remembered = lastSelectedTab[id], workspace.tabs[remembered].map({ !$0.meta.isTombstone }) == true {
            selectTab(remembered, focusingOtherWindow: false)
        }
    }

    /// Next/Previous Space (⌥⌘→ / ⌥⌘←), wrapping. [02 §space] observed.
    public func stepSpace(by delta: Int) {
        let spaces = dockSpaces
        guard !spaces.isEmpty, let current = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return }
        let index = ((current + delta) % spaces.count + spaces.count) % spaces.count
        selectSpace(spaces[index].id)
    }

    /// Go to Space N (⌃1…⌃9), 1-based. [02 §space] observed.
    public func goToSpace(number: Int) {
        let spaces = dockSpaces
        guard number >= 1, number <= spaces.count else { return }
        selectSpace(spaces[number - 1].id)
    }

    public func requestDeleteSpace(_ id: UUID) {
        guard canDeleteSpace else { return }
        pendingSpaceDeletionID = id
    }

    public func cancelDeleteSpace() { pendingSpaceDeletionID = nil }

    /// Confirms "Delete Space": the model archives its tabs and folders. [06 §11] observed.
    public func confirmDeleteSpace() {
        guard let id = pendingSpaceDeletionID else { return }
        pendingSpaceDeletionID = nil
        let spaces = dockSpaces
        let index = spaces.firstIndex(where: { $0.id == id }) ?? 0
        let fallback = spaces.indices.contains(index + 1) ? spaces[index + 1].id : spaces.last(where: { $0.id != id })?.id
        let doomed = workspace.allTabs(inSpace: id).map(\.id)
        guard mutate({ try TreeOps.deleteSpace($0, id: id, now: now()) }) else { return }
        doomed.forEach(closeLive)
        if selectedSpaceID == id { selectedSpaceID = fallback }
        if let tab = selectedTabID, workspace.tabs[tab]?.meta.isTombstone == true { selectedTabID = nil }
    }

    // MARK: Clear Archive (B69)

    /// Whether the archive holds anything to clear. The menu item is disabled otherwise (inferred).
    public var canClearArchive: Bool { !workspace.archiveNewestFirst.isEmpty }

    /// Archive ▸ Clear Archive ([01 §Archive] observed item): asks first, since the archived tabs
    /// cannot be brought back (our decision; the spec does not record a confirmation).
    public func requestClearArchive() {
        guard canClearArchive else { return }
        isClearArchiveConfirmationPresented = true
    }

    public func cancelClearArchive() { isClearArchiveConfirmationPresented = false }

    /// Confirmed: every archive item is removed (`TreeOps.clearArchive`, tombstones). No tab is
    /// archived or closed.
    public func confirmClearArchive() {
        guard isClearArchiveConfirmationPresented else { return }
        isClearArchiveConfirmationPresented = false
        _ = mutate { TreeOps.clearArchive($0, now: now()) }
    }

    func requestFromMenu(_ r: SidebarRequest) { request(r) }

    // MARK: Split view

    /// Add Split View (⌃⇧=): the current tab goes left, a new empty tab opens right and the
    /// command bar opens inside that pane. [06 §5] observed.
    /// `axis` and `side` place the new pane (the web toolbar's Add Right / Left / Top / Bottom
    /// Split, [06 §17.3] observed); the default is ⌃⇧='s right pane.
    public func addSplitView(axis: SplitAxis = .horizontal, side: SplitSide = .trailing) {
        guard let base = selectedTabID, let spaceID = selectedSpaceID else { return }
        let newID = makeID(), layoutID = makeID()
        let ok = mutate { state in
            let opened = try TreeOps.openTab(state, id: newID, spaceID: spaceID, url: nil, title: "New Tab", now: now())
            return try TreeOps.addSplitPane(opened, layoutID: layoutID, existingTabID: base, newTabID: newID,
                                            axis: axis, side: side, now: now())
        }
        guard ok else { return }
        selectTab(newID)
        request(.openCommandBar(.splitPane))
    }

    /// "Open in Split View" from a row's menu: shows `id` next to the selected tab. [05 §context menus] observed.
    public func openInSplitView(_ id: UUID) {
        guard let base = selectedTabID, base != id else { return addSplitView() }
        // A page on screen in another window cannot join this window's split. inferred (B14).
        if let other = controller.sidebar(showing: id, except: self) {
            other.onFocusRequest?()
            return
        }
        let layoutID = makeID()
        mutate { try TreeOps.addSplitPane($0, layoutID: layoutID, existingTabID: base, newTabID: id, now: now()) }
    }

    /// An open tab chosen in the command bar of a split pane that has no page yet (the empty pane
    /// ⌃⇧= made) takes that pane's place, and the empty tab is archived the way ⌃⇧- would.
    /// [06 §5] observed: the bar opens in the new pane to fill it; [06 §6] observed: its rows show
    /// the Space name instead of "Switch to Tab". Leaving the split with an empty pane is inferred
    /// to be wrong (B19). Only a Today tab of the same Space that is in no split qualifies: a pinned
    /// tab keeps its place, another Space's tab cannot join this Space's split, and a tab of a split
    /// (this one included) stays in it. Returns whether the pane was filled.
    @discardableResult
    func fillEmptyPane(_ pane: UUID, with id: UUID) -> Bool {
        guard pane != id, let paneTab = workspace.tabs[pane], !paneTab.meta.isTombstone, paneTab.url == nil,
              isInSplit(pane), !isInSplit(id), let chosen = workspace.tabs[id], !chosen.meta.isTombstone,
              case .today(let spaceID) = chosen.location, paneTab.location.spaceID == spaceID,
              controller.sidebar(showing: id, except: self) == nil else { return false }
        let layoutID = makeID()
        let ok = mutate { state in
            let joined = try TreeOps.splitTab(state, layoutID: layoutID, tabID: id, targetTabID: pane,
                                              side: .trailing, moveNextToTarget: true, now: now())
            return try TreeOps.archiveTab(joined, id: pane, now: now())
        }
        guard ok else { return false }
        closeLive(pane)
        if selectedTabID == pane { selectedTabID = nil }
        selectTab(id)
        return true
    }

    /// "Separate Page from Split View" (View menu): takes the tab out of its split layout and keeps
    /// the tab itself. [01 §View] observed the item.
    public func separateFromSplit(_ id: UUID) {
        mutate { TreeOps.removeSplitPane($0, tabID: id, now: now()) }
    }

    /// Whether a tab is part of a live split group (the sidebar treats a group as a unit). [06 §5] observed.
    func isInSplit(_ id: UUID) -> Bool {
        workspace.splits.values.contains { !$0.meta.isTombstone && $0.root.tabIDs.contains(id) }
    }

    // MARK: - Hover card

    func hoverBegan(_ id: UUID) {
        hoverTask?.cancel()
        hoveredTabID = id
        hoverCardTabID = nil
        guard draggingItem == nil, renamingItemID == nil, workspace.tabs[id] != nil else { return }
        let delay = hoverDelay
        hoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.hoveredTabID == id else { return }
            self.hoverCardTabID = id
        }
    }

    func hoverEnded(_ id: UUID) {
        guard hoveredTabID == id else { return }
        hoveredTabID = nil
        hoverTask?.cancel()
        hoverCardTabID = nil
    }

    // MARK: - Drag and drop

    /// Starts an in-app drag. The AppKit drag source (`SidebarDragSourceView`) reports the end of
    /// the session itself (`dragSessionEnded`), including Esc and a release outside every target.
    /// `isSessionActive`, when given, is polled by a watchdog as a fallback and must return whether
    /// the drag is still going. Tests omit it and call `endDrag()` themselves.
    func beginDrag(_ item: SidebarDragItem, isSessionActive: (@MainActor () -> Bool)? = nil) {
        dismissQuickList()
        let beforePress = selectionBeforePress
        endDrag()
        selectionBeforePress = beforePress
        draggingItem = item
        hoverTask?.cancel()
        hoverCardTabID = nil
        guard let isSessionActive else { return }
        let interval = dragWatchInterval
        dragWatchTask = Task { [weak self] in
            // Two consecutive inactive polls are required: the drop callback of a successful drop
            // arrives right after the button goes up and must not lose the race against this poll.
            var inactive = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                inactive = isSessionActive() ? 0 : inactive + 1
                if inactive >= 2 {
                    self.endDrag()
                    return
                }
            }
        }
    }

    /// Mouse-down on an item, before any drag: a tab or split group is selected at once (and its
    /// page comes to the front). [06 §15.1] observed. Folders act on click only (toggle).
    func pressSelect(_ item: SidebarDragItem) {
        guard draggingItem == nil, renamingItemID == nil else { return }
        selectionBeforePress = nil
        switch item {
        case .tab(let id):
            if selectedTabID != id {
                selectionBeforePress = selectedTabID
                selectTab(id)
            }
        case .splitGroup(let id):
            selectSplitGroup(id)
        case .folder:
            break
        }
    }

    /// Whether a press on `item` may turn into a drag (not while it is being renamed: the press
    /// then selects text).
    func canStartDrag(_ item: SidebarDragItem) -> Bool {
        renamingItemID != item.id && draggingItem == nil
    }

    /// An external drag (a link from another app) entered the sidebar.
    func beginExternalDrag() {
        guard draggingItem == nil, !isDraggingExternalURL else { return }
        isDraggingExternalURL = true
    }

    /// The AppKit drag session ended: after a drop (already applied), a release outside every
    /// target, or Esc. [06 §15.9] observed: Esc removes the indicator at once and a later release
    /// changes nothing. The session never switches the Space back. [06 §15.6] observed.
    func dragSessionEnded() {
        endDrag()
    }

    /// Ends any drag and clears all drag feedback. A cancelled drag changes nothing in the workspace.
    func endDrag() {
        dragWatchTask?.cancel()
        dragWatchTask = nil
        cancelDockHover()
        cancelEdgeSwitch()
        stopAutoScroll()
        lastDragPointer = nil
        draggingItem = nil
        isDraggingExternalURL = false
        dropTarget = nil
        selectionBeforePress = nil
    }

    /// The tab a drop on the web panel pairs with, for the pane showing `paneTabID`; nil when the
    /// drop is refused. The press that started the drag selected the dragged tab ([06 §15.1]
    /// observed), so the single panel now shows the dragged tab itself; [06 §15.7] observed that
    /// the drop forms a split with the page that was current, so that page is used (B19).
    func webPanelDropPartner(forPane paneTabID: UUID) -> UUID? {
        guard case .tab(let id)? = draggingItem else { return nil }
        guard paneTabID == id else { return paneTabID }
        guard let before = selectionBeforePress, before != id,
              let tab = workspace.tabs[before], !tab.meta.isTombstone else { return nil }
        return before
    }

    private var isDragActive: Bool { draggingItem != nil || isDraggingExternalURL }

    /// Whether the current drag can form a split on a tab row's middle band: a single tab that is
    /// not a favorite, or a link from outside. [06 §15.2] observed for tabs, [06 §15.7] for links.
    var dragAllowsSplit: Bool {
        if isDraggingExternalURL { return true }
        guard case .tab(let id)? = draggingItem, let tab = workspace.tabs[id] else { return false }
        if case .favorite = tab.location { return false }
        return true
    }

    /// The side of the split preview drawn on row `id`, if the drop target is its middle band.
    func splitPreviewSide(for id: UUID) -> SplitSide? {
        if case .row(id, .split(let side))? = dropTarget { return side }
        return nil
    }

    /// The plan for the current drag over `target`, or nil. For an external URL the plan is computed
    /// for a scratch tab opened at the top of Today, so the same rules apply as for a tab move.
    func dropPlan(for target: SidebarDropTarget) -> SidebarDropPlan? {
        guard let spaceID = selectedSpaceID, incognitoAllowsDrop(on: target) else { return nil }
        if let item = draggingItem {
            return SidebarDropPlanner.plan(item: item, target: target, workspace: workspace, spaceID: spaceID, profileID: currentProfileID)
        }
        guard isDraggingExternalURL, let scratch = try? scratchURLTab(in: spaceID) else { return nil }
        return SidebarDropPlanner.plan(item: .tab(Self.scratchTabID), target: target, workspace: scratch, spaceID: spaceID, profileID: currentProfileID)
    }

    /// Title shown in the drag preview.
    func dragTitle(for item: SidebarDragItem) -> String {
        switch item {
        case .tab(let id): return workspace.tabs[id]?.displayTitle ?? ""
        case .folder(let id): return workspace.folders[id]?.title ?? ""
        case .splitGroup:
            guard let group = snapshot.splitGroup(layoutID: item.id) else { return "" }
            return group.members.map(\.displayTitle).joined(separator: " | ")
        }
    }

    /// Hit-tests `point` and updates the indicator in one step. Returns whether the drop is accepted.
    /// Also drives the edge Space switch and the auto-scroll, which do not depend on a target.
    @discardableResult
    func updateDropTarget(at point: CGPoint, in geometry: SidebarDropGeometry) -> Bool {
        if isDragActive { lastDragPointer = point }
        updateEdgeSwitch(x: point.x, sidebarWidth: geometry.width)
        let accepted: Bool
        if let target = SidebarDropHitTester.target(at: point, in: geometry, allowsSplit: dragAllowsSplit) {
            accepted = updateDropTarget(target)
        } else {
            // No target here (e.g. the dead zone above "+ New Tab", [06 §15.4]): no indicator.
            if dropTarget != nil { dropTarget = nil }
            cancelDockHover()
            accepted = false
        }
        updateAutoScroll(pointer: point, viewport: geometry.list)
        return accepted
    }

    /// Re-hit-tests the last drag pointer against fresh geometry. The view calls it whenever the
    /// reported frames change (the list scrolled under a resting pointer), so the indicator always
    /// matches the rows currently under the pointer. No-op outside a drag.
    func refreshDropTarget(in geometry: SidebarDropGeometry) {
        guard isDragActive, let point = lastDragPointer else { return }
        updateDropTarget(at: point, in: geometry)
    }

    /// Updates the indicator; returns whether the target accepts the drop.
    @discardableResult
    func updateDropTarget(_ target: SidebarDropTarget) -> Bool {
        let accepted = dropPlan(for: target) != nil
        let new: SidebarDropTarget? = accepted ? target : nil
        if dropTarget != new {
            dropTarget = new
            if new != nil, draggingItem != nil, controller.feedback.settings.playsReorderHaptics {
                playReorderHaptic()
            }
        }
        // Hovering a dot switches the Space even when a drop there would change nothing (the item
        // already lives in that Space): the switch is for placing it inside. [06 §15.6] observed.
        trackDockHover(target)
        return accepted
    }

    /// The drag left the sidebar: no indicator, no pending Space switch, no scrolling.
    func clearDropTarget() {
        if dropTarget != nil { dropTarget = nil }
        cancelDockHover()
        cancelEdgeSwitch()
        stopAutoScroll()
    }

    // MARK: Auto-scroll while dragging

    /// Starts or stops the auto-scroll loop for a drag pointer at `pointer` over the list area
    /// `viewport` (both in the sidebar root space). [06 §15.8] (see `SidebarAutoScroll`).
    func updateAutoScroll(pointer: CGPoint, viewport: CGRect) {
        autoScrollViewport = viewport
        guard isDragActive, let metrics = listScroller?.metrics,
              SidebarAutoScroll.edge(pointerY: pointer.y, viewport: viewport, metrics: metrics) != nil else {
            stopAutoScroll()
            return
        }
        guard autoScrollTask == nil else { return }
        autoScrollTimeInBand = 0
        let interval = autoScrollTickInterval
        autoScrollTask = Task { [weak self] in
            let clock = ContinuousClock()
            var last = clock.now
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let now = clock.now
                let elapsed = now - last
                last = now
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18
                if !self.autoScrollStep(elapsed: seconds) {
                    self.stopAutoScroll()
                    return
                }
            }
        }
    }

    /// One auto-scroll step of `elapsed` seconds for the last drag pointer. Returns false when the
    /// list should stop scrolling (pointer out of the bands, content end reached, drag over).
    /// During the dwell ([06 §15.8] ≈ 0.3–0.5 s) the step keeps the loop alive without scrolling.
    @discardableResult
    func autoScrollStep(elapsed: Double) -> Bool {
        guard isDragActive, let pointer = lastDragPointer, let scroller = listScroller,
              let metrics = scroller.metrics,
              SidebarAutoScroll.edge(pointerY: pointer.y, viewport: autoScrollViewport, metrics: metrics) != nil else {
            autoScrollVelocity = 0
            return false
        }
        autoScrollTimeInBand += max(0, elapsed)
        let velocity = SidebarAutoScroll.velocity(
            pointerY: pointer.y, viewport: autoScrollViewport, metrics: metrics,
            timeInBand: autoScrollTimeInBand, dwell: autoScrollDwell
        )
        autoScrollVelocity = velocity
        guard velocity != 0 else { return true }
        let offset = SidebarAutoScroll.offset(after: elapsed, velocity: velocity, from: metrics)
        if offset != metrics.offset { scroller.scroll(toOffset: offset) }
        return true
    }

    func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollVelocity = 0
        autoScrollTimeInBand = 0
    }

    /// Applies the in-app drop. Returns whether the workspace changed.
    @discardableResult
    func performDrop(on target: SidebarDropTarget) -> Bool {
        defer { endDrag() }
        guard let plan = dropPlan(for: target) else { return false }
        let layoutID: UUID? = plan.action.needsLayoutID ? makeID() : nil
        let stamp = now()
        let before = workspace
        guard mutate({ try SidebarDropPlanner.apply(plan, to: $0, layoutID: layoutID, now: stamp) }) else { return false }
        // Dragging a tab into the pinned area pins it, too (first-pin hint, [06 §4]).
        notePins(since: before)
        finishDrop(plan, target: target, droppedTabID: nil)
        return true
    }

    /// Applies a link dropped from outside: opens a tab for `url` at the dropped position and
    /// selects it. Position rules are the ones of a tab move. [06 §15.7] observed: on an insertion
    /// line the link opens there as a Today tab; on a row's middle band the split preview shows (the
    /// result of that drop is inferred: a split with the new tab). Returns the new tab's id, or nil
    /// if the target does not accept it.
    @discardableResult
    func performURLDrop(_ url: URL, on target: SidebarDropTarget) -> UUID? {
        defer { endDrag() }
        guard let spaceID = selectedSpaceID, let plan = dropPlan(for: target) else { return nil }
        let id = makeID()
        let layoutID: UUID? = plan.action.needsLayoutID ? makeID() : nil
        let title = url.host ?? url.absoluteString
        // One mutation: either the tab is opened at the dropped position or nothing changes.
        let stamp = now()
        guard mutate({ ws in
            let opened = try TreeOps.openTab(ws, id: id, spaceID: spaceID, url: url, title: title, now: stamp)
            return try SidebarDropPlanner.apply(plan, to: opened, newTabID: id, layoutID: layoutID, now: stamp)
        }) else { return nil }
        // Dropped on a dock icon: the tab lives in another Space, so show that Space.
        if let space = workspace.tabs[id]?.location.spaceID, space != selectedSpaceID { selectedSpaceID = space }
        selectTab(id)
        return id
    }

    /// A sidebar tab dropped on the web panel, on `side` of the pane showing `targetTabID`.
    /// [06 §15.7] observed: the two form a split with the dropped tab on the pointer's side; a
    /// pinned tab stays where it is and a new split row appears in Today (a copy of the pinned page
    /// is opened, inferred). The dropped page becomes the focused pane (as for a row drop, [06 §15.2]).
    @discardableResult
    func performWebPanelDrop(onTab targetTabID: UUID, side: SplitSide) -> Bool {
        defer { endDrag() }
        guard case .tab(let id)? = draggingItem, let spaceID = selectedSpaceID,
              let action = SidebarDropPlanner.webPanelAction(tabID: id, targetTabID: targetTabID, side: side, spaceID: spaceID, workspace: workspace)
        else { return false }
        let plan = SidebarDropPlan(action: action)
        let copyID: UUID? = action.needsCopyID ? makeID() : nil
        let layoutID = makeID()
        // The copy shows the page as it is now (live URL), else the stored one.
        let stamp = now()
        let liveURL = action.needsCopyID ? linkURL(for: id) : nil
        guard mutate({ ws in
            try SidebarDropPlanner.apply(plan, to: ws, newTabID: copyID, layoutID: layoutID, copyURL: liveURL, now: stamp)
        }) else { return false }
        selectTab(copyID ?? id)
        return true
    }

    /// Selection after a drop. A split drop focuses the dropped tab ([06 §15.2] observed). A drop on
    /// a dock dot leaves the window on that Space with the moved tab NOT selected ([06 §15.6] observed).
    private func finishDrop(_ plan: SidebarDropPlan, target: SidebarDropTarget, droppedTabID: UUID?) {
        switch plan.action {
        case .splitTab(let id, _, _, _):
            selectTab(droppedTabID ?? id)
        case .splitCopy:
            break
        case .moveTab, .moveTabs, .moveFolder, .moveSplitLayout:
            guard case .dockSpace(let spaceID) = target else { return }
            if let selected = selectedTabID, workspace.tabs[selected]?.location.spaceID == spaceID {
                selectedTabID = nil
                for (space, tab) in lastSelectedTab where tab == selected { lastSelectedTab[space] = nil }
            }
            selectSpace(spaceID)
        }
    }

    /// Placeholder tab used only to compute plans for external drops. Never stored.
    private static let scratchTabID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

    private func scratchURLTab(in spaceID: UUID) throws -> WorkspaceState {
        try TreeOps.openTab(workspace, id: Self.scratchTabID, spaceID: spaceID, url: nil, title: "", now: now())
    }

    // MARK: Edge Space switch while dragging

    /// Starts (or keeps) the timer that shows the previous / next Space while the drag pointer
    /// rests at the sidebar's left / right edge. [06 §15.6] observed. Leaving the edge cancels it;
    /// it fires once per stay (inferred). It does not wrap around the dock (inferred).
    func updateEdgeSwitch(x: CGFloat, sidebarWidth: CGFloat) {
        guard isDragActive, let direction = SidebarEdgeSwitch.direction(x: x, sidebarWidth: sidebarWidth) else {
            cancelEdgeSwitch()
            return
        }
        guard edgeSwitchDirection != direction else { return }
        cancelEdgeSwitch()
        edgeSwitchDirection = direction
        let delay = direction < 0 ? edgeSwitchLeftDelay : edgeSwitchRightDelay
        edgeSwitchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.edgeSwitchDirection == direction, self.isDragActive else { return }
            self.edgeSwitchTask = nil
            guard let id = self.adjacentSpaceID(direction) else { return }
            self.dropTarget = nil
            self.cancelDockHover()
            self.selectSpace(id)
        }
    }

    private func cancelEdgeSwitch() {
        edgeSwitchTask?.cancel()
        edgeSwitchTask = nil
        edgeSwitchDirection = nil
    }

    /// The Space before (-1) or after (+1) the current one in dock order, without wrapping.
    private func adjacentSpaceID(_ direction: Int) -> UUID? {
        let spaces = dockSpaces
        guard let index = spaces.firstIndex(where: { $0.id == selectedSpaceID }) else { return nil }
        let next = index + direction
        return spaces.indices.contains(next) ? spaces[next].id : nil
    }

    // MARK: Dock hover while dragging

    /// Starts (or keeps) the timer that switches to the hovered Space; any other target cancels it.
    private func trackDockHover(_ target: SidebarDropTarget?) {
        guard case .dockSpace(let id)? = target, id != selectedSpaceID else {
            cancelDockHover()
            return
        }
        guard dockHoverSpaceID != id else { return }
        cancelDockHover()
        dockHoverSpaceID = id
        let delay = dockSwitchDelay
        dockHoverTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.dockHoverSpaceID == id,
                  self.draggingItem != nil || self.isDraggingExternalURL else { return }
            self.dockHoverSpaceID = nil
            self.dropTarget = nil
            self.selectSpace(id)
        }
    }

    private func cancelDockHover() {
        dockHoverTask?.cancel()
        dockHoverTask = nil
        dockHoverSpaceID = nil
    }
}

// MARK: - Sidebar list details (B76)

extension SidebarViewModel {

    // MARK: First-pin rename hint

    /// Whether the row of `id` shows the "Double-click to rename" line. [06 §4] observed.
    func showsPinRenameHint(_ id: UUID) -> Bool {
        pinRenameHintTabID == id && renamingItemID != id
    }

    /// After a change that may have pinned tabs: the first tab pinned on this device gets the
    /// rename hint, once. [06 §4] observed ("on the first pin"); the per-device flag in
    /// `ui-state.json` is inferred. With several tabs pinned at once the first in sidebar order
    /// gets it. The hint lasts until the tab is renamed or unpinned, or the app quits. inferred.
    fileprivate func notePins(since before: WorkspaceState) {
        guard !isIncognito, !controller.pinRenameHintShown else { return }
        func wasPinned(_ id: UUID) -> Bool {
            before.tabs[id].map { !$0.meta.isTombstone && $0.location.isPinned } ?? false
        }
        let newlyPinned = Set(workspace.tabs.values
            .filter { !$0.meta.isTombstone && $0.location.isPinned && !wasPinned($0.id) }
            .map(\.id))
        guard !newlyPinned.isEmpty else { return }
        let firstInList = snapshot.pinned.first { newlyPinned.contains($0.id) }?.id
        pinRenameHintTabID = firstInList ?? newlyPinned.min { $0.uuidString < $1.uuidString }
        controller.markPinRenameHintShown()
    }

    // MARK: Selected row jump button

    /// The list row that stands for the selected tab: its own row, or the split-group row that
    /// holds it. Nil for a favorite, a tab hidden in a collapsed folder, or no selection.
    var selectedListRowID: UUID? {
        guard let id = selectedTabID else { return nil }
        let snap = snapshot
        if let group = snap.splitGroup(containing: id) { return group.layoutID }
        return (snap.pinned + snap.today).contains { $0.id == id } ? id : nil
    }

    /// The ↓ / ↑ button: scrolls the list so the selected row (at `rowFrame`, sidebar root space)
    /// is in the middle of `viewport` (the visible list, same space). [06 §15.8] observed (the
    /// button points toward the selected row); centering it is inferred.
    func revealSelectedRow(rowFrame: CGRect, viewport: CGRect) {
        guard let scroller = listScroller, let metrics = scroller.metrics else { return }
        scroller.scroll(toOffset: SidebarSelectionJump.revealOffset(rowFrame: rowFrame, viewport: viewport, metrics: metrics))
    }

    // MARK: Trackpad swipe between Spaces

    /// A horizontal two-finger swipe over the sidebar pages to the neighbor Space. [05 §window
    /// hierarchy] observed ("swipe or click the dock to switch"). Unlike ⌥⌘← / ⌥⌘→ it does not
    /// wrap: the Spaces are a row of pages and there is no page past the last one. inferred.
    func swipeSpace(by delta: Int) {
        guard draggingItem == nil, !isDraggingExternalURL, delta != 0 else { return }
        let spaces = dockSpaces
        guard let current = spaces.firstIndex(where: { $0.id == selectedSpaceID }),
              spaces.indices.contains(current + delta) else { return }
        dismissQuickList()
        selectSpace(spaces[current + delta].id)
    }

    // MARK: Folder quick list

    /// The pointer entered a folder row. After `quickListDelay` the folder's quick list shows; a
    /// list already open for another folder moves to this one at once. [06 §14] observed (hover
    /// opens it); the delay is inferred. Only a collapsed folder that holds tabs has one: an open
    /// folder already lists its tabs below it. inferred.
    func folderHoverBegan(_ id: UUID) {
        quickListHoveredFolderID = id
        guard draggingItem == nil, !isDraggingExternalURL, renamingItemID == nil, !isQuickListFocused,
              let folder = workspace.folders[id], !folder.meta.isTombstone, !folder.isExpanded,
              !FolderQuickList.tabs(inFolder: id, workspace: workspace).isEmpty else {
            if quickListFolderID != id { scheduleQuickListDismiss() }
            return
        }
        quickListTask?.cancel()
        quickListTask = nil
        guard quickListFolderID != id else { return }
        if quickListFolderID != nil {
            quickListQuery = ""
            quickListFolderID = id
            return
        }
        let delay = quickListDelay
        quickListTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, self.quickListHoveredFolderID == id else { return }
            self.quickListQuery = ""
            self.quickListFolderID = id
        }
    }

    /// The pointer left a folder row: a pending list is cancelled; an open one closes after
    /// `quickListDismissDelay` unless the pointer reaches it.
    func folderHoverEnded(_ id: UUID) {
        guard quickListHoveredFolderID == id else { return }
        quickListHoveredFolderID = nil
        scheduleQuickListDismiss()
    }

    /// The pointer entered or left the quick list itself.
    func quickListHoverChanged(_ inside: Bool) {
        isPointerInQuickList = inside
        if inside {
            quickListTask?.cancel()
            quickListTask = nil
        } else {
            scheduleQuickListDismiss()
        }
    }

    /// The quick list took the keyboard (its search field was clicked) or gave it up. While it has
    /// it, the pointer may leave; giving it up (a click elsewhere) closes the list. inferred.
    func quickListFocusChanged(_ focused: Bool) {
        isQuickListFocused = focused
        if focused {
            quickListTask?.cancel()
            quickListTask = nil
        } else if quickListFolderID != nil {
            dismissQuickList()
        }
    }

    /// Closes the quick list now (Esc, a pick, a drag, a Space switch, a rename).
    func dismissQuickList() {
        quickListTask?.cancel()
        quickListTask = nil
        isPointerInQuickList = false
        isQuickListFocused = false
        quickListQuery = ""
        quickListFolderID = nil
    }

    /// Opens a tab picked in the quick list and closes the list.
    func openFromQuickList(_ tabID: UUID) {
        dismissQuickList()
        selectTab(tabID)
    }

    /// Rows of a folder's quick list for the current query, with relative times.
    func quickListRows(folderID: UUID) -> [FolderQuickListRow] {
        FolderQuickList.rows(folderID: folderID, workspace: workspace, query: quickListQuery, now: now())
    }

    private func scheduleQuickListDismiss() {
        quickListTask?.cancel()
        quickListTask = nil
        guard quickListFolderID != nil, !isQuickListFocused else { return }
        let delay = quickListDismissDelay
        quickListTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.isPointerInQuickList, !self.isQuickListFocused,
                  self.quickListHoveredFolderID == nil || self.quickListHoveredFolderID != self.quickListFolderID
            else { return }
            if self.quickListPointerProbe?() == true {
                // Still over the list: check again later instead of closing under the pointer.
                self.scheduleQuickListDismiss()
                return
            }
            self.dismissQuickList()
        }
    }
}
