import XCTest
import OpenArcModel
@testable import OpenArcShell

/// Issue #15: while a two-finger swipe runs, the window background blends toward the target
/// Space's color by how far the swipe has gone (it used to jump after the switch).
@MainActor
final class SwipeBackgroundB191Tests: XCTestCase {
    /// A swipe whose let-go settle runs to the end at once (no animation in tests).
    private func makeSwipe() -> SpaceSwipeState {
        let swipe = SpaceSwipeState()
        swipe.pageWidth = 276
        swipe.animateSettle = { change, completion in change(); completion() }
        return swipe
    }

    func testProgressAndTarget() {
        let previous = UUID(), next = UUID()
        let swipe = makeSwipe()
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
        XCTAssertNil(swipe.fromSpaceID)
    }

    /// Letting go finishes the blend on the pages' spring instead of jumping: toward the target when
    /// the swipe commits, back to the current Space when it springs back. The background keeps the
    /// starting Space's color under the blend until it settles (the selection changes at once).
    func testLetGoSettlesTheBlend() {
        let current = UUID(), next = UUID()
        let swipe = makeSwipe()
        var pending: (() -> Void)?
        var settledTo: Double?
        swipe.animateSettle = { change, completion in change(); settledTo = swipe.progress; pending = completion }

        swipe.begin(from: current, previous: nil, next: next)
        XCTAssertEqual(swipe.fromSpaceID, current)
        swipe.move(-138)
        swipe.end(target: next)
        XCTAssertEqual(settledTo, 1, "a committed swipe blends the rest of the way to the target")
        XCTAssertEqual(swipe.targetSpaceID, next)
        XCTAssertEqual(swipe.fromSpaceID, current, "the start color stays under the blend while it settles")
        XCTAssertFalse(swipe.isActive)
        pending?()
        XCTAssertNil(swipe.targetSpaceID)
        XCTAssertNil(swipe.fromSpaceID)
        XCTAssertEqual(swipe.progress, 0)

        swipe.begin(from: current, previous: nil, next: next)
        swipe.move(-60)
        swipe.end(target: nil)
        XCTAssertEqual(settledTo, 0, "a swipe that springs back blends back to the current Space")
        XCTAssertEqual(swipe.targetSpaceID, next, "the target fades out instead of vanishing")
        pending?()
        XCTAssertNil(swipe.targetSpaceID)
    }

    /// A new swipe during a settle: the old settle's end does not clear the new swipe's blend.
    func testOvertakenSettleDoesNotClearANewSwipe() {
        let current = UUID(), next = UUID()
        let swipe = makeSwipe()
        var pending: [() -> Void] = []
        swipe.animateSettle = { change, completion in change(); pending.append(completion) }
        swipe.begin(from: current, previous: nil, next: next)
        swipe.move(-200)
        swipe.end(target: next)
        swipe.begin(from: next, previous: current, next: nil)
        swipe.move(100)
        pending.forEach { $0() }
        XCTAssertEqual(swipe.targetSpaceID, current)
        XCTAssertEqual(swipe.fromSpaceID, next)
        XCTAssertEqual(swipe.progress, 100.0 / 276.0, accuracy: 0.001)
    }

    /// No neighbor that way: nothing to blend to.
    func testNoTargetAtTheEnd() {
        let swipe = makeSwipe()
        swipe.begin(previous: nil, next: UUID())
        swipe.move(80)
        XCTAssertNil(swipe.targetSpaceID)
        XCTAssertEqual(swipe.progress, 0, accuracy: 0.001)
    }
}
