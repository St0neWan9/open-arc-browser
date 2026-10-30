import Foundation
import OpenArcModel
import OpenArcEngine

// Pluggable candidate sources. A source returns unranked candidates for the current query; the
// pure `CommandBarRanker` filters, orders and de-duplicates them. Sources never touch the network
// themselves: browsing history and web suggestions come from the engine (`EngineAutocomplete`,
// plan B66) through injected closures and providers.

/// A producer of command bar candidates.
public protocol CommandBarSource: Sendable {
    /// Returns candidates for the query. May return everything and let the ranker filter, but must
    /// be deterministic (sorted, no dictionary-order leaks). Should return promptly once its task
    /// is cancelled (the next keystroke cancels the previous query).
    func results(for context: CommandBarQueryContext) async -> [CommandBarResult]
    /// A slow source (network): the bar shows the other sources' rows first and merges these when
    /// they arrive (`CommandBarViewModel.refresh`). Default false.
    var isDeferred: Bool { get }
}

extension CommandBarSource {
    public var isDeferred: Bool { false }
}

// MARK: - Workspace tabs (open, pinned, favorite)

/// Tabs of the workspace: Today, pinned (in folders too) and favorites, across every Space of the
/// window's profile (plan B109, F4 live E2 observed 2026-10-29: the empty ⌘T bar lists open tabs of
/// every Space, labelled with their Space's name). Tabs of another profile's Spaces are left out
/// (inferred: profiles keep their browsing apart, [03 §Profiles]). The window's profile is the one
/// of `context.currentSpaceID`; with no known Space every tab is listed.
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
        let profileID = context.currentSpaceID.flatMap { state.profileID(ofSpace: $0) }
        let tabs = state.tabs.values
            .filter { !$0.meta.isTombstone && Self.belongs($0, to: profileID, in: state) }
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

    /// Whether a tab belongs to the window's profile: its Space's profile, or a favorite's own
    /// profile (both resolved to this device's profiles). nil profile: every tab.
    static func belongs(_ tab: TabNode, to profileID: UUID?, in state: WorkspaceState) -> Bool {
        guard let profileID else { return true }
        switch tab.location {
        case .favorite(let owner): return state.localProfileID(for: owner) == profileID
        case .pinned(let spaceID, _), .today(let spaceID): return state.profileID(ofSpace: spaceID) == profileID
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

// MARK: - Browsing history (plan B66)

/// Pages of the profile's browsing history that match the typed text (the engine's history, not
/// the sidebar: a page that was closed and never archived shows up too, F1 #2). Never listed for
/// an empty query ([04 §command bar] observed: the empty list is open tabs and an app command) and
/// never in an incognito window ([06 §20.1] observed: "no history"). Activating a row opens the
/// page like a typed URL (the current tab for ⌘L, a new tab for ⌘T).
public struct CommandBarHistorySource: CommandBarSource {
    /// Right-hand text of history rows. unknown (not shown in the spec); the archive rows' word.
    public static let openLabel = CommandBarArchiveSource.openLabel
    /// History rows asked from the engine per query. inferred (the five-row panel of
    /// [04 §command bar] leaves room for a few).
    public static let defaultMaxCount = 4

    private let matches: @Sendable (_ text: String, _ maxCount: Int) async -> [HistoryMatch]
    private let now: @Sendable () async -> Date
    private let maxCount: Int

    /// - Parameters:
    ///   - now: the clock frecency is measured against.
    ///   - matches: the engine's history query for the window's profile
    ///     (`EngineAutocomplete.historyMatches`).
    public init(
        maxCount: Int = CommandBarHistorySource.defaultMaxCount,
        now: @escaping @Sendable () async -> Date = { Date() },
        matches: @escaping @Sendable (_ text: String, _ maxCount: Int) async -> [HistoryMatch]
    ) {
        self.matches = matches
        self.now = now
        self.maxCount = maxCount
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let query = context.trimmedText
        // The incognito bar (whose empty list is help rows only) lists no history. [06 §20.1] observed.
        guard !query.isEmpty, !context.listsHelpOnlyWhenEmpty else { return [] }
        let found = await matches(query, maxCount)
        guard !Task.isCancelled else { return [] }
        let at = await now()
        return found.prefix(maxCount).enumerated().map { index, page in
            let host = CommandBarTextNormalizer.host(page.url)
            var row = CommandBarResult(
                id: "history:\(page.url.absoluteString)",
                kind: .historyItem,
                title: page.title.isEmpty ? (host ?? page.url.absoluteString) : page.title,
                subtitle: host,
                url: page.url,
                iconHint: .history,
                actionLabel: Self.openLabel,
                action: .openURL(page.url, target: context.mode.openTarget),
                completion: page.url.absoluteString,
                lastActiveAt: page.lastVisit,
                sourceOrder: index
            )
            row.frecency = page.frecency(at: at)
            return row
        }
    }
}

// MARK: - Most visited pages (plan B121)

/// The profile's most visited pages ("top sites", `EngineAutocomplete.topSites`) for an empty or
/// short query. [05 §command bar] inferred (analysis): the bar's results include most-visited pages;
/// where they go is not recorded, so the ranker places them after the open tabs and before the app
/// commands (inferred). Never in an incognito window (no history, [06 §20.1] observed). Activating
/// a row opens the page like a history row.
public struct CommandBarTopSitesSource: CommandBarSource {
    /// Right-hand text of most-visited rows. unknown (not shown in the spec); the history rows' word.
    public static let openLabel = CommandBarHistorySource.openLabel
    /// Longest typed query (in characters, trimmed) that still lists most-visited pages. inferred.
    public static let shortQueryMaxLength = 2
    /// Pages asked from the engine per query. inferred.
    public static let defaultMaxCount = 6

    private let sites: @Sendable (_ maxCount: Int) async -> [HistoryMatch]
    private let now: @Sendable () async -> Date
    private let maxCount: Int

    /// - Parameters:
    ///   - now: the clock frecency is measured against (ranks the rows of a short query).
    ///   - sites: the engine's most visited pages for the window's profile
    ///     (`EngineAutocomplete.topSites`).
    public init(
        maxCount: Int = CommandBarTopSitesSource.defaultMaxCount,
        now: @escaping @Sendable () async -> Date = { Date() },
        sites: @escaping @Sendable (_ maxCount: Int) async -> [HistoryMatch]
    ) {
        self.sites = sites
        self.now = now
        self.maxCount = maxCount
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        guard !context.listsHelpOnlyWhenEmpty, context.trimmedText.count <= Self.shortQueryMaxLength else { return [] }
        let found = await sites(maxCount)
        guard !Task.isCancelled else { return [] }
        let at = await now()
        return found.prefix(maxCount).enumerated().map { index, page in
            let host = CommandBarTextNormalizer.host(page.url)
            var row = CommandBarResult(
                id: "top-site:\(page.url.absoluteString)",
                kind: .topSite,
                title: page.title.isEmpty ? (host ?? page.url.absoluteString) : page.title,
                subtitle: host,
                url: page.url,
                iconHint: .site(faviconURL: nil),
                actionLabel: Self.openLabel,
                action: .openURL(page.url, target: context.mode.openTarget),
                completion: page.url.absoluteString,
                lastActiveAt: page.lastVisit,
                sourceOrder: index
            )
            row.frecency = page.frecency(at: at)
            return row
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

/// Supplies web search suggestions for a query: `CommandBarEngineSuggestionProvider` in the app,
/// `CommandBarStaticSuggestionProvider` in previews and tests.
public protocol CommandBarSuggestionProviding: Sendable {
    func suggestions(for query: String) async -> [String]
    /// The suggestions including the service's navigation rows (plan B128). Default: the phrases
    /// of `suggestions(for:)` as query rows.
    func completions(for query: String) async -> [SearchSuggestion]
}

extension CommandBarSuggestionProviding {
    public func completions(for query: String) async -> [SearchSuggestion] {
        await suggestions(for: query).map { SearchSuggestion(text: $0) }
    }
}

/// The engine's suggestions (`EngineAutocomplete.searchSuggestions`, plan B66) from the search
/// engine of the window's profile. `request` reads the window state at query time and answers nil
/// when the profile's "Include search engine suggestions" is off ([03 §Profiles] observed toggle),
/// so a settings change applies from the next keystroke.
public struct CommandBarEngineSuggestionProvider: CommandBarSuggestionProviding {
    private let autocomplete: any EngineAutocomplete
    private let request: @Sendable (_ query: String) async -> SearchSuggestionRequest?

    public init(
        autocomplete: any EngineAutocomplete,
        request: @escaping @Sendable (_ query: String) async -> SearchSuggestionRequest?
    ) {
        self.autocomplete = autocomplete
        self.request = request
    }

    public func suggestions(for query: String) async -> [String] {
        guard let request = await request(query), !Task.isCancelled else { return [] }
        return await autocomplete.searchSuggestions(request)
    }

    /// Query and navigation rows (`EngineAutocomplete.searchCompletions`, plan B128).
    public func completions(for query: String) async -> [SearchSuggestion] {
        guard let request = await request(query), !Task.isCancelled else { return [] }
        return await autocomplete.searchCompletions(request)
    }
}

/// Offline provider: phrases from a fixed list that contain the query (case-insensitive). For
/// previews and tests.
public struct CommandBarStaticSuggestionProvider: CommandBarSuggestionProviding {
    public var phrases: [String]
    /// Navigation rows: each one whose title or host starts with the query is answered after the
    /// matching phrases (plan B128).
    public var navigations: [SearchSuggestion]

    public init(phrases: [String], navigations: [SearchSuggestion] = []) {
        self.phrases = phrases
        self.navigations = navigations
    }

    public func suggestions(for query: String) async -> [String] {
        let folded = CommandBarTextNormalizer.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return [] }
        return phrases.filter { CommandBarTextNormalizer.fold($0).hasPrefix(folded) }
    }

    public func completions(for query: String) async -> [SearchSuggestion] {
        let folded = CommandBarTextNormalizer.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !folded.isEmpty else { return [] }
        let pages = navigations.filter { page in
            let host = page.url.flatMap(CommandBarTextNormalizer.host) ?? ""
            return CommandBarTextNormalizer.fold(page.text).contains(folded) || host.hasPrefix(folded)
        }
        return await suggestions(for: query).map { SearchSuggestion(text: $0) } + pages
    }
}

/// Web suggestion rows from an injected provider: magnifier glyph ([07 §9] observed row glyphs),
/// the suggestion as the title, "Search" on the right (unknown). Deferred by default: they come
/// over the network, so the other rows show first.
///
/// Navigation rows of the service (plan B128) become site rows: "Title — domain" with the site's
/// favicon, opening the page ([05 §命令栏] observed "National Weather Service — weather.gov" among
/// the query rows). One whose host starts with the typed text becomes the completing site row
/// (`siteCompletion`; [05 §命令栏] observed that a site whose host the typed text starts comes
/// first and completes inline; that a suggested site may be that row is inferred).
public struct CommandBarWebSuggestionsSource: CommandBarSource {
    private let provider: any CommandBarSuggestionProviding
    private let maxCount: Int
    public let isDeferred: Bool

    public init(provider: any CommandBarSuggestionProviding, maxCount: Int = 4, isDeferred: Bool = true) {
        self.provider = provider
        self.maxCount = maxCount
        self.isDeferred = isDeferred
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let query = context.trimmedText
        guard !query.isEmpty else { return [] }
        let suggestions = await provider.completions(for: query)
        guard !Task.isCancelled else { return [] }
        return suggestions.prefix(maxCount).enumerated().map { index, suggestion in
            if let url = suggestion.url {
                return CommandBarSiteRows.row(
                    id: "navigation:\(url.absoluteString)",
                    url: url,
                    title: suggestion.text,
                    typed: query,
                    strength: Self.navigationStrength,
                    sourceOrder: index,
                    target: context.mode.openTarget
                )
            }
            let text = suggestion.text
            return CommandBarResult(
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

    /// How well a navigation suggestion's site counts as known, against a visited site's frecency
    /// (0...1), when both complete the typed text. inferred.
    public static let navigationStrength = 0.5
}

// MARK: - Known sites (plan B128)

/// Site rows shared by the known-site source and the navigation suggestions.
enum CommandBarSiteRows {
    /// A site row: "Title — host" with the site's favicon ([05 §命令栏] observed), opening `url`.
    /// When `typed` is a proper prefix of the host it is the completing row (`siteCompletion`),
    /// whose Tab completion is the host; otherwise a plain `siteSuggestion`.
    static func row(
        id: String,
        url: URL,
        title: String,
        typed: String,
        strength: Double,
        sourceOrder: Int,
        target: CommandBarOpenTarget
    ) -> CommandBarResult {
        let host = CommandBarTextNormalizer.host(url) ?? url.absoluteString
        let completes = CommandBarSiteCompletionRules.completedHost(forTyped: typed, host: host) != nil
        var row = CommandBarResult(
            id: id,
            kind: completes ? .siteCompletion : .siteSuggestion,
            title: title.isEmpty ? host : title,
            subtitle: host,
            url: url,
            iconHint: .site(faviconURL: nil),
            actionLabel: CommandBarHistorySource.openLabel,
            action: .openURL(url, target: target),
            completion: completes ? host : url.absoluteString,
            sourceOrder: sourceOrder
        )
        row.frecency = min(max(strength, 0), 1)
        return row
    }
}

/// Sites the profile knows (its most visited pages and the history pages of the typed text) whose
/// host starts with the typed text: the completing site row, first in the list and completed
/// inline in the field ([05 §命令栏] observed 2026-10-30: "weather" → "Weather.com — weather.com"
/// first, ".com" completed in the field). Never in an incognito window (no history, [06 §20.1]
/// observed). Which pages count is inferred (`CommandBarKnownSites`).
public struct CommandBarKnownSitesSource: CommandBarSource {
    /// Pages asked from the engine per query. inferred.
    public static let defaultMaxCount = 12

    private let pages: @Sendable (_ text: String, _ maxCount: Int) async -> [CommandBarSiteCandidate]
    private let maxCount: Int

    /// - Parameter pages: the window profile's known sites for the typed text
    ///   (`CommandBarKnownSites.candidates` over the engine's most visited and history pages).
    public init(
        maxCount: Int = CommandBarKnownSitesSource.defaultMaxCount,
        pages: @escaping @Sendable (_ text: String, _ maxCount: Int) async -> [CommandBarSiteCandidate]
    ) {
        self.pages = pages
        self.maxCount = maxCount
    }

    public func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
        let typed = context.trimmedText
        guard typed.count >= CommandBarSiteCompletionRules.minimumPrefixLength, !context.listsHelpOnlyWhenEmpty else { return [] }
        let candidates = await pages(typed, maxCount)
        guard !Task.isCancelled,
              let best = CommandBarSiteCompletionRules.bestCandidate(forTyped: typed, candidates: candidates) else { return [] }
        return [CommandBarSiteRows.row(
            id: "site:\(best.candidate.url.absoluteString)",
            url: best.candidate.url,
            title: best.candidate.title,
            typed: typed,
            strength: best.candidate.strength,
            sourceOrder: best.candidate.sourceOrder,
            target: context.mode.openTarget
        )]
    }
}

/// The default set of sources for a workspace. `commandState` is the window state the command and
/// space rows depend on; the default offers every command and no move rows. `history` is the
/// engine's history source (nil: no history rows); `topSites` its most-visited source (nil: none);
/// `knownSites` the completing site row's source (nil: none, plan B128); `suggestions` the web
/// suggestion provider (its navigation rows are site rows).
public func commandBarDefaultSources(
    workspace: @escaping @Sendable () async -> WorkspaceState,
    commandState: @escaping @Sendable () async -> CommandBarCommandState = { .everything },
    history: CommandBarHistorySource? = nil,
    topSites: CommandBarTopSitesSource? = nil,
    knownSites: CommandBarKnownSitesSource? = nil,
    suggestions: any CommandBarSuggestionProviding = CommandBarStaticSuggestionProvider(phrases: []),
    suggestionsAreDeferred: Bool = false
) -> [any CommandBarSource] {
    var sources: [any CommandBarSource] = [
        CommandBarWorkspaceTabsSource(workspace: workspace),
        CommandBarArchiveSource(workspace: workspace),
    ]
    if let history { sources.append(history) }
    if let topSites { sources.append(topSites) }
    if let knownSites { sources.append(knownSites) }
    sources += [
        CommandBarCommandsSource(state: commandState),
        CommandBarSpacesSource(workspace: workspace, state: commandState),
        CommandBarTypedInputSource(),
        CommandBarWebSuggestionsSource(provider: suggestions, isDeferred: suggestionsAreDeferred),
    ]
    return sources
}
