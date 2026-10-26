import XCTest
import OpenArcModel
@testable import OpenArcShell

/// Ranking and sources. [04 §command bar] observed: with no input the list is open tabs followed
/// by an app command (Contact the Team); [05 §command bar] observed: open tabs come first as
/// "Switch to Tab". All score tiers and tie-breaks are INFERRED (the spec only shows the UI).
final class CommandBarRankingTests: XCTestCase {
    private func context(_ text: String, mode: CommandBarMode = .newTab, current: UUID? = nil, space: UUID? = nil) -> CommandBarQueryContext {
        CommandBarQueryContext(text: text, mode: mode, currentSpaceID: space, currentTabID: current)
    }

    private func candidates(_ world: CommandBarFixtures.World, text: String, mode: CommandBarMode = .newTab) async -> [CommandBarResult] {
        let ctx = context(text, mode: mode)
        let ws = world.workspace
        var out: [CommandBarResult] = []
        for source in commandBarDefaultSources(
            workspace: { ws },
            suggestions: CommandBarStaticSuggestionProvider(phrases: ["swift concurrency", "swiftui lists", "Swift"])
        ) {
            out += await source.results(for: ctx)
        }
        return out
    }

    private func titles(_ results: [CommandBarResult]) -> [String] { results.map(\.title) }

    // MARK: Empty query

