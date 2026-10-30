import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan B66: `EngineAutocomplete` (history and search suggestions for the command bar).
/// Spec: docs/arc-spec/05-surfaces.md §command bar (one entry for tabs, search and commands,
/// observed), 03-settings.md §Profiles ("Search engine", "Include search engine suggestions",
/// observed), 06-flows.md §20.1 (incognito: no history, observed). Frecency weights are inferred.
final class AutocompleteEngineTests: XCTestCase {
    private let profile = UUID()
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// [05 §command bar]: on-disk tabs record each http(s) navigation in the profile's history.
    func testNavigationsOfOnDiskTabsAreRecorded() async throws {
        let now = t0
        let engine = FakeEngine(titleProvider: { url in url.host == "swift.org" ? "Swift.org" : (url.host ?? "") }, clock: { now })
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://swift.org/")))
        try await tab.load(try XCTUnwrap(URL(string: "https://example.com/a")))
        try await tab.load(try XCTUnwrap(URL(string: "data:text/plain,x")))
        let found = await engine.autocomplete.historyMatches(for: "swift", profileID: profile, maxCount: 5)
        XCTAssertEqual(found.map(\.title), ["Swift.org"])
        XCTAssertEqual(found.first?.lastVisit, now)
        XCTAssertEqual(engine.fakeAutocomplete.history(profileID: profile).count, 2, "data: URLs are not history")
        // B132: the fake also answers site icons.
        XCTAssertEqual(engine.autocomplete.capabilities, [.history, .searchSuggestions, .siteIcons])
    }

    /// [06 §20.1] observed "no history" in incognito: off-the-record tabs never record visits.
    func testOffTheRecordTabsRecordNothing() async throws {
        let engine = FakeEngine()
        _ = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://secret.example/"), isOffTheRecord: true))
        let found = await engine.autocomplete.historyMatches(for: "secret", profileID: profile, maxCount: 5)
        XCTAssertEqual(found, [])
    }

    /// Every word must match the title or the URL; at most `maxCount`; best frecency first.
    func testHistoryMatchesAllWordsAndOrdersByFrecency() async {
        let auto = FakeAutocomplete(clock: { [t0] in t0 })
        let day: TimeInterval = 86_400
        auto.addPage(HistoryMatch(url: URL(string: "https://a.example/swift-old")!, title: "Swift concurrency guide",
                                  lastVisit: t0.addingTimeInterval(-200 * day), visitCount: 2), profileID: profile)
        auto.addPage(HistoryMatch(url: URL(string: "https://b.example/swift")!, title: "Swift concurrency talk",
                                  lastVisit: t0.addingTimeInterval(-1 * day), visitCount: 20, typedCount: 3), profileID: profile)
        auto.addPage(HistoryMatch(url: URL(string: "https://c.example/")!, title: "Rust book",
                                  lastVisit: t0, visitCount: 50), profileID: profile)
        auto.addPage(HistoryMatch(url: URL(string: "https://d.example/")!, title: "Swift concurrency elsewhere",
                                  lastVisit: t0), profileID: UUID())
        let found = await auto.historyMatches(for: "swift CONCURRENCY", profileID: profile, maxCount: 5)
        XCTAssertEqual(found.map(\.title), ["Swift concurrency talk", "Swift concurrency guide"])
        let one = await auto.historyMatches(for: "swift", profileID: profile, maxCount: 1)
        XCTAssertEqual(one.count, 1)
        let none = await auto.historyMatches(for: "   ", profileID: profile, maxCount: 5)
        XCTAssertEqual(none, [])
    }

    /// Frecency (inferred): recent and frequent beats old; typed visits weigh more.
    func testFrecencyPrefersRecentFrequentTyped() {
        let url = URL(string: "https://x.example/")!
        let recent = HistoryMatch(url: url, title: "", lastVisit: t0, visitCount: 1)
        let old = HistoryMatch(url: url, title: "", lastVisit: t0.addingTimeInterval(-365 * 86_400), visitCount: 1)
        let frequent = HistoryMatch(url: url, title: "", lastVisit: t0, visitCount: 30)
        let typed = HistoryMatch(url: url, title: "", lastVisit: t0, visitCount: 1, typedCount: 5)
        XCTAssertGreaterThan(recent.frecency(at: t0), old.frecency(at: t0))
        XCTAssertGreaterThan(frequent.frecency(at: t0), recent.frecency(at: t0))
        XCTAssertGreaterThan(typed.frecency(at: t0), recent.frecency(at: t0))
        XCTAssertLessThanOrEqual(frequent.frecency(at: t0), 1)
    }

