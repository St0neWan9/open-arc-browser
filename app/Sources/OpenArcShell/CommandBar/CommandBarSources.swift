import Foundation
import OpenArcModel

// Pluggable candidate sources. A source returns unranked candidates for the current query; the
// pure `CommandBarRanker` filters, orders and de-duplicates them. Sources never touch the network:
// web suggestions come through an injected provider.

/// A producer of command bar candidates.
public protocol CommandBarSource: Sendable {
    /// Returns candidates for the query. May return everything and let the ranker filter, but must
    /// be deterministic (sorted, no dictionary-order leaks).
    func results(for context: CommandBarQueryContext) async -> [CommandBarResult]
}

// MARK: - Workspace tabs (open, pinned, favorite)

/// Tabs of the workspace: Today, pinned (in folders too) and favorites, across all spaces.
/// `BrowserEngine` cannot enumerate tabs, so the persisted workspace is the source of "open tabs".
public struct CommandBarWorkspaceTabsSource: CommandBarSource {
    /// Label of the action on an open tab. [05 §command bar] observed.
    public static let switchLabel = "Switch to Tab"

    private let workspace: @Sendable () async -> WorkspaceState

    public init(workspace: @escaping @Sendable () async -> WorkspaceState) {
        self.workspace = workspace
    }

