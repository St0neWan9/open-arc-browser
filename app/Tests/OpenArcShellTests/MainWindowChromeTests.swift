import XCTest
import SwiftUI
import AppKit
import OpenArcDesign
@testable import OpenArcShell

/// B16: the main window's traffic lights sit where the reference measures them, and the chrome
/// configurator settles (B28 rule: compare before write, no update loop) across resizes and the
/// Library switch. [07 §2] observed: 16 pt hit boxes at (12, 16), (35, 16), (58, 16), circle
/// centers on y 24; in the Library 3 pt right and 4 pt lower.
@MainActor
final class MainWindowChromeTests: XCTestCase {
    private final class Box: ObservableObject {
        @Published var inLibrary = false
    }

    private struct Root: View {
        @ObservedObject var box: Box
        var body: some View {
            Color.gray
                .background(MainWindowChromeConfigurator(inLibrary: box.inLibrary))
        }
    }

    private func makeWindow(_ box: Box) -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 100, y: 100, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Root(box: box))
        window.orderFront(nil)
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    /// The center of a standard button in window coordinates, top-left origin.
    private func center(_ type: NSWindow.ButtonType, in window: NSWindow) -> CGPoint? {
        guard let button = window.standardWindowButton(type) else { return nil }
        let rect = button.convert(button.bounds, to: nil)
        let height = window.frame.height
        return CGPoint(x: rect.midX, y: height - rect.midY)
    }

    private func spin(_ seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func assertCenters(_ window: NSWindow, dx: CGFloat = 0, dy: CGFloat = 0, file: StaticString = #filePath, line: UInt = #line) {
        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in types.enumerated() {
            guard let c = center(type, in: window) else { return XCTFail("no \(type)", file: file, line: line) }
            XCTAssertEqual(c.x, 20 + CGFloat(index) * 23 + dx, accuracy: 0.5, "\(type) x", file: file, line: line)
            XCTAssertEqual(c.y, 24 + dy, accuracy: 0.5, "\(type) y", file: file, line: line)
        }
    }

    func testTrafficLightsAtMeasuredCentersAndSettle() async throws {
        let box = Box()
        let window = makeWindow(box)
        try await spin(0.3)
        assertCenters(window)

        // Resizing makes AppKit lay the title bar out again; the buttons come back to their spot.
        window.setContentSize(CGSize(width: 1500, height: 900))
        try await spin(0.3)
        assertCenters(window)

        // The Library moves them 3 right and 4 down, and back.
        box.inLibrary = true
        try await spin(0.3)
        assertCenters(window, dx: 3, dy: 4)
        box.inLibrary = false
        try await spin(0.3)
        assertCenters(window)

        // Settled: no more moves while nothing changes.
        let frames = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)?.frame }
        try await spin(0.3)
        XCTAssertEqual([NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)?.frame }, frames)
        XCTAssertFalse(MainWindowChromeConfigurator.Coordinator.needsLayout(window, inLibrary: false))
        XCTAssertFalse(MainWindowChromeConfigurator.Coordinator.apply(to: window, inLibrary: false), "a settled window needs no write")
    }
}
