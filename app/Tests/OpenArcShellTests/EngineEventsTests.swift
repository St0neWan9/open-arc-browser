import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan C9: every engine event reaches the shell (run against FakeEngine; the Chromium engine
/// delivers the same `TabEvent`s, see ChromiumEngineConformanceTests).
/// Spec: [06 §13] observed the reload button turning into stop while loading; [06 §4] observed the
/// URL box showing the domain; [07 §4] observed the 18 pt row icon cell; [05 §context menus]
/// observed "Mute". The favicon cache, the crash page and the theme color store are our own design
/// (inferred).
@MainActor
final class EngineEventsTests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private var spaceID: UUID!
    private var directory: URL?

    override func setUp() async throws {
        engine = FakeEngine()
        model = makeModel(persistence: nil)
        spaceID = try XCTUnwrap(model.selectedSpaceID)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeModel(persistence: WorkspaceStore?) -> ShellModel {
        ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), persistence: persistence),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    private var controller: WorkspaceController { model.controller }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func openPage(_ address: String) async throws -> (UUID, FakeTab) {
        let opened = try await model.openNewTab(url: try url(address))
        let id = try XCTUnwrap(opened)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        return (id, live)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    private static let otherPNG = Data([0x89, 0x50, 0x4E, 0x47, 9, 9, 9])

    // MARK: Favicons

    /// The engine's PNG reaches the row (sidebar, favorites, split groups use the same lookup),
    /// and the icon URL is stored in the tab record.
    func testFaviconBytesReachTheRowAndTheRecord() async throws {
        let (id, live) = try await openPage("https://www.site.example/a")
        let icon = try url("https://www.site.example/icon.png")
        live.simulateFavicon(Favicon(url: icon, pngData: Self.png))
        try await waitUntil { self.model.sidebar.faviconImage(for: id) == Self.png }
        XCTAssertEqual(model.workspace.tabs[id]?.faviconURL, icon)
    }

    /// An unloaded tab (after relaunch) and archived items show the cached icon; other pages of
    /// the same site share it until their own icon arrives (inferred).
    func testCachedFaviconsServeUnloadedTabsAndOtherPagesOfTheSite() async throws {
        let (id, live) = try await openPage("https://site.example/a")
        let icon = try url("https://site.example/favicon.ico")
        live.simulateFavicon(Favicon(url: icon, pngData: Self.png))
        // FakeEngine already reported this icon URL without bytes on load: wait for the bytes.
        try await waitUntil { self.model.sidebar.faviconImage(for: id) == Self.png }
        XCTAssertEqual(model.workspace.tabs[id]?.faviconURL, icon)

        XCTAssertEqual(controller.faviconImage(iconURL: icon, pageURL: nil), Self.png, "by icon URL")
        XCTAssertEqual(controller.faviconImage(iconURL: nil, pageURL: try url("https://www.site.example/b")), Self.png, "by site")
        XCTAssertNil(controller.faviconImage(iconURL: nil, pageURL: try url("https://elsewhere.example")))

        // Unloading drops the live state; the row still shows the cached icon.
        controller.closeLive(id)
        await controller.settleEngineWork()
        XCTAssertNil(model.sidebar.liveTab(for: id))
        XCTAssertEqual(model.sidebar.faviconImage(for: id), Self.png)
    }

    /// After a cross-site navigation the previous site's icon leaves the row and the record
    /// (inferred), and the new site's icon replaces it when it arrives.
    func testCrossSiteNavigationDropsTheOldIcon() async throws {
        let (id, live) = try await openPage("https://one.example")
        live.simulateFavicon(Favicon(url: try url("https://one.example/i.png"), pngData: Self.png))
        try await waitUntil { self.model.sidebar.faviconImage(for: id) == Self.png }

        // FakeEngine sends the new page's icon URL without bytes: nothing cached for two.example.
        try await live.load(try url("https://two.example"))
        try await waitUntil { self.model.workspace.tabs[id]?.url == URL(string: "https://two.example") }
        XCTAssertNil(model.sidebar.faviconImage(for: id), "no icon of one.example on a two.example row")

        live.simulateFavicon(Favicon(url: try url("https://two.example/i.png"), pngData: Self.otherPNG))
        try await waitUntil { self.model.sidebar.faviconImage(for: id) == Self.otherPNG }
        XCTAssertEqual(model.workspace.tabs[id]?.faviconURL, URL(string: "https://two.example/i.png"))
    }

    /// Command bar tab rows draw their tab's favicon.
    func testCommandBarRowsGetTheTabFavicon() async throws {
        let (id, live) = try await openPage("https://site.example")
        live.simulateFavicon(Favicon(url: try url("https://site.example/i.png"), pngData: Self.png))
        try await waitUntil { self.model.sidebar.faviconImage(for: id) == Self.png }
        let row = CommandBarResult(
            id: "tab:\(id)", kind: .todayTab, title: "Site", url: try url("https://site.example"),
            iconHint: .site(faviconURL: nil), actionLabel: nil, action: .switchToTab(tabID: id)
        )
        XCTAssertEqual(model.commandBar.faviconProvider?(row), Self.png)
        let history = CommandBarResult(
            id: "h", kind: .typedURL, title: "Other page", url: try url("https://site.example/other"),
            iconHint: .site(faviconURL: nil), actionLabel: nil, action: .openURL(try url("https://site.example/other"), target: .currentTab)
        )
        XCTAssertEqual(model.commandBar.faviconProvider?(history), Self.png, "same site")
    }

    /// The on-disk cache brings icons back after relaunch, before any page loads.
    func testFaviconCacheSurvivesRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c9-favicons-\(UUID().uuidString)", isDirectory: true)
        directory = dir
        let icon = try url("https://site.example/favicon.ico")
        let first = FaviconCache(directory: dir)
        first.store(Favicon(url: icon, pngData: Self.png), pageURL: try url("https://site.example/a"))
        let file = FaviconCache.fileURL(dir, key: FaviconCache.iconKey(icon))
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }

        let relaunched = FaviconCache(directory: dir)
        XCTAssertEqual(relaunched.image(iconURL: icon), Self.png)
        XCTAssertEqual(relaunched.image(forPage: try url("https://www.site.example/b")), Self.png)
        XCTAssertNil(FaviconCache(directory: nil).image(iconURL: icon), "memory-only caches start empty")
    }

    /// A page's own icon wins over the last icon seen on its site.
    func testFaviconLookupPrefersThePageOverTheSite() throws {
        let cache = FaviconCache(directory: nil)
        let first = try url("http://host.example/first.html"), second = try url("http://host.example/second.html")
        cache.store(Favicon(url: try url("http://host.example/a.png"), pngData: Self.png), pageURL: first)
        cache.store(Favicon(url: try url("http://host.example/b.png"), pngData: Self.otherPNG), pageURL: second)
        XCTAssertEqual(cache.image(forPage: try url("http://host.example/first.html#part")), Self.png, "same page, fragment ignored")
        XCTAssertEqual(cache.image(forPage: second), Self.otherPNG)
        XCTAssertEqual(cache.image(forPage: try url("http://host.example/third.html")), Self.otherPNG, "site: last icon seen")
    }

    func testFaviconCachePrunesTheOldestFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("c9-prune-\(UUID().uuidString)", isDirectory: true)
        directory = dir
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for index in 0..<5 {
            let file = dir.appendingPathComponent("\(index).png")
            try Self.png.write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
        }
        FaviconCache.prune(dir, keeping: 3)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["2.png", "3.png", "4.png"])
    }

    // MARK: Loading and navigation state

    /// [06 §13] observed: while loading the reload button is stop, and it turns back after.
    func testLoadProgressDrivesTheRowSpinnerAndReloadStop() async throws {
        let (id, live) = try await openPage("https://site.example")
        live.simulateLoadState(LoadState(isLoading: true, progress: 0.3))
        try await waitUntil { self.model.sidebar.liveState(for: id)?.isLoading == true }
        XCTAssertEqual(model.sidebar.reloadMode, .stop)
        XCTAssertEqual(model.sidebar.liveState(for: id)?.progress, 0.3)
        live.simulateLoadState(.idle)
        try await waitUntil { self.model.sidebar.reloadMode == .reload }
    }

    /// Back/forward follow the engine's navigation state.
    func testBackForwardFollowNavigationState() async throws {
        let (_, live) = try await openPage("https://site.example/1")
        XCTAssertFalse(model.sidebar.canGoBack)
        try await live.load(try url("https://site.example/2"))
        try await waitUntil { self.model.sidebar.canGoBack }
        XCTAssertFalse(model.sidebar.canGoForward)
        model.sidebar.goBack()
        try await waitUntil { self.model.sidebar.canGoForward && !self.model.sidebar.canGoBack }
    }

    /// Same-document navigations and redirects update the row title, the record and the URL box.
    func testSameDocumentNavigationAndRedirectUpdateTitleAndURL() async throws {
        let (id, live) = try await openPage("https://site.example/index")
        live.simulateURLChange(try url("https://site.example/index#part"))
        try await waitUntil { self.model.workspace.tabs[id]?.url == URL(string: "https://site.example/index#part") }
        XCTAssertTrue(model.sidebar.canGoBack, "a fragment navigation is a history entry")

        live.simulateURLChange(try url("https://site.example/pushed"), title: "Pushed")
        try await waitUntil { self.model.workspace.tabs[id]?.title == "Pushed" }

        // A redirect to another host: the final URL wins, in the record and in the URL box.
        live.simulateURLChange(try url("https://final.example/landing"), title: "Landing")
        try await waitUntil { self.model.workspace.tabs[id]?.url == URL(string: "https://final.example/landing") }
        XCTAssertEqual(model.sidebar.urlBoxContent, .domain("final.example", isSecure: true))
    }

    // MARK: Audio, crash, theme color

    /// [05 §context menus] observed "Mute": audible state comes from the engine, mute goes back.
    func testAudioStateAndMute() async throws {
        let (id, live) = try await openPage("https://media.example")
        live.simulateAudio(true)
        try await waitUntil { self.model.sidebar.liveState(for: id)?.isAudible == true }
        model.sidebar.toggleMute(id)
        try await waitUntil { self.model.sidebar.liveState(for: id)?.isMuted == true }
        live.simulateAudio(false)
        try await waitUntil { self.model.sidebar.liveState(for: id)?.isAudible == false }
    }

    /// A renderer crash shows the crash page; its Reload brings the page back (own design).
    func testCrashShowsTheCrashPageAndReloadClearsIt() async throws {
        let (id, live) = try await openPage("https://site.example")
        XCTAssertNil(model.crashedPageState(for: id))
        live.simulateCrash()
        try await waitUntil { self.model.crashedPageState(for: id) != nil }
        XCTAssertEqual(model.sidebar.reloadMode, .reload)
        model.crashedPageState(for: id)?.reload()
        try await waitUntil { self.model.crashedPageState(for: id) == nil }
        XCTAssertEqual(live.commands.last, .reload(bypassingCache: false))
    }

    /// The page's theme color is kept on the live state for C17; no UI uses it yet.
    func testThemeColorIsStoredOnTheLiveState() async throws {
        let (id, live) = try await openPage("https://site.example")
        let color = RGBAColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        live.simulateThemeColor(color)
        try await waitUntil { self.model.sidebar.liveState(for: id)?.themeColor == color }
        live.simulateThemeColor(nil)
        try await waitUntil { self.model.sidebar.liveState(for: id)?.themeColor == nil }
    }

    // MARK: New tabs

    /// target=_blank / middle-click without opener contents arrive as URL requests and become a
    /// Today tab next to the opener, loaded by `makeTab` with the opener set (C7b rules).
    func testURLNewTabRequestsOpenNextToTheOpener() async throws {
        let (opener, openerLive) = try await openPage("https://app.example")
        let target = try url("https://app.example/other")
        engine.simulateNewTabRequest(NewTabRequest(opener: openerLive.id, url: target, disposition: .backgroundTab, hasUserGesture: true))
        try await waitUntil { self.model.workspace.today(spaceID: self.spaceID).count == 4 }
        let today = model.workspace.today(spaceID: spaceID).map(\.id)
        XCTAssertEqual(today.first, opener)
        let child = today[1]
        XCTAssertEqual(model.workspace.tabs[child]?.url, target)
        XCTAssertEqual(model.selectedTabID, opener, "a background tab is not selected")
        try await waitUntil { self.model.sidebar.liveTab(for: child) != nil }
        XCTAssertEqual((model.sidebar.liveTab(for: child) as? FakeTab)?.opener, openerLive.id)
    }
}