    public init(workspace: WorkspaceState) {
        self.workspace = { workspace }
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let state = await workspace()
        let tabs = state.tabs.values
            .filter { !$0.meta.isTombstone }
            .sorted { lhs, rhs in
                if lhs.lastActiveAt != rhs.lastActiveAt { return lhs.lastActiveAt > rhs.lastActiveAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        return tabs.enumerated().map { index, tab in
            let url = tab.url ?? tab.pinnedURL
            let kind: CommandBarResultKind
            switch tab.location {
            case .favorite: kind = .favoriteTab
            case .pinned: kind = .pinnedTab
            case .today: kind = .todayTab
            }
            let spaceID = tab.location.spaceID
            let host = url.flatMap { CommandBarTextNormalizer.host($0) }
            var title = tab.displayTitle
            if title.isEmpty { title = host ?? url?.absoluteString ?? "New Tab" }
            return CommandBarResult(
                id: "tab:\(tab.id.uuidString)",
                kind: kind,
                title: title,
                subtitle: host,
                url: url,
                iconHint: .site(faviconURL: tab.faviconURL),
                spaceID: spaceID,
                spaceName: spaceID.flatMap { state.spaces[$0]?.name },
                actionLabel: Self.switchLabel,
                action: .switchToTab(tabID: tab.id),
                completion: url?.absoluteString ?? title,
                lastActiveAt: tab.lastActiveAt,
                sourceOrder: index
            )
        }
    }
}

// MARK: - Archive

/// Archived tabs. Activating one restores it (a new tab at the top of Today, the archive item is
/// tombstoned) instead of just opening its URL. inferred, see `SidebarViewModel.restoreArchived`.
public struct CommandBarArchiveSource: CommandBarSource {
    /// Right-hand text of archived rows. unknown (not shown in the spec).
    public static let openLabel = "Open"

    private let workspace: @Sendable () async -> WorkspaceState

    public init(workspace: @escaping @Sendable () async -> WorkspaceState) {
        self.workspace = workspace
    }

    public init(workspace: WorkspaceState) {
        self.workspace = { workspace }
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        // Archived items are only searched, never listed for an empty query. inferred.
        guard !context.trimmedText.isEmpty else { return [] }
        let state = await workspace()
        return state.archiveNewestFirst.enumerated().compactMap { index, item in
            guard let url = item.url else { return nil }
            let host = CommandBarTextNormalizer.host(url)
            return CommandBarResult(
                id: "archive:\(item.id.uuidString)",
                kind: .archivedItem,
                title: item.title.isEmpty ? (host ?? url.absoluteString) : item.title,
                subtitle: host,
                url: url,
                iconHint: .archive,
                spaceID: item.spaceID,
                spaceName: item.spaceID.flatMap { state.spaces[$0]?.name },
                actionLabel: Self.openLabel,
                action: .restoreArchived(itemID: item.id),
                completion: url.absoluteString,
                lastActiveAt: item.archivedAt,
                sourceOrder: index
            )
        }
    }
}

// MARK: - Built-in commands

/// Built-in app commands. Rows have no action label ([06 §6] observed) and show their shortcut
/// ([06 §16.2] observed). Commands that cannot run in the current window state are left out, not
/// dimmed ([06 §16.2] observed, see `CommandBarCommand.isAvailable`).
public struct CommandBarCommandsSource: CommandBarSource {
    private let commands: [CommandBarCommand]
    private let state: @Sendable () async -> CommandBarCommandState

    public init(
        commands: [CommandBarCommand] = CommandBarCommand.allCases,
        state: @escaping @Sendable () async -> CommandBarCommandState = { .everything }
    ) {
        self.commands = commands
        self.state = state
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let state = await state()
        return commands.enumerated().compactMap { index, command in
            guard command.isAvailable(in: state) else { return nil }
            return CommandBarResult(
                id: "command:\(command.rawValue)",
                kind: .command,
                title: command.title(in: state),
                iconHint: .command,
                actionLabel: nil,
                action: .runCommand(command),
                sourceOrder: index,
                shortcutHint: command.shortcutHint
            )
        }
    }
}

// MARK: - Spaces

/// Space rows for a typed query (inferred; the spec shows no space rows in the bar):
/// - "Go to “<Space>”" for every other live space, the wording of the Spaces menu items
///   [01 §Spaces, 02 §Space] observed;
/// - "Move Tab to “<Space>”" when there is a current tab: the sidebar's Move to ▸ <Space> intent
///   [05 §context menus] observed as a menu, offered here (inferred).
/// Rows have no action label, like app commands [06 §6] observed. Never listed for an empty query.
public struct CommandBarSpacesSource: CommandBarSource {
    private let workspace: @Sendable () async -> WorkspaceState
    private let state: @Sendable () async -> CommandBarCommandState

    public init(
        workspace: @escaping @Sendable () async -> WorkspaceState,
        state: @escaping @Sendable () async -> CommandBarCommandState = { .everything }
    ) {
        self.workspace = workspace
        self.state = state
    }

    public static func goToTitle(_ name: String) -> String { "Go to “\(name)”" }
    public static func moveTabTitle(_ name: String) -> String { "Move Tab to “\(name)”" }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        guard !context.trimmedText.isEmpty else { return [] }
        let ws = await workspace()
        let state = await state()
        // An incognito window has no Spaces to go to or move to. [06 §20.2] observed (B61).
        guard !state.isIncognito else { return [] }
        let spaces = ws.allLiveSpaces
        var out: [CommandBarResult] = []
        for (index, space) in spaces.enumerated() where space.id != context.currentSpaceID {
            out.append(CommandBarResult(
                id: "space:\(space.id.uuidString)",
                kind: .space,
                title: Self.goToTitle(space.name),
                iconHint: .space,
                spaceID: space.id,
                spaceName: space.name,
                actionLabel: nil,
                action: .goToSpace(spaceID: space.id),
                completion: space.name,
                sourceOrder: index,
                matchTexts: ["go to " + space.name, "space " + space.name, "switch to " + space.name],
                // ⌃1…⌃9 follow the dock order. [02 §Space] observed.
                shortcutHint: index < 9 ? "⌃\(index + 1)" : nil
            ))
        }
        // The tab the bar acts on: the pane's or edited tab (⌘L), else the window's selected tab.
        if let tabID = context.currentTabID ?? state.movableTabID,
           let tab = ws.tabs[tabID], !tab.meta.isTombstone {
            let ownSpace = tab.location.spaceID
            for (index, space) in spaces.enumerated() where space.id != ownSpace {
                out.append(CommandBarResult(
                    id: "move-tab:\(tabID.uuidString):\(space.id.uuidString)",
                    kind: .moveTabToSpace,
                    title: Self.moveTabTitle(space.name),
                    iconHint: .space,
                    spaceID: space.id,
                    spaceName: space.name,
                    actionLabel: nil,
                    action: .moveTab(tabID: tabID, toSpaceID: space.id),
                    completion: space.name,
                    sourceOrder: spaces.count + index,
                    matchTexts: ["move to " + space.name, "move to space"]
                ))
            }
        }
        return out
    }
}

// MARK: - Typed input (URL or search)

/// Turns the typed text into a "go to URL" row or a "search the web" row via the classifier.
public struct CommandBarTypedInputSource: CommandBarSource {
    /// Right-hand texts. unknown (not shown in the spec).
    public static let openURLLabel = "Open URL"
    public static let searchLabel = "Search"

