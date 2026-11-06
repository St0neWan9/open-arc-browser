import XCTest
import CoreGraphics
import OpenArcDesign
@testable import OpenArcShell

/// Issue #16: the sidebar scroll knob is lighter and shows only while the list scrolls.
@MainActor
final class ScrollKnobB190Tests: XCTestCase {
    /// A scroll step shows it; it hides again after the delay without another step.
    func testKnobShowsOnlyWhileScrolling() async throws {
        let scroll = SidebarListScrollState()
        scroll.scrollEndDelay = 0.05
        XCTAssertFalse(scroll.isScrolling)
        scroll.noteScrolled()
        XCTAssertTrue(scroll.isScrolling)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(scroll.isScrolling, "hidden again once the scroll stopped")
    }

    /// The knob geometry is unchanged; only its ink got lighter.
    func testKnobGeometry() {
        let frame = SidebarScrollerGeometry.knobFrame(
            contentFrame: CGRect(x: 0, y: -200, width: 276, height: 1200),
            viewport: CGSize(width: 276, height: 800)
        )
        let knob = try? XCTUnwrap(frame)
        XCTAssertNotNil(knob)
        XCTAssertEqual(knob?.width, CGFloat(Metrics.SidebarScroller.knobWidth))
    }
}
