import XCTest
import OpenArcModel
@testable import OpenArcShell

/// Issue #15: while a two-finger swipe runs, the window background blends toward the target
/// Space's color by how far the swipe has gone (it used to jump after the switch).
@MainActor
final class SwipeBackgroundB191Tests: XCTestCase {
    func testProgressAndTarget() {
        let previous = UUID(), next = UUID()
        let swipe = SpaceSwipeState()
        swipe.pageWidth = 276
        swipe.begin(previous: previous, next: next)
        XCTAssertEqual(swipe.progress, 0)
        XCTAssertNil(swipe.targetSpaceID)

        swipe.move(-138)
        XCTAssertEqual(swipe.targetSpaceID, next, "content to the left reveals the next Space")
        XCTAssertEqual(swipe.progress, 0.5, accuracy: 0.001)

        swipe.move(-400)
        XCTAssertEqual(swipe.progress, 1, accuracy: 0.001, "capped at a page")

        swipe.move(60)
        XCTAssertEqual(swipe.targetSpaceID, previous, "the other way blends to the previous Space")
        XCTAssertEqual(swipe.progress, 60.0 / 276.0, accuracy: 0.001)

        swipe.end(target: nil)
        XCTAssertEqual(swipe.progress, 0)
        XCTAssertNil(swipe.targetSpaceID)
    }

    /// No neighbor that way: nothing to blend to.
    func testNoTargetAtTheEnd() {
        let swipe = SpaceSwipeState()
        swipe.pageWidth = 276
        swipe.begin(previous: nil, next: UUID())
        swipe.move(80)
        XCTAssertNil(swipe.targetSpaceID)
        XCTAssertEqual(swipe.progress, 0, accuracy: 0.001)
    }
}
