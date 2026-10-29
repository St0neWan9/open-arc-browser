import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B103: the first selection of a tab without an engine tab costs one frame on the main
/// thread. The click's pass shows the selection and the empty panel in the theme color
/// ([07 §8.1] observed: the empty panel is the theme tint, with no text); the engine tab, its page
/// and the record's title follow in later passes, and the menu bar is rebuilt only when a value it
/// shows changed. Nothing is made ahead of a selection.
@MainActor
final class FirstSelectTests: XCTestCase {
    private let f = SidebarFixture()
    private var engine: FakeEngine!
    private var controller: WorkspaceController!

    override func setUp() async throws {
        engine = FakeEngine()
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let ids = SidebarIDSource()
        let fixed = f.now.addingTimeInterval(10)
        controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { fixed }, makeID: { ids.make() },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
        engine = nil
    }

    private func window() -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.home))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    /// [07 §8.1] observed (empty panel), B103: the selection lands at once; the engine tab does
    /// not exist yet in the click's pass and is made in a later one.
    func testEngineTabIsMadeAfterTheSelectionsPassSpec07Section8_1() async throws {
        let model = window()
        let before = engine.tabIDs
        model.sidebar.selectTab(f.today1)
        XCTAssertEqual(model.selectedTabID, f.today1, "the click selects at once")
        XCTAssertNil(model.selectedLiveTab, "the click's pass shows the empty panel")
        XCTAssertEqual(engine.tabIDs, before, "no engine tab in the click's pass")
        await model.sidebar.settleEngineWork()
        XCTAssertNotNil(model.selectedLiveTab, "the engine tab follows")
        XCTAssertEqual(engine.tabIDs.count, before.count + 1)
    }

    /// B103: selecting through tabs quickly makes engine tabs only for the tabs selected, one each,
    /// and a tab that went away before its turn gets none.
    func testOnlySelectedTabsGetOneEngineTabEach() async throws {
        let model = window()
        model.sidebar.selectTab(f.today1)
        model.sidebar.selectTab(f.today2)
        model.sidebar.selectTab(f.today1)
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(engine.tabIDs.count, 2, "today1 and today2, once each")
        XCTAssertNil(controller.liveTab(for: f.today3), "nothing is made ahead of a selection")

        model.sidebar.selectTab(f.today3)
        try controller.mutate(origin: nil) { try TreeOps.archiveTab($0, id: self.f.today3, reason: .closed, now: self.f.now) }
        await model.sidebar.settleEngineWork()
        XCTAssertNil(controller.liveTab(for: f.today3), "archived before its pass: no engine tab")
        XCTAssertEqual(engine.tabIDs.count, 2)
    }

    /// B103: two callers asking for the same tab's engine tab share one; both see it when they
    /// return (AppleScript `execute` relies on that).
    func testConcurrentEnsureLiveShareOneEngineTab() async throws {
        let controller = try XCTUnwrap(controller)
        let id = f.today1, profile = f.profile
        let first = Task { try await controller.ensureLive(id, fallbackProfileID: profile) }
        let second = Task { try await controller.ensureLive(id, fallbackProfileID: profile) }
        try await first.value
        try await second.value
        XCTAssertNotNil(controller.liveTab(for: f.today1))
        XCTAssertEqual(engine.tabIDs.count, 1)
    }

    /// B103: a page's URL, title and favicon reach the tab record after the pass that reported
    /// them, as one change per burst.
    func testPageContentReachesTheRecordAfterTheEventsPass() async throws {
        let model = window()
        model.sidebar.selectTab(f.today1)
        await model.sidebar.settleEngineWork()
        let live = try XCTUnwrap(model.selectedLiveTab as? FakeTab)
        let changes = controller.workspaceGeneration
        let next = try url("https://next.example.com/a")
        live.simulateURLChange(next, title: "Next page")
        for _ in 0..<200 where controller.liveState(for: f.today1)?.title != "Next page" { await Task.yield() }
        XCTAssertEqual(controller.liveState(for: f.today1)?.title, "Next page", "the live state follows the event")
        await controller.settleEngineWork()
        XCTAssertEqual(controller.workspace.tabs[f.today1]?.url, next)
        XCTAssertEqual(controller.workspace.tabs[f.today1]?.title, "Next page")
        XCTAssertEqual(controller.workspaceGeneration - changes, 1, "URL and title: one record change")
    }

    /// B103: the menu bar is rebuilt when a value it shows changes (the pin title, back and
    /// forward), not when the window changes in a way the menus do not show.
    func testMenuBarPublishesOnlyForValuesItShows() async throws {
        let model = window()
        let menuBar = model.menuBar
        model.sidebar.selectTab(f.today1)
        await model.sidebar.settleEngineWork()
        menuBar.check()
        let published = menuBar.publishCount
        XCTAssertEqual(menuBar.inputs, model.menuBarInputs)

        // A title change of another tab's page: nothing the menus show.
        model.sidebar.selectTab(f.today2)
        await model.sidebar.settleEngineWork()
        menuBar.check()
        let afterSelect = menuBar.publishCount
        let other = try XCTUnwrap(controller.liveTab(for: f.today1) as? FakeTab)
        other.simulateURLChange(try url("https://other.example.com/b"), title: "Other")
        await controller.settleEngineWork()
        menuBar.check()
        XCTAssertEqual(menuBar.publishCount, afterSelect, "a background page's title changes no menu")
        XCTAssertGreaterThanOrEqual(afterSelect, published)

        // Pinning the selected tab flips Tabs ▸ Pin Tab to Unpin Tab ([06 §16.2] observed).
        model.sidebar.togglePin(f.today2)
        menuBar.check()
        XCTAssertEqual(menuBar.inputs.pinMenuTitle, "Unpin Tab")
        XCTAssertEqual(menuBar.publishCount, afterSelect + 1)
    }

    /// B103: the check runs by itself after a change, in a later pass.
    func testMenuBarChecksAfterAChange() async throws {
        let model = window()
        let menuBar = model.menuBar
        XCTAssertFalse(menuBar.inputs.hasSelectedTab)
        model.sidebar.selectTab(f.today1)
        XCTAssertFalse(menuBar.inputs.hasSelectedTab, "not in the click's pass")
        for _ in 0..<200 where !menuBar.inputs.hasSelectedTab { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(menuBar.inputs.hasSelectedTab)
    }

    /// B103: View ▸ Collapse Pinned Tabs is enabled while the Space has pinned content, also once
    /// collapsed (it then reads Expand Pinned Tabs), and comes from the memoized rows.
    func testCollapsePinnedAvailability() {
        let model = window()
        XCTAssertTrue(model.sidebar.canCollapsePinned)
        model.sidebar.toggleCollapsePinned()
        XCTAssertTrue(model.sidebar.canCollapsePinned, "the area keeps its content while collapsed")
        XCTAssertTrue(model.menuBarInputs.canCollapsePinned)
        model.sidebar.selectSpace(f.work)
        XCTAssertFalse(model.sidebar.canCollapsePinned, "the Work Space has no pinned items")
    }
}
