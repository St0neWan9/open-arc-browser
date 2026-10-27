import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B49: Peek, the floating preview of a link. Spec: docs/arc-spec/06-flows.md §22 (E2):
/// §22.1 when it opens, §22.2 geometry, buttons, badge and address, §22.3 close / expand / split,
/// §22.4 the ≈ 0.3 s opening; 03 §Links the two switches.
@MainActor
final class LinkPeekTests: XCTestCase {
    private var engine: FakeEngine!
    private var preferences: AppPreferences!
    private var model: ShellModel!
    private var spaceID: UUID!
    private var profileID: UUID!
    private let now = Date(timeIntervalSince1970: 0)

    override func setUp() async throws {
        engine = FakeEngine()
        preferences = .inMemory()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: preferences),
            workspace: .demo(now: now),
            now: { Date(timeIntervalSince1970: 0) }
        )
        spaceID = try XCTUnwrap(model.selectedSpaceID)
        profileID = try XCTUnwrap(model.workspace.defaultProfileID)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var controller: WorkspaceController { model.controller }
    private var peek: LinkPeekModel { model.linkPeek }
    private var todayIDs: [UUID] { model.workspace.today(spaceID: spaceID).map(\.id) }
    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    /// Opens a Today tab on `address`, makes it a favorite when asked, selects it and returns its
    /// id and engine tab once the triggers reached the engine.
    private func showTab(_ address: String, favorite: Bool) async throws -> (UUID, FakeTab) {
        let opened = try await model.openNewTab(url: try url(address))
        let id = try XCTUnwrap(opened)
        if favorite {
            try controller.mutate(origin: nil) { try TreeOps.moveTab($0, id: id, to: .favorite(profileID: self.profileID), position: .last, now: self.now) }
            model.sidebar.selectTab(id)
        }
        try await waitUntil { self.model.sidebar.liveTab(for: id) != nil }
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        await controller.settleEngineWork()
        return (id, live)
    }

    // MARK: - 06 §22.1 when it opens

    /// 06 §22.1 observed (favorites; pinned tabs inferred, 03 §Links note): other-site links in
    /// favorites and pinned tabs, Shift-clicks everywhere; each switch off removes its trigger.
    func testTriggersPerLocationAndSwitches() {
        typealias W = WorkspaceController
        let fav = TabLocation.favorite(profileID: UUID())
        let pinned = TabLocation.pinned(spaceID: UUID(), folderID: nil)
        let today = TabLocation.today(spaceID: UUID())
        XCTAssertEqual(W.linkPreviewTriggers(for: fav, shiftClick: true, otherSites: true), [.otherSiteLink, .shiftClick])
        XCTAssertEqual(W.linkPreviewTriggers(for: pinned, shiftClick: true, otherSites: true), [.otherSiteLink, .shiftClick])
        XCTAssertEqual(W.linkPreviewTriggers(for: today, shiftClick: true, otherSites: true), [.shiftClick])
        XCTAssertEqual(W.linkPreviewTriggers(for: fav, shiftClick: false, otherSites: true), [.otherSiteLink])
        XCTAssertEqual(W.linkPreviewTriggers(for: fav, shiftClick: true, otherSites: false), [.shiftClick])
        XCTAssertEqual(W.linkPreviewTriggers(for: today, shiftClick: false, otherSites: true), [])
    }

    /// 06 §22.1 observed: live tabs get their triggers, and moving a tab between Today and the
    /// favorites, or flipping a switch (03 §Links), updates them.
    func testLiveTabsFollowTheirLocationAndTheSwitches() async throws {
        let (id, live) = try await showTab("https://links.example/", favorite: false)
        XCTAssertEqual(live.currentLinkPreviewTriggers, [.shiftClick])
        try controller.mutate(origin: nil) { try TreeOps.moveTab($0, id: id, to: .favorite(profileID: self.profileID), position: .last, now: self.now) }
        await controller.settleEngineWork()
        XCTAssertEqual(live.currentLinkPreviewTriggers, [.otherSiteLink, .shiftClick])
        let settings = SettingsModel(shell: model)
        settings.opensPeekForOtherSites = false
        await controller.settleEngineWork()
        XCTAssertEqual(live.currentLinkPreviewTriggers, [.shiftClick])
        settings.opensPeekOnShiftClick = false
        await controller.settleEngineWork()
        XCTAssertEqual(live.currentLinkPreviewTriggers, [])
        XCTAssertFalse(preferences.opensPeekOnShiftClick)
    }

    /// 06 §22.1 observed: a favorite's link to another site opens Peek; the favorite keeps its page.
    func testFavoriteOtherSiteLinkOpensPeek() async throws {
        let (id, live) = try await showTab("https://links.example/", favorite: true)
        try await live.simulateLinkClick(to: try url("https://example.org/"))
        try await waitUntil { self.peek.session?.tab != nil }
        XCTAssertEqual(peek.session?.sourceTabID, id)
        XCTAssertEqual(peek.session?.url, try url("https://example.org/"))
        let sourceURL = await live.currentState().url
        XCTAssertEqual(sourceURL, try url("https://links.example/"), "06 §22.3: the favorite is unchanged")
        // 06 §22.2 observed: the address shows the Peek page; the favorite carries the badge.
        XCTAssertEqual(model.sidebar.urlBoxContent, .domain("example.org", isSecure: true))
        XCTAssertEqual(model.sidebar.linkPeekSourceTabID, id)
        XCTAssertEqual(model.selectedTabID, id)
    }

    /// 06 §22.1 observed: a same-site link navigates the favorite; no Peek.
    func testFavoriteSameSiteLinkNavigates() async throws {
        let (_, live) = try await showTab("https://links.example/", favorite: true)
        try await live.simulateLinkClick(to: try url("https://links.example/two"))
        await controller.settleEngineWork()
        XCTAssertNil(peek.session)
        let sourceURL = await live.currentState().url
        XCTAssertEqual(sourceURL, try url("https://links.example/two"))
    }

    /// 06 §22.1 observed: in a Today tab a plain click navigates, a Shift-click opens Peek.
    func testTodayTabPlainClickNavigatesShiftClickPeeks() async throws {
        let (id, live) = try await showTab("https://links.example/", favorite: false)
        try await live.simulateLinkClick(to: try url("https://example.org/"))
        await controller.settleEngineWork()
        XCTAssertNil(peek.session, "plain click navigates in place")
        try await live.simulateLinkClick(to: try url("https://www.iana.org/"), shift: true)
        try await waitUntil { self.peek.session?.tab != nil }
        XCTAssertEqual(peek.session?.sourceTabID, id)
        XCTAssertEqual(peek.session?.url, try url("https://www.iana.org/"))
    }

    /// 03 §Links: with the Shift-click switch off a Shift-click opens a new window as before ([06 §4]).
    func testShiftClickSwitchOffKeepsTheNewWindow() async throws {
        preferences.opensPeekOnShiftClick = false
        controller.syncLinkPreviewTriggers()
        let (_, live) = try await showTab("https://links.example/", favorite: false)
        let before = todayIDs.count
        try await live.simulateLinkClick(to: try url("https://example.org/"), shift: true)
        try await waitUntil { self.todayIDs.count == before + 1 }
        XCTAssertNil(peek.session)
    }

    // MARK: - 06 §22.3 close, expand, split

    private func openPeek() async throws -> (UUID, FakeTab) {
        let (id, live) = try await showTab("https://links.example/", favorite: true)
        try await live.simulateLinkClick(to: try url("https://example.org/"))
        try await waitUntil { self.peek.session?.tab != nil }
        return (id, live)
    }

    /// 06 §22.3 observed: closing returns to the unchanged favorite; the Peek page goes away.
    func testCloseDiscardsThePeekPage() async throws {
        let (id, _) = try await openPeek()
        let peekTab = try XCTUnwrap(peek.session?.tab)
        let tabsBefore = model.workspace.tabs.count
        peek.close()
        await controller.settleEngineWork()
        XCTAssertNil(peek.session)
        XCTAssertFalse(engine.tabIDs.contains(peekTab))
        XCTAssertEqual(model.workspace.tabs.count, tabsBefore, "no model tab was made")
        XCTAssertEqual(model.selectedTabID, id)
        XCTAssertNil(model.sidebar.linkPeekSourceTabID)
        XCTAssertEqual(model.sidebar.urlBoxContent, .domain("links.example", isSecure: true))
    }

    /// 06 §22.3 observed: ⤢ makes the Peek page a new tab at the top of Today, selected; the
    /// favorite keeps its URL. The engine tab is kept (inferred).
    func testExpandMakesATodayTabAtTheTop() async throws {
        let (favorite, _) = try await openPeek()
        let peekTab = try XCTUnwrap(peek.session?.tab)
        let id = try XCTUnwrap(peek.expand())
        await controller.settleEngineWork()
        XCTAssertEqual(todayIDs.first, id)
        XCTAssertEqual(model.selectedTabID, id)
        XCTAssertEqual(model.workspace.tabs[id]?.url, try url("https://example.org/"))
        XCTAssertEqual(model.sidebar.liveTab(for: id)?.id, peekTab, "the Peek page's engine tab moves over")
        XCTAssertEqual(model.workspace.tabs[favorite]?.url, try url("https://links.example/"))
        XCTAssertNil(peek.session)
    }

    /// 06 §22.3 observed: ▯▯ makes a split row in Today: left a copy of the source page, right
    /// the Peek page, focused; the favorite is unchanged.
    func testSplitPutsACopyOfTheSourceLeftAndThePeekRight() async throws {
        let (favorite, _) = try await openPeek()
        let ids = try XCTUnwrap(peek.openInSplit())
        await controller.settleEngineWork()
        let layout = try XCTUnwrap(SplitPaneLayout.activeLayout(in: model.workspace, containing: ids.peek))
        XCTAssertEqual(layout.root.tabIDs, [ids.copy, ids.peek])
        XCTAssertEqual(model.selectedTabID, ids.peek)
        XCTAssertEqual(model.workspace.tabs[ids.copy]?.url, try url("https://links.example/"))
        XCTAssertEqual(model.workspace.tabs[ids.peek]?.url, try url("https://example.org/"))
        XCTAssertEqual(Array(todayIDs.prefix(2)), [ids.copy, ids.peek])
        XCTAssertEqual(model.workspace.tabs[favorite]?.location, .favorite(profileID: profileID))
        XCTAssertNotNil(model.sidebar.liveTab(for: ids.copy))
    }

    /// inferred: choosing another tab closes the preview.
    func testSelectingAnotherTabClosesPeek() async throws {
        _ = try await openPeek()
        let other = try XCTUnwrap(todayIDs.first)
        model.sidebar.selectTab(other)
        XCTAssertNil(peek.session)
    }

    // MARK: - 06 §22.2 geometry, §22.4 motion

    /// 06 §22.2 observed in a 1920 × 985 window: panel x 440–1755, y 12–972; buttons 34 × 33 at
    /// x 1768, y 19 / 63 / 106 observed (the pitch 44 gives 107, within the 1 pt rounding); the
    /// page behind inset ≈ 9.5 on every side.
    func testGeometryAtTheReferenceSize() {
        let window = CGSize(width: 1920, height: 985)
        let base = MainWindowLayout(windowSize: window).webPanelFrame
        XCTAssertEqual(base, CGRect(x: 276, y: 10, width: 1634, height: 965))
        let layout = LinkPeekLayout(windowSize: window, webPanelFrame: base)
        let panel = layout.panelFrame
        XCTAssertEqual(panel.minX, 440, accuracy: 0.5)
        XCTAssertEqual(panel.maxX, 1755, accuracy: 0.5)
        XCTAssertEqual(panel.minY, 12, accuracy: 0.01)
        // 06 §22.2 gives y 12–972 and height 961: the AX height (961) wins, so the bottom is 973.
        XCTAssertEqual(panel.height, 961, accuracy: 0.01)
        let buttons = layout.buttonFrames
        XCTAssertEqual(buttons.count, 3)
        XCTAssertEqual(buttons[0].minX, 1768, accuracy: 0.5)
        XCTAssertEqual(buttons.map(\.minY), [19, 63, 107])
        XCTAssertEqual(buttons[0].size, CGSize(width: 34, height: 33))
        XCTAssertEqual(LinkPeekButtonKind.allCases, [.close, .expand, .split])
        let behind = MainWindowLayout(windowSize: window).withPeekInset().webPanelFrame
        XCTAssertEqual(behind, base.insetBy(dx: 9.5, dy: 9.5))
    }

    /// inferred (06 §22.5: other sizes not captured): the panel follows the web panel and the
    /// buttons stay inside the window.
    func testGeometryInANarrowWindowKeepsTheButtonsOnScreen() {
        let window = CGSize(width: 900, height: 600)
        let base = MainWindowLayout(windowSize: window).webPanelFrame
        let layout = LinkPeekLayout(windowSize: window, webPanelFrame: base)
        XCTAssertLessThanOrEqual(layout.buttonFrames[0].maxX, window.width)
        XCTAssertGreaterThanOrEqual(layout.panelFrame.minX, base.minX)
        XCTAssertEqual(layout.panelFrame.height, 600 - 985 + 961, accuracy: 0.01)
    }

    /// 06 §22.4 observed ≈ 0.3 s, buttons from 133 pt to the left; curve unknown.
    func testOpeningMotionToken() {
        XCTAssertEqual(Motion.peekOpen.curve.nominalDuration, 0.3, accuracy: 0.001)
        XCTAssertEqual(Motion.peekOpen.evidence, .unknown)
        XCTAssertEqual(Motion.peekButtonsStartOffsetX, -133)
    }

    /// 06 §22.2 observed: a white page under the veil reads ≈ #76727E (dark appearance).
    func testDimColorOverWhite() {
        let c = PeekColors.dim, a = PeekColors.dimOpacity
        let mixed = (c.red * a + (1 - a), c.green * a + (1 - a), c.blue * a + (1 - a))
        XCTAssertEqual(mixed.0 * 255, 0x76, accuracy: 3)
        XCTAssertEqual(mixed.1 * 255, 0x72, accuracy: 3)
        XCTAssertEqual(mixed.2 * 255, 0x7E, accuracy: 3)
    }
}
