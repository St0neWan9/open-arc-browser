import XCTest
@testable import OpenArcShell

/// B173: the About window says what Arc's says, in our name (user's Arc screenshot).
@MainActor
final class AboutWindowB173Tests: XCTestCase {
    private let info = AboutInfo(appName: "Open Arc", version: "0.1.2", build: "3",
                                 engineVersion: "Chromium 157.0.8103.39", year: 2026)

    func testLines() {
        XCTAssertEqual(info.versionLine, "Version 0.1.2 (3)")
        XCTAssertEqual(info.engineLine, "Chromium Engine Version 157.0.8103.39")
        XCTAssertEqual(info.copyrightLine, "Copyright © 2026 The Open Arc Authors.")
    }

    func testAnotherEngineKeepsItsName() {
        var fake = info
        fake.engineVersion = "FakeEngine 1.0"
        XCTAssertEqual(fake.engineLine, "FakeEngine 1.0")
    }

    func testCreditsHaveThreeLinks() {
        let credits = info.credits
        XCTAssertEqual(String(credits.characters),
                       "Open Arc is made possible by the Chromium open source project, Chromium's open source software, as well as other open source software.")
        let links = credits.runs.compactMap(\.link)
        XCTAssertEqual(links, [AboutLinks.chromium, AboutLinks.chromiumCredits, AboutLinks.otherCredits])
    }
}
