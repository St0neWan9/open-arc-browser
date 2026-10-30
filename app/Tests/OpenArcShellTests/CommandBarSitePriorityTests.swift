import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Plan B141 (F5-34, F5-35): which site row completes, and when a site gets a row at all.
///
/// Spec: docs/arc-spec/05-surfaces.md §命令栏, B128 block, our rules (inferred):
///   - "常访问的优先": a site the profile visits (history or most visited pages) completes ahead of
///     a site the search service suggests;
///   - "建议晚到时不抢走用户已选中的行": late suggestions never take the selection away;
///   - "已打开的同站标签保留「Switch to Tab」行,不再加网站行".
@MainActor
final class CommandBarSitePriorityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let weatherCom = URL(string: "https://weather.com/")!
    private let weatherGov = URL(string: "https://www.weather.gov/")!

    /// A history-only site seen once five days ago: its strength (≈ 0.49) is below a navigation
    /// suggestion's fixed strength.
    private var onceVisitedWeatherCom: CommandBarSiteCandidate {
        let page = HistoryMatch(url: URL(string: "https://weather.com/")!, title: "Weather.com",
                                lastVisit: now.addingTimeInterval(-5 * 86_400))
        let sites = CommandBarKnownSites.candidates(history: [page], topSites: [], now: now)
        return sites[0]
    }

    /// Answers once `open()` is called, so a test controls when late rows arrive.
    private final class GatedProvider: CommandBarSuggestionProviding, @unchecked Sendable {
        // @unchecked Sendable: `answer` is immutable; the gate is an actor.
        let answer: [SearchSuggestion]
        let gate = Gate()
        init(answer: [SearchSuggestion]) { self.answer = answer }
        func suggestions(for query: String) async -> [String] { answer.filter { !$0.isNavigation }.map(\.text) }
        func completions(for query: String) async -> [SearchSuggestion] {
            await gate.wait()
            return answer
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        var waiterCount = 0
        func wait() async {
            if isOpen { return }
            waiterCount += 1
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private func sources(known: [CommandBarSiteCandidate], provider: any CommandBarSuggestionProviding,
                         deferred: Bool, workspace: WorkspaceState = WorkspaceState()) -> [any CommandBarSource] {
        commandBarDefaultSources(
            workspace: { workspace },
            knownSites: CommandBarKnownSitesSource { _, _ in known },
            suggestions: provider,
            suggestionsAreDeferred: deferred
        )
    }

    /// Types `text` and waits until the first (immediate) list is shown and the deferred request
    /// is waiting at the gate. Bounded.
    private func typeUntilImmediateRows(_ text: String, model: CommandBarViewModel, gate: Gate) async {
        model.queryText = text
        // Bounded by wall time (10 s), not by a yield count, so a loaded parallel run still waits.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let waiting = await gate.waiterCount
            if waiting > 0, model.results.contains(where: { $0.kind == .webSearch }) { break }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(model.results.contains { $0.kind == .webSearch }, "the immediate rows were shown")
    }

    // MARK: F5-34: visited sites first

    /// [05 §命令栏] B128 "常访问的优先" (inferred): a site seen once days ago, only in history,
    /// still completes ahead of the search service's navigation suggestion.
    func testHistoryOnlySiteBeatsNavigationSuggestionInRanking() throws {
        let site = onceVisitedWeatherCom
        XCTAssertLessThan(site.strength, CommandBarWebSuggestionsSource.navigationStrength,
                          "fixture: weaker than a suggestion by frecency alone")
        let visited = CommandBarSiteRows.row(id: CommandBarSiteRows.visitedIDPrefix + site.url.absoluteString,
                                             url: site.url, title: site.title, typed: "weather",
                                             strength: site.strength, sourceOrder: 0, target: .newTab)
        let suggested = CommandBarSiteRows.row(id: "navigation:\(weatherGov.absoluteString)", url: weatherGov,
                                               title: "National Weather Service", typed: "weather",
                                               strength: CommandBarWebSuggestionsSource.navigationStrength,
                                               sourceOrder: 0, target: .newTab)
        for order in [[suggested, visited], [visited, suggested]] {
            let ranked = CommandBarRanker.rank(order, context: CommandBarQueryContext(text: "weather", mode: .newTab))
            XCTAssertEqual(ranked.first?.url, weatherCom)
            XCTAssertEqual(ranked.first?.kind, .siteCompletion)
            XCTAssertEqual(ranked.filter { $0.kind == .siteCompletion }.count, 1)
            XCTAssertTrue(ranked.contains { $0.url == weatherGov && $0.kind == .siteSuggestion })
        }
    }

    /// [05 §命令栏] B128 (inferred): the same through the bar, suggestions answering at once.
    func testHistoryOnlySiteCompletesInTheBar() async {
        let provider = CommandBarStaticSuggestionProvider(
            phrases: ["weather radar"],
            navigations: [SearchSuggestion(text: "National Weather Service", url: weatherGov)]
        )
        let model = CommandBarViewModel(sources: sources(known: [onceVisitedWeatherCom], provider: provider, deferred: false))
        model.open(mode: .newTab)
        await model.waitForRefresh()
        model.queryText = "weather"
        await model.waitForRefresh()
        XCTAssertEqual(model.results.first?.url, weatherCom)
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.com")
    }

    /// [05 §命令栏] B128 "建议晚到时不抢走用户已选中的行" (inferred): a late navigation
    /// suggestion leaves the completing visited site first and selected; the completion stays.
    func testLateSuggestionKeepsTheVisitedSiteFirstAndSelected() async {
        let provider = GatedProvider(answer: [
            SearchSuggestion(text: "weather radar"),
            SearchSuggestion(text: "National Weather Service", url: weatherGov),
        ])
        let model = CommandBarViewModel(sources: sources(known: [onceVisitedWeatherCom], provider: provider, deferred: true))
        model.open(mode: .newTab)
        await model.waitForRefresh()
        await typeUntilImmediateRows("weather", model: model, gate: provider.gate)
        XCTAssertEqual(model.results.first?.url, weatherCom)
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.com")

        await provider.gate.open()
        await model.waitForRefresh()
        XCTAssertTrue(model.results.contains { $0.url == weatherGov }, "the late rows arrived")
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selectedResult?.url, weatherCom)
        XCTAssertEqual(model.selectedResult?.kind, .siteCompletion)
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.com")
    }

    /// [05 §命令栏] B128 (inferred): a row the user moved to stays selected when late rows come.
    func testLateSuggestionKeepsTheRowTheUserMovedTo() async {
        let provider = GatedProvider(answer: [
            SearchSuggestion(text: "National Weather Service", url: weatherGov),
            SearchSuggestion(text: "weather radar"),
        ])
        let model = CommandBarViewModel(sources: sources(known: [onceVisitedWeatherCom], provider: provider, deferred: true))
        model.open(mode: .newTab)
        await model.waitForRefresh()
        await typeUntilImmediateRows("weather", model: model, gate: provider.gate)
        model.handle(.down)
        let chosen = model.selectedResult?.id
        XCTAssertNotNil(chosen)
        XCTAssertNil(model.inlineCompletion)

        await provider.gate.open()
        await model.waitForRefresh()
        XCTAssertTrue(model.results.contains { $0.url == weatherGov }, "the late rows arrived")
        XCTAssertEqual(model.selectedResult?.id, chosen)
        XCTAssertNil(model.inlineCompletion)
    }

    /// [05 §命令栏] B128 (inferred): with the selection untouched on the first row, late rows that
    /// bring a new first row (a suggested site, no visited one) keep the selection on the first row
    /// instead of following the old row down the list.
    func testLateRowsKeepAnUntouchedSelectionOnTheFirstRow() async {
        let provider = GatedProvider(answer: [SearchSuggestion(text: "National Weather Service", url: weatherGov)])
        let model = CommandBarViewModel(sources: sources(known: [], provider: provider, deferred: true))
        model.open(mode: .newTab)
        await model.waitForRefresh()
        await typeUntilImmediateRows("weather", model: model, gate: provider.gate)
        XCTAssertEqual(model.selectedIndex, 0)

        await provider.gate.open()
        await model.waitForRefresh()
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.selectedResult?.url, weatherGov)
        XCTAssertEqual(model.inlineCompletion?.completedText, "weather.gov")
    }

    // MARK: F5-35: an open tab of the site

    /// [05 §命令栏] B128 "已打开的同站标签保留「Switch to Tab」行,不再加网站行" (inferred): a tab on
    /// a deeper page of the site keeps its row, the site gets none (visited or suggested), and the
    /// field does not complete. Another site's row stays.
    func testOpenTabOnADeeperPageDropsTheSiteRow() async throws {
        var ws = WorkspaceState()
        let profile = UUID(), space = UUID(), tab = UUID()
        ws.profiles[profile] = Profile(id: profile, name: "Default", now: now)
        ws = try TreeOps.createSpace(ws, id: space, profileID: profile, name: "Home", now: now)
        let deep = URL(string: "https://www.weather.com/weather/today/l/NYC")!
        ws = try TreeOps.openTab(ws, id: tab, spaceID: space, url: deep, title: "Today's Forecast", now: now)
        let known = [CommandBarSiteCandidate(url: weatherCom, title: "Weather.com", host: "weather.com", strength: 1)]
        let provider = CommandBarStaticSuggestionProvider(
            phrases: [],
            navigations: [
                SearchSuggestion(text: "Weather.com", url: weatherCom),
                SearchSuggestion(text: "National Weather Service", url: weatherGov),
            ]
        )
        let model = CommandBarViewModel(sources: sources(known: known, provider: provider, deferred: false, workspace: ws))
        model.open(mode: .newTab)
        await model.waitForRefresh()
        model.queryText = "weather"
        await model.waitForRefresh()

        XCTAssertTrue(model.results.contains { $0.action == .switchToTab(tabID: tab) }, "the tab keeps its row")
        XCTAssertFalse(model.results.contains { ($0.kind == .siteCompletion || $0.kind == .siteSuggestion) && $0.subtitle == "weather.com" },
                       "no site row for the open tab's site")
        XCTAssertNil(model.results.first { $0.url == weatherCom && $0.kind != .typedURL && !$0.kind.isTab })
        XCTAssertTrue(model.results.contains { $0.url == weatherGov }, "another site keeps its row")
        XCTAssertNotEqual(model.inlineCompletion?.completedText, "weather.com")
    }

    /// [05 §命令栏] B128 (inferred), pure ranking: the site row goes whatever page of the host the
    /// tab is on; a tab of another host leaves it.
    func testDeduplicateDropsSiteRowsOfAnOpenTabsHost() {
        let site = CommandBarSiteRows.row(id: CommandBarSiteRows.visitedIDPrefix + weatherCom.absoluteString,
                                          url: weatherCom, title: "Weather.com", typed: "weather",
                                          strength: 1, sourceOrder: 0, target: .newTab)
        func tab(_ url: String) -> CommandBarResult {
            CommandBarResult(id: "tab:\(url)", kind: .todayTab, title: "Weather today", url: URL(string: url)!,
                             iconHint: .search, actionLabel: "Switch to Tab", action: .switchToTab(tabID: UUID()),
                             completion: url)
        }
        let sameSite = CommandBarRanker.deduplicate([tab("https://weather.com/weather/today"), site], query: "weather")
        XCTAssertEqual(sameSite.map(\.kind), [.todayTab])
        let otherSite = CommandBarRanker.deduplicate([tab("https://radar.example/weather"), site], query: "weather")
        XCTAssertEqual(otherSite.map(\.kind), [.todayTab, .siteCompletion])
    }
}
