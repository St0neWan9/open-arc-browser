import Foundation
import OpenArcModel

// Window state for the command bar's command and space rows. The sources read it at query time,
// so availability ("Close this Split Pane" only with a split, back/forward only with history) and
// the "Move Tab to “<Space>”" rows always follow the window.

extension ShellModel {
    /// What the command rows depend on right now.
    var commandBarCommandState: CommandBarCommandState {
        CommandBarCommandState(
            hasSelectedTab: selectedTabID != nil,
            hasSelectedSpace: selectedSpaceID != nil,
            spaceCount: sidebar.dockSpaces.count,
            canRestoreLastClosedTab: sidebar.canRestoreLastClosedTab,
            hasActiveSplit: hasActiveSplit,
            canGoBack: sidebar.canGoBack,
            canGoForward: sidebar.canGoForward,
            isSidebarVisible: isSidebarVisible,
            movableTabID: selectedTabID,
            isSelectedTabPinned: selectedTabID.flatMap { workspace.tabs[$0] }.flatMap { tab in
                switch tab.location {
                case .pinned: return true
                case .today: return false
                case .favorite: return nil
                }
            }
        )
    }

    /// Gives the window's command bars sources that know the window state. Called once from `init`.
    func installCommandBarSources() {
        let sidebar = self.sidebar
        let workspace: @Sendable () async -> WorkspaceState = { @MainActor in sidebar.workspace }
        let state: @Sendable () async -> CommandBarCommandState = { @MainActor [weak self] in
            self?.commandBarCommandState ?? .everything
        }
        commandBar.sources = commandBarDefaultSources(workspace: workspace, commandState: state)
        paneCommandBar.sources = commandBarDefaultSources(workspace: workspace, commandState: state)
    }
}

extension ShellModel {
    /// Command state for the Little Arc bar: commands act on the main window, but there is no
    /// main-window tab to move from Little Arc, so no "Move Tab to" rows. inferred.
    var littleArcCommandBarState: CommandBarCommandState {
        var state = commandBarCommandState
        state.movableTabID = nil
        return state
    }
}
