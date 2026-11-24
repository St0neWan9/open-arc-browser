import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
@testable import OpenArcDesign
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

    /// B251: Arc on a Display P3 screen, violet Space (window P3 79 / 64 / 248), white page: fill
    /// 232 / 230 / 254, border 209 / 207 / 229, text 69 / 68 / 76 (P3 components).
    func testLightColorsMatchTheCapture() {
        let window = DisplayP3.toSRGB([79, 64, 248].map { Double($0) / 255 })
        let colors = LinkStatusTokens.colors(windowBackground: window, isDark: false)
        func assertP3(_ c: RGBAColor, _ expected: [Double], _ label: String) {
            for (got, want) in zip(DisplayP3.fromSRGB(c), expected) {
                XCTAssertEqual(got * 255, want, accuracy: 1.5, label)
            }
        }
        assertP3(colors.fill, [232, 230, 254], "fill")
        assertP3(colors.border, [209, 207, 229], "border")
        assertP3(colors.text, [69, 68, 76], "text")
        XCTAssertEqual(colors.fill.alpha, 1)
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

    /// B219, [06 §44] observed: a long address is cut at ≈ 400 pt, then after 1 s on the same link
    /// the pill widens to the whole address.
    @MainActor
    func testLongAddressWidensAfterOneSecond() async throws {
        let engine = FakeEngine()
        let made = try await engine.makeTab(TabConfiguration(profileID: UUID()))
        let tab = try XCTUnwrap(made as? FakeTab)
        let host = NSHostingView(rootView: LinkStatusBubble(tab: tab, palette: nil).frame(width: 1200, height: 200).background(Color.white))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 200)
        let window = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: 1200, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        // On the pill's middle row, 450 pt in: past the 400 pt limit.
        func isPillAt450() -> Bool { isPillAt(450) }
        func isPillAt(_ x: CGFloat) -> Bool {
            host.layoutSubtreeIfNeeded()
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / 1200
            let c = rep.colorAt(x: Int(x * scale), y: Int((200 - 22) * scale))?.usingColorSpace(.sRGB)
            return (c?.redComponent ?? 1) < 0.995
        }
        let path = String(repeating: "segment/", count: 12)
        try await Task.sleep(nanoseconds: 50_000_000)  // the view subscribes to the tab first
        tab.simulateHoveredLink(URL(string: "https://example.com/\(path)end"))
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(isPillAt(390), "the pill shows")
        XCTAssertFalse(isPillAt450(), "cut at 400 pt first")
        for _ in 0..<200 where !isPillAt450() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(isPillAt450(), "the whole address after 1 s")
    }
}
