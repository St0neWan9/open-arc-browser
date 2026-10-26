import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcDesign
@testable import OpenArcShell

final class MainWindowLayoutTests: XCTestCase {
    /// At the reference window size the web panel lands where it was measured:
    /// left edge x = 276, 10 pt from the top, right and bottom. [04 §window structure]
    func testWebPanelMatchesMeasuredReferenceWindow() {
        let layout = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985))
        XCTAssertEqual(layout.sidebarFrame, CGRect(x: 0, y: 0, width: 276, height: 985))
        XCTAssertEqual(layout.webPanelFrame, CGRect(x: 276, y: 10, width: 1920 - 276 - 10, height: 985 - 20))
    }

    /// [07 §4] observed: URL box x 8–268, y 46–82; favorites y 90–137.
    func testSidebarBlocksUseMeasuredOffsets() {
        let layout = MainWindowLayout(windowSize: CGSize(width: 1920, height: 985))
        XCTAssertEqual(layout.addressFieldFrame.minY, 46)
        XCTAssertEqual(layout.addressFieldFrame.height, 36)
        XCTAssertEqual(layout.addressFieldFrame.minX, 8)
        XCTAssertEqual(layout.addressFieldFrame.maxX, 268)
        XCTAssertEqual(layout.favoritesFrame.minY, 90)
        XCTAssertEqual(layout.favoritesFrame.height, 47)
        XCTAssertLessThanOrEqual(layout.addressFieldFrame.maxX, layout.webPanelFrame.minX)
    }

    func testHiddenSidebarGivesPanelSymmetricInsets() {
        let layout = MainWindowLayout(windowSize: CGSize(width: 1000, height: 600), isSidebarVisible: false)
        XCTAssertEqual(layout.sidebarFrame, .zero)
        // [06 §14] observed: ≈ 5 pt themed border on all four sides while hidden.
        XCTAssertEqual(layout.webPanelFrame, CGRect(x: 5, y: 5, width: 990, height: 590))
    }

    /// [07 §5] observed: 765 × 327 at y 324 in the 1920 × 985 window.
    func testCommandBarIsCenteredAndAboveMiddle() {
        let size = CGSize(width: 1920, height: 985)
        let frame = MainWindowLayout(windowSize: size).commandBarFrame()
        XCTAssertEqual(frame.size, CGSize(width: 765, height: 327))
        XCTAssertEqual(frame.minY, 324)
        XCTAssertEqual(frame.midX, size.width / 2, accuracy: 0.5)
        XCTAssertLessThan(frame.midY, size.height / 2)
    }

    func testTinyWindowNeverProducesNegativeSizes() {
        let layout = MainWindowLayout(windowSize: CGSize(width: 100, height: 10))
        XCTAssertGreaterThanOrEqual(layout.webPanelFrame.width, 0)
        XCTAssertGreaterThanOrEqual(layout.webPanelFrame.height, 0)
    }
}

@MainActor
final class ShellModelTests: XCTestCase {
    func testDemoWorkspaceHasPinnedFolderAndTodayTabs() throws {
        let workspace = WorkspaceState.demo(now: Date(timeIntervalSince1970: 0))
        let space = try XCTUnwrap(workspace.allLiveSpaces.first)
        let pinned = workspace.pinnedChildren(spaceID: space.id, folderID: nil)
        XCTAssertEqual(pinned.count, 1)
        guard case .folder(let folder) = pinned.first else { return XCTFail("expected folder") }
        XCTAssertEqual(workspace.pinnedChildren(spaceID: space.id, folderID: folder.id).count, 1)
        XCTAssertEqual(workspace.today(spaceID: space.id).count, 2)
    }

    func testActivateCreatesEngineTabOnceAndSyncsContent() async throws {
        let engine = FakeEngine(titleProvider: { _ in "Fake Title" })
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore())
        let model = ShellModel(dependencies: deps, workspace: .demo(), now: { Date(timeIntervalSince1970: 100) })
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let tabID = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first).id

        try await model.activate(tabID: tabID)
        try await model.activate(tabID: tabID)

        XCTAssertEqual(engine.tabIDs.count, 1)
        XCTAssertEqual(model.selectedTabID, tabID)
        XCTAssertEqual(model.workspace.tabs[tabID]?.title, "Fake Title")
        XCTAssertEqual(model.workspace.tabs[tabID]?.lastActiveAt, Date(timeIntervalSince1970: 100))
    }

    func testOpenNewTabGoesToTopOfToday() async throws {
        let model = ShellModel(dependencies: .fake(), workspace: .demo())
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let id = try await model.openNewTab(url: URL(string: "https://new.example"))
        XCTAssertEqual(model.workspace.today(spaceID: spaceID).first?.id, id)
        XCTAssertEqual(model.selectedTabID, id)
    }

    func testEnvironmentInjection() {
        let engine = FakeEngine()
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore())
        var env = EnvironmentValues()
        env.appDependencies = deps
        XCTAssertTrue(env.browserEngine === engine)
        XCTAssertTrue(env.syncStore is DisabledSyncStore)
        // Default environment falls back to FakeEngine.
        XCTAssertTrue(EnvironmentValues().browserEngine is FakeEngine)
    }

    func testBundleIdentifierPlaceholder() {
        XCTAssertEqual(AppIdentity.releaseBundleIdentifier, "org.openarc.browser")
        XCTAssertEqual(AppIdentity.developmentBundleIdentifier, "org.openarc.browser.dev")
        // The test host is not one of our bundles, so the release id applies.
        XCTAssertEqual(AppIdentity.bundleIdentifier, "org.openarc.browser")
    }

    /// Drag types are `<bundle id>.<name>`, so the development build exports its own (plan B37).
    func testDragTypesDeriveFromTheBundleIdentifier() {
        XCTAssertEqual(SidebarDragPayload.itemType.identifier, "\(AppIdentity.bundleIdentifier).sidebar-item")
        XCTAssertEqual(LibraryBoardDragPayload.columnType.identifier, "\(AppIdentity.bundleIdentifier).library-space")
    }
}

@MainActor
final class ShellRenderingTests: XCTestCase {
    /// Builds the real root view in an NSHostingView and lays it out (no window, no app launch).
    func testMainWindowViewLaysOutWithFakeEngine() async throws {
        let model = ShellModel(dependencies: .fake(), workspace: .demo())
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        try await model.activate(tabID: try XCTUnwrap(model.workspace.today(spaceID: spaceID).first).id)

        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1920, height: 985)
        // Smoke test: building and laying out the full hierarchy must not crash or assert.
        host.layoutSubtreeIfNeeded()
        XCTAssertNotNil(model.selectedLiveTab)
    }

    func testSurfaceContainerShowsPlaceholder() async throws {
        let engine = FakeEngine(titleProvider: { _ in "Hosted" })
        let tab = try await engine.makeTab(TabConfiguration(profileID: UUID(), initialURL: URL(string: "https://h.example")))
        let container = SurfaceContainerView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        tab.surface.attach(to: container)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertEqual(container.lastPlaceholder?.title, "Hosted")
        tab.surface.detach()
        XCTAssertTrue(container.subviews.isEmpty)
    }
}
