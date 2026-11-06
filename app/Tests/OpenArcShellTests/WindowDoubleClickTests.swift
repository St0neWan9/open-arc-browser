import XCTest
@testable import OpenArcShell

/// Issue #14: double-clicking the window's top background strip does what the system setting for
/// a title-bar double-click says (zoom/maximize by default), not full screen.
final class WindowDoubleClickTests: XCTestCase {
    func testSystemSetting() {
        XCTAssertEqual(WindowDoubleClickAction.action(for: "Minimize"), .minimize)
        XCTAssertEqual(WindowDoubleClickAction.action(for: "None"), .none)
        XCTAssertEqual(WindowDoubleClickAction.action(for: "Maximize"), .zoom)
        XCTAssertEqual(WindowDoubleClickAction.action(for: nil), .zoom, "macOS defaults to Maximize")
        XCTAssertEqual(WindowDoubleClickAction.action(for: "something else"), .zoom)
    }
}
