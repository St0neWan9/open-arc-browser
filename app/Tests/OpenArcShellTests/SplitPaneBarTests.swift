import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// The split pane top bar (B18): layout, per-pane back/forward, ✕, domain pill and dimming.
/// [06 §5] observed: each pane has a top bar with back, forward, a centered domain pill and ✕;
/// an inactive pane's bar is fainter.
@MainActor
final class SplitPaneBarTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
    }

    /// Selects a Today tab and adds a split. Returns (left, right); the right pane is selected.
    private func splitModel(_ model: ShellModel) async throws -> (left: UUID, right: UUID) {
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let base = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: base)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        model.dismissCommandBar()
        let right = try XCTUnwrap(model.selectedTabID)
        for id in [base, right] { await model.sidebar.ensureLive(id) }
        return (base, right)
    }

    /// Loads two pages into `tabID`, so that pane can go back.
    private func navigateTwice(_ model: ShellModel, _ tabID: UUID) async throws {
        let live = try XCTUnwrap(model.sidebar.liveTab(for: tabID))
        try await live.load(URL(string: "https://first.example")!)
        try await live.load(URL(string: "https://second.example")!)
        try await waitUntil {
            let bar = model.paneBarState(for: tabID)
            return bar.canGoBack && bar.domain == "second.example"
        }
    }

    /// Lets the engine's event stream deliver state; bounded.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached")
    }

    private func url(_ model: ShellModel, _ tabID: UUID) async throws -> URL? {
        await (try XCTUnwrap(model.sidebar.liveTab(for: tabID))).currentState().url
    }

    // MARK: Layout

    /// [06 §5]: the bar sits on top of the pane; the page fills the rest and never overlaps it.
    func testBarAndPageFrames() {
        let pane = CGRect(x: 100, y: 20, width: 800, height: 600)
        let layout = SplitPaneBarLayout(paneFrame: pane)
        let h = SplitPaneBarTokens.height
        XCTAssertEqual(layout.barFrame, CGRect(x: 100, y: 20, width: 800, height: h))
        XCTAssertEqual(layout.pageFrame, CGRect(x: 100, y: 20 + h, width: 800, height: 600 - h))
        XCTAssertFalse(layout.pageFrame.intersects(layout.barFrame))
        XCTAssertEqual(layout.barFrame.union(layout.pageFrame), pane)
        // Back and forward on the left, ✕ on the right, the pill centered between them.
        for button in [layout.backButtonFrame, layout.forwardButtonFrame, layout.closeButtonFrame, layout.pillFrame] {
            XCTAssertTrue(layout.barFrame.contains(button))
        }
        XCTAssertLessThan(layout.backButtonFrame.maxX, layout.forwardButtonFrame.minX + 0.001)
        XCTAssertLessThan(layout.forwardButtonFrame.maxX, layout.pillFrame.minX)
        XCTAssertLessThan(layout.pillFrame.maxX, layout.closeButtonFrame.minX)
        XCTAssertEqual(layout.pillFrame.midX, layout.barFrame.midX, accuracy: 0.001)
        XCTAssertEqual(layout.closeButtonFrame.maxX, pane.maxX - SplitPaneBarTokens.horizontalPadding, accuracy: 0.001)
    }

    /// [06 §5]: a pane shorter than the bar gets no page; nothing goes negative.
    func testTinyPaneClampsFrames() {
        let layout = SplitPaneBarLayout(paneFrame: CGRect(x: 0, y: 0, width: 40, height: 10))
        XCTAssertEqual(layout.barFrame.height, 10)
        XCTAssertEqual(layout.pageFrame.height, 0)
        XCTAssertGreaterThanOrEqual(layout.pillFrame.width, 0)
    }

    /// [06 §5]: in the window, every pane's page lies inside its pane and below its bar.
    func testWindowPanesLeaveRoomForBars() async throws {
        let model = makeModel()
        _ = try await splitModel(model)
        let container = CGRect(origin: .zero, size: MainWindowLayout(windowSize: CGSize(width: 1920, height: 985)).webPanelFrame.size)
        let panes = model.splitPaneFrames(in: container)
        XCTAssertEqual(panes.count, 2)
        for pane in panes {
            let layout = SplitPaneBarLayout(paneFrame: pane.frame)
            XCTAssertEqual(layout.pageFrame.minY, layout.barFrame.maxY, accuracy: 0.001)
            XCTAssertTrue(pane.frame.contains(layout.pageFrame))
        }
    }

    // MARK: Actions

    /// [06 §5]: back and forward follow that pane's own history and act on its tab only.
    func testBackForwardActOnThePaneTab() async throws {
        let model = makeModel()
        let (left, right) = try await splitModel(model)
        try await navigateTwice(model, left)
        let rightBefore = try await url(model, right)
        XCTAssertTrue(model.paneBarState(for: left).canGoBack)
        XCTAssertFalse(model.paneBarState(for: left).canGoForward)
        XCTAssertFalse(model.paneBarState(for: right).canGoBack)

        model.paneGoBack(left)
        await model.sidebar.settleEngineWork()
        let afterBack = try await url(model, left)
        XCTAssertEqual(afterBack, URL(string: "https://first.example"))
        XCTAssertEqual(model.selectedTabID, left, "the pane takes focus")
        let rightAfter = try await url(model, right)
        XCTAssertEqual(rightAfter, rightBefore, "the other pane is untouched")

        try await waitUntil { model.paneBarState(for: left).canGoForward }
        model.paneGoForward(left)
        await model.sidebar.settleEngineWork()
        let afterForward = try await url(model, left)
        XCTAssertEqual(afterForward, URL(string: "https://second.example"))
    }

    /// [06 §5]: ✕ closes that pane (not the focused one); with two panes the window returns to a
    /// single page showing the other tab.
    func testCloseButtonClosesThatPane() async throws {
        let model = makeModel()
        let (left, right) = try await splitModel(model)
        XCTAssertEqual(model.selectedTabID, right)
        model.paneClose(left)
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.workspace.tabs[left]?.meta.isTombstone, true, "the closed pane's tab is archived")
        XCTAssertFalse(model.hasActiveSplit)
        XCTAssertEqual(model.selectedTabID, right)
        XCTAssertTrue(model.workspace.tabs[right].map { !$0.meta.isTombstone } ?? false)
    }

    /// [06 §5, §6]: the pill opens the pane command bar in ⌘L mode for that pane's tab,
    /// prefilled with its address.
    func testDomainPillOpensAddressBarForThatPane() async throws {
        let model = makeModel()
        let (left, _) = try await splitModel(model)
        try await navigateTwice(model, left)
        XCTAssertEqual(model.paneBarState(for: left).domain, "second.example")

        model.paneOpenAddressBar(left)
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarPaneTabID, left)
        XCTAssertEqual(model.paneCommandBar.mode, .currentTab)
        XCTAssertEqual(model.paneCommandBar.currentTabID, left)
        XCTAssertEqual(model.paneCommandBar.queryText, "https://second.example")
        XCTAssertEqual(model.selectedTabID, left)
    }

    // MARK: Dimming

    /// [06 §5]: only the inactive pane's bar is dimmed; focusing the other pane swaps it.
    func testInactivePaneIsDimmed() async throws {
        let model = makeModel()
        let (left, right) = try await splitModel(model)
        XCTAssertTrue(model.paneBarState(for: left).isDimmed)
        XCTAssertFalse(model.paneBarState(for: right).isDimmed)
        XCTAssertEqual(model.paneBarState(for: left).opacity, SplitPaneBarTokens.inactiveOpacity)
        XCTAssertEqual(model.paneBarState(for: right).opacity, SplitPaneBarTokens.activeOpacity)
        XCTAssertLessThan(SplitPaneBarTokens.inactiveOpacity, SplitPaneBarTokens.activeOpacity)

        model.focusPane(left)
        XCTAssertFalse(model.paneBarState(for: left).isDimmed)
        XCTAssertTrue(model.paneBarState(for: right).isDimmed)
    }
}
