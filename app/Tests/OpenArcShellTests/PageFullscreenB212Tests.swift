import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B212: a page in HTML fullscreen (a video's full screen button) takes the window full
/// screen with the page alone in it, and gives it back when it leaves.
@MainActor
final class PageFullscreenB212Tests: XCTestCase {
    private func makeModel(_ engine: FakeEngine) -> ShellModel {
        ShellModel(dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
                   workspace: .demo(now: Date(timeIntervalSince1970: 0)), now: { Date(timeIntervalSince1970: 0) })
    }

    private func waitUntil(_ model: ShellModel, _ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    func testLayoutLeavesThePageAloneInTheWindow() {
        var layout = MainWindowLayout(windowSize: CGSize(width: 1920, height: 1080))
        layout.isPageFullscreen = true
        XCTAssertEqual(layout.webPanelFrame, CGRect(x: 0, y: 0, width: 1920, height: 1080))
    }

    func testFullscreenPageFillsTheWindowAndLeaves() async throws {
        let engine = FakeEngine()
        let model = makeModel(engine)
        defer { model.stop() }
        let address = try XCTUnwrap(URL(string: "https://video.example/watch"))
        let opened = try await model.openNewTab(url: address)
        let id = try XCTUnwrap(opened)
        let tab = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertFalse(model.isPageFullscreen)

        tab.simulateFullscreen(true)
        try await waitUntil(model) { model.isPageFullscreen }
        let layout = model.windowLayout(size: size)
        XCTAssertEqual(layout.webPanelFrame, CGRect(origin: .zero, size: size))
        XCTAssertEqual(layout.sidebarFrame, .zero)
        XCTAssertFalse(layout.isWebToolbarShown)
        XCTAssertFalse(model.showsWindowButtons)
        XCTAssertFalse(model.tracksSidebarPeek)

        model.exitPageFullscreen(tabID: id)
        try await waitUntil(model) { !model.isPageFullscreen }
        XCTAssertNotEqual(model.windowLayout(size: size).webPanelFrame, CGRect(origin: .zero, size: size))
    }

    // MARK: Window

    private final class FakeWindow {
        var isFullScreen = false
        var toggles = 0
    }

    private func makeDriver(_ window: FakeWindow, exits: @escaping @MainActor (UUID) -> Void) -> PageFullscreenWindowView {
        let view = PageFullscreenWindowView()
        view.windowIsFullScreenForTesting = { window.isFullScreen }
        view.toggleWindowForTesting = { window.toggles += 1; window.isFullScreen.toggle() }
        view.exitPage = exits
        return view
    }

    func testWindowGoesFullScreenForThePageAndBack() {
        let window = FakeWindow()
        var exited: [UUID] = []
        let view = makeDriver(window) { exited.append($0) }
        let tab = UUID()
        view.apply(tabID: tab)
        XCTAssertTrue(window.isFullScreen)
        view.apply(tabID: nil)
        XCTAssertFalse(window.isFullScreen, "back to the desktop with the page")
        XCTAssertEqual(window.toggles, 2)
    }

    func testAlreadyFullScreenWindowStays() {
        let window = FakeWindow()
        window.isFullScreen = true
        let view = makeDriver(window) { _ in }
        view.apply(tabID: UUID())
        view.apply(tabID: nil)
        XCTAssertTrue(window.isFullScreen)
        XCTAssertEqual(window.toggles, 0)
    }

    /// Leaving the window's full screen (green button, ⌃⌘F) ends the page's fullscreen, and the
    /// window does not go back while the engine catches up.
    func testLeavingTheWindowsFullScreenEndsThePages() {
        let window = FakeWindow()
        var exited: [UUID] = []
        let view = makeDriver(window) { exited.append($0) }
        let tab = UUID()
        view.apply(tabID: tab)
        window.isFullScreen = false
        view.windowDidExitFullScreen()
        XCTAssertEqual(exited, [tab])
        view.apply(tabID: tab)
        XCTAssertFalse(window.isFullScreen, "not taken full screen again")
        view.apply(tabID: nil)
        view.apply(tabID: tab)
        XCTAssertTrue(window.isFullScreen, "a new request goes full screen again")
    }

    /// Selecting another tab ends the fullscreen of the one that had it.
    func testSelectingAnotherTabEndsItsFullscreen() {
        let window = FakeWindow()
        var exited: [UUID] = []
        let view = makeDriver(window) { exited.append($0) }
        let tab = UUID()
        view.apply(tabID: tab)
        view.apply(tabID: nil)
        XCTAssertEqual(exited, [tab])
        XCTAssertFalse(window.isFullScreen)
    }
}
