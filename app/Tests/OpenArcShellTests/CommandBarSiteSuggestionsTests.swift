import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B128: site rows, navigation suggestions and the inline completion of the command bar.
///
/// Spec: docs/arc-spec/05-surfaces.md §命令栏 and 07-design-system.md §5 (Arc observed 2026-10-30,
/// "weather" typed into ⌘T in a Space with no picked color):
///   - the field completes inline, "weather" with ".com" selected after it, and the leading glyph
///     is the site's favicon;
///   - the first row is that site, "Weather.com — weather.com", highlighted;
///   - the second row is the plain search "weather";
///   - the navigation suggestion "National Weather Service — weather.gov" sits among the query
///     suggestions "weather radar" and "weather tomorrow";
///   - ↓ moves to the search row: the completion goes away and the glyph is the magnifier again.
/// Typing replaces the completion, Backspace removes it, Return opens the site (task statement,
/// observed). Every score, threshold and tie-break is inferred.
@MainActor
final class CommandBarSiteSuggestionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let weatherCom = URL(string: "https://weather.com/")!
    private let weatherGov = URL(string: "https://www.weather.gov/")!

    // MARK: Fixtures

    /// The observed answer of the search service for "weather": two query rows around a
    /// navigation row ([05 §命令栏] observed order of the rows below the search row).
    private var observedSuggestions: CommandBarStaticSuggestionProvider {
        CommandBarStaticSuggestionProvider(
            phrases: ["weather radar"],
            navigations: [SearchSuggestion(text: "National Weather Service", url: weatherGov)]
        )
    }

    private struct MixedProvider: CommandBarSuggestionProviding {
        var answer: [SearchSuggestion]
        func suggestions(for query: String) async -> [String] { answer.filter { !$0.isNavigation }.map(\.text) }
        func completions(for query: String) async -> [SearchSuggestion] { answer }
    }

    /// Sources over an empty workspace with Weather.com as a frequently visited site and the
    /// observed suggestion answer.
    private func weatherSources(
        knownSites: [CommandBarSiteCandidate]? = nil,
        suggestions: (any CommandBarSuggestionProviding)? = nil
    ) -> [any CommandBarSource] {
        let sites = knownSites ?? [CommandBarSiteCandidate(url: weatherCom, title: "Weather.com", host: "weather.com", strength: 0.9)]
        let provider = suggestions ?? MixedProvider(answer: [
            SearchSuggestion(text: "weather radar"),
            SearchSuggestion(text: "National Weather Service", url: weatherGov),
            SearchSuggestion(text: "weather tomorrow"),
        ])
        let workspace = WorkspaceState()
        return commandBarDefaultSources(
            workspace: { workspace },
            knownSites: CommandBarKnownSitesSource { _, _ in sites },
            suggestions: provider
        )
    }

    private func typed(_ text: String, sources: [any CommandBarSource]) async -> CommandBarViewModel {
        let model = CommandBarViewModel(sources: sources)
        model.open(mode: .newTab)
        await model.waitForRefresh()
        model.queryText = text
        await model.waitForRefresh()
        return model
    }

    // MARK: Pure rules

    /// [05 §命令栏] observed "weather" → "weather.com"; the length and character limits are inferred.
    func testCompletedHostRules() {
        XCTAssertEqual(CommandBarSiteCompletionRules.completedHost(forTyped: "weather", host: "weather.com"), "weather.com")
        XCTAssertEqual(CommandBarSiteCompletionRules.completedHost(forTyped: "WEATH", host: "weather.com"), "weather.com")
        XCTAssertNil(CommandBarSiteCompletionRules.completedHost(forTyped: "weather.com", host: "weather.com"), "a full host is not completed")
        XCTAssertNil(CommandBarSiteCompletionRules.completedHost(forTyped: "w", host: "weather.com"), "one letter is too short")
        XCTAssertNil(CommandBarSiteCompletionRules.completedHost(forTyped: "eather", host: "weather.com"), "host prefix only")
        XCTAssertNil(CommandBarSiteCompletionRules.completedHost(forTyped: "weather radar", host: "weather.com"))
        XCTAssertNil(CommandBarSiteCompletionRules.completedHost(forTyped: "weather/", host: "weather.com/x"))
    }

    /// The best site: the strongest, then the shorter host. inferred.
    func testBestCandidatePrefersTheStrongerThenShorterHost() throws {
        let gov = CommandBarSiteCandidate(url: weatherGov, title: "NWS", host: "weather.gov", strength: 0.5, sourceOrder: 0)
        let com = CommandBarSiteCandidate(url: weatherCom, title: "Weather.com", host: "weather.com", strength: 0.9, sourceOrder: 1)
        let long = CommandBarSiteCandidate(url: URL(string: "https://weatherspark.com/")!, title: "Spark", host: "weatherspark.com", strength: 0.9, sourceOrder: 2)
        let best = try XCTUnwrap(CommandBarSiteCompletionRules.bestCandidate(forTyped: "weather", candidates: [gov, long, com]))
        XCTAssertEqual(best.candidate.host, "weather.com")
        XCTAssertNil(CommandBarSiteCompletionRules.bestCandidate(forTyped: "rain", candidates: [gov, com]))
    }

    /// The selected suffix is everything after the typed text; the typed letters stay as typed.
    func testInlineCompletionKeepsTypedLettersAndSelectsTheSuffix() throws {
        let row = CommandBarSiteRows.row(id: "site", url: weatherCom, title: "Weather.com", typed: "Weather", strength: 1, sourceOrder: 0, target: .newTab)
        XCTAssertEqual(row.kind, .siteCompletion)
        let completion = try XCTUnwrap(CommandBarSiteCompletionRules.inlineCompletion(text: "Weather", selectedIndex: 0, results: [row]))
        XCTAssertEqual(completion.completedText, "Weather.com")
        XCTAssertEqual(completion.suffix, ".com")
        XCTAssertEqual(completion.selectedRange, NSRange(location: 7, length: 4))
        XCTAssertNil(CommandBarSiteCompletionRules.inlineCompletion(text: "Weather", selectedIndex: 1, results: [row]),
                     "[05 §命令栏] observed: another selected row clears the completion")
        XCTAssertNil(CommandBarSiteCompletionRules.inlineCompletion(text: "Weather ", selectedIndex: 0, results: [row]))
    }

    /// Typing along the completion keeps the rest selected until the new list arrives. inferred.
    func testCompletionCarriesOverMatchingKeystrokes() throws {
        let start = CommandBarInlineCompletion(typedText: "weather", completedText: "weather.com", suffix: ".com", resultID: "site")
        let next = try XCTUnwrap(CommandBarSiteCompletionRules.carriedCompletion(start, typed: "weather.c"))
        XCTAssertEqual(next.completedText, "weather.com")
        XCTAssertEqual(next.suffix, "om")
        XCTAssertNil(CommandBarSiteCompletionRules.carriedCompletion(start, typed: "weathex"))
        XCTAssertNil(CommandBarSiteCompletionRules.carriedCompletion(start, typed: "weather.com"))
    }

    /// One candidate per host, the root page, the root page's title, a most visited page counts at
    /// least `topSiteMinimumStrength`. inferred.
    func testKnownSitesFoldPagesIntoOneSitePerHost() throws {
        let old = now.addingTimeInterval(-200 * 86_400)
        let history = [
            HistoryMatch(url: URL(string: "https://weather.com/weather/today/l/NYC")!, title: "Today NYC", lastVisit: now, visitCount: 30),
            HistoryMatch(url: URL(string: "https://www.weather.com/")!, title: "Weather.com", lastVisit: old),
            HistoryMatch(url: URL(string: "file:///tmp/weather.txt")!, title: "file", lastVisit: now),
        ]
        let top = [HistoryMatch(url: URL(string: "https://weather.gov/forecast")!, title: "Forecast", lastVisit: old)]
        let sites = CommandBarKnownSites.candidates(history: history, topSites: top, now: now)
        XCTAssertEqual(sites.map(\.host), ["weather.gov", "weather.com"])
        let com = try XCTUnwrap(sites.first { $0.host == "weather.com" })
        XCTAssertEqual(com.title, "Weather.com")
        XCTAssertEqual(com.url, URL(string: "https://www.weather.com/"))
        XCTAssertGreaterThan(com.strength, 0.6, "the frequently visited deep page lifts the site")
        let gov = try XCTUnwrap(sites.first { $0.host == "weather.gov" })
        XCTAssertEqual(gov.title, "weather.gov", "no root page visited: the host is the title")
        XCTAssertEqual(gov.strength, CommandBarKnownSites.topSiteMinimumStrength, accuracy: 0.0001)
    }

    // MARK: Engine: navigation suggestions

    /// [05 §命令栏] observed navigation rows: the service's NAVIGATION entries are read with their
    /// page title instead of being dropped (Google's "githu" answer, recorded 2026-10-30).
    func testParserReadsNavigationRowsWithTheirTitles() {
        let body = Data(#")]}'\#n["weath",["weather radar","https://www.weather.gov/","weather tomorrow","javascript:alert(1)"],["","National Weather Service","",""],[],{"google:suggesttype":["QUERY","NAVIGATION","QUERY","NAVIGATION"]}]"#.utf8)
        let found = SearchSuggestionParser.completions(from: body, query: "weath")
        XCTAssertEqual(found, [
            SearchSuggestion(text: "weather radar"),
            SearchSuggestion(text: "National Weather Service", url: weatherGov),
            SearchSuggestion(text: "weather tomorrow"),
        ])
        XCTAssertEqual(SearchSuggestionParser.suggestions(from: body, query: "weath"), ["weather radar", "weather tomorrow"],
                       "the phrase list keeps leaving pages out")
        let untitled = Data(#"["x",["https://example.org/a"],[""],[],{"google:suggesttype":["NAVIGATION"]}]"#.utf8)
        XCTAssertEqual(SearchSuggestionParser.completions(from: untitled, query: "x").first?.text, "example.org")
    }

    /// Engines that only know phrases answer query rows through the protocol default.
    func testEnginesWithoutNavigationAnswerQueryRows() async {
        let auto = FakeAutocomplete()
        auto.suggestionProvider = { _ in ["weather radar"] }
        let request = SearchSuggestionRequest(query: "weather", urlTemplate: SearchEngine.google.suggestURLTemplate, profileID: UUID())
        let rows = await auto.searchCompletions(request)
        XCTAssertEqual(rows, [SearchSuggestion(text: "weather radar")])
        let gov = weatherGov
        auto.completionProvider = { _ in [SearchSuggestion(text: "NWS", url: gov), SearchSuggestion(text: "weather")] }
        let mixed = await auto.searchCompletions(request)
        XCTAssertEqual(mixed, [SearchSuggestion(text: "NWS", url: weatherGov)], "the query itself is not a suggestion")
        let phrases = await auto.searchSuggestions(request)
        XCTAssertEqual(phrases, [])
    }

    // MARK: Rows and order ([05 §命令栏] observed)

    /// The observed list for "weather": the site first ("Weather.com — weather.com"), the plain
    /// search second, then the navigation suggestion among the query suggestions, in the service's
    /// order. Site rows show no right-hand text in the window ([07 §5] E27 observed).
    func testWeatherListMatchesTheObservedOrder() async throws {
        let model = await typed("weather", sources: weatherSources())
        let rows = model.results
        XCTAssertEqual(rows.map(\.kind), [.siteCompletion, .webSearch, .searchSuggestion, .siteSuggestion, .searchSuggestion])
        XCTAssertEqual(rows[0].title, "Weather.com")
        XCTAssertEqual(rows[0].subtitle, "weather.com")
        XCTAssertEqual(rows[0].iconHint, .site(faviconURL: nil))
        XCTAssertEqual(rows[0].action, .openURL(weatherCom, target: .newTab))
        XCTAssertEqual(rows[1].action, .searchWeb(query: "weather", target: .newTab))
        XCTAssertEqual(rows[3].title, "National Weather Service")
        XCTAssertEqual(rows[3].subtitle, "weather.gov")
        XCTAssertEqual(rows[3].action, .openURL(weatherGov, target: .newTab))
        XCTAssertEqual(rows.map(\.title).filter { $0.hasPrefix("weather ") }, ["weather radar", "weather tomorrow"])
        for row in rows {
            XCTAssertNil(row.trailingLabel(for: .window))
            XCTAssertEqual(row.trailingAccessory(for: .window), .none)
        }
        XCTAssertEqual(model.selectedIndex, 0, "[05 §命令栏] observed: the site row is highlighted")
    }

    /// A navigation suggestion whose host starts with the typed text is the completing row when
    /// the profile knows no such site (inferred), and the most visited site wins over it.
    func testSuggestedSiteCompletesWhenNoVisitedSiteDoes() async throws {
        let suggested = MixedProvider(answer: [SearchSuggestion(text: "National Weather Service", url: weatherGov)])
        let alone = await typed("weather", sources: weatherSources(knownSites: [], suggestions: suggested))
        XCTAssertEqual(alone.results.first?.kind, .siteCompletion)
        XCTAssertEqual(alone.results.first?.url, weatherGov)
        XCTAssertEqual(alone.inlineCompletion?.completedText, "weather.gov")

        let both = await typed("weather", sources: weatherSources(suggestions: suggested))
        XCTAssertEqual(both.results.first?.url, weatherCom, "a visited site beats a suggested one")
        XCTAssertEqual(both.results.filter { $0.kind == .siteCompletion }.count, 1, "one completing row")
        XCTAssertTrue(both.results.contains { $0.url == weatherGov && $0.kind == .siteSuggestion })
    }

    /// An open tab of the site keeps its "Switch to Tab" row first; the site row does not repeat it.
    func testOpenTabOfTheSiteWinsOverTheSiteRow() async throws {
        var ws = WorkspaceState()
        let profile = UUID(), space = UUID(), tab = UUID()
        ws.profiles[profile] = Profile(id: profile, name: "Default", now: now)
        ws = try TreeOps.createSpace(ws, id: space, profileID: profile, name: "Home", now: now)
        ws = try TreeOps.openTab(ws, id: tab, spaceID: space, url: weatherCom, title: "Weather", now: now)
        let workspace = ws
        let com = weatherCom
        let sources = commandBarDefaultSources(
            workspace: { workspace },
            knownSites: CommandBarKnownSitesSource { _, _ in
                [CommandBarSiteCandidate(url: com, title: "Weather.com", host: "weather.com", strength: 1)]
            }
        )
        let model = await typed("weather", sources: sources)
        XCTAssertEqual(model.results.first?.action, .switchToTab(tabID: tab))
        XCTAssertFalse(model.results.contains { $0.kind == .siteCompletion })
        XCTAssertNil(model.inlineCompletion)
    }

    // MARK: Inline completion ([05 §命令栏] observed)

    /// "weather" shows "weather.com" with ".com" selected and the site's glyph; ↓ to the search
    /// row clears it and brings back the magnifier; ↑ brings it back.
    func testCompletionFollowsTheFirstRowAndArrowKeys() async throws {
        let model = await typed("weather", sources: weatherSources())
        let completion = try XCTUnwrap(model.inlineCompletion)
        XCTAssertEqual(model.displayedText, "weather.com")
        XCTAssertEqual(completion.suffix, ".com")
        XCTAssertEqual(completion.selectedRange, NSRange(location: 7, length: 4))
        XCTAssertEqual(CommandBarInputGlyph.forField(text: model.queryText, firstResult: model.results.first, inlineCompletion: completion),
                       .site(model.results[0]))

        model.handle(.down)
        XCTAssertEqual(model.selectedResult?.kind, .webSearch)
        XCTAssertNil(model.inlineCompletion)
        XCTAssertEqual(model.displayedText, "weather", "[05 §命令栏] observed: the field shows the typed text")
        XCTAssertEqual(CommandBarInputGlyph.forField(text: model.queryText, firstResult: model.results.first, inlineCompletion: model.inlineCompletion),
                       .magnifier)
        XCTAssertEqual(model.handle(.returnKey), .activate(.searchWeb(query: "weather", target: .newTab)))

        model.handle(.up)
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.com")
    }

    /// Return opens the completed site.
    func testReturnOpensTheCompletedSite() async throws {
        let model = await typed("weather", sources: weatherSources())
        XCTAssertEqual(model.handle(.returnKey), .activate(.openURL(weatherCom, target: .newTab)))
    }

    /// Backspace removes the completion (the field shows the typed text, the search row is
    /// selected, Return searches); the next Backspace deletes a letter and no completion returns
    /// until a letter is typed again.
    func testBackspaceRemovesTheCompletion() async throws {
        let model = await typed("weather", sources: weatherSources())
        XCTAssertNotNil(model.inlineCompletion)
        XCTAssertEqual(model.handle(.deleteBackward), .handled, "the key only drops the completion")
        XCTAssertNil(model.inlineCompletion)
        XCTAssertEqual(model.displayedText, "weather")
        XCTAssertEqual(model.selectedResult?.kind, .webSearch)
        XCTAssertEqual(model.handle(.returnKey), .activate(.searchWeb(query: "weather", target: .newTab)))

        XCTAssertEqual(model.handle(.deleteBackward), .ignored, "without a completion the field deletes")
        model.queryText = "weathe"
        await model.waitForRefresh()
        XCTAssertNil(model.inlineCompletion, "deleting does not bring a completion back")
        XCTAssertEqual(model.results.first?.kind, .siteCompletion, "the site row stays listed")
        XCTAssertEqual(model.selectedResult?.kind, .webSearch)

        model.queryText = "weather"
        await model.waitForRefresh()
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.com", "typing brings it back")
        XCTAssertEqual(model.selectedIndex, 0)
    }

    /// Typing replaces the selected suffix: the field reports the new text, and a letter that
    /// follows the completion keeps the rest selected while the list refreshes.
    func testTypingReplacesTheSuffixAndCarriesTheCompletion() async throws {
        let model = await typed("weather", sources: weatherSources())
        model.queryText = "weather."
        XCTAssertEqual(model.inlineCompletion?.suffix, "com", "carried before the list arrives")
        await model.waitForRefresh()
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.com")
        XCTAssertEqual(model.handle(.returnKey), .activate(.openURL(weatherCom, target: .newTab)))

        model.queryText = "weatherx"
        XCTAssertNil(model.inlineCompletion, "a letter off the completion replaces it")
        await model.waitForRefresh()
        XCTAssertNil(model.inlineCompletion)
    }

    /// → keeps the completed text as typed text (inferred); the full host then reads as an address
    /// and has nothing left to complete.
    func testAcceptingTheCompletionMakesItTypedText() async throws {
        let model = await typed("weather", sources: weatherSources())
        model.acceptInlineCompletion()
        XCTAssertEqual(model.queryText, "weather.com")
        await model.waitForRefresh()
        XCTAssertNil(model.inlineCompletion)
        XCTAssertEqual(model.handle(.returnKey), .activate(.openURL(try XCTUnwrap(URL(string: "https://weather.com")), target: .newTab)))
    }

    /// The field's key mapping: Backspace goes to the bar; ←, → and End accept a completion.
    func testFieldKeyMapping() {
        typealias C = CommandBarTextField.Coordinator
        XCTAssertEqual(C.key(for: #selector(NSResponder.deleteBackward(_:))), .deleteBackward)
        XCTAssertTrue(C.acceptsCompletion(#selector(NSResponder.moveRight(_:))))
        XCTAssertTrue(C.acceptsCompletion(#selector(NSResponder.moveToEndOfLine(_:))))
        XCTAssertFalse(C.acceptsCompletion(#selector(NSResponder.moveUp(_:))))
    }

    // MARK: Through the window (FakeEngine)

    /// End to end: a frequently visited site in the engine's history completes in the window's
    /// ⌘T bar, the engine's navigation suggestion shows as a site row, and an incognito window
    /// (no history, [06 §20.1] observed) completes nothing from history.
    func testWindowBarCompletesFromTheEngine() async throws {
        let f = SidebarFixture()
        let at = f.now.addingTimeInterval(10)
        let engine = FakeEngine(clock: { at })
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { at },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        let shell = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer { shell.stop(); controller.stop() }
        shell.sidebar.selectSpace(f.home)
        let auto = engine.fakeAutocomplete
        auto.addPage(HistoryMatch(url: weatherCom, title: "Weather.com", lastVisit: at, visitCount: 20, typedCount: 5), profileID: f.profile)
        let gov = weatherGov
        auto.completionProvider = { _ in [
            SearchSuggestion(text: "weather radar"),
            SearchSuggestion(text: "National Weather Service", url: gov),
            SearchSuggestion(text: "weather tomorrow"),
        ] }

        shell.presentCommandBar(.newTab)
        shell.commandBar.queryText = "weather"
        await shell.commandBar.waitForRefresh()
        let bar = shell.commandBar
        XCTAssertEqual(bar.results.first?.kind, .siteCompletion)
        XCTAssertEqual(bar.results.first?.url, weatherCom)
        XCTAssertEqual(bar.displayedText, "weather.com")
        XCTAssertEqual(bar.results.dropFirst().first?.kind, .webSearch)
        let nav = try XCTUnwrap(bar.results.first { $0.kind == .siteSuggestion })
        XCTAssertEqual(nav.subtitle, "weather.gov")
        XCTAssertFalse(bar.results.contains { $0.kind == .historyItem && $0.url == weatherCom }, "one row for the site")

        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        defer { incognito.stop() }
        incognito.presentCommandBar(.newTab)
        incognito.commandBar.queryText = "weather"
        await incognito.commandBar.waitForRefresh()
        XCTAssertNotEqual(incognito.commandBar.results.first?.url, weatherCom)
    }
}
