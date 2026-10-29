import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B74: the window title follows the Space, then the page.
/// [06 §1] observed: after Create Space the window title is the Space name.
/// [06 §20.1] observed: an incognito window opens titled "Space 1", then shows the page title.
/// [06 §29.2] observed: AppleScript window `name` is the window's full title.
@MainActor
final class WindowTitleTests: XCTestCase {
    private let f = SidebarFixture()
    private var controller: WorkspaceController!

    override func setUp() async throws {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: .inMemory())
        let ids = SidebarIDSource()
        let fixed = f.now.addingTimeInterval(10)
        controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { fixed }, makeID: { ids.make() },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
    }

    override func tearDown() async throws {
        controller.stop()
        controller = nil
    }

    private func window(space: UUID? = nil, tab: UUID? = nil) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space ?? f.home, selectedTabID: tab))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    /// What the title must read when no page title applies: the selected tab's stored title, else
    /// the Space name.
    private func expectedFallback(_ model: ShellModel) -> String {
        model.selectedTabID.flatMap { model.workspace.tabs[$0]?.title } ?? model.selectedSpace?.name ?? ""
    }

    /// [06 §1] observed: a window without a selected tab is titled with its Space's name; creating
    /// a Space retitles it with the new name.
    func testTitleIsSpaceNameSpec06Section1() throws {
        let model = window()
        XCTAssertNil(model.selectedTabID)
        XCTAssertEqual(model.windowTitle, "Home")
        model.selectSpace(f.work)
        XCTAssertEqual(model.windowTitle, expectedFallback(model))
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Reading"
        XCTAssertNotNil(model.spaceFlow.create())
        XCTAssertNil(model.selectedTabID, "a new Space is empty")
        XCTAssertEqual(model.windowTitle, "Reading", "[06 §1] title = Space name after create")
    }

    /// [06 §1, §20.1] then the page: loading a page makes its title the window title.
    func testTitleFollowsThePageTitle() async throws {
        let model = window()
        let opened = try await model.openNewTab(url: URL(string: "https://page.example/a"))
        let id = try XCTUnwrap(opened)
        try await waitUntil { model.sidebar.liveState(for: id)?.title == "page.example" }
        XCTAssertEqual(model.windowTitle, "page.example")
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        live.simulateURLChange(try XCTUnwrap(URL(string: "https://page.example/b")), title: "Second Page")
        try await waitUntil { model.windowTitle == "Second Page" }
    }

    /// A selected tab without a live page shows its stored title; after closing it the title falls
    /// back to the next selection or the Space. inferred.
    func testStoredTitleThenFallbackAfterClose() throws {
        let model = window(tab: f.today1)
        XCTAssertEqual(model.selectedTabID, f.today1)
        XCTAssertEqual(model.windowTitle, "today1")
        model.sidebar.closeTab(f.today1)
        XCTAssertNotEqual(model.selectedTabID, f.today1)
        XCTAssertEqual(model.windowTitle, expectedFallback(model))
    }

    /// [06 §20.1] observed: an incognito window reads "Space 1" (not "Incognito Tabs"), then the
    /// page title.
    func testIncognitoSpace1ThenPageTitleSpec06Section20_1() async throws {
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        XCTAssertEqual(incognito.sidebar.selectedSpace?.name, "Incognito Tabs")
        XCTAssertEqual(incognito.windowTitle, "Space 1")
        incognito.dismissCommandBar()
        let opened = try await incognito.openNewTab(url: URL(string: "https://private.example"))
        let id = try XCTUnwrap(opened)
        try await waitUntil { incognito.sidebar.liveState(for: id)?.title == "private.example" }
        XCTAssertEqual(incognito.windowTitle, "private.example")
    }

    /// [06 §1, §20.1]: the AppKit window follows the model: set on attach, updated on Space and
    /// page changes.
    func testCoordinatorSetsNSWindowTitle() async throws {
        let model = window()
        let nsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        nsWindow.isReleasedWhenClosed = false
        let coordinator = BrowserWindowObserver.Coordinator(model: model)
        coordinator.attach(to: nsWindow)
        XCTAssertEqual(nsWindow.title, "Home")
        model.selectSpace(f.work)
        let expected = model.windowTitle
        try await waitUntil { nsWindow.title == expected }
        let opened = try await model.openNewTab(url: URL(string: "https://title.example"))
        _ = try XCTUnwrap(opened)
        try await waitUntil { nsWindow.title == "title.example" }
        withExtendedLifetime(coordinator) {}
    }

    /// B102: setting an `NSWindow` title makes AppKit lay out the title bar and rebuild the Window
    /// menu's window list, so a selection never sets it in its own turn, and a burst of selections
    /// sets it once, when the burst is over, and only to a new string. The window stays in the
    /// Window menu ([01 §Window] observed window list).
    func testTitleUpdatesAreCoalescedAndSkippedWhenUnchanged() async throws {
        let model = window(tab: f.today1)
        let nsWindow = TitleCountingWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        nsWindow.isReleasedWhenClosed = false
        let coordinator = BrowserWindowObserver.Coordinator(model: model)
        coordinator.attach(to: nsWindow)
        XCTAssertEqual(nsWindow.title, "today1")
        XCTAssertFalse(nsWindow.isExcludedFromWindowsMenu, "[01 §Window] the window is listed")
        nsWindow.titleSets = 0
        for tab in [f.today2, f.today3, f.today2, f.today3, f.today2, f.today3] { model.sidebar.selectTab(tab) }
        XCTAssertEqual(nsWindow.titleSets, 0, "not set in the turn of the change")
        try await waitUntil { nsWindow.title == model.windowTitle && nsWindow.title != "today1" }
        // Let any update still scheduled run, then count.
        try await Task.sleep(nanoseconds: UInt64(BrowserWindowObserver.titleCoalescingDelay * 3 * 1_000_000_000))
        await controller.settleEngineWork()
        try await waitUntil { nsWindow.title == model.windowTitle }
        let afterBurst = nsWindow.titleSets
        XCTAssertGreaterThanOrEqual(afterBurst, 1)
        XCTAssertLessThanOrEqual(afterBurst, 2, "six selections set the title at most once (plus a later page title)")
        // A change that leaves the title as it is never sets it.
        model.sidebar.toggleFolder(f.folderA)
        try await Task.sleep(nanoseconds: UInt64(BrowserWindowObserver.titleCoalescingDelay * 3 * 1_000_000_000))
        XCTAssertEqual(nsWindow.titleSets, afterBurst, "an unchanged title is not set again")
        withExtendedLifetime(coordinator) {}
    }

    /// [06 §29.2] observed: AppleScript window `name` is the full window title (Space, then page).
    func testScriptingNameMatchesWindowTitleSpec06Section29_2() async throws {
        var next = 7_000
        let host = ScriptingHost(makeID: { next += 1; return SidebarFixture.id(next) })
        let model = window()
        host.register(model, window: nil)
        let windowID = try XCTUnwrap(host.entry(for: model)?.id)
        XCTAssertEqual(host.windowName(windowID), "Home")
        let opened = try await model.openNewTab(url: URL(string: "https://script.example"))
        let id = try XCTUnwrap(opened)
        try await waitUntil { model.sidebar.liveState(for: id)?.title == "script.example" }
        XCTAssertEqual(host.windowName(windowID), "script.example")
        XCTAssertEqual(host.windowName(SidebarFixture.id(9_999)), "", "unknown window")
    }
}

/// Counts title sets (B102).
private final class TitleCountingWindow: NSWindow {
    var titleSets = 0

    override var title: String {
        didSet { titleSets += 1 }
    }
}
