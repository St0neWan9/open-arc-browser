import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B186 (issue #7): a window shows a "New Tab Created" notice when a tab is created. Spec:
/// docs/arc-spec/06-flows.md §34 (observed from a screenshot of Arc): a lavender pill with dark
/// text at the window's top right; which actions show it and how long it stays were not captured.
@MainActor
final class NewTabToastB186Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private var spaceID: UUID!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        model.windowToast.duration = 60
        spaceID = try XCTUnwrap(model.selectedSpaceID)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    /// [06 §34]: a tab created in the window shows the notice.
    func testNewTabShowsTheNotice() async throws {
        XCTAssertNil(model.windowToast.text)
        let id = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://site.example")))
        XCTAssertNotNil(id)
        try await waitUntil { self.model.windowToast.text == "New Tab Created" }
    }

    /// The page-request path (a link opened in a new tab) shows it too.
    func testPageOpenedTabShowsTheNotice() async throws {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://site.example")))
        let opener = try XCTUnwrap(opened)
        model.windowToast.dismiss()
        XCTAssertNil(model.windowToast.text)
        engine.simulateNewTabRequest(NewTabRequest(
            opener: try XCTUnwrap(model.sidebar.liveTab(for: opener)?.id),
            url: try XCTUnwrap(URL(string: "https://next.example")),
            disposition: .foregroundTab, hasUserGesture: true
        ))
        try await waitUntil { self.model.windowToast.text == "New Tab Created" }
    }

    /// Two tabs in a row both show it (the notice counts creations, not tabs).
    func testEveryNewTabShowsIt() async throws {
        let first = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://a.example")))
        XCTAssertNotNil(first)
        let before = model.sidebar.newTabNotice
        let second = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://b.example")))
        XCTAssertNotNil(second)
        XCTAssertEqual(model.sidebar.newTabNotice, before + 1)
    }

    /// The pill goes away on its own (how long is unknown in the spec; 2 s here).
    func testToastHidesItself() async throws {
        let toast = WindowToastModel()
        toast.duration = 0.01
        toast.show("New Tab Created")
        XCTAssertEqual(toast.text, "New Tab Created")
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertNil(toast.text)
    }
}
