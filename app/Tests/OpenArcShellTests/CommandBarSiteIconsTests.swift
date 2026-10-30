import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B132 (1): icons of never visited sites in the command bar.
///
/// Spec: docs/arc-spec/05-surfaces.md §命令栏 (observed): site rows carry the site's icon
/// ("Weather.com — weather.com", "National Weather Service — weather.gov"), also for sites never
/// visited on the machine (E30: Weebly, WebMD, Yahoo, Hacker News), and the field's glyph turns
/// into the completed site's icon. Which rows ask, the retry interval and the concurrency limit
/// are inferred (SiteIconLoader.swift).
@MainActor
final class CommandBarSiteIconsTests: XCTestCase {
    private let weatherCom = URL(string: "https://weather.com/")!
    private let weatherGov = URL(string: "https://www.weather.gov/")!
    private let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])

    @MainActor
    private struct Window {
        let engine: FakeEngine
        let controller: WorkspaceController
        let shell: ShellModel
        func stop() {
            shell.stop()
            controller.stop()
        }
    }

    /// A window whose engine suggests weather.gov (never visited) and knows weather.com (visited,
    /// no icon cached).
    private func window(incognito: Bool = false) -> Window {
        let f = SidebarFixture()
        let at = f.now.addingTimeInterval(10)
        let engine = FakeEngine(clock: { at })
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { at },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        let shell = ShellModel.window(for: BrowserWindowRequest(kind: incognito ? .incognito : .newWindow), on: controller)
        if !incognito { shell.sidebar.selectSpace(f.home) }
        let auto = engine.fakeAutocomplete
        auto.addPage(HistoryMatch(url: weatherCom, title: "Weather.com", lastVisit: at, visitCount: 20, typedCount: 5), profileID: f.profile)
        let gov = weatherGov
        auto.completionProvider = { _ in [
            SearchSuggestion(text: "weather radar"),
            SearchSuggestion(text: "National Weather Service", url: gov),
        ] }
        return Window(engine: engine, controller: controller, shell: shell)
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("timed out: \(what)")
    }

    private func row(_ bar: CommandBarViewModel, _ url: URL) throws -> CommandBarResult {
        try XCTUnwrap(bar.results.first { $0.url == url }, "no row for \(url)")
    }

    /// [05 §命令栏] observed: a never visited suggested site shows its icon. The row starts with the
    /// globe (no icon cached) and swaps once the engine answered.
    func testNeverVisitedSiteRowGetsItsIconSpec05CommandBar() async throws {
        let w = window()
        defer { w.stop() }
        w.engine.fakeAutocomplete.siteIcons = ["weather.gov": png]
        let bar = w.shell.commandBar
        w.shell.presentCommandBar(.newTab)
        bar.queryText = "weather"
        await bar.waitForRefresh()
        let gov = try row(bar, weatherGov)
        let revision = bar.faviconRevision
        try await waitUntil("weather.gov icon") { bar.faviconProvider?(gov) == png }
        XCTAssertGreaterThan(bar.faviconRevision, revision, "the bar redraws when the icon arrives")
        XCTAssertTrue(w.engine.fakeAutocomplete.siteIconRequests.contains(weatherGov))
        // Stored under the site: the sidebar and the next bar find it without asking again.
        XCTAssertEqual(w.controller.favicons.image(forPage: URL(string: "https://weather.gov/forecast")), png)
    }

    /// [05 §命令栏] observed: the field's glyph is the completed site's icon. weather.com completes
    /// inline; its icon is fetched like any site row.
    func testCompletedSiteGlyphUsesTheFetchedIconSpec05CommandBar() async throws {
        let w = window()
        defer { w.stop() }
        w.engine.fakeAutocomplete.siteIcons = ["weather.com": png]
        let bar = w.shell.commandBar
        w.shell.presentCommandBar(.newTab)
        bar.queryText = "weather"
        await bar.waitForRefresh()
        XCTAssertEqual(bar.displayedText, "weather.com")
        let glyph = CommandBarInputGlyph.forField(text: bar.queryText, firstResult: bar.results.first, inlineCompletion: bar.inlineCompletion)
        guard case .site(let siteRow) = glyph else { return XCTFail("expected the site glyph, got \(glyph)") }
        try await waitUntil("weather.com icon") { bar.faviconProvider?(siteRow) == png }
    }

    /// inferred: typing does not wait for icons, a site is asked once while its request runs, and a
    /// site without an icon is not asked again on the next keystroke.
    func testTypingDoesNotWaitAndMissingIconsAreNotRefetched() async throws {
        let w = window()
        defer { w.stop() }
        let auto = w.engine.fakeAutocomplete
        auto.siteIconDelay = .seconds(30)
        let bar = w.shell.commandBar
        w.shell.presentCommandBar(.newTab)
        bar.queryText = "weather"
        await bar.waitForRefresh()
        XCTAssertNotNil(bar.results.first { $0.url == weatherGov }, "the list is there while icons load")
        XCTAssertNil(bar.faviconProvider?(try row(bar, weatherGov)), "globe until the icon arrives")
        bar.queryText = "weathe"
        await bar.waitForRefresh()
        bar.queryText = "weather"
        await bar.waitForRefresh()
        XCTAssertEqual(auto.siteIconRequests.filter { $0 == weatherGov }.count, 1, "one request per site while it runs")

        // A site that answered nothing is left alone (SiteIconLoader.retryInterval).
        w.controller.siteIcons.cancelAll()
        auto.siteIconDelay = .zero
        bar.queryText = "weath"
        await bar.waitForRefresh()
        try await waitUntil("requests finish") { w.controller.siteIcons.runningCount == 0 }
        let asked = auto.siteIconRequests.count
        bar.queryText = "weathe"
        await bar.waitForRefresh()
        XCTAssertEqual(auto.siteIconRequests.count, asked, "no second request for sites without an icon")
    }

    /// An engine without site icons is never asked; rows keep the globe.
    func testEngineWithoutSiteIconsKeepsTheGlobe() async throws {
        let w = window()
        defer { w.stop() }
        w.engine.fakeAutocomplete.capabilities = [.history, .searchSuggestions]
        let bar = w.shell.commandBar
        w.shell.presentCommandBar(.newTab)
        bar.queryText = "weather"
        await bar.waitForRefresh()
        XCTAssertNil(bar.faviconProvider?(try row(bar, weatherGov)))
        XCTAssertEqual(w.engine.fakeAutocomplete.siteIconRequests, [])
    }

    func testSiteKeyIgnoresWWWAndOtherSchemes() {
        XCTAssertEqual(SiteIconLoader.siteKey(URL(string: "https://www.Weather.gov/x")!), "weather.gov")
        XCTAssertNil(SiteIconLoader.siteKey(URL(string: "file:///tmp/a")!))
        XCTAssertNil(SiteIconLoader.siteKey(URL(string: "openarc://settings")!))
    }
}
