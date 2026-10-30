import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B133: command bar follow-ups from E30.
///
/// Spec: docs/arc-spec/05-surfaces.md §命令栏, "行内补全规则实测(E30, 2026-10-31)" (observed):
///   - one typed character: the field's glyph is the default search engine's icon (Google "G");
///   - Backspace after an inline completion keeps the site row first ("youtube.com — youtube.com",
///     globe) — tested in `CommandBarSiteSuggestionsTests.testBackspaceRemovesTheCompletion`;
///   - "Search YouTube Tab" / "Search Wikipedia Tab" hint; Tab enters a site search with a red
///     "YouTube" chip, the placeholder "Search…" and no rows.
/// The site list, the search URLs, the colors and leaving with Backspace are inferred.
@MainActor
final class CommandBarB133Tests: XCTestCase {
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9])

    private func bar(_ sources: [any CommandBarSource] = commandBarDefaultSources(workspace: { WorkspaceState() })) async -> CommandBarViewModel {
        let model = CommandBarViewModel(sources: sources)
        model.open(mode: .newTab)
        await model.waitForRefresh()
        return model
    }

    // MARK: Tab to Search — matching

    /// [05 §命令栏] E30 observed pairs: "yout" → YouTube, "w" → Wikipedia.
    func testHintMatchesObservedPairsSpec05CommandBarE30() {
        XCTAssertEqual(CommandBarSearchSites.match(typed: "yout")?.name, "YouTube")
        XCTAssertEqual(CommandBarSearchSites.match(typed: "w")?.name, "Wikipedia")
        XCTAssertEqual(CommandBarSearchSites.match(typed: "W")?.name, "Wikipedia", "case-insensitive")
        XCTAssertEqual(CommandBarSearchSites.match(typed: "stackover")?.name, "Stack Overflow", "name without spaces")
        XCTAssertEqual(CommandBarSearchSites.match(typed: "git")?.hintTitle, "Search GitHub")
    }

    /// No hint for empty text, a query with spaces, a path or an unknown site. inferred.
    func testHintNeedsASiteLikeText() {
        XCTAssertNil(CommandBarSearchSites.match(typed: ""))
        XCTAssertNil(CommandBarSearchSites.match(typed: "you tube"))
        XCTAssertNil(CommandBarSearchSites.match(typed: "youtube.com/watch"))
        XCTAssertNil(CommandBarSearchSites.match(typed: "zzzz"))
        XCTAssertNil(CommandBarSearchSites.match(typed: "yout "))
    }

    /// The completed host decides first: "yo" completed to youtube.com offers YouTube. inferred.
    func testCompletedHostWins() {
        let sites = [
            CommandBarSearchSite(id: "a", name: "Yodel", host: "yodel.example", searchURLTemplate: "https://yodel.example/?q=%@"),
            CommandBarSearchSites.builtIn[0],
        ]
        XCTAssertEqual(CommandBarSearchSites.match(typed: "yo", sites: sites)?.name, "Yodel")
        XCTAssertEqual(CommandBarSearchSites.match(typed: "yo", completedHost: "www.youtube.com", sites: sites)?.name, "YouTube")
    }

    /// Search URLs escape the query, including characters that split a query. inferred.
    func testSiteSearchURL() throws {
        let youtube = try XCTUnwrap(CommandBarSearchSites.match(typed: "you"))
        XCTAssertEqual(youtube.searchURL(for: "lo-fi & chill")?.absoluteString,
                       "https://www.youtube.com/results?search_query=lo-fi%20%26%20chill")
        XCTAssertNil(youtube.searchURL(for: "   "))
        XCTAssertEqual(youtube.brandColor, RGBAColor(hex: 0xFF0000), "[05 §命令栏] E30 observed red chip")
        XCTAssertNil(CommandBarSearchSites.match(typed: "wiki")?.brandColor, "no brand color → theme selection (inferred)")
    }

    // MARK: Tab to Search — keyboard

    /// [05 §命令栏] E30: the hint shows while typing "yout"; Tab enters the site search (empty
    /// field, no rows); typing lists nothing; Return searches the site.
    func testTabEntersSiteSearchAndReturnSearchesItSpec05CommandBarE30() async throws {
        let model = await bar()
        model.queryText = "yout"
        await model.waitForRefresh()
        XCTAssertEqual(model.siteSearchOffer?.name, "YouTube")
        XCTAssertFalse(model.results.isEmpty)

        XCTAssertEqual(model.handle(.tab), .handled)
        XCTAssertEqual(model.siteSearch?.name, "YouTube")
        XCTAssertNil(model.siteSearchOffer, "no hint during a site search")
        XCTAssertEqual(model.queryText, "")
        XCTAssertTrue(model.results.isEmpty, "no result rows")

        model.queryText = "cats"
        await model.waitForRefresh()
        XCTAssertTrue(model.results.isEmpty, "typing lists nothing")
        XCTAssertNil(model.inlineCompletion)
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/results?search_query=cats"))
        XCTAssertEqual(model.handle(.returnKey), .activate(.openURL(url, target: .newTab)))
    }

    /// Return with an empty site search does nothing. inferred.
    func testReturnOnEmptySiteSearchDoesNothing() async {
        let model = await bar()
        model.queryText = "w"
        await model.waitForRefresh()
        model.handle(.tab)
        XCTAssertEqual(model.siteSearch?.name, "Wikipedia")
        XCTAssertNil(model.activate())
    }

    /// Backspace on the empty site search leaves it and the list comes back; Backspace with text
    /// deletes as usual; Esc closes as usual. Leaving is inferred; Esc [05 §命令栏] observed.
    func testBackspaceLeavesAndEscapeCloses() async {
        let model = await bar()
        model.queryText = "yout"
        await model.waitForRefresh()
        model.handle(.tab)
        model.queryText = "a"
        XCTAssertEqual(model.handle(.deleteBackward), .ignored, "the field deletes the letter")
        model.queryText = ""
        XCTAssertEqual(model.handle(.deleteBackward), .handled)
        XCTAssertNil(model.siteSearch)
        await model.waitForRefresh()
        XCTAssertFalse(model.results.isEmpty, "the empty-query rows are back")

        model.queryText = "yout"
        await model.waitForRefresh()
        model.handle(.tab)
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        XCTAssertEqual(model.handle(.escape), .dismiss)
        XCTAssertEqual(dismissed, 1)
        model.dismiss()
        XCTAssertNil(model.siteSearch, "closing ends the site search")
    }

    /// Without a site on offer Tab keeps its old meaning (the row's completion). inferred.
    func testTabWithoutOfferCompletesTheRow() async {
        let model = await bar()
        model.queryText = "zzzz"
        await model.waitForRefresh()
        XCTAssertNil(model.siteSearchOffer)
        model.handle(.tab)
        XCTAssertNil(model.siteSearch)
        XCTAssertEqual(model.queryText, "zzzz")
    }

    /// The unedited ⌘L prefill offers nothing (inferred: it is not typed text).
    func testPrefillOffersNoSiteSearch() async throws {
        let model = CommandBarViewModel(sources: commandBarDefaultSources(workspace: { WorkspaceState() }))
        model.open(mode: .currentTab, currentURL: try XCTUnwrap(URL(string: "https://www.youtube.com/")))
        await model.waitForRefresh()
        XCTAssertNil(model.siteSearchOffer)
    }

    // MARK: Input glyph

    /// [05 §命令栏] E30 observed: one character → the search engine's icon; empty → magnifier
    /// (B109); two characters with no command or completion → magnifier.
    func testOneCharacterShowsTheSearchEngineGlyphSpec05CommandBarE30() throws {
        let engineRow = CommandBarResult(id: "se", kind: .siteSuggestion, title: "google.com",
                                         url: URL(string: "https://www.google.com/"),
                                         iconHint: .site(faviconURL: nil), actionLabel: nil,
                                         action: .openURL(try XCTUnwrap(URL(string: "https://www.google.com/")), target: .newTab))
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "w", firstResult: nil, searchEngine: engineRow), .searchEngine(engineRow))
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "w", firstResult: nil, searchEngine: engineRow).iconRow, engineRow)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "", firstResult: nil, searchEngine: engineRow), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "we", firstResult: nil, searchEngine: engineRow), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: " ", firstResult: nil, searchEngine: engineRow), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "w", firstResult: nil), .magnifier, "no engine → magnifier")
        XCTAssertEqual(CommandBarInputGlyph.searchEngine(engineRow).symbolName, "magnifyingglass", "fallback")
    }

    func testSearchEngineSites() {
        XCTAssertEqual(SearchEngine.google.siteURL, URL(string: "https://www.google.com/"))
        XCTAssertEqual(SearchEngine.duckDuckGo.siteURL, URL(string: "https://duckduckgo.com/"))
        for engine in SearchEngine.allCases { XCTAssertNotNil(engine.siteURL, "\(engine)") }
    }

    /// Through the window: the bar knows the profile's engine, asks the engine for its icon, and
    /// the icon is what the one-character glyph draws.
    func testWindowLoadsTheSearchEngineIcon() async throws {
        let f = SidebarFixture()
        let at = f.now.addingTimeInterval(10)
        let engine = FakeEngine(clock: { at })
        engine.fakeAutocomplete.siteIcons = ["google.com": png]
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let controller = WorkspaceController(dependencies: deps, workspace: f.ws, now: { at },
                                             notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker())
        let shell = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer {
            shell.stop()
            controller.stop()
        }
        shell.sidebar.selectSpace(f.home)
        let bar = shell.commandBar
        shell.presentCommandBar(.newTab)
        bar.queryText = "w"
        await bar.waitForRefresh()
        let row = try XCTUnwrap(bar.searchEngineIconRow)
        XCTAssertEqual(row.url, URL(string: "https://www.google.com/"))
        for _ in 0..<500 where bar.faviconProvider?(row) != png {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(bar.faviconProvider?(row), png)
        let glyph = CommandBarInputGlyph.forField(text: bar.queryText, firstResult: bar.results.first,
                                                  inlineCompletion: bar.inlineCompletion, searchEngine: row)
        if case .command = glyph { return }  // a command heading the list keeps its glyph
        XCTAssertEqual(glyph, .searchEngine(row))
    }
}
