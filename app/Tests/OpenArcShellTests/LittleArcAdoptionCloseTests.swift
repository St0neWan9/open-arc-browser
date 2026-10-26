import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
import OpenArcDesign
@testable import OpenArcShell

/// B30: after ⇧⌘W (no browser window left) → ⌥⌘N → a URL → Return → "Open in Open Arc", an empty
/// compact Little Arc window stayed on screen above the new main window. [06 §7] observed: Little
/// Arc is a command-bar-only window that becomes a browsing window once a page opens; what
/// adoption does to the windows is inferred (the spec does not record it): the Little Arc window
/// goes away and only the main window remains.
///
/// The window was the same one: adoption closed the model (`phase = .closed`), and the window was
/// left to SwiftUI's `dismiss`, which does not reliably close it. A `.closed` model was drawn like
/// a compact one, so the configurator shrank the window back to the empty 490×330 command bar.
/// This hosts the real view in a plain `NSWindow`, where `dismiss` does nothing, so only the
/// window's own close path can remove it.
@MainActor
final class LittleArcAdoptionCloseTests: XCTestCase {
    private func makeController(_ f: SidebarFixture) -> WorkspaceController {
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now.addingTimeInterval(10) }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func host(_ model: LittleArcModel) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: model.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: LittleArcWindowView(model: model))
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    /// Lets the main run loop run SwiftUI updates and the configurator's queued passes.
    private func spin(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testAdoptionWithNoBrowserWindowLeavesNoLittleArcWindow() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        // ⇧⌘W: the only browser window closed.
        let closed = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.work))
        addTeardownBlock { @MainActor in closed.stop() }
        closed.windowDidClose()
        XCTAssertNil(controller.activeWindow)
        var browserRequests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { browserRequests.append($0) }
        var littleArcRequests = 0
        controller.openLittleArcWindow = { _ in littleArcRequests += 1 }

        // ⌥⌘N: a compact Little Arc window on the hidden host.
        let model = LittleArcModel(shell: controller.littleArcHost())
        let window = host(model)
        try await spin(0.2)
        XCTAssertTrue(window.isVisible)

        // "example.edu" + Return: the window expands on the page.
        model.open(try XCTUnwrap(URL(string: "https://example.edu")))
        await model.settleEngineWork()
        try await spin(0.3)
        XCTAssertEqual(model.phase, .expanded)

        // "Open in Open Arc".
        let adopted = try XCTUnwrap(model.adopt())
        try await spin(0.3)
        XCTAssertEqual(model.phase, .closed)
        XCTAssertFalse(window.isVisible, "no Little Arc window is left on screen after adoption")
        XCTAssertNotEqual(window.contentRect(forFrameRect: window.frame).width, Metrics.LittleArc.initialSize.width,
                          "a closed Little Arc window never falls back to the compact command bar")
        XCTAssertEqual(littleArcRequests, 0, "adoption opens no Little Arc window")
        XCTAssertEqual(browserRequests.count, 1, "one main window is requested")
        XCTAssertEqual(browserRequests.first?.tabID, adopted)
    }

    /// Escape in the compact window closes the window itself, not only the model. [06 §7] observed.
    func testEscapeClosesTheHostingWindow() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let model = LittleArcModel(shell: controller.littleArcHost())
        let window = host(model)
        try await spin(0.2)
        XCTAssertEqual(model.commandBar.handle(.escape), .dismiss)
        try await spin(0.2)
        XCTAssertFalse(window.isVisible)
    }

    /// Little Arc windows are never brought back by window restoration on relaunch (they hold an
    /// engine-only page that is gone). inferred.
    func testLittleArcWindowIsNotRestorable() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let window = host(LittleArcModel(shell: controller.littleArcHost()))
        try await spin(0.2)
        XCTAssertFalse(window.isRestorable)
    }
}

/// Window ids: only Little Arc windows this run opened show a command bar (B30, after [A19] for
/// browser windows). A window SwiftUI or macOS brings back from the last session, or the group's
/// default window, starts closed and closes at once.
@MainActor
final class LittleArcWindowIDTests: XCTestCase {
    func testOnlyIssuedWindowIDsGetAnOpenModel() {
        let f = SidebarFixture()
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        let issued = controller.issueLittleArcWindowID()
        XCTAssertTrue(controller.wasIssuedLittleArcWindow(issued))
        XCTAssertEqual(LittleArcModel.window(issued, on: controller).phase, .compact)
        XCTAssertEqual(LittleArcModel.window(UUID(), on: controller).phase, .closed, "a restored window closes")
        XCTAssertEqual(LittleArcModel.window(nil, on: controller).phase, .closed, "the default window closes")
    }

    /// A closed model keeps the size of the phase it closed in: a closing expanded window never
    /// shrinks back to the empty compact command bar. [06 §7] observed compact ≈ 490×330.
    func testClosedModelKeepsItsLastSize() async throws {
        let f = SidebarFixture()
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        let model = LittleArcModel(shell: controller.littleArcHost())
        model.open(try XCTUnwrap(URL(string: "https://example.edu")))
        await model.settleEngineWork()
        model.close()
        XCTAssertEqual(model.phase, .closed)
        XCTAssertEqual(model.displayedPhase, .expanded)
        XCTAssertEqual(model.windowSize, LittleArcTokens.expandedSize)
        await model.settleEngineWork()
    }
}
