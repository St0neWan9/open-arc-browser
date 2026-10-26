import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// Split view behind the shell: focus, add, close, separate, expand and rendering.
/// [06 §5] observed; [01 §View] observed menu items.
@MainActor
final class SplitViewShellTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
    }

    /// Selects a Today tab and adds a split. Returns (base, new).
    private func splitModel(_ model: ShellModel) async throws -> (base: UUID, new: UUID) {
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let base = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: base)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        return (base, try XCTUnwrap(model.selectedTabID))
    }

    /// [06 §5] observed: current tab left, new tab right, command bar opens in the new pane.
    func testAddSplitViewPutsNewTabRightAndOpensPaneCommandBar() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        XCTAssertNotEqual(base, new)
        XCTAssertEqual(model.activeSplitLayout?.root.tabIDs, [base, new])
        XCTAssertEqual(model.selectedTabID, new)
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBarPaneTabID, new)
        XCTAssertEqual(model.paneCommandBar.presentation, .pane)
    }

    /// [06 §5] observed: the bar is about 400 pt wide at the lower right of the new pane and does
    /// not cover the left pane.
    func testPaneCommandBarFrameIsLowerRightOfNewPane() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        let container = CGRect(origin: .zero, size: MainWindowLayout(windowSize: CGSize(width: 1920, height: 985)).webPanelFrame.size)
        let panes = model.splitPaneFrames(in: container)
        let left = try XCTUnwrap(panes.first { $0.tabID == base }).frame
        let right = try XCTUnwrap(panes.first { $0.tabID == new }).frame
        let bar = CommandBarLayout(presentation: .pane, resultCount: model.paneCommandBar.results.count)
        let local = bar.panelFrame(in: right.size)
        let inContainer = local.offsetBy(dx: right.minX, dy: right.minY)
        XCTAssertEqual(inContainer.width, Metrics.SplitView.paneCommandBarWidth)
        XCTAssertEqual(inContainer.maxX, right.maxX - CommandBarLayout.paneMargin, accuracy: 0.001)
        XCTAssertEqual(inContainer.maxY, right.maxY - CommandBarLayout.paneMargin, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(inContainer.minX, right.minX)
        XCTAssertGreaterThan(inContainer.minX, left.maxX)
    }

    /// [06 §5] observed: choosing a result loads it into the new pane's tab, even if the selection
    /// moved to the other pane meanwhile.
    func testChoosingAResultLoadsIntoThePaneTab() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        model.sidebar.selectTab(base)
        model.perform(.openURL(URL(string: "https://pane.example")!, target: .currentTab))
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.selectedTabID, new)
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertNil(model.commandBarPaneTabID)
        let state = await model.sidebar.liveTab(for: new)?.currentState()
        XCTAssertEqual(state?.url, URL(string: "https://pane.example"))
        let baseState = await model.sidebar.liveTab(for: base)?.currentState()
        XCTAssertNotEqual(baseState?.url, URL(string: "https://pane.example"))
    }

    /// A window command bar (⌘T) replaces the pane bar and vice versa; only one bar shows.
    func testWindowAndPaneBarsExcludeEachOther() async throws {
        let model = makeModel()
        let (_, new) = try await splitModel(model)
        model.presentCommandBar(.newTab)
        XCTAssertNil(model.commandBarPaneTabID)
        XCTAssertEqual(model.commandBar.mode, .newTab)
        model.presentCommandBarInPane(new)
        XCTAssertEqual(model.commandBarPaneTabID, new)
        model.dismissCommandBar()
        XCTAssertNil(model.commandBarPaneTabID)
        XCTAssertFalse(model.isCommandBarPresented)
    }

    /// Clicking a pane focuses it (selects its tab) and dismisses another pane's bar.
    func testFocusPaneChangesSelection() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        model.focusPane(base)
        XCTAssertEqual(model.selectedTabID, base)
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(model.activeSplitLayout?.root.tabIDs, [base, new], "focus does not change the layout")
        model.focusPane(new)
        XCTAssertEqual(model.selectedTabID, new)
    }

    /// [06 §5] observed: ⌃⇧- closes the pane and returns to a single page.
    func testCloseSplitPaneReturnsToSinglePage() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        model.dismissCommandBar()
        model.closeSplitPane()
        XCTAssertNil(model.activeSplitLayout)
        XCTAssertEqual(model.selectedTabID, base)
        XCTAssertTrue(model.workspace.splits.values.allSatisfy { $0.meta.isTombstone })
        XCTAssertEqual(model.workspace.tabs[new]?.meta.isTombstone, true, "the closed pane's tab is archived")
        XCTAssertEqual(model.workspace.tabs[base]?.meta.isTombstone, false)
    }

    /// Closing one pane of three keeps the other two as a split; the neighbor takes focus.
    func testClosePaneOfThreeKeepsSplit() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        model.dismissCommandBar()
        let third = try XCTUnwrap(model.sidebar.newTab(url: URL(string: "https://third.example")))
        model.sidebar.selectTab(new)
        model.sidebar.openInSplitView(third)
        XCTAssertEqual(model.activeSplitLayout?.root.tabIDs, [base, new, third])
        model.closeSplitPane()
        XCTAssertEqual(model.activeSplitLayout?.root.tabIDs, [base, third])
        XCTAssertEqual(model.selectedTabID, base)
    }

    /// Separate Page from Split View keeps the tab open and selected. [01 §View] observed.
    func testSeparatePageKeepsTab() async throws {
        let model = makeModel()
        let (base, new) = try await splitModel(model)
        model.dismissCommandBar()
        model.separatePageFromSplitView()
        XCTAssertNil(model.activeSplitLayout)
        XCTAssertEqual(model.selectedTabID, new)
        XCTAssertEqual(model.workspace.tabs[new]?.meta.isTombstone, false)
        XCTAssertEqual(model.workspace.tabs[base]?.meta.isTombstone, false)
    }

    /// The split items are available only while a split exists. [01 §View] observed.
    func testSplitItemsRequireASplit() async throws {
        let model = makeModel()
        XCTAssertFalse(model.hasActiveSplit)
        model.closeSplitPane()
        model.separatePageFromSplitView()
        model.toggleExpandCurrentSplit()
        XCTAssertFalse(model.isSplitExpanded)
        _ = try await splitModel(model)
        XCTAssertTrue(model.hasActiveSplit)
    }

    /// Expand Current Split shows only the focused pane; again shows all. inferred.
    func testExpandCurrentSplit() async throws {
        let model = makeModel()
        let (_, new) = try await splitModel(model)
        let container = CGRect(x: 0, y: 0, width: 1634, height: 965)
        model.toggleExpandCurrentSplit()
        XCTAssertEqual(model.splitPaneFrames(in: container), [SplitPaneFrame(tabID: new, frame: container)])
        model.toggleExpandCurrentSplit()
        XCTAssertEqual(model.splitPaneFrames(in: container).count, 2)
        model.toggleExpandCurrentSplit()
        model.dismissCommandBar()
        model.separatePageFromSplitView()
        XCTAssertFalse(model.isSplitExpandedNow)
    }

    /// The window lays out with a split, with and without the pane command bar. [06 §5] observed.
    func testWindowWithSplitLaysOut() async throws {
        let model = makeModel()
        let (_, new) = try await splitModel(model)
        XCTAssertEqual(model.commandBarPaneTabID, new)
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1920, height: 985)
        host.layoutSubtreeIfNeeded()
        model.dismissCommandBar()
        host.layoutSubtreeIfNeeded()
        model.toggleExpandCurrentSplit()
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.hasActiveSplit)
    }

    /// A click inside the pane reports a pointer-down; outside it does not (the event is never consumed).
    func testPointerObserverHitsOnlyInsideBounds() {
        let view = PointerDownObserverView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView?.addSubview(view)
        var count = 0
        view.onPointerDown = { count += 1 }
        view.handle(locationInWindow: CGPoint(x: 50, y: 50))
        view.handle(locationInWindow: CGPoint(x: 200, y: 200))
        XCTAssertEqual(count, 1)
        XCTAssertNil(view.hitTest(CGPoint(x: 50, y: 50)))
    }
}
