import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// Plan B218: the hovered link's address at the web panel's bottom left.
/// Spec: docs/arc-spec/06-flows.md §44 (observed in Arc 1.170).
final class LinkStatusB218Tests: XCTestCase {
    private func text(_ string: String) -> String { LinkStatusText.display(URL(string: string)!) }

    /// [06 §44] observed: no scheme, no bare trailing slash; path, query and fragment stay.
    func testDisplayText() {
        XCTAssertEqual(text("https://example.org/"), "example.org")
        XCTAssertEqual(text("http://neverssl.com/"), "neverssl.com")
        XCTAssertEqual(text("https://example.com/some/long/path/to/a/page?query=value&other=1#section"),
                       "example.com/some/long/path/to/a/page?query=value&other=1#section")
        XCTAssertEqual(text("mailto:someone@example.com"), "mailto:someone@example.com", "other schemes in full")
    }

    /// [06 §44] observed on a #FEEFE4 window: fill #F7F3ED, text #615B55.
    func testLightColorsMatchTheCapture() {
        let colors = LinkStatusTokens.colors(windowBackground: RGBAColor(hex: 0xFEEFE4), isDark: false)
        let observed = RGBAColor(hex: 0xF7F3ED)
        XCTAssertEqual(colors.fill.red, observed.red, accuracy: 2.0 / 255)
        XCTAssertEqual(colors.fill.green, observed.green, accuracy: 3.0 / 255)
        XCTAssertEqual(colors.fill.blue, observed.blue, accuracy: 3.0 / 255)
        XCTAssertEqual(colors.text, RGBAColor(hex: 0x615B55))
    }

    /// Long addresses stop at ≈ 400 pt (then cut in the middle); short ones hug the text.
    @MainActor
    func testPillWidthIsCapped() {
        let long = LinkStatusBubble.textWidth(String(repeating: "example.com/path/", count: 10))
        XCTAssertGreaterThan(long, CGFloat(LinkStatusTokens.maxWidth))
        XCTAssertLessThan(LinkStatusBubble.textWidth("example.org"), 100)
    }

    /// The pill follows the page's hovered link: drawn at the bottom left while a link is under
    /// the pointer, gone after. Rendered offscreen.
    @MainActor
    func testBubbleFollowsTheHoveredLink() async throws {
        let engine = FakeEngine()
        let made = try await engine.makeTab(TabConfiguration(profileID: UUID()))
        let tab = try XCTUnwrap(made as? FakeTab)
        let host = NSHostingView(rootView: LinkStatusBubble(tab: tab, palette: nil).frame(width: 600, height: 300).background(Color.white))
        host.frame = CGRect(x: 0, y: 0, width: 600, height: 300)
        // In a window far off screen: SwiftUI starts the view's task once it is in a window.
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 600, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        // Inside the pill, left of its text, on its middle row (pill 24 tall, 10 pt from the edges).
        func pillPixel() -> NSColor? {
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / 600
            return rep.colorAt(x: Int(15 * scale), y: Int((300 - 22) * scale))?.usingColorSpace(.sRGB)
        }
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<200 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(condition())
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(pillPixel()?.redComponent ?? 0, 1, accuracy: 0.01, "nothing before a hover")
        tab.simulateHoveredLink(URL(string: "https://example.org/"))
        try await waitFor { (pillPixel()?.redComponent ?? 1) < 0.99 }
        tab.simulateHoveredLink(nil)
        try await waitFor { (pillPixel()?.redComponent ?? 0) > 0.995 }
    }
}