    /// [04 §command bar] observed: five rows, open tabs first, an app command last.
    func testEmptyQueryListsOpenTabsThenContactTheTeam() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "")
        let ranked = CommandBarRanker.rank(all, context: context("", space: world.homeSpace))
        XCTAssertEqual(ranked.count, 5)
        XCTAssertTrue(ranked.prefix(4).allSatisfy { $0.kind.isTab })
        XCTAssertEqual(ranked.last?.action, .runCommand(.contactTheTeam))
        XCTAssertNil(ranked.last?.actionLabel, "[06 §6] app commands have no action label")
        XCTAssertTrue(ranked.prefix(4).allSatisfy { $0.actionLabel == "Switch to Tab" })
    }

    /// Inferred: most recent first, current space before other spaces, the viewed tab is skipped.
    func testEmptyQueryOrdersByRecencyAndSkipsCurrentTab() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "")
        let current = world.tabIDs["Another Tab"]
        let ranked = CommandBarRanker.rank(all, context: context("", current: current, space: world.homeSpace))
        XCTAssertEqual(titles(ranked), ["Example News", "GitHub", "Apple Developer Documentation", "Swift.org", "Contact the Team"])
        XCTAssertFalse(titles(ranked).contains("Jira Board"), "other-space tab ranks after the current space and falls off the 4-tab limit")
    }

    // MARK: Text matching tiers (inferred)

    /// [05 §command bar] ranking tiers, inferred.
    func testExactTitleBeatsPrefixBeatsSubstring() {
        let exact = CommandBarRanker.textScore(query: "github", title: "GitHub", url: nil)
        let prefix = CommandBarRanker.textScore(query: "git", title: "GitHub", url: nil)
        let word = CommandBarRanker.textScore(query: "hub", title: "My Hub Page", url: nil)
        let substring = CommandBarRanker.textScore(query: "hub", title: "GitHub", url: nil)
        XCTAssertEqual(exact, 1000)
        XCTAssertGreaterThan(exact!, prefix!)
        XCTAssertGreaterThan(prefix!, word!)
        XCTAssertGreaterThan(word!, substring!)
        XCTAssertNil(CommandBarRanker.textScore(query: "zzz", title: "GitHub", url: URL(string: "https://github.com")))
    }

    /// [05 §command bar] ranking: exact URL tier, inferred.
    func testExactURLAndHostMatchIgnoresSchemeWwwAndTrailingSlash() {
        let url = URL(string: "https://www.swift.org/")
        XCTAssertEqual(CommandBarRanker.textScore(query: "swift.org", title: "Welcome", url: url), 950)
        XCTAssertEqual(CommandBarRanker.textScore(query: "https://swift.org", title: "Welcome", url: url), 950)
        XCTAssertEqual(CommandBarRanker.textScore(query: "swift.org/", title: "Welcome", url: url), 950)
    }

    /// [05 §command bar] ranking, inferred.
    func testMatchingIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(CommandBarRanker.textScore(query: "CAFE", title: "Café", url: nil), 1000)
    }

    /// [05 §command bar] ranking: multi-word queries, inferred.
    func testAllTokensMatchWhenWordsAreSplitAcrossTitleAndURL() {
        XCTAssertNotNil(CommandBarRanker.textScore(query: "developer documentation", title: "Apple Developer Documentation", url: nil))
        XCTAssertNotNil(CommandBarRanker.textScore(query: "apple documentation", title: "Docs", url: URL(string: "https://developer.apple.com/documentation")))
        XCTAssertNil(CommandBarRanker.textScore(query: "apple recipes", title: "Docs", url: URL(string: "https://developer.apple.com/documentation")))
    }

    /// [05 §command bar] open tabs first (observed); exact URL on top (inferred).
    func testExactURLTabIsFirst() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "github.com")
        let ranked = CommandBarRanker.rank(all, context: context("github.com", space: world.homeSpace))
        XCTAssertEqual(ranked.first?.title, "GitHub")
        XCTAssertEqual(ranked.first?.action, .switchToTab(tabID: world.tabIDs["GitHub"]!))
    }

    /// A typed URL that no tab owns is offered ahead of prefix matches; a tab with that URL replaces the row.
    func testTypedURLRankingAndDeduplication() async throws {
        let world = try CommandBarFixtures.world()
        var all = await candidates(world, text: "example.com")
        var ranked = CommandBarRanker.rank(all, context: context("example.com", space: world.homeSpace))
        XCTAssertEqual(ranked.first?.kind, .typedURL)
        XCTAssertEqual(ranked.first?.action, .openURL(URL(string: "https://example.com")!, target: .newTab))

        all = await candidates(world, text: "news.example.com")
        ranked = CommandBarRanker.rank(all, context: context("news.example.com", space: world.homeSpace))
        XCTAssertEqual(ranked.first?.title, "Example News")
        XCTAssertFalse(ranked.contains { $0.kind == .typedURL }, "typed URL collapses into the open tab")
    }

    /// [05 §command bar] archived candidates, inferred.
    func testArchivedItemOnlyAppearsForQueriesAndRanksBelowOpenTabs() async throws {
        let world = try CommandBarFixtures.world()
        let empty = CommandBarRanker.rank(await candidates(world, text: ""), context: context("", space: world.homeSpace))
        XCTAssertFalse(empty.contains { $0.kind == .archivedItem })

        let all = await candidates(world, text: "recipe")
        let ranked = CommandBarRanker.rank(all, context: context("recipe", space: world.homeSpace))
        let archived = try XCTUnwrap(ranked.first { $0.kind == .archivedItem })
        XCTAssertEqual(archived.title, "Old Recipe")
        // Activating an archived row restores it instead of only opening the URL. inferred, B4.
        XCTAssertEqual(archived.action, .restoreArchived(itemID: try XCTUnwrap(world.tabIDs["Old Recipe"])))
    }

    /// [05 §command bar] de-duplication, inferred.
    func testArchivedDuplicateOfOpenTabIsDropped() throws {
        let url = URL(string: "https://dup.example.com/a")!
        let tab = CommandBarResult(id: "tab:1", kind: .todayTab, title: "Dup", url: url, iconHint: .globe, actionLabel: "Switch to Tab", action: .switchToTab(tabID: UUID()))
        let archived = CommandBarResult(id: "archive:1", kind: .archivedItem, title: "Dup", url: URL(string: "http://www.dup.example.com/a/")!, iconHint: .archive, actionLabel: "Open", action: .openURL(url, target: .newTab))
        let ranked = CommandBarRanker.rank([archived, tab], context: context("dup"))
        XCTAssertEqual(ranked.map(\.id), ["tab:1"])
    }

    /// [05 §command bar] pinned tabs are open tabs ("Switch to Tab", observed).
    func testPinnedAndFavoriteTabsAreSwitchToTabRows() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "swift")
        let ranked = CommandBarRanker.rank(all, context: context("swift", space: world.homeSpace))
        let swiftTab = try XCTUnwrap(ranked.first { $0.title == "Swift.org" })
        XCTAssertEqual(swiftTab.kind, .pinnedTab)
        XCTAssertEqual(swiftTab.action, .switchToTab(tabID: world.tabIDs["Swift.org"]!))
    }

    /// Observed: open tabs come before other candidates. Here an open tab and a command both match a prefix.
    func testTabsComeBeforeCommandsOfComparableMatchQuality() async throws {
        let world = try CommandBarFixtures.world()
        var ws = world.workspace
        let id = UUID()
        ws = try TreeOps.openTab(ws, id: id, spaceID: world.homeSpace, url: URL(string: "https://lib.example.com"), title: "Library notes", now: CommandBarFixtures.base)
        let source = CommandBarWorkspaceTabsSource(workspace: ws)
        let ctx = context("library", space: world.homeSpace)
        let all = await source.results(for: ctx) + (await CommandBarCommandsSource().results(for: ctx))
        let ranked = CommandBarRanker.rank(all, context: ctx)
        XCTAssertEqual(ranked.first?.title, "Library notes")
        XCTAssertEqual(ranked.dropFirst().first?.action, .runCommand(.openLibrary))
    }

    /// [06 §6] app commands (observed); keyword search inferred.
    func testCommandsMatchByKeyword() async {
        let ctx = context("reopen")
        let ranked = CommandBarRanker.rank(await CommandBarCommandsSource().results(for: ctx), context: ctx)
        XCTAssertEqual(ranked.first?.action, .runCommand(.restoreLastClosedTab))
    }

    /// [CLAUDE.md] AI features and ChatGPT are out of scope for v1.
    func testCommandsContainNoAIFeatures() {
        for command in CommandBarCommand.allCases {
            let text = (command.title + " " + command.keywords.joined(separator: " ")).lowercased()
            XCTAssertFalse(text.contains("chatgpt"), command.title)
            XCTAssertFalse(text.contains("max"), command.title)
            XCTAssertFalse(text.split(separator: " ").contains("ai"), command.title)
        }
    }

    /// [05 §command bar] search row position, inferred.
    func testSearchRowSitsBelowPrefixMatchesAndAboveSubstringMatches() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "git")
        let ranked = CommandBarRanker.rank(all, context: context("git", space: world.homeSpace))
        let kinds = ranked.map(\.kind)
        let searchIndex = try XCTUnwrap(kinds.firstIndex(of: .webSearch))
        XCTAssertEqual(ranked.first?.title, "GitHub")
        XCTAssertLessThan(try XCTUnwrap(ranked.firstIndex { $0.title == "GitHub" }), searchIndex)
    }

    /// [05 §command bar] web suggestions, inferred.
    func testSuggestionsEqualToQueryAreDroppedAndOrderIsKept() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "swift")
        let ranked = CommandBarRanker.rank(all, context: context("swift", space: world.homeSpace))
        let suggestions = ranked.filter { $0.kind == .searchSuggestion }.map(\.title)
        XCTAssertEqual(suggestions, ["swift concurrency", "swiftui lists"], "'Swift' equals the query and is covered by the search row")
    }

    /// [05 §command bar] single entry for search (observed); row order inferred.
    func testSearchOnlyQueryPutsSearchRowFirst() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "purple elephants")
        let ranked = CommandBarRanker.rank(all, context: context("purple elephants", space: world.homeSpace))
        XCTAssertEqual(ranked.first?.kind, .webSearch)
        XCTAssertEqual(ranked.first?.action, .searchWeb(query: "purple elephants", target: .newTab))
    }

    /// [05 §command bar] ranking determinism, inferred.
    func testRankingIsDeterministicForShuffledInput() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "e")
        let ctx = context("e", space: world.homeSpace)
        let expected = CommandBarRanker.rank(all, context: ctx).map(\.id)
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5 {
            XCTAssertEqual(CommandBarRanker.rank(all.shuffled(using: &generator), context: ctx).map(\.id), expected)
        }
    }

    /// [04 §command bar] result count limit, inferred.
    func testLimitIsApplied() async throws {
        let world = try CommandBarFixtures.world()
        let all = await candidates(world, text: "e")
        XCTAssertLessThanOrEqual(CommandBarRanker.rank(all, context: context("e"), limit: 3).count, 3)
    }

    // MARK: Sources

    /// [05 §command bar] open tabs source, inferred ordering.
    func testWorkspaceSourceSkipsTombstonesAndIsSortedByRecency() async throws {
        let world = try CommandBarFixtures.world()
        let results = await CommandBarWorkspaceTabsSource(workspace: world.workspace).results(for: context(""))
        XCTAssertFalse(results.contains { $0.title == "Old Recipe" }, "archived (tombstoned) tab is not an open tab")
        let dates = results.compactMap(\.lastActiveAt)
        XCTAssertEqual(dates, dates.sorted(by: >))
        XCTAssertEqual(results.first { $0.title == "Jira Board" }?.spaceName, "Work")
    }

    /// [06 §6] observed: inside a pane the right-hand text is the owning space name.
    func testPaneShowsSpaceNameInsteadOfActionLabel() async throws {
        let world = try CommandBarFixtures.world()
        let results = await CommandBarWorkspaceTabsSource(workspace: world.workspace).results(for: context(""))
        let jira = try XCTUnwrap(results.first { $0.title == "Jira Board" })
        XCTAssertEqual(jira.trailingLabel(for: .pane), "Work")
        XCTAssertEqual(jira.trailingLabel(for: .window), "Switch to Tab")
        let command = CommandBarResult(id: "c", kind: .command, title: "x", iconHint: .command, actionLabel: nil, action: .runCommand(.newFolder))
        XCTAssertNil(command.trailingLabel(for: .pane))
    }

    /// [05 §command bar] injected suggestion provider (fake), inferred.
    func testStaticSuggestionProviderMatchesPrefixCaseInsensitively() async {
        let provider = CommandBarStaticSuggestionProvider(phrases: ["Swift Concurrency", "rust", "swiftui"])
        let found = await provider.suggestions(for: "SWIFT")
        XCTAssertEqual(found, ["Swift Concurrency", "swiftui"])
        let none = await provider.suggestions(for: "  ")
        XCTAssertEqual(none, [])
    }
}

