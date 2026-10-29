import Foundation
import Combine
import OpenArcModel

// What the menu bar shows of a browser window, and when it must be rebuilt (B103).
//
// SwiftUI rebuilds the whole main menu (every `Commands` body and every menu item view) whenever an
// object the menus observe publishes. The window model publishes on every change of its sidebar,
// which follows every workspace change and every engine event of every page (a title arriving, a
// load progressing), so observing it directly cost a menu rebuild of several milliseconds inside
// most frames, the click that selects a tab included. The menus observe this object instead: it
// publishes only when a value the menu items display (a title, an enabled state, a check, the
// Space list) changed, checked in the run loop pass after a change, once that change has drawn.

/// The values the menu bar items read from a window: titles, enabled states, checks and the Space
/// list. Two equal values draw the same menus. Every value a menu item view reads from
/// `ShellModel` (or its sidebar) belongs here; actions read the model when they run.
struct MenuBarInputs: Equatable {
    /// One Spaces ▸ row: the Space, its icon and name.
    struct SpaceRow: Equatable {
        var id: UUID
        var name: String
        var icon: String?
    }

    var isIncognito = false
    var hasSelectedTab = false
    var hasSelectedURL = false
    var hasLivePage = false
    var canRestoreLastClosedTab = false
    var canCreateEasel = false
    var canCapturePage = false
    var webAppearance: WebAppearance = .automatic
    var sidebarToggleTitle = ""
    var canToggleWebToolbar = false
    var collapsePinnedMenuTitle = ""
    var canCollapsePinned = false
    var reloadMode: SidebarReloadMode = .reload
    var hasActiveSplit = false
    var canResetZoom = false
    var canZoomIn = false
    var canZoomOut = false
    var allowsJavaScriptFromAppleEvents = false
    var selectedSpaceID: UUID?
    var isCreatingSpace = false
    var spaces: [SpaceRow] = []
    var pinMenuTitle = ""
    var canResetPinnedTabs = false
    var staysOnTop = false
    var canGoBack = false
    var canGoForward = false
    var canClearArchive = false
}

extension ShellModel {
    /// What the menu bar shows of this window now.
    var menuBarInputs: MenuBarInputs {
        MenuBarInputs(
            isIncognito: isIncognito,
            hasSelectedTab: selectedTabID != nil,
            hasSelectedURL: sidebar.selectedURL != nil,
            hasLivePage: canRunPageCommands,
            canRestoreLastClosedTab: sidebar.canRestoreLastClosedTab,
            canCreateEasel: canCreateEasel,
            canCapturePage: canCapturePage,
            webAppearance: webAppearance,
            sidebarToggleTitle: sidebarToggleTitle,
            canToggleWebToolbar: canToggleWebToolbar,
            collapsePinnedMenuTitle: collapsePinnedMenuTitle,
            canCollapsePinned: sidebar.canCollapsePinned || sidebar.isPinnedAreaCollapsed,
            reloadMode: sidebar.reloadMode,
            hasActiveSplit: hasActiveSplit,
            canResetZoom: canResetZoom,
            canZoomIn: canZoomIn,
            canZoomOut: canZoomOut,
            allowsJavaScriptFromAppleEvents: allowsJavaScriptFromAppleEvents,
            selectedSpaceID: selectedSpaceID,
            isCreatingSpace: spaceFlow.isCreating,
            spaces: sidebar.dockSpaces.map { MenuBarInputs.SpaceRow(id: $0.id, name: $0.name, icon: $0.icon) },
            pinMenuTitle: pinMenuTitle,
            canResetPinnedTabs: sidebar.canResetPinnedTabs,
            staysOnTop: staysOnTop,
            canGoBack: sidebar.canGoBack,
            canGoForward: sidebar.canGoForward,
            canClearArchive: sidebar.canClearArchive
        )
    }
}

/// Tells the menu bar when a window's menus must be rebuilt (see the file comment). One per
/// window, made by `ShellModel.menuBar`; the browser window offers it as its focused scene object
/// and every menu item view observes it.
@MainActor
public final class MenuBarState: ObservableObject {
    /// The window whose menus these are.
    public private(set) weak var model: ShellModel?
    /// The values the menus were last built from.
    private(set) var inputs: MenuBarInputs
    /// How often the menus were told to rebuild. For tests and diagnostics.
    private(set) var publishCount = 0
    private var modelChanges: AnyCancellable?
    private var isCheckScheduled = false

    init(model: ShellModel) {
        self.model = model
        inputs = model.menuBarInputs
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            // The model is main-actor isolated and publishes on the main thread.
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
    }

    /// Checks the window's menu values in the run loop pass after the one that changed the window,
    /// once that pass has drawn: the changes of one pass (a click, a burst of engine events) cost
    /// one check, outside their frame. A key press in the next pass already finds the menus
    /// current; only a key handled in the same pass as the change sees the items from before it
    /// (their actions read the window as it is when they run).
    private func scheduleCheck() {
        guard !isCheckScheduled else { return }
        isCheckScheduled = true
        Task { [weak self] in
            await MainRunLoopTurn.next()
            self?.check()
        }
    }

    /// Rebuilds the menus when a value they show changed. Runs after a change; tests call it to
    /// skip the wait.
    func check() {
        isCheckScheduled = false
        guard let model else { return }
        let next = model.menuBarInputs
        guard next != inputs else { return }
        objectWillChange.send()
        inputs = next
        publishCount += 1
    }
}
