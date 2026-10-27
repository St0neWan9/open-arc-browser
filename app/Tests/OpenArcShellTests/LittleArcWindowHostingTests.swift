import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// B28: expanding a Little Arc window (compact → expanded) hung the app in a SwiftUI update loop,
/// because the window configurator wrote window properties on every view update and each write
/// invalidated the hosting view again. This hosts the real view in a real window, expands it,
/// resizes it, and checks that the configurator settles. [06 §7] observed: the window starts
/// command-bar-only at 490×329 ([07 §11, §12] observed) and becomes a browsing window once a page is opened; the expanded
/// size is `LittleArcTokens.expandedSize` (unknown).
@MainActor
final class LittleArcWindowHostingTests: XCTestCase {
    private func makeShell() -> ShellModel {
        let shell = ShellModel(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        addTeardownBlock { @MainActor in shell.stop() }
        return shell
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

    private func contentSize(_ window: NSWindow) -> CGSize {
        window.contentRect(forFrameRect: window.frame).size
    }

    /// Gives the main run loop `seconds` to run SwiftUI updates and queued main-queue work (the
    /// test suspends; a nested `RunLoop.run` would not drain the main queue from an async test). A
    /// configurator that keeps invalidating its hosting view starves the main actor, so the test
    /// never resumes (the loop of B28 ran inside one run-loop pass).
    private func spin(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func testExpandAndResizeSettle() async throws {
        let model = LittleArcModel(shell: makeShell())
        let window = host(model)
        LittleArcWindowConfigurator.diagnostics = .init()
        try await spin(0.2)
        // The hosting view may add the hidden title bar's inset to the height.
        XCTAssertEqual(contentSize(window).width, model.windowSize.width, "compact size [06 §7]")
        XCTAssertEqual(contentSize(window).height, model.windowSize.height, accuracy: 40, "compact size [06 §7]")
        XCTAssertFalse(window.styleMask.contains(.resizable), "compact is a fixed size")
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, true, "compact: no title bar controls [06 §7]")

        model.open(URL(string: "https://swift.org/blog")!)
        await model.settleEngineWork()
        XCTAssertNotNil(model.liveTab)
        try await spin(0.5)
        XCTAssertEqual(model.phase, .expanded)
        XCTAssertEqual(contentSize(window), LittleArcTokens.expandedSize)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.standardWindowButton(.closeButton)?.isHidden, false)

        // The user resizes the expanded window; the configurator must neither loop nor undo it.
        let resized = CGSize(width: 1000, height: 760)
        window.setContentSize(resized)
        try await spin(0.5)
        XCTAssertEqual(contentSize(window), resized)

        // Settled: more run-loop time costs no more configurator passes.
        let settled = LittleArcWindowConfigurator.diagnostics
        try await spin(0.3)
        XCTAssertEqual(LittleArcWindowConfigurator.diagnostics.passCount, settled.passCount, "configurator keeps running")
        XCTAssertLessThan(settled.passCount, 30, "configurator passes are bounded")
        // One write pass per phase (compact, expanded); a pass that finds nothing to change writes nothing.
        XCTAssertLessThanOrEqual(settled.writeCount, 3)
    }
}