// MARK: - Shared fixtures (also used by CommandBarViewModelTests)

/// Shared fixtures for the command bar tests.
enum CommandBarFixtures {
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    struct World {
        var workspace: WorkspaceState
        var homeSpace: UUID
        var workSpace: UUID
        /// Titles → tab ids.
        var tabIDs: [String: UUID]
    }

    /// Two spaces. Tabs (newest first by their `now`):
    /// Home: Swift.org (pinned), Apple Docs, GitHub, Example News; Work: Jira Board. Plus one archived item.
    static func world() throws -> World {
        var s = WorkspaceState()
        let profile = UUID(), home = UUID(), work = UUID(), folder = UUID()
        s.profiles[profile] = Profile(id: profile, name: "Default", now: base)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", themeID: nil, now: base)
        s = try TreeOps.createSpace(s, id: work, profileID: profile, name: "Work", themeID: nil, now: base)
        s = try TreeOps.createFolder(s, id: folder, spaceID: home, title: "Reading", now: base)
        var ids: [String: UUID] = [:]
        func add(_ title: String, _ url: String, space: UUID, minutesAgo: Double, pinned: Bool = false) throws {
            let id = UUID()
            let at = base.addingTimeInterval(-minutesAgo * 60)
            s = try TreeOps.openTab(s, id: id, spaceID: space, url: URL(string: url), title: title, now: at)
            if pinned { s = try TreeOps.pinTab(s, id: id, now: at) }
            s.tabs[id]?.lastActiveAt = at
            ids[title] = id
        }
        try add("Swift.org", "https://www.swift.org/", space: home, minutesAgo: 50, pinned: true)
        try add("Apple Developer Documentation", "https://developer.apple.com/documentation", space: home, minutesAgo: 40)
        try add("GitHub", "https://github.com/", space: home, minutesAgo: 30)
        try add("Example News", "https://news.example.com/", space: home, minutesAgo: 20)
        try add("Jira Board", "https://jira.example.com/board", space: work, minutesAgo: 10)
        try add("Old Recipe", "https://recipes.example.net/pie", space: home, minutesAgo: 5)
        try add("Another Tab", "https://another.example.org/", space: home, minutesAgo: 1)
        s = try TreeOps.archiveTab(s, id: ids["Old Recipe"]!, now: base)
        return World(workspace: s, homeSpace: home, workSpace: work, tabIDs: ids)
    }

