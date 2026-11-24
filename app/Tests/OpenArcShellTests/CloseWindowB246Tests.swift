import XCTest
import AppKit
@testable import OpenArcShell

/// B246: our title bar buttons are see-through at rest but must still count as buttons: at alpha
/// 0 AppKit treats them as absent, so ⇧⌘W (`performClose`), ⌘M and accessibility found none.
@MainActor
final class CloseWindowB246Tests: XCTestCase {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 300, height: 200),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    func testRestingButtonsStayPresent() async throws {
        let window = makeWindow()
        MainWindowChromeConfigurator.Coordinator.syncMute(in: window)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        XCTAssertEqual(close.alphaValue, WindowButtonLook.restingButtonAlpha, accuracy: 0.0001, "see-through at rest")
        XCTAssertGreaterThan(close.alphaValue, 0)
        XCTAssertTrue(close.isAccessibilityEnabled())
        window.performClose(nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(window.isVisible, "⇧⌘W closes the window")
    }
}
