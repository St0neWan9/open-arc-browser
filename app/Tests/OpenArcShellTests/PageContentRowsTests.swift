import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B107: a page load mirrors its URL, title and favicon into the tab record. That change moves
/// no row, so the sidebar replaces those tabs in the rows it already has instead of walking the
/// Space again, and the commit skips the work that follows from a tab's place (color schemes, link
/// preview triggers, engine profiles). The rows must still equal a fresh derivation.
@MainActor
final class PageContentRowsTests: XCTestCase {
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

    /// The rows a fresh walk of the Space makes now.
    private func freshRows(_ sidebar: SidebarViewModel) -> SidebarSnapshot {
        SidebarSnapshot.make(workspace: controller.workspace, spaceID: sidebar.selectedSpaceID, profileID: sidebar.currentProfileID)
    }

    /// Loads `next` in `id`'s page and waits until the record shows it.
    private func load(_ id: UUID, _ sidebar: SidebarViewModel, url next: URL, title: String) async throws {
        sidebar.selectTab(id)
        await sidebar.settleEngineWork()
        let live = try XCTUnwrap(controller.liveTab(for: id) as? FakeTab)
        live.simulateURLChange(next, title: title)
        for _ in 0..<200 where controller.liveState(for: id)?.title != title { await Task.yield() }
        await controller.settleEngineWork()
        XCTAssertEqual(controller.workspace.tabs[id]?.title, title)
    }

    /// A pinned tab, a tab in a nested folder and a Today tab load pages: their rows show the new
    /// title and URL in place, the rows equal a fresh walk, and the Space's structure counter did
    /// not move (the rows were patched, not derived again).
    func testPageContentPatchesTheRowsInPlace() async throws {
        let model = window()
        let sidebar = model.sidebar
        let before = sidebar.listContent
        let structure = controller.sidebarStructureGeneration
        try await load(f.pinnedTab, sidebar, url: url("https://pinned.example.com/next"), title: "Pinned next")
        try await load(f.deepTab, sidebar, url: url("https://deep.example.com/next"), title: "Deep next")
        try await load(f.today2, sidebar, url: url("https://today2.example.com/next"), title: "Today next")
        XCTAssertEqual(controller.sidebarStructureGeneration, structure, "content changes leave the structure alone")

        let after = sidebar.listContent
        XCTAssertFalse(after === before, "the rows changed")
        XCTAssertTrue(after.snapshot.hasSameRows(as: freshRows(sidebar)), "patched rows equal a fresh walk")
        XCTAssertEqual(after.snapshot.pinned.map(\.id), before.snapshot.pinned.map(\.id), "no row moved")
        XCTAssertEqual(after.geometry.entries.map(\.top), before.geometry.entries.map(\.top))
        let rows = Dictionary(uniqueKeysWithValues: after.geometry.entries.compactMap { entry -> (UUID, TabNode)? in
            if case .row(let item) = entry.content, case .tab(let tab) = item.kind { return (tab.id, tab) }
            return nil
        })
        XCTAssertEqual(rows[f.pinnedTab]?.title, "Pinned next")
        XCTAssertEqual(rows[f.deepTab]?.title, "Deep next")
        XCTAssertEqual(rows[f.today2]?.url, try url("https://today2.example.com/next"))
    }

    /// A favorite's page title reaches the favorites block too.
    func testFavoriteContentPatchesTheFavorites() async throws {
        let model = window()
        let sidebar = model.sidebar
        _ = sidebar.listContent
        try await load(f.fav1, sidebar, url: url("https://fav1.example.com/next"), title: "Fav next")
        XCTAssertEqual(sidebar.snapshot.favorites.first { $0.id == f.fav1 }?.title, "Fav next")
        XCTAssertTrue(sidebar.snapshot.hasSameRows(as: freshRows(sidebar)))
    }