    /// Clearing history (all time or a range) and deleting the profile remove the pages.
    func testClearingHistoryRemovesPages() async throws {
        let engine = FakeEngine(clock: { [t0] in t0 })
        engine.fakeAutocomplete.addVisit(url: URL(string: "https://old.example/")!, title: "old", profileID: profile, at: t0.addingTimeInterval(-3600))
        engine.fakeAutocomplete.addVisit(url: URL(string: "https://new.example/")!, title: "new", profileID: profile, at: t0)
        await engine.clearBrowsingData(profile, types: .history, since: t0.addingTimeInterval(-60))
        XCTAssertEqual(engine.fakeAutocomplete.history(profileID: profile).map(\.title), ["old"])
        await engine.clearBrowsingData(profile, types: .cookies, since: nil)
        XCTAssertEqual(engine.fakeAutocomplete.history(profileID: profile).count, 1, "cookies only keeps history")
        try await engine.deleteProfileData(profile)
        XCTAssertEqual(engine.fakeAutocomplete.history(profileID: profile), [])
    }

    /// [03 §Profiles] "Search engine": the request URL comes from the engine's suggestion template.
    func testSuggestionRequestBuildsEscapedURL() {
        let request = SearchSuggestionRequest(query: " swift & c++ ", urlTemplate: SearchEngine.duckDuckGo.suggestURLTemplate, profileID: profile)
        XCTAssertEqual(request.url?.absoluteString, "https://duckduckgo.com/ac/?type=list&q=swift%20%26%20c%2B%2B")
        XCTAssertNil(SearchSuggestionRequest(query: "  ", urlTemplate: "https://x/?q=%@", profileID: profile).url)
        XCTAssertNil(SearchSuggestionRequest(query: "a", urlTemplate: "https://x/", profileID: profile).url)
        for engine in SearchEngine.allCases {
            let url = SearchSuggestionRequest(query: "q", urlTemplate: engine.suggestURLTemplate, profileID: profile).url
            XCTAssertEqual(url?.scheme, "https", engine.rawValue)
        }
    }

    /// The OpenSearch suggestion format of every engine, Google's XSSI guard and navigation rows.
    func testSuggestionParser() {
        let plain = Data(#"["swi",["swift","Swift","swiss bank","swi",""]]"#.utf8)
        XCTAssertEqual(SearchSuggestionParser.suggestions(from: plain, query: "swi"), ["swift", "swiss bank"])
        let google = Data(#")]}'\#n["swi",["swift","https://swift.org/","swim"],["","",""],[],{"google:suggesttype":["QUERY","NAVIGATION","QUERY"]}]"#.utf8)
        XCTAssertEqual(SearchSuggestionParser.suggestions(from: google, query: "swi"), ["swift", "swim"])
        XCTAssertEqual(SearchSuggestionParser.suggestions(from: Data("not json".utf8), query: "x"), [])
        XCTAssertEqual(SearchSuggestionParser.suggestions(from: Data(#"{"q":1}"#.utf8), query: "x"), [])
    }

    /// Suggestions are async and cancellable: cancelling the task ends the call with nothing.
    func testSuggestionsAreCancellable() async {
        let auto = FakeAutocomplete()
        auto.suggestionProvider = { request in [request.query, request.query + " tutorial"] }
        let request = SearchSuggestionRequest(query: "swift", urlTemplate: SearchEngine.google.suggestURLTemplate, profileID: profile)
        let found = await auto.searchSuggestions(request)
        XCTAssertEqual(found, ["swift tutorial"], "the query itself is not a suggestion")

        auto.suggestionDelay = .seconds(30)
        let task = Task { await auto.searchSuggestions(request) }
        while auto.suggestionRequests.count < 2 { await Task.yield() }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(auto.cancelledSuggestionCount, 1)
    }

    /// An engine build without the capability answers nothing (the Chromium framework before B66).
    func testMissingCapabilitiesDegradeToNoResults() async {
        let auto = FakeAutocomplete()
        auto.addVisit(url: URL(string: "https://swift.org/")!, title: "Swift", profileID: profile)
        auto.suggestionProvider = { _ in ["swift"] }
        auto.capabilities = []
        let history = await auto.historyMatches(for: "swift", profileID: profile, maxCount: 3)
        let suggestions = await auto.searchSuggestions(SearchSuggestionRequest(query: "sw", urlTemplate: "https://x/?q=%@", profileID: profile))
        XCTAssertEqual(history, [])
        XCTAssertEqual(suggestions, [])
        let unavailable = UnavailableAutocomplete.shared
        XCTAssertEqual(unavailable.capabilities, [])
        let none = await unavailable.historyMatches(for: "swift", profileID: profile, maxCount: 3)
        XCTAssertEqual(none, [])
    }
}
