import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B186 (issue #7): a window shows a "New Tab Created" notice when a page opens a tab while
/// the sidebar is hidden. Spec: docs/arc-spec/06-flows.md §34 (observed in Arc): a lavender pill
/// with dark text at the window's top right; a tab the user starts and a page tab with the
/// sidebar shown show nothing; how long it stays was not captured.
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

    /// [06 §34] observed: a tab the user starts (⌘T, the New Tab row) shows no notice.
    func testUserStartedTabShowsNoNotice() async throws {
        let id = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://site.example")))
        XCTAssertNotNil(id)
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertNil(model.windowToast.text)
    }

    /// [06 §34] observed: a tab a page opens while the sidebar is hidden shows the notice.
    func testPageOpenedTabWithSidebarHiddenShowsTheNotice() async throws {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://site.example")))
        let opener = try XCTUnwrap(opened)
        if model.isSidebarVisible { model.toggleSidebar() }
        model.windowToast.dismiss()
        engine.simulateNewTabRequest(NewTabRequest(
            opener: try XCTUnwrap(model.sidebar.liveTab(for: opener)?.id),
            url: try XCTUnwrap(URL(string: "https://next.example")),
            disposition: .foregroundTab, hasUserGesture: true
        ))
        try await waitUntil { self.model.windowToast.text == "New Tab Created" }
    }

    /// [06 §34] observed: with the sidebar shown the new row is visible, so no notice.
    func testPageOpenedTabWithSidebarShownShowsNoNotice() async throws {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://site.example")))
        let opener = try XCTUnwrap(opened)
        if !model.isSidebarVisible { model.toggleSidebar() }
        model.windowToast.dismiss()
        engine.simulateNewTabRequest(NewTabRequest(
            opener: try XCTUnwrap(model.sidebar.liveTab(for: opener)?.id),
            url: try XCTUnwrap(URL(string: "https://next.example")),
            disposition: .foregroundTab, hasUserGesture: true
        ))
        try await Task.sleep(nanoseconds: 300_000_000)
        await model.controller.settleEngineWork()
        XCTAssertNil(model.windowToast.text)
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
