import XCTest
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B214: windows come back where they were after a relaunch, and the app opens a window when
/// none appeared after launch (user, 2026-11-10: after an update the app ran with no window).
@MainActor
final class WindowFrameRestoreB214Tests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1055)

    func testFrameOnAScreenIsKept() {
        let frame = CGRect(x: 200, y: 120, width: 1300, height: 820)
        XCTAssertEqual(WindowFrameRestore.frame(frame, screens: [screen]), frame)
    }

    /// A display that is gone, or a sliver left on screen: SwiftUI places the window instead.
    func testFrameOffScreenIsDropped() {
        XCTAssertNil(WindowFrameRestore.frame(CGRect(x: 2500, y: 100, width: 1200, height: 800), screens: [screen]))
        XCTAssertNil(WindowFrameRestore.frame(CGRect(x: 1880, y: 100, width: 1200, height: 800), screens: [screen]))
        XCTAssertNil(WindowFrameRestore.frame(nil, screens: [screen]))
        let second = CGRect(x: 1920, y: 0, width: 2560, height: 1415)
        XCTAssertNotNil(WindowFrameRestore.frame(CGRect(x: 2500, y: 100, width: 1200, height: 800), screens: [screen, second]))
    }

    /// Files written before B214 have no frame.
    func testOldWindowStateDecodes() throws {
        let json = Data(#"{"isSidebarVisible": false}"#.utf8)
        let state = try JSONDecoder().decode(WindowUIState.self, from: json)
        XCTAssertNil(state.frame)
        let frame = SavedWindowFrame(x: 1, y: 2, width: 3, height: 4)
        let again = try JSONDecoder().decode(WindowUIState.self, from: JSONEncoder().encode(WindowUIState(frame: frame)))
        XCTAssertEqual(again.frame, frame)
    }

    /// No browser window connected the inbox a while after launch: one opens, once.
    func testWindowOpensWhenNoneAppeared() {
        let inbox = ExternalOpenInbox()
        var opened = 0
        inbox.fallbackWindowOpener = { opened += 1 }
        inbox.openWindowIfNoneAppeared()
        inbox.openWindowIfNoneAppeared()
        XCTAssertEqual(opened, 1)
    }

    func testNoExtraWindowWhenOneAppeared() {
        let inbox = ExternalOpenInbox()
        var opened = 0
        inbox.fallbackWindowOpener = { opened += 1 }
        inbox.connect { _ in }
        inbox.openWindowIfNoneAppeared()
        XCTAssertEqual(opened, 0)
    }
}
