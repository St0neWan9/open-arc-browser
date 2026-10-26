import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Sidebar hide/show. [01 §View] observed menu item "Hide Sidebar"; [05 §window hierarchy] observed
/// that the hide button sits in the sidebar top bar; [04 §window structure] observed the 10 pt web
/// panel insets. Hidden-state insets and the animation timing are inferred / unknown.
@MainActor
final class SidebarVisibilityTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private let reference = CGSize(width: 1920, height: 985)

    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
    }

    /// [04 §window structure] observed: sidebar showing, panel starts at x = 276 with 10 pt on the
    /// other three sides. Hidden: ≈ 5 pt themed border on all four sides [06 §14] observed,
    /// sidebar frame is empty.
    func testWebPanelFrameInBothStatesAt1920x985() {
        let shown = MainWindowLayout(windowSize: reference, isSidebarVisible: true)
        XCTAssertEqual(shown.webPanelFrame, CGRect(x: 276, y: 10, width: 1634, height: 965))

        let hidden = MainWindowLayout(windowSize: reference, isSidebarVisible: false)
        XCTAssertEqual(hidden.sidebarFrame, .zero)
        // Hiding the sidebar keeps the top/right/bottom inset and gives the left edge the same one.
        XCTAssertEqual(hidden.webPanelFrame.minY, shown.webPanelFrame.minY)
        XCTAssertEqual(hidden.webPanelFrame.maxY, shown.webPanelFrame.maxY)
        XCTAssertEqual(hidden.webPanelFrame.maxX, shown.webPanelFrame.maxX)
        let inset = SidebarPeekTokens.hiddenWebPanelInset
        XCTAssertEqual(hidden.webPanelFrame.minX, inset)
        XCTAssertEqual(hidden.webPanelFrame.minY, inset)
        XCTAssertEqual(reference.width - hidden.webPanelFrame.maxX, inset)
        XCTAssertEqual(reference.height - hidden.webPanelFrame.maxY, inset)
    }

    /// The command bar is centered in the window, so hiding the sidebar does not move it.
    /// [04 §command bar] observed.
    func testCommandBarFrameIsIndependentOfSidebar() {
        let shown = MainWindowLayout(windowSize: reference, isSidebarVisible: true).commandBarFrame()
        let hidden = MainWindowLayout(windowSize: reference, isSidebarVisible: false).commandBarFrame()
        XCTAssertEqual(shown, hidden)
        XCTAssertEqual(hidden.midX, reference.width / 2, accuracy: 0.5)
    }

    /// [06 §5] observed: panes are 10 pt apart and fill the web panel. With the sidebar hidden the
    /// panel is 1900 wide ([06 §14]: the same 10 pt border on all four sides).
    func testSplitPaneFramesFollowHiddenWebPanel() {
        let hiddenPanel = MainWindowLayout(windowSize: reference, isSidebarVisible: false).webPanelFrame
        let container = CGRect(origin: .zero, size: hiddenPanel.size)
        let gap = Metrics.SplitView.paneGap
        for count in 2...4 {
            let ids = (0..<count).map { _ in UUID() }
            let root = SplitNode.split(axis: .horizontal, children: ids.map { SplitChild(node: .pane(tabID: $0), fraction: 1 / Double(count)) })
            let frames = SplitPaneLayout.frames(for: root, in: container)
            XCTAssertEqual(frames.count, count)
            XCTAssertEqual(frames.first?.frame.minX ?? -1, 0, accuracy: 0.001)
            XCTAssertEqual(frames.last?.frame.maxX ?? -1, hiddenPanel.width, accuracy: 0.001)
            XCTAssertEqual(frames[0].frame.width, (hiddenPanel.width - gap * Double(count - 1)) / Double(count), accuracy: 0.001)
            XCTAssertEqual(frames[1].frame.minX - frames[0].frame.maxX, gap, accuracy: 0.001)
            XCTAssertTrue(frames.allSatisfy { $0.frame.height == hiddenPanel.height })
        }
    }

    /// The hide button in the sidebar top bar goes through `SidebarRequest.toggleSidebar`.
    /// [05 §window hierarchy] observed.
    func testSidebarButtonRequestTogglesVisibility() {
        let model = makeModel()
        XCTAssertTrue(model.isSidebarVisible)
        model.sidebar.toggleSidebar()
        XCTAssertFalse(model.isSidebarVisible)
        model.sidebar.toggleSidebar()
        XCTAssertTrue(model.isSidebarVisible)

        var seen: [SidebarRequest] = []
        let forward = model.sidebar.requestHandler
        model.sidebar.requestHandler = { seen.append($0); forward?($0) }
        model.sidebar.toggleSidebar()
        XCTAssertEqual(seen, [.toggleSidebar])
        XCTAssertFalse(model.isSidebarVisible)
    }

    /// [01 §View] observed "Hide Sidebar"; "Show Sidebar" while hidden is inferred. The menu and
    /// the command bar command toggle the same state.
    func testMenuTitleFollowsStateAndAllEntryPointsAgree() {
        let model = makeModel()
        XCTAssertEqual(model.sidebarToggleTitle, "Hide Sidebar")
        model.toggleSidebar()
        XCTAssertEqual(model.sidebarToggleTitle, "Show Sidebar")
        model.perform(.runCommand(.toggleSidebar))
        XCTAssertEqual(model.sidebarToggleTitle, "Hide Sidebar")
        XCTAssertTrue(model.isSidebarVisible)
    }

    /// The Create Space view lives in the sidebar column, so it keeps the column open while the
    /// sidebar is hidden. inferred.
    func testCreateSpaceKeepsColumnOpenWhileHidden() {
        let model = makeModel()
        model.toggleSidebar()
        XCTAssertFalse(model.showsSidebarColumn)
        model.spaceFlow.beginCreate()
        XCTAssertTrue(model.showsSidebarColumn)
        XCTAssertFalse(model.isSidebarVisible)
    }

    func testToggleAnimationIsShort() {
        XCTAssertLessThanOrEqual(ShellLocalTokens.sidebarToggleDuration, 0.3)
        XCTAssertGreaterThan(ShellLocalTokens.sidebarToggleDuration, 0)
    }

    /// Smoke test: the window content builds and lays out with the sidebar hidden, also with a split.
    func testMainWindowContentLaysOutWithSidebarHidden() async throws {
        let model = makeModel()
        model.toggleSidebar()
        let host = NSHostingView(rootView: MainWindowContent(model: model, sidebar: model.sidebar))
        host.frame = CGRect(origin: .zero, size: reference)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.frame.size, reference)

        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let base = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: base)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        XCTAssertNotNil(model.activeSplitLayout)
        // The shell model lays the live panes out inside the hidden-state panel.
        let panel = MainWindowLayout(windowSize: reference, isSidebarVisible: false).webPanelFrame
        let panes = model.splitPaneFrames(in: CGRect(origin: .zero, size: panel.size))
        XCTAssertEqual(panes.count, 2)
        XCTAssertEqual(panes.last?.frame.maxX ?? 0, panel.width, accuracy: 0.001)
        host.layoutSubtreeIfNeeded()
        model.stop()
    }
}
