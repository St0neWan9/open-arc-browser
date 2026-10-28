import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan C31 (`docs/f1-review-final.md` 09 #17; `docs/arc-spec/00-feature-inventory.md` §A observed:
/// the Chrome extension ecosystem is inherited from the engine). Extension APIs that need a
/// browser window — `chrome.tabs.create`, `chrome.windows.create`, `chrome.runtime.openOptionsPage`
/// — open tabs and windows in the shell through the app-level new-tab path. Placement is inferred:
/// the engine made the tab already (the extension holds its id), so the shell adopts it; it opens
/// in the window's Space when that Space uses the extension's profile, else in the profile's first
/// Space.
@MainActor
final class ExtensionOpenedTabsC31Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private var spaceID: UUID!
    private var profileID: UUID!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        spaceID = try XCTUnwrap(model.selectedSpaceID)
        profileID = try XCTUnwrap(model.workspace.spaces[spaceID]?.profileID)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var controller: WorkspaceController { model.controller }
    private var todayIDs: [UUID] { model.workspace.today(spaceID: spaceID).map(\.id) }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    /// `chrome.tabs.create({url})` (active by default): a selected tab at the top of Today in the
    /// window's Space, backed by the engine's tab (adopted, not a second one).
    func testTabsCreateOpensASelectedTabAndAdoptsTheEngineTab() async throws {
        let before = todayIDs
        let page = try url("https://docs.example/welcome")
        let token = engine.simulateExtensionOpensTab(url: page, profileID: profileID)
        try await waitUntil { self.todayIDs.count == before.count + 1 }
        let opened = try XCTUnwrap(todayIDs.first)
        XCTAssertFalse(before.contains(opened))
        XCTAssertEqual(model.workspace.tabs[opened]?.url, page)
        XCTAssertEqual(model.selectedTabID, opened, "active: selected")
        try await waitUntil { self.model.sidebar.liveTab(for: opened) != nil }
        XCTAssertFalse(engine.pendingTabTokens.contains(token), "the engine's tab was adopted")
        let live = try XCTUnwrap(model.sidebar.liveTab(for: opened) as? FakeTab)
        XCTAssertNil(live.opener)
        XCTAssertEqual(live.profileID, profileID)
    }

    /// `chrome.tabs.create({active: false})`: the tab opens in Today without being selected.
    func testTabsCreateInactiveStaysInTheBackground() async throws {
        let selected = model.selectedTabID
        let before = todayIDs
        engine.simulateExtensionOpensTab(url: try url("https://bg.example"), profileID: profileID, disposition: .backgroundTab)
        try await waitUntil { self.todayIDs.count == before.count + 1 }
        XCTAssertEqual(model.selectedTabID, selected)
        let opened = try XCTUnwrap(todayIDs.first { !before.contains($0) })
        try await waitUntil { self.engine.pendingTabTokens.isEmpty && self.model.sidebar.liveTab(for: opened) != nil }
    }

    /// `chrome.windows.create({url})`: a new browser window on the new tab.
    func testWindowsCreateOpensANewWindow() async throws {
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }
        engine.simulateExtensionOpensTab(url: try url("https://w.example"), profileID: profileID, disposition: .newWindow)
        try await waitUntil { requests.count == 1 }
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.kind, .newWindow)
        XCTAssertEqual(request.spaceID, spaceID)
        let tab = try XCTUnwrap(request.tabID)
        XCTAssertEqual(model.workspace.tabs[tab]?.url, try url("https://w.example"))
    }

    /// `chrome.runtime.openOptionsPage()`: its options page opens in a selected tab.
    func testOpenOptionsPageOpensItsPage() async throws {
        let options = try url("chrome-extension://abcdefghijklmnopabcdefghijklmnop/options.html")
        engine.simulateExtensionOpensTab(url: options, profileID: profileID)
        try await waitUntil { self.model.selectedTabID.flatMap { self.model.workspace.tabs[$0]?.url } == options }
    }

    /// An extension of another profile opens its tab in a Space of that profile, not in the
    /// window's Space.
    func testTabOfAnotherProfileGoesToThatProfilesSpace() async throws {
        let otherProfile = UUID(), otherSpace = UUID()
        let stamp = Date(timeIntervalSince1970: 0)
        try controller.mutate(origin: nil) { s in
            let themeID = try XCTUnwrap(s.spaces[self.spaceID]?.themeID)
            let withProfile = TreeOps.createProfile(s, id: otherProfile, name: "Work", now: stamp)
            return try TreeOps.createSpace(withProfile, id: otherSpace, profileID: otherProfile, name: "Work", themeID: themeID, now: stamp)
        }
        let before = todayIDs
        let page = try url("https://work.example")
        engine.simulateExtensionOpensTab(url: page, profileID: otherProfile, disposition: .backgroundTab)
        try await waitUntil { !self.model.workspace.today(spaceID: otherSpace).isEmpty }
        XCTAssertEqual(model.workspace.today(spaceID: otherSpace).first?.url, page)
        XCTAssertEqual(todayIDs, before, "not in the window's Space of another profile")
    }
}
