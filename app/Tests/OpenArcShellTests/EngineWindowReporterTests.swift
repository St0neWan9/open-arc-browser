import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B126: the shell reports its windows to the engine (`BrowserEngine.setWindows`) for the
/// extensions' `chrome.windows.*` and `chrome.action.openPopup()` (B125). [00 §A] inferred
/// (analysis): extensions work in Arc; how Arc reports its windows to them is not in the spec, so
/// every rule checked here is inferred: a browser window is `normal` with its selected Space's
/// live tabs, a Little Arc window is a `popup` with its page, an incognito window belongs to the
/// incognito context only, and the list runs most recently focused first.
@MainActor
final class EngineWindowReporterTests: XCTestCase {
    private func makeController(_ f: SidebarFixture, engine: FakeEngine) -> WorkspaceController {
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore())
        let fixed = f.now.addingTimeInterval(10)
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { fixed }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// A browser window is reported as a normal window of its profile with the live tabs of its
    /// Space; the tab it shows is active, and the window is focused while it is key. Moving the
    /// window reports its new frame.
    func testBrowserWindowIsReportedWithItsTabsFocusAndFrame() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let a = window(controller, space: f.home)
        try await a.activate(tabID: f.today1)
        a.windowDidBecomeKey()
        a.windowFrameDidChange(x: 10, y: 20, width: 1000, height: 700)
        await controller.engineWindows.settle()

        let reported = try XCTUnwrap(engine.windows.first)
        XCTAssertEqual(engine.windows.count, 1)
        XCTAssertEqual(reported.id, a.windowID)
        XCTAssertEqual(reported.profileID, f.profile)
        XCTAssertFalse(reported.isOffTheRecord)
        XCTAssertFalse(reported.isPopup)
        XCTAssertTrue(reported.isFocused)
        XCTAssertEqual([reported.x, reported.y, reported.width, reported.height], [10, 20, 1000, 700])
        let live = try XCTUnwrap(controller.liveTab(for: f.today1)?.id)
        XCTAssertEqual(reported.tabIDs, [live])
        XCTAssertEqual(reported.activeTabIDs, [live])

        a.windowDidResignKey()
        await controller.engineWindows.settle()
        XCTAssertEqual(engine.windows.first?.isFocused, false)
    }

    /// Several windows run most recently focused first; a closed window leaves the list.
    func testWindowsRunMostRecentlyFocusedFirst() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let a = window(controller, space: f.home)
        let b = window(controller, space: f.work)
        a.windowDidBecomeKey()
        b.windowDidBecomeKey()
        a.windowDidResignKey()
        await controller.engineWindows.settle()
        XCTAssertEqual(engine.windows.map(\.id), [b.windowID, a.windowID])
        XCTAssertEqual(engine.windows.map(\.isFocused), [true, false])

        a.windowDidBecomeKey()
        await controller.engineWindows.settle()
        XCTAssertEqual(engine.windows.map(\.id), [a.windowID, b.windowID])

        a.windowDidClose()
        await controller.engineWindows.settle()
        XCTAssertEqual(engine.windows.map(\.id), [b.windowID])
    }

    /// Unchanged state is not sent again (a burst of changes is one report).
    func testUnchangedListIsNotSentAgain() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let a = window(controller, space: f.home)
        a.windowDidBecomeKey()
        a.windowDidBecomeKey()
        await controller.engineWindows.settle()
        let reports = engine.windowReports
        a.windowFrameDidChange(x: 0, y: 0, width: 0, height: 0)
        controller.engineWindows.setNeedsReport()
        await controller.engineWindows.settle()
        XCTAssertEqual(engine.windowReports, reports)
    }

    /// An incognito window is reported off the record, through the app's one reporter.
    func testIncognitoWindowIsOffTheRecord() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        incognito.windowDidBecomeKey()
        await controller.engineWindows.settle()
        let reported = try XCTUnwrap(engine.windows.first { $0.id == incognito.windowID })
        XCTAssertTrue(reported.isOffTheRecord)
        XCTAssertTrue(reported.isFocused)
    }

    /// A Little Arc window is a popup window with its page; it leaves the list when it closes.
    func testLittleArcIsAPopupWindowWithItsPage() async throws {
        let engine = FakeEngine()
        let shell = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        addTeardownBlock { @MainActor in shell.stop() }
        let model = LittleArcModel(shell: shell, initialURL: URL(string: "https://swift.org"))
        await model.settleEngineWork()
        model.windowKeyStateChanged(isKey: true)
        model.windowFrameDidChange(x: 5, y: 6, width: 490, height: 329)
        await shell.controller.engineWindows.settle()

        let reported = try XCTUnwrap(engine.windows.first { $0.id == model.windowID })
        XCTAssertTrue(reported.isPopup)
        XCTAssertTrue(reported.isFocused)
        XCTAssertEqual(engine.windows.first?.id, model.windowID, "the focused Little Arc comes first")
        let page = try XCTUnwrap(model.liveTab?.id)
        XCTAssertEqual(reported.tabIDs, [page])
        XCTAssertEqual(reported.activeTabIDs, [page])
        XCTAssertEqual(reported.width, 490)

        model.close()
        await shell.controller.engineWindows.settle()
        XCTAssertNil(engine.windows.first { $0.id == model.windowID })
    }
}