    /// A split group's member that loads a page updates the group row.
    func testSplitMemberContentPatchesTheGroupRow() async throws {
        let layoutID = SidebarFixture.id(900)
        try controller.mutate(origin: nil) {
            try TreeOps.splitTab($0, layoutID: layoutID, tabID: self.f.today1, targetTabID: self.f.today2,
                                 side: .trailing, moveNextToTarget: true, now: self.f.now)
        }
        let model = window()
        let sidebar = model.sidebar
        XCTAssertNotNil(sidebar.snapshot.splitGroup(layoutID: layoutID))
        try await load(f.today1, sidebar, url: url("https://today1.example.com/next"), title: "Member next")
        let group = try XCTUnwrap(sidebar.snapshot.splitGroup(layoutID: layoutID))
        XCTAssertEqual(group.members.first { $0.id == f.today1 }?.title, "Member next")
        XCTAssertTrue(sidebar.snapshot.hasSameRows(as: freshRows(sidebar)))
    }

    /// Any other change (a rename, a move) walks the Space again: the rows follow it.
    func testStructuralChangeAfterContentChangeStillDerivesTheRows() async throws {
        let model = window()
        let sidebar = model.sidebar
        try await load(f.today1, sidebar, url: url("https://today1.example.com/next"), title: "Next")
        let structure = controller.sidebarStructureGeneration
        sidebar.togglePin(f.today3)
        XCTAssertGreaterThan(controller.sidebarStructureGeneration, structure)
        XCTAssertTrue(sidebar.snapshot.hasSameRows(as: freshRows(sidebar)))
        XCTAssertTrue(sidebar.snapshot.pinned.contains { $0.id == f.today3 })
    }

    /// Several pages reporting in one pass cost one record change.
    func testContentOfSeveralPagesIsOneChange() async throws {
        let model = window()
        let sidebar = model.sidebar
        sidebar.selectTab(f.today1)
        sidebar.selectTab(f.today2)
        await sidebar.settleEngineWork()
        let changes = controller.workspaceGeneration
        // Both pages' events in one pass (as the engine delivers a burst), without awaiting between.
        controller.apply(.urlChanged(try url("https://one.example.com")), to: f.today1)
        controller.apply(.titleChanged("One"), to: f.today1)
        controller.apply(.urlChanged(try url("https://two.example.com")), to: f.today2)
        controller.apply(.titleChanged("Two"), to: f.today2)
        await controller.settleEngineWork()
        XCTAssertEqual(controller.workspace.tabs[f.today1]?.title, "One")
        XCTAssertEqual(controller.workspace.tabs[f.today2]?.title, "Two")
        XCTAssertEqual(controller.workspaceGeneration - changes, 1, "both pages: one record change")
        XCTAssertTrue(sidebar.snapshot.hasSameRows(as: freshRows(sidebar)))
    }

    /// A URL loaded in a live tab (⌘L, Reset to Pinned URL) is in the tab's record once engine
    /// work settles, even right after a quick run of selections (B107 merge check: the record lagged
    /// behind the event stream, so an Add Split pane that had loaded a page still looked empty).
    func testLoadInLiveTabReachesTheRecordWhenEngineWorkSettles() async throws {
        let model = window()
        let sidebar = model.sidebar
        for _ in 0..<20 {
            sidebar.selectTab(f.today1)
            await sidebar.settleEngineWork()
            sidebar.selectTab(f.today2)
            sidebar.selectTab(f.today1)
            let next = try url("https://loaded.example/\(Int.random(in: 0..<1_000_000))")
            sidebar.navigateSelectedTab(to: next)
            await sidebar.settleEngineWork()
            XCTAssertEqual(controller.workspace.tabs[f.today1]?.url, next, "the record shows the loaded page")
        }
    }

    /// The content log answers only as far back as it reaches.
    func testContentLogAnswersOnlyWithinItsReach() async throws {
        let model = window()
        let sidebar = model.sidebar
        let start = controller.sidebarRowsGeneration
        XCTAssertEqual(controller.tabsWithContentChanges(afterRowsGeneration: start), [])
        try await load(f.today1, sidebar, url: url("https://today1.example.com/a"), title: "A")
        XCTAssertEqual(controller.tabsWithContentChanges(afterRowsGeneration: start), [f.today1])
        // A structural change is not in the log.
        sidebar.togglePin(f.today3)
        XCTAssertNil(controller.tabsWithContentChanges(afterRowsGeneration: start))
    }
}
