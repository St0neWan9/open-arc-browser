import Foundation
import OpenArcModel
import OpenArcEngine

// Window state for the command bar's command and space rows. The sources read it at query time,
// so availability ("Close this Split Pane" only with a split, back/forward only with history) and
// the "Move Tab to “<Space>”" rows always follow the window.

extension ShellModel {
    /// What the command rows depend on right now.
    var commandBarCommandState: CommandBarCommandState {
        var state = baseCommandBarCommandState
        // "Favorite Tab" only for a Today tab of a normal window. [06 §21.4] B55.
        state.canFavoriteSelectedTab = !isIncognito && selectedTabID.flatMap { workspace.tabs[$0] }.map { tab in
            if case .today = tab.location { return true } else { return false }
        } == true
        state.isIncognito = isIncognito
        return state
    }

    private var baseCommandBarCommandState: CommandBarCommandState {
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
        commandBar.sources = commandBarSources(workspace: workspace, commandState: state)
        paneCommandBar.sources = commandBarSources(workspace: workspace, commandState: state)
        // The incognito window's empty bar lists the help rows only. [06 §20.1] observed (B61).
        commandBar.listsHelpOnlyWhenEmpty = isIncognito
        paneCommandBar.listsHelpOnlyWhenEmpty = isIncognito
    }

    /// The default sources plus the engine's browsing history and search suggestions (plan B66).
    func commandBarSources(
        workspace: @escaping @Sendable () async -> WorkspaceState,
        commandState: @escaping @Sendable () async -> CommandBarCommandState
    ) -> [any CommandBarSource] {
        commandBarDefaultSources(
            workspace: workspace,
            commandState: commandState,
            history: commandBarHistorySource(),
            suggestions: commandBarSuggestionProvider(),
            suggestionsAreDeferred: true
        )
    }

    /// History rows from the engine for the window's profile. An incognito window has none: its
    /// browsing is never recorded, and its bar lists "no history" ([06 §20.1] observed). nil there.
    func commandBarHistorySource() -> CommandBarHistorySource? {
        guard !isIncognito else { return nil }
        let autocomplete = dependencies.engine.autocomplete
        let sidebar = self.sidebar
        let clock = controller.now
        let now: @Sendable () async -> Date = { @MainActor in clock() }
        return CommandBarHistorySource(now: now) { @MainActor text, maxCount in
            guard let profileID = sidebar.currentProfileID else { return [] }
            return await autocomplete.historyMatches(for: text, profileID: profileID, maxCount: maxCount)
        }
    }

    /// Search suggestions from the engine, asked of the search engine of the window's profile
    /// ([03 §Profiles] observed "Search engine") while its "Include search engine suggestions" is
    /// on (observed toggle). An incognito window follows its parent profile's settings and asks
    /// through its off-the-record context (inferred: the spec records suggestions only for normal
    /// windows, [06 §16.2, §19.1, §23]; Chrome also suggests in incognito).
    func commandBarSuggestionProvider() -> CommandBarEngineSuggestionProvider {
        let autocomplete = dependencies.engine.autocomplete
        let incognito = isIncognito
        return CommandBarEngineSuggestionProvider(autocomplete: autocomplete) { @MainActor [weak self] query in
            guard let self, let profileID = self.sidebar.currentProfileID else { return nil }
            let settings = self.currentProfileSettings
            guard settings.includesSearchSuggestions else { return nil }
            return SearchSuggestionRequest(
                query: query,
                urlTemplate: settings.searchEngine.suggestURLTemplate,
                profileID: profileID,
                isOffTheRecord: incognito
            )
        }
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
