import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B66 (F1 review #2, #3): browsing history and search suggestions in the command bar, with a
/// FakeEngine behind `EngineAutocomplete`.
/// Spec: docs/arc-spec/05-surfaces.md §command bar (observed: one entry for new tabs, search and
/// commands; open tabs first as "Switch to Tab"), 04-visual-metrics.md §command bar (observed:
/// the empty list is open tabs and an app command), 07-design-system.md §3 / §9 (observed: rows
/// "title — host", glyphs globe / magnifier / clock), 06-flows.md §16.2, §19.1, §23 (observed: a
/// word without a matching command lists search suggestions), §20.1 (observed: incognito bar has no
/// history), 03-settings.md §Profiles (observed: "Search engine", "Include search engine
/// suggestions"). Row order beyond "open tabs first" is inferred.
@MainActor
final class CommandBarHistorySuggestionsTests: XCTestCase {
    private var engine: FakeEngine!
    private var controller: WorkspaceController!
    private var shell: ShellModel!
    private let f = SidebarFixture()

    override func setUp() async throws {
        let now = f.now.addingTimeInterval(10)
        engine = FakeEngine(clock: { now })
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { now },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        shell = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        shell.sidebar.selectSpace(f.home)
    }

    override func tearDown() async throws {
        shell.stop()
        controller.stop()
        shell = nil
        controller = nil
        engine = nil
    }

    private var autocomplete: FakeAutocomplete { engine.fakeAutocomplete }
    private let day: TimeInterval = 86_400

    private func type(_ text: String, in bar: CommandBarViewModel? = nil) async {
        let bar = bar ?? shell.commandBar
        bar.queryText = text
        await bar.waitForRefresh()
    }

    // MARK: History

    /// F1 #2 acceptance: a page visited yesterday, closed and not archived, appears when typing
    /// its title. Row style: clock glyph, "title — host" ([07 §3] observed two-part row), "Open"
    /// on the right (unknown wording), Enter opens it in a new tab for ⌘T.
    func testPageVisitedYesterdayAppearsByTitle() async throws {
        let url = try XCTUnwrap(URL(string: "https://www.kernel.org/doc/html/latest/"))
        autocomplete.addVisit(url: url, title: "The Linux Kernel documentation", profileID: f.profile, at: f.now.addingTimeInterval(-day))
        shell.presentCommandBar(.newTab)
        await type("linux kernel")
        let row = try XCTUnwrap(shell.commandBar.results.first { $0.kind == .historyItem })
        XCTAssertEqual(row.title, "The Linux Kernel documentation")
        XCTAssertEqual(row.subtitle, "kernel.org")
        XCTAssertEqual(row.iconHint, .history)
        XCTAssertEqual(row.actionLabel, CommandBarHistorySource.openLabel)
        XCTAssertEqual(row.action, .openURL(url, target: .newTab))
        XCTAssertEqual(autocomplete.historyQueries.last, "linux kernel")

        // ⌘L routes the same row to the current tab.
        shell.presentCommandBar(.currentTab)
        await type("linux kernel")
        XCTAssertEqual(shell.commandBar.results.first { $0.kind == .historyItem }?.action, .openURL(url, target: .currentTab))
    }

    /// [04 §command bar] observed: the empty list is open tabs and an app command, no history.
    func testEmptyQueryListsNoHistory() async throws {
        autocomplete.addVisit(url: try XCTUnwrap(URL(string: "https://swift.org/")), title: "Swift", profileID: f.profile)
        shell.presentCommandBar(.newTab)
        await shell.commandBar.waitForRefresh()
        XCTAssertFalse(shell.commandBar.results.contains { $0.kind == .historyItem })
        XCTAssertEqual(shell.commandBar.results.last?.action, .runCommand(.contactTheTeam))
    }

    /// Navigations of the window's own tabs land in the history (FakeEngine records them) and a
    /// page that is still open is offered as "Switch to Tab", not again as history.
    func testOpenTabWinsOverItsHistoryRow() async throws {
        _ = shell.sidebar.newTab(url: URL(string: "https://swiftpackageindex.com/"), title: "Swift Package Index")
        await shell.sidebar.settleEngineWork()
        XCTAssertFalse(autocomplete.history(profileID: f.profile).isEmpty, "the engine recorded the visit")
        shell.presentCommandBar(.newTab)
        await type("swiftpackageindex")
        let kinds = shell.commandBar.results.filter { $0.url?.host == "swiftpackageindex.com" }.map(\.kind)
        XCTAssertEqual(kinds, [.todayTab], "[05 §command bar] the open tab, once")
    }

    /// The order: open tabs, then history pages ahead of the engine's suggestions, which keep the
    /// engine's order and come last ([05 §command bar] observed open tabs first; rest inferred).
    func testOrderTabsHistorySuggestions() async throws {
        autocomplete.addPage(HistoryMatch(url: try XCTUnwrap(URL(string: "https://today9.example.net/guide")), title: "today9 guide",
                                          lastVisit: f.now.addingTimeInterval(-2 * day), visitCount: 5), profileID: f.profile)
        autocomplete.suggestionProvider = { request in ["\(request.query) weather", "\(request.query) news"] }
        shell.presentCommandBar(.newTab)
        await type("today")
        let results = shell.commandBar.results
        let kinds = results.map(\.kind)
        XCTAssertTrue(kinds.first?.isTab == true, "open tabs first: \(kinds)")
        let history = try XCTUnwrap(kinds.firstIndex(of: .historyItem))
        let suggestions = results.indices.filter { results[$0].kind == .searchSuggestion }
        // B128: the visited host "today9.example.net" also completes "today" (a site row after the
        // tabs), so the eight-row list may cut the last suggestion; the shown ones keep the order.
        XCTAssertEqual(results.first { $0.kind == .siteCompletion }?.subtitle, "today9.example.net")
        let shown = suggestions.map { results[$0].title }
        XCTAssertFalse(shown.isEmpty)
        XCTAssertEqual(shown, Array(["today weather", "today news"].prefix(shown.count)), "engine order")
        XCTAssertTrue(suggestions.allSatisfy { $0 > history }, "history before suggestions: \(kinds)")
        XCTAssertTrue(results.suffix(suggestions.count).allSatisfy { $0.kind == .searchSuggestion }, "suggestions last")
        let lastTab = try XCTUnwrap(kinds.lastIndex { $0.isTab })
        XCTAssertLessThan(lastTab, history)
        // Suggestion rows: magnifier glyph, "Search" on the right, Enter searches with the engine.
        let suggestion = results[suggestions[0]]
        XCTAssertEqual(suggestion.iconHint, .search)
        XCTAssertEqual(suggestion.actionLabel, CommandBarTypedInputSource.searchLabel)
        XCTAssertEqual(suggestion.action, .searchWeb(query: "today weather", target: .newTab))
    }

    /// Ranking unit (inferred): a history page ranks below an open tab of the same match, rises
    /// with frecency, and stays above suggestions even for a weak match.
    func testHistoryScoreTiers() {
        let context = CommandBarQueryContext(text: "swift", mode: .newTab)
        func history(_ title: String, frecency: Double) -> CommandBarResult {
            var row = CommandBarResult(id: "history:\(title)", kind: .historyItem, title: title, url: URL(string: "https://h.example/\(title.count)"),
                                       iconHint: .history, actionLabel: "Open", action: .openURL(URL(string: "https://h.example")!, target: .newTab))
            row.frecency = frecency
            return row
        }
        let tab = CommandBarResult(id: "tab:1", kind: .todayTab, title: "Swift Forums", url: URL(string: "https://forums.swift.org"),
                                   iconHint: .site(faviconURL: nil), actionLabel: "Switch to Tab", action: .switchToTab(tabID: UUID()))
        let suggestion = CommandBarResult(id: "suggestion:0:swiftly", kind: .searchSuggestion, title: "swiftly", iconHint: .search,
                                          actionLabel: "Search", action: .searchWeb(query: "swiftly", target: .newTab))
        let hot = history("Swift Blog", frecency: 1)
        let cold = history("Swift Book", frecency: 0)
        let weak = history("Taylor — about swift birds", frecency: 0)
        let ranked = CommandBarRanker.rank([suggestion, weak, cold, hot, tab], context: context).map(\.id)
        XCTAssertEqual(ranked, [tab.id, hot.id, cold.id, weak.id, suggestion.id])
    }

    /// [06 §20.1] observed: the incognito bar lists no history, even for a matching page.
    func testIncognitoBarHasNoHistory() async throws {
        autocomplete.addVisit(url: try XCTUnwrap(URL(string: "https://swift.org/")), title: "Swift", profileID: f.profile)
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        defer { incognito.stop() }
        await type("swift", in: incognito.commandBar)
        XCTAssertFalse(incognito.commandBar.results.contains { $0.kind == .historyItem })
        XCTAssertTrue(autocomplete.historyQueries.isEmpty, "the incognito bar never asks the history")
    }

    // MARK: Suggestions

    /// F1 #3 acceptance: typing lists the engine's suggestions, asked of the profile's search
    /// engine ([03 §Profiles] observed "Search engine"); switching the engine changes the endpoint.
    func testSuggestionsComeFromTheProfilesSearchEngine() async throws {
        autocomplete.suggestionProvider = { request in ["\(request.query) tutorial", "\(request.query) ui"] }
        shell.presentCommandBar(.newTab)
        await type("swift")
        XCTAssertEqual(shell.commandBar.results.filter { $0.kind == .searchSuggestion }.map(\.title), ["swift tutorial", "swift ui"])
        let request = try XCTUnwrap(autocomplete.suggestionRequests.last)
        XCTAssertEqual(request.urlTemplate, SearchEngine.google.suggestURLTemplate)
        XCTAssertEqual(request.profileID, f.profile)
        XCTAssertFalse(request.isOffTheRecord)

        var settings = shell.currentProfileSettings
        settings.searchEngine = .duckDuckGo
        XCTAssertTrue(shell.sidebar.updateProfileSettings(f.profile, settings))
        await type("swifty")
        XCTAssertEqual(autocomplete.suggestionRequests.last?.urlTemplate, SearchEngine.duckDuckGo.suggestURLTemplate)
    }

    /// [03 §Profiles] observed "Include search engine suggestions": off asks nothing and lists no
    /// suggestion rows; history stays.
    func testSuggestionsToggleOffRemovesThem() async throws {
        autocomplete.suggestionProvider = { _ in ["swift tutorial"] }
        autocomplete.addVisit(url: try XCTUnwrap(URL(string: "https://swift.org/")), title: "Swift", profileID: f.profile)
        let settingsModel = SettingsModel(shell: controller.appHost())
        settingsModel.selectedProfileID = f.profile
        XCTAssertTrue(settingsModel.includesSearchSuggestions, "default on")
        settingsModel.includesSearchSuggestions = false
        XCTAssertFalse(shell.currentProfileSettings.includesSearchSuggestions)
        shell.presentCommandBar(.newTab)
        await type("swift")
        XCTAssertFalse(shell.commandBar.results.contains { $0.kind == .searchSuggestion })
        // B128: the visited swift.org is the completing site row (one row per page).
        XCTAssertTrue(shell.commandBar.results.contains { [.historyItem, .siteCompletion].contains($0.kind) && $0.url?.host == "swift.org" })
        XCTAssertTrue(autocomplete.suggestionRequests.isEmpty)
    }

    /// Incognito suggestions (inferred): the parent profile's engine and toggle, sent through the
    /// off-the-record context.
    func testIncognitoSuggestionsGoOffTheRecord() async throws {
        autocomplete.suggestionProvider = { _ in ["swift tutorial"] }
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        defer { incognito.stop() }
        await type("swift", in: incognito.commandBar)
        XCTAssertEqual(incognito.commandBar.results.filter { $0.kind == .searchSuggestion }.map(\.title), ["swift tutorial"])
        XCTAssertEqual(autocomplete.suggestionRequests.last?.isOffTheRecord, true)
    }

    /// Suggestions come over the network: the other rows show at once, and the next keystroke
    /// cancels the pending request (async, cancellable).
    func testSlowSuggestionsDoNotHoldUpRowsAndAreCancelled() async throws {
        autocomplete.suggestionProvider = { _ in ["late suggestion"] }
        autocomplete.suggestionDelay = .seconds(60)
        shell.presentCommandBar(.newTab)
        await shell.commandBar.waitForRefresh()
        shell.commandBar.queryText = "today"
        var spins = 0
        while (shell.commandBar.results.isEmpty || autocomplete.suggestionRequests.isEmpty) && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(shell.commandBar.results.contains { $0.kind.isTab }, "local rows are shown first")
        XCTAssertFalse(shell.commandBar.results.contains { $0.kind == .searchSuggestion })

        autocomplete.suggestionDelay = .zero
        await type("today1")
        spins = 0
        while autocomplete.cancelledSuggestionCount == 0 && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        XCTAssertEqual(autocomplete.cancelledSuggestionCount, 1, "the superseded request was cancelled")
        XCTAssertEqual(shell.commandBar.results.filter { $0.kind == .searchSuggestion }.map(\.title), ["late suggestion"])
    }

    /// An engine without the capabilities (a Chromium framework from before B66) degrades to no
    /// history and no suggestions; the rest of the bar works.
    func testEngineWithoutAutocompleteDegrades() async {
        autocomplete.capabilities = []
        autocomplete.suggestionProvider = { _ in ["swift tutorial"] }
        autocomplete.addVisit(url: URL(string: "https://swift.org/")!, title: "Swift", profileID: f.profile)
        shell.presentCommandBar(.newTab)
        await type("swift")
        XCTAssertFalse(shell.commandBar.results.contains { $0.kind == .historyItem || $0.kind == .searchSuggestion })
        XCTAssertTrue(shell.commandBar.results.contains { $0.kind == .webSearch })
    }

    /// Little Arc's bar has the same sources.
    func testLittleArcBarListsHistoryAndSuggestions() async throws {
        autocomplete.suggestionProvider = { _ in ["swift tutorial"] }
        autocomplete.addVisit(url: try XCTUnwrap(URL(string: "https://swift.org/")), title: "Swift", profileID: f.profile)
        let little = LittleArcModel(shell: shell)
        await type("swift", in: little.commandBar)
        // B128: the visited swift.org shows as the completing site row (one row per page).
        XCTAssertTrue(little.commandBar.results.contains { [.historyItem, .siteCompletion].contains($0.kind) && $0.url?.host == "swift.org" })
        XCTAssertTrue(little.commandBar.results.contains { $0.kind == .searchSuggestion })
    }
}
