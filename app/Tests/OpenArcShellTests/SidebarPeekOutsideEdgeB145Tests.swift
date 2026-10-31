import XCTest
import SwiftUI
@testable import OpenArcShell

/// B145: the hidden sidebar also slides out when the pointer crosses the window's left edge into
/// the strip outside it, so a window away from the screen edge is as easy as one touching it.
/// [06 §26.2] observed (x = 0 inside the window; x = 1–5 never); the outside strip is inferred
/// (analysis): 50 pt, 250 pt once the pointer is in it.
@MainActor
final class SidebarPeekOutsideEdgeB145Tests: XCTestCase {
    private let size = CGSize(width: 1200, height: 800)

    func testOutsideStripOpens_06_26_2() {
        let layout = SidebarPeekLayout(windowSize: size)
        XCTAssertEqual(SidebarPeekTokens.outsideEdgeZoneWidth, 50)
        XCTAssertEqual(SidebarPeekTokens.outsideEdgeZoneWidthWhileInside, 250)
        XCTAssertEqual(layout.region(of: CGPoint(x: -1, y: 400), presentation: .hidden), .edge)
        XCTAssertEqual(layout.region(of: CGPoint(x: -50, y: 400), presentation: .hidden), .edge)
        XCTAssertEqual(layout.region(of: CGPoint(x: -51, y: 400), presentation: .hidden), .outside)
        XCTAssertEqual(layout.region(of: CGPoint(x: -120, y: 400), presentation: .hidden, wasAtEdge: true), .edge)
        XCTAssertEqual(layout.region(of: CGPoint(x: -251, y: 400), presentation: .hidden, wasAtEdge: true), .outside)
        // Inside the window only the first column still counts. [06 §26.2] observed.
        XCTAssertEqual(layout.region(of: CGPoint(x: 0, y: 400), presentation: .hidden), .edge)
        XCTAssertEqual(layout.region(of: CGPoint(x: 1, y: 400), presentation: .hidden), .outside)
        // As tall as the window: not above or below it.
        XCTAssertEqual(layout.region(of: CGPoint(x: -10, y: -1), presentation: .hidden), .outside)
        XCTAssertEqual(layout.region(of: CGPoint(x: -10, y: 801), presentation: .hidden), .outside)
    }

    func testCrossingTheEdgeOpensAndLeftDriftKeepsItOpen_06_26_2() {
        var clock = Date(timeIntervalSince1970: 100)
        var pending: [(TimeInterval, @MainActor () -> Void)] = []
        let c = SidebarPeekController(isPinned: false, now: { clock }, schedule: { pending.append(($0, $1)) })
        c.pointerMoved(to: CGPoint(x: 30, y: 400), windowSize: size)
        XCTAssertTrue(pending.isEmpty)
        c.pointerMoved(to: CGPoint(x: -20, y: 400), windowSize: size)
        XCTAssertEqual(pending.count, 1, "the dwell starts outside the window")
        c.pointerMoved(to: CGPoint(x: -90, y: 400), windowSize: size)
        XCTAssertEqual(pending.count, 1, "still in the widened strip")
        clock = clock.addingTimeInterval(SidebarPeekTokens.openDelay)
        pending.removeFirst().1()
        XCTAssertEqual(c.presentation, .peeking)
        c.pointerMoved(to: CGPoint(x: -200, y: 400), windowSize: size)
        XCTAssertEqual(c.presentation, .peeking)
        c.pointerMoved(to: CGPoint(x: 100, y: 400), windowSize: size)
        XCTAssertEqual(c.presentation, .peeking, "over the panel")
        c.pointerMoved(to: CGPoint(x: 600, y: 400), windowSize: size)
        XCTAssertEqual(c.presentation, .hidden)
    }

    func testFarLeftDoesNotOpen_06_26_2() {
        var pending: [(TimeInterval, @MainActor () -> Void)] = []
        let c = SidebarPeekController(isPinned: false, schedule: { pending.append(($0, $1)) })
        c.pointerMoved(to: CGPoint(x: -400, y: 400), windowSize: size)
        c.pointerMoved(to: CGPoint(x: -120, y: 400), windowSize: size)
        XCTAssertTrue(pending.isEmpty, "the 50 pt strip only, coming from far away")
    }
}