    public init() {}

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let target = context.mode.openTarget
        switch CommandBarInputClassifier.classify(context.text) {
        case .empty:
            return []
        case .url(let url):
            let typed = context.trimmedText
            return [
                CommandBarResult(
                    id: "typed-url",
                    kind: .typedURL,
                    title: typed,
                    subtitle: CommandBarTextNormalizer.host(url),
                    url: url,
                    iconHint: .globe,
                    actionLabel: Self.openURLLabel,
                    action: .openURL(url, target: target),
                    completion: typed
                ),
                searchRow(typed, target: target),
            ]
        case .search(let query):
            return [searchRow(query, target: target)]
        }
    }

    private func searchRow(_ query: String, target: CommandBarOpenTarget) -> CommandBarResult {
        CommandBarResult(
            id: "web-search",
            kind: .webSearch,
            title: query,
            iconHint: .search,
            actionLabel: Self.searchLabel,
            action: .searchWeb(query: query, target: target),
            completion: query
        )
    }
}

// MARK: - Web search suggestions

/// Supplies web search suggestions for a query. The real implementation (network) lives outside
/// this folder; v1 ships `CommandBarStaticSuggestionProvider`.
public protocol CommandBarSuggestionProviding: Sendable {
    func suggestions(for query: String) async -> [String]
}

/// Offline provider: phrases from a fixed list that contain the query (case-insensitive). For
/// previews and tests.
public struct CommandBarStaticSuggestionProvider: CommandBarSuggestionProviding {
    public var phrases: [String]

    public init(phrases: [String]) {
        self.phrases = phrases
    }

    public func suggestions(for query: String) async -> [String] {
        let folded = CommandBarTextNormalizer.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return [] }
        return phrases.filter { CommandBarTextNormalizer.fold($0).hasPrefix(folded) }
    }
}

/// Web suggestion rows from an injected provider.
public struct CommandBarWebSuggestionsSource: CommandBarSource {
    private let provider: any CommandBarSuggestionProviding
    private let maxCount: Int

    public init(provider: any CommandBarSuggestionProviding, maxCount: Int = 4) {
        self.provider = provider
        self.maxCount = maxCount
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let query = context.trimmedText
        guard !query.isEmpty else { return [] }
        let suggestions = await provider.suggestions(for: query)
        return suggestions.prefix(maxCount).enumerated().map { index, text in
            CommandBarResult(
                id: "suggestion:\(index):\(text)",
                kind: .searchSuggestion,
                title: text,
                iconHint: .search,
                actionLabel: CommandBarTypedInputSource.searchLabel,
                action: .searchWeb(query: text, target: context.mode.openTarget),
                completion: text,
                sourceOrder: index
            )
        }
    }
}

/// The default set of sources for a workspace. `commandState` is the window state the command and
/// space rows depend on; the default offers every command and no move rows.
public func commandBarDefaultSources(
    workspace: @escaping @Sendable () async -> WorkspaceState,
    commandState: @escaping @Sendable () async -> CommandBarCommandState = { .everything },
    suggestions: any CommandBarSuggestionProviding = CommandBarStaticSuggestionProvider(phrases: [])
) -> [any CommandBarSource] {
    [
        CommandBarWorkspaceTabsSource(workspace: workspace),
        CommandBarArchiveSource(workspace: workspace),
        CommandBarCommandsSource(state: commandState),
        CommandBarSpacesSource(workspace: workspace, state: commandState),
        CommandBarTypedInputSource(),
        CommandBarWebSuggestionsSource(provider: suggestions),
    ]
}