    /// A view model over the fixture world with static web suggestions.
    @MainActor
    static func viewModel(
        _ world: World,
        mode: CommandBarMode = .newTab,
        presentation: CommandBarPresentation = .window,
        currentTab: String? = nil,
        suggestions: [String] = ["swift concurrency", "swiftui lists"]
    ) -> CommandBarViewModel {
        let workspace = world.workspace
        let model = CommandBarViewModel(
            sources: commandBarDefaultSources(
                workspace: { workspace },
                suggestions: CommandBarStaticSuggestionProvider(phrases: suggestions)
            ),
            mode: mode,
            presentation: presentation,
            currentSpaceID: world.homeSpace,
            currentTabID: currentTab.flatMap { world.tabIDs[$0] }
        )
        return model
    }

    /// Runs `open` and waits for the first result list.
    @MainActor
    static func open(_ model: CommandBarViewModel, world: World, mode: CommandBarMode, currentTab: String? = nil) async {
        let tab = currentTab.flatMap { world.tabIDs[$0] }
        let url = currentTab.flatMap { world.workspace.tabs[world.tabIDs[$0]!]?.url }
        model.open(mode: mode, currentURL: url, currentTabID: tab, currentSpaceID: world.homeSpace)
        await model.waitForRefresh()
    }

    @MainActor
    static func type(_ model: CommandBarViewModel, _ text: String) async {
        model.queryText = text
        await model.waitForRefresh()
    }
}
