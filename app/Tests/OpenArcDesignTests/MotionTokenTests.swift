import XCTest
import OpenArcDesign

/// Pins the motion tokens measured in docs/arc-spec/07-design-system.md §11 动效(E7) and
/// design-tokens.json `motion`, with their evidence levels.
final class MotionTokenTests: XCTestCase {
    /// [07 §11] Space switch: spring 0.2 s / 1.0 (stiffness ≈ 987, damping ≈ 62.8), observed.
    func testSpaceSwitchIsCriticallyDampedSpring() {
        XCTAssertEqual(Motion.spaceSwitch.curve, .spring(response: 0.2, dampingFraction: 1.0))
        XCTAssertEqual(Motion.spaceSwitch.evidence, .observed)
        let k = try! XCTUnwrap(Motion.spaceSwitch.curve.springConstants)
        XCTAssertEqual(k.stiffness, 987, accuracy: 1)
        XCTAssertEqual(k.damping, 62.8, accuracy: 0.1)
        // [06 §1] the 0.3 s fade stays for Space creation only.
        XCTAssertEqual(Motion.spaceCreateFade.curve, .easeInOut(duration: 0.3))
    }

    /// [07 §11] ⌘S: bezier(0.03, 0.62, 0.54, 0.95) over ≈ 67 ms; curve inferred.
    func testSidebarToggleIsFastEaseOut() {
        XCTAssertEqual(Motion.sidebarToggle.curve, .timingCurve(x1: 0.03, y1: 0.62, x2: 0.54, y2: 0.95, duration: 0.067))
        XCTAssertEqual(Motion.sidebarToggle.evidence, .inferred)
    }

    /// [07 §11] peek: ≈ 0.11 s dwell, no close delay, slide ≤ 0.3 s with an unknown curve.
    func testSidebarPeekTiming() {
        XCTAssertEqual(Motion.sidebarPeekOpenDwell, 0.11)
        XCTAssertEqual(Motion.sidebarPeekCloseDelay, 0)
        XCTAssertEqual(Motion.sidebarPeekSlideMax, 0.3)
        XCTAssertLessThanOrEqual(Motion.sidebarPeekSlide.curve.nominalDuration, Motion.sidebarPeekSlideMax)
        XCTAssertEqual(Motion.sidebarPeekSlide.evidence, .unknown)
    }

    /// [07 §11] theme bubble: open spring 0.31 / 0.81, close 0.35 / 0.85, observed.
    func testThemeBubbleSprings() {
        XCTAssertEqual(Motion.themeBubbleOpen.curve, .spring(response: 0.31, dampingFraction: 0.81))
        XCTAssertEqual(Motion.themeBubbleClose.curve, .spring(response: 0.35, dampingFraction: 0.85))
        XCTAssertEqual(Motion.themeBubbleOpen.evidence, .observed)
        XCTAssertEqual(Motion.themeBubbleClose.evidence, .observed)
        let open = try! XCTUnwrap(Motion.themeBubbleOpen.curve.springConstants)
        XCTAssertEqual(open.stiffness, 411, accuracy: 1)
        XCTAssertEqual(open.damping, 32.8, accuracy: 0.1)
    }

    /// [07 §11] Little Arc: no fade on open, 98 % ↔ 100 %, ≈ 0.2 s fade on close / adopt.
    func testLittleArcMotion() {
        XCTAssertEqual(Motion.littleArcScale, 0.98)
        XCTAssertEqual(Motion.littleArcOpen.curve, .spring(response: 0.24, dampingFraction: 0.45))
        XCTAssertEqual(Motion.littleArcOpen.evidence, .inferred)
        XCTAssertEqual(Motion.littleArcClose.curve, .timingCurve(x1: 0.27, y1: 1.0, x2: 0.40, y2: 0.98, duration: 0.2))
        XCTAssertEqual(Motion.littleArcExpandToMain.curve, .timingCurve(x1: 0.33, y1: 0.71, x2: 0.19, y2: 1.0, duration: 0.19))
        XCTAssertEqual(Motion.littleArcGrowOnLoad.curve, .instant)
    }

    /// [07 §11] observed one-frame changes: command bar, rows, folders, split view, Library.
    func testUnanimatedLayoutChanges() {
        XCTAssertEqual(Motion.layoutChange, MotionToken(.instant, .observed))
        XCTAssertEqual(Motion.library.curve, .instant)
        XCTAssertEqual(Motion.libraryCrossfadeMax, 0.5)
        XCTAssertEqual(MotionCurve.instant.nominalDuration, 0)
        XCTAssertNil(MotionCurve.instant.springConstants)
    }

    /// [07 §11] not measured: hover card, selection highlight. [06 §12] hover delay stays 0.5 s.
    func testUnknownsStayMarked() {
        XCTAssertEqual(Motion.hoverCardDelay, 0.5)
        XCTAssertEqual(Motion.hoverCard.evidence, .unknown)
        XCTAssertEqual(Motion.selectionHighlight.evidence, .unknown)
        XCTAssertEqual(Motion.favoriteMakeRoom.evidence, .unknown)
    }
}
