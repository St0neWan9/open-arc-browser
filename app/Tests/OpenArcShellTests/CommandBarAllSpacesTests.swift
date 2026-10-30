import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plans B109 and B121: the command bar's empty list across Spaces, and most visited pages.
/// Spec: docs/arc-spec/04-visual-metrics.md §command bar (observed: the empty list is open tabs,
/// then an app command; input row with a magnifier), 05-surfaces.md §command bar (observed: open
/// tabs first as "Switch to Tab"; inferred (analysis): results include most-visited pages),
/// 06-flows.md §6 (observed: the action text is "Switch to Tab" or the owning Space's name), §7
/// (observed: Little Arc rows "title — domain", magnifier), 07-design-system.md §5 (observed:
/// globe in an earlier capture). F4 live E2 / E3 (2026-10-29, observed): the empty ⌘T bar lists
/// open tabs of every Space; rows of other Spaces show that Space's name in gray instead of
/// "Switch to Tab", which only the highlighted row of the window's Space shows; no " — domain";
/// the empty bar's glyph is a magnifier.
final class CommandBarAllSpacesTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// Profile P: Spaces "Home" and "Work"; profile Q: Space "Other". One tab each, plus a favorite
    /// of P and one of Q; newest first: q-tab, work-tab, home-tab, p-fav, q-fav.
    private struct World {
        var ws = WorkspaceState()
        let p = UUID(), q = UUID(), home = UUID(), work = UUID(), other = UUID()
        let homeTab = UUID(), workTab = UUID(), otherTab = UUID(), pFav = UUID(), qFav = UUID()

        init() throws {
            let base = CommandBarAllSpacesTests.base
            ws.profiles[p] = Profile(id: p, name: "Default", now: base)
            ws.profiles[q] = Profile(id: q, name: "Second", now: base.addingTimeInterval(1))
            ws = try TreeOps.createSpace(ws, id: home, profileID: p, name: "Home", now: base)
            ws = try TreeOps.createSpace(ws, id: work, profileID: p, name: "Work", afterSpaceID: home, now: base)
            ws = try TreeOps.createSpace(ws, id: other, profileID: q, name: "Other", now: base)
            try add(pFav, "P Favorite", "https://pfav.example/", space: home, minutesAgo: 40, to: .favorite(profileID: p))
            try add(qFav, "Q Favorite", "https://qfav.example/", space: other, minutesAgo: 50, to: .favorite(profileID: q))
            try add(homeTab, "Home Tab", "https://home.example/", space: home, minutesAgo: 30)
            try add(workTab, "Work Tab", "https://work.example/", space: work, minutesAgo: 20)
            try add(otherTab, "Other Profile Tab", "https://other.example/", space: other, minutesAgo: 10)
        }

        private mutating func add(_ id: UUID, _ title: String, _ url: String, space: UUID, minutesAgo: Double, to location: TabLocation? = nil) throws {
            let at = CommandBarAllSpacesTests.base.addingTimeInterval(-minutesAgo * 60)
            ws = try TreeOps.openTab(ws, id: id, spaceID: space, url: URL(string: url), title: title, now: at)
            if let location { ws = try TreeOps.moveTab(ws, id: id, to: location, position: .last, now: at) }
            ws.tabs[id]?.lastActiveAt = at
        }
    }

    private func rank(_ world: World, text: String = "", space: UUID, presentation: CommandBarPresentation = .window,
                      topSites: [HistoryMatch] = []) async -> [CommandBarResult] {
        let ws = world.ws
        let context = CommandBarQueryContext(text: text, mode: .newTab, presentation: presentation, currentSpaceID: space)
        let sites = CommandBarTopSitesSource { maxCount in Array(topSites.prefix(maxCount)) }
        var all: [CommandBarResult] = []
        for source in commandBarDefaultSources(workspace: { ws }, topSites: sites) {
            all += await source.results(for: context)
        }
        return CommandBarRanker.rank(all, context: context, limit: 8)  // CommandBarViewModel.defaultMaxResults
    }

    // MARK: B109: tabs of every Space of the profile

    /// F4 live E2 observed: tabs of every Space; the other profile's Space (and favorite) is left
    /// out (inferred); most recent first across Spaces (inferred); an app command last
    /// ([04 §command bar] observed).
    func testEmptyQueryListsTabsOfEverySpaceOfTheProfileOnly() async throws {
        let world = try World()
        let rows = await rank(world, space: world.home)
        XCTAssertEqual(rows.map(\.title), ["Work Tab", "Home Tab", "P Favorite", "Contact the Team"])
        XCTAssertFalse(rows.contains { $0.title == "Other Profile Tab" || $0.title == "Q Favorite" })

        // From the other profile's Space only its own tabs show.
        let fromOther = await rank(world, space: world.other)
        XCTAssertEqual(fromOther.map(\.title), ["Other Profile Tab", "Q Favorite", "Contact the Team"])
    }

    /// F4 live E2 observed: a tab of another Space shows that Space's name instead of "Switch to
    /// Tab"; a tab of the window's Space shows "Switch to Tab" only on the highlighted row.
    func testSpaceNameVersusSwitchToTabLabel() async throws {
        let world = try World()
        let rows = await rank(world, space: world.home)
        let home = try XCTUnwrap(rows.first { $0.title == "Home Tab" })
        let work = try XCTUnwrap(rows.first { $0.title == "Work Tab" })
        let favorite = try XCTUnwrap(rows.first { $0.title == "P Favorite" })
        let command = try XCTUnwrap(rows.last)
        let label = { (row: CommandBarResult, selected: Bool) in
            row.trailingLabel(for: .window, isSelected: selected, currentSpaceID: world.home)
        }
        XCTAssertEqual(label(home, true), "Switch to Tab")
        XCTAssertNil(label(home, false), "only the highlighted row reads Switch to Tab")
        XCTAssertEqual(label(work, false), "Work")
        XCTAssertEqual(label(work, true), "Work", "inferred: the Space name stays when highlighted")
        XCTAssertEqual(label(favorite, true), "Switch to Tab", "favorites belong to no Space")
        XCTAssertNil(label(favorite, false))
        XCTAssertNil(label(command, true), "[06 §6] app commands have no action text")
        // A pane keeps its rule ([06 §6] observed): every tab row shows its Space name.
        XCTAssertEqual(home.trailingLabel(for: .pane, isSelected: false, currentSpaceID: world.home), "Home")
        // No known window Space: the action label as before.
        XCTAssertEqual(work.trailingLabel(for: .window), "Switch to Tab")
    }

    /// F4 live E2 observed: no " — domain" on the empty list. Typed queries keep the subtitle
    /// ([07 §3] observed "— example.net"), and so does Little Arc ([06 §7] observed).
    func testEmptyListHasNoDomainSuffix() async throws {
        let world = try World()
        let empty = await rank(world, space: world.home)
        XCTAssertTrue(empty.allSatisfy { $0.subtitle == nil }, "\(empty.map(\.subtitle))")
        let typed = await rank(world, text: "work tab", space: world.home)
        XCTAssertEqual(typed.first { $0.title == "Work Tab" }?.subtitle, "work.example")
        let littleArc = await rank(world, space: world.home, presentation: .littleArc)
        XCTAssertEqual(littleArc.first { $0.title == "Work Tab" }?.subtitle, "work.example")
    }

    /// F4 live E3 observed: magnifier for the empty field. [07 §5] E27 observed: with text, the
    /// magnifier unless a command is the first result (B127 replaced the globe).
    func testInputGlyphIsMagnifierWhenEmpty() {
        let command = CommandBarResult(id: "command:openSettings", kind: .command, title: "Settings…",
                                       iconHint: .command, actionLabel: nil, action: .runCommand(.openSettings))
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "", firstResult: nil), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "", firstResult: command), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "swift", firstResult: nil), .magnifier)
        XCTAssertEqual(CommandBarInputGlyph.forField(text: "settings", firstResult: command), .command(.openSettings))
    }

    /// Choosing a tab of another Space switches the window to that Space and selects the tab
    /// ([06 §6] observed rows of other Spaces; the switch is inferred).
    @MainActor
    func testChoosingTabOfAnotherSpaceSwitchesSpace() async throws {
        var fixture = SidebarFixture()
        // The Work tab is the most recent, so it makes the four-tab list.
        let (workTab, later) = (fixture.workTab, fixture.now.addingTimeInterval(5))
        fixture.ws.tabs[workTab]?.lastActiveAt = later
        let f = fixture
        let engine = FakeEngine(clock: { f.now })
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        let shell = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer { shell.stop(); controller.stop() }
        shell.sidebar.selectSpace(f.home)
        shell.presentCommandBar(.newTab)
        await shell.commandBar.waitForRefresh()
        let row = try XCTUnwrap(shell.commandBar.results.first { $0.action == .switchToTab(tabID: f.workTab) },
                                "the Work Space's tab is listed from Home: \(shell.commandBar.results.map(\.title))")
        XCTAssertEqual(row.trailingLabel(for: .window, isSelected: false, currentSpaceID: shell.commandBar.currentSpaceID), "Work")
        shell.perform(row.action)
        XCTAssertEqual(shell.selectedSpaceID, f.work)
        XCTAssertEqual(shell.selectedTabID, f.workTab)
    }

    // MARK: B121: most visited pages

    private static func page(_ host: String, title: String, visits: Int, typed: Int = 0, daysAgo: Double = 1) -> HistoryMatch {
        HistoryMatch(url: URL(string: "https://\(host)/")!, title: title,
                     lastVisit: Self.base.addingTimeInterval(-daysAgo * 86_400), visitCount: visits, typedCount: typed)
    }

    /// The engine (FakeEngine) answers a profile's pages most visited first, at most `maxCount`,
    /// only from that profile, and nothing without history.
    func testFakeEngineTopSitesProvider() async {
        let p = UUID(), q = UUID()
        let auto = FakeAutocomplete(clock: { Self.base })
        auto.addPage(Self.page("a.example", title: "A", visits: 3), profileID: p)
        auto.addPage(Self.page("b.example", title: "B", visits: 9), profileID: p)
        auto.addPage(Self.page("c.example", title: "C", visits: 1, typed: 2), profileID: p)
        auto.addPage(Self.page("q.example", title: "Q", visits: 50), profileID: q)
        let top = await auto.topSites(profileID: p, maxCount: 2)
        XCTAssertEqual(top.map(\.title), ["B", "C"], "visits, a typed visit counting three times")
        let all = await auto.topSites(profileID: p, maxCount: 10)
        XCTAssertEqual(all.map(\.title), ["B", "C", "A"])
        auto.capabilities = []
        let none = await auto.topSites(profileID: p, maxCount: 10)
        XCTAssertEqual(none, [])
        // An engine without a most-visited query answers nothing.
        let unavailable = await UnavailableAutocomplete.shared.topSites(profileID: p, maxCount: 5)
        XCTAssertEqual(unavailable, [])
    }

    /// The source lists pages for an empty or short query only, never in incognito; rows open
    /// the page like a history row (inferred).
    func testTopSitesSourceForEmptyOrShortQueryOnly() async {
        let source = CommandBarTopSitesSource { _ in [Self.page("swift.org", title: "Swift.org", visits: 4)] }
        func rows(_ text: String, incognito: Bool = false) async -> [CommandBarResult] {
            await source.results(for: CommandBarQueryContext(text: text, mode: .newTab, listsHelpOnlyWhenEmpty: incognito))
        }
        let empty = await rows("")
        XCTAssertEqual(empty.map(\.kind), [.topSite])
        XCTAssertEqual(empty.first?.action, .openURL(URL(string: "https://swift.org/")!, target: .newTab))
        XCTAssertEqual(empty.first?.actionLabel, CommandBarTopSitesSource.openLabel)
        let short = await rows("sw")
        XCTAssertEqual(short.count, 1)
        let long = await rows("swi")
        XCTAssertEqual(long, [], "longer than \(CommandBarTopSitesSource.shortQueryMaxLength) characters")
        let incognito = await rows("", incognito: true)
        XCTAssertEqual(incognito, [])
    }

    /// Most visited pages go after the open tabs and before the app command (inferred: the spec
    /// does not place them), only in tab slots left free so the five-row list holds, and never
    /// repeat an open tab.
    func testTopSitesAfterOpenTabsBeforeCommands() async throws {
        let world = try World()
        let sites = [
            Self.page("work.example", title: "Work (open)", visits: 99),
            Self.page("swift.org", title: "Swift.org", visits: 20),
            Self.page("news.example", title: "News", visits: 10),
            Self.page("mail.example", title: "Mail", visits: 5),
        ]
        let rows = await rank(world, space: world.home, topSites: sites)
        XCTAssertEqual(rows.map(\.title), ["Work Tab", "Home Tab", "P Favorite", "Swift.org", "Contact the Team"])
        XCTAssertEqual(rows.map(\.kind), [.todayTab, .todayTab, .favoriteTab, .topSite, .command])

        // With no open tabs, up to `emptyQueryTopSiteLimit` most visited pages fill the list.
        var bare = world
        for id in [world.homeTab, world.workTab, world.pFav] { bare.ws = try TreeOps.archiveTab(bare.ws, id: id, now: Self.base) }
        let onlySites = await rank(bare, space: world.home, topSites: sites)
        XCTAssertEqual(onlySites.map(\.title), ["Work (open)", "Swift.org", "News", "Contact the Team"])

        // A short typed query ranks them like history pages, below the matching open tab.
        let typed = await rank(world, text: "wo", space: world.home, topSites: sites)
        let tabIndex = try XCTUnwrap(typed.firstIndex { $0.title == "Work Tab" })
        XCTAssertFalse(typed.contains { $0.title == "Work (open)" }, "an open page is not repeated")
        XCTAssertTrue(typed.filter { $0.kind == .topSite }.allSatisfy { row in typed.firstIndex(of: row)! > tabIndex })
    }

    /// The window wiring: the FakeEngine's most visited pages of the window's profile reach the
    /// empty bar; an incognito window has none.
    @MainActor
    func testWindowBarShowsEngineTopSites() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine(clock: { f.now })
        engine.fakeAutocomplete.addPage(Self.page("swift.org", title: "Swift.org", visits: 12), profileID: f.profile)
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        let shell = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer { shell.stop(); controller.stop() }
        shell.sidebar.selectSpace(f.home)
        XCTAssertNotNil(shell.commandBarTopSitesSource())
        let rows = await CommandBarTopSitesSource(sites: { maxCount in
            await engine.autocomplete.topSites(profileID: f.profile, maxCount: maxCount)
        }).results(for: CommandBarQueryContext(text: "", mode: .newTab))
        XCTAssertEqual(rows.map(\.title), ["Swift.org"])
        let fromShell = await shell.commandBarTopSitesSource()?.results(for: CommandBarQueryContext(text: "", mode: .newTab))
        // The window may already have loaded a fixture tab into the profile's history (one visit);
        // the most visited page still comes first.
        XCTAssertEqual(fromShell?.first?.title, "Swift.org")
    }
}
