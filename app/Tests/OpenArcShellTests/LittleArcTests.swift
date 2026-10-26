import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
@testable import OpenArcShell

/// Little Arc window flow. [06 §7] observed: command-bar-only window of ≈ 490×330, ✕ in the field,
/// Escape closes, opening a page expands it to a browsing window. [02] observed: ⌥⌘N.
/// Inferred (no evidence in the spec): the page stays out of the workspace until "Open in Open Arc",
/// which opens it as a Today tab in the current space; closing the window closes the engine tab.
@MainActor
final class LittleArcTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func makeShell(engine: FakeEngine = FakeEngine()) -> ShellModel {
        ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: t0),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    /// Types `text` and presses Return, as the user would to pick the first row.
    private func choose(_ text: String, in model: LittleArcModel) async {
        await model.commandBar.waitForRefresh()
        model.commandBar.queryText = text
        await model.commandBar.waitForRefresh()
        model.commandBar.handle(.returnKey)
        await model.settleEngineWork()
    }

    /// [06 §7] observed: the window starts command-bar-only at ≈ 490×330 with the Little Arc bar.
    func testCompactWindowIsCommandBarSized() {
        let model = LittleArcModel(shell: makeShell())
        XCTAssertEqual(model.phase, .compact)
        XCTAssertEqual(model.windowSize, CGSize(width: 490, height: 330))
        XCTAssertEqual(model.commandBar.presentation, .littleArc)
        let layout = CommandBarLayout(presentation: .littleArc, resultCount: 5)
        XCTAssertEqual(layout.panelSize, model.windowSize)
        XCTAssertNil(model.liveTab)
    }

    /// [06 §7] observed: Escape closes the compact window. The ✕ button sends the same Escape key
    /// to the bar (see `CommandBarView.accessoryButton`).
    func testEscapeClosesCompactWindow() async {
        let engine = FakeEngine()
        let model = LittleArcModel(shell: makeShell(engine: engine))
        var closeCount = 0
        model.onClose = { closeCount += 1 }
        XCTAssertEqual(model.commandBar.handle(.escape), .dismiss)
        XCTAssertEqual(model.phase, .closed)
        XCTAssertEqual(closeCount, 1)
        // Closing again (the window's own close notification) does nothing more.
        model.windowDidClose()
        XCTAssertEqual(closeCount, 1)
        await model.settleEngineWork()
        XCTAssertTrue(engine.tabIDs.isEmpty)
    }

    /// [06 §7] observed: ✕ closes the window; the button is a close action on the same model.
    func testCloseButtonClosesCompactWindow() {
        let model = LittleArcModel(shell: makeShell())
        var closed = false
        model.onClose = { closed = true }
        model.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(model.phase, .closed)
    }

    /// [06 §7] observed: opening a page expands the window; the page loads in an engine tab.
    /// The expanded size is unknown (`LittleArcTokens.expandedSize`).
    func testChoosingAURLExpandsAndLoads() async throws {
        let engine = FakeEngine()
        let model = LittleArcModel(shell: makeShell(engine: engine))
        await choose("swift.org/blog", in: model)
        XCTAssertEqual(model.phase, .expanded)
        XCTAssertEqual(model.windowSize, LittleArcTokens.expandedSize)
        let tab = try XCTUnwrap(model.liveTab)
        XCTAssertEqual(engine.tabIDs, [tab.id])
        let state = await tab.currentState()
        XCTAssertEqual(state.url, URL(string: "https://swift.org/blog"))
        XCTAssertEqual(model.currentURL, URL(string: "https://swift.org/blog"))
        XCTAssertEqual(model.addressContent, .domain("swift.org", isSecure: true))
    }

    /// [06 §7]: a search result also opens a page (the profile's search engine, [03 §Profile] observed Google).
    func testChoosingASearchExpandsAndLoadsSearchURL() async throws {
        let shell = makeShell()
        let model = LittleArcModel(shell: shell)
        model.handle(.searchWeb(query: "swift concurrency", target: .newTab))
        await model.settleEngineWork()
        XCTAssertEqual(model.phase, .expanded)
        let state = try await XCTUnwrap(model.liveTab).currentState()
        XCTAssertEqual(state.url, shell.searchURL(for: "swift concurrency"))
    }

    /// Inferred: a Little Arc page is not in any Space before it is adopted.
    func testNoModelTabBeforeAdoption() async {
        let shell = makeShell()
        let before = shell.workspace.tabs
        let selected = shell.selectedTabID
        let model = LittleArcModel(shell: shell)
        await choose("https://news.ycombinator.com/item", in: model)
        XCTAssertNotNil(model.liveTab)
        XCTAssertEqual(shell.workspace.tabs, before)
        XCTAssertEqual(shell.selectedTabID, selected)
        XCTAssertFalse(shell.workspace.tabs.values.contains { $0.url == URL(string: "https://news.ycombinator.com/item") })
    }

    /// Inferred: "Open in Open Arc" opens the page as the top Today tab of the main window's current
    /// space, selects it and closes the Little Arc window. [06 §13] observed: new tabs go to the top of Today.
    func testAdoptionCreatesSelectedTodayTabInCurrentSpace() async throws {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let spaceID = try XCTUnwrap(shell.selectedSpaceID)
        let model = LittleArcModel(shell: shell)
        var closed = false
        model.onClose = { closed = true }
        await choose("https://news.ycombinator.com/item", in: model)
        let littleTab = try XCTUnwrap(model.liveTab)

        let id = try XCTUnwrap(model.adopt())
        await shell.sidebar.settleEngineWork()
        await model.settleEngineWork()

        let today = shell.workspace.today(spaceID: spaceID)
        XCTAssertEqual(today.first?.id, id)
        XCTAssertEqual(today.first?.url, URL(string: "https://news.ycombinator.com/item"))
        XCTAssertEqual(today.first?.title, "news.ycombinator.com")
        XCTAssertEqual(shell.selectedTabID, id)
        XCTAssertTrue(closed)
        XCTAssertEqual(model.phase, .closed)
        // The main window now hosts the page; the Little Arc engine tab is gone.
        XCTAssertFalse(engine.tabIDs.contains(littleTab.id))
        XCTAssertNotNil(shell.selectedLiveTab)
    }

    /// Adoption needs a page: nothing happens in the compact state.
    func testAdoptionIsUnavailableWhileCompact() {
        let shell = makeShell()
        let before = shell.workspace.tabs
        let model = LittleArcModel(shell: shell)
        XCTAssertNil(model.adopt())
        XCTAssertEqual(shell.workspace.tabs, before)
        XCTAssertEqual(model.phase, .compact)
    }

    /// Inferred: closing the expanded window closes its engine tab and archives nothing.
    func testClosingExpandedWindowClosesEngineTab() async throws {
        let engine = FakeEngine()
        let shell = makeShell(engine: engine)
        let archiveBefore = shell.workspace.archive
        let tabsBefore = shell.workspace.tabs
        let model = LittleArcModel(shell: shell)
        await choose("webkit.org/blog", in: model)
        XCTAssertEqual(engine.tabIDs.count, 1)

        model.windowDidClose()
        await model.settleEngineWork()
        XCTAssertEqual(model.phase, .closed)
        XCTAssertNil(model.liveTab)
        XCTAssertTrue(engine.tabIDs.isEmpty)
        XCTAssertEqual(shell.workspace.archive, archiveBefore)
        XCTAssertEqual(shell.workspace.tabs, tabsBefore)
    }

    /// The top bar's back/forward follow the page's history.
    func testToolbarNavigation() async throws {
        let model = LittleArcModel(shell: makeShell())
        await choose("webkit.org/a", in: model)
        model.open(URL(string: "https://webkit.org/b")!)
        await model.settleEngineWork()
        // Let the event stream deliver the navigation state.
        for _ in 0..<50 where !model.canGoBack { await Task.yield() }
        XCTAssertTrue(model.canGoBack)
        model.goBack()
        await model.settleEngineWork()
        let state = try await XCTUnwrap(model.liveTab).currentState()
        XCTAssertEqual(state.url, URL(string: "https://webkit.org/a"))
    }

    /// [02] observed ⌥⌘N; the command bar's "New Little Arc Window" row opens a window through the
    /// opener the main window installs.
    func testNewLittleArcCommandOpensWindow() {
        let shell = makeShell()
        var opened = 0
        shell.openLittleArcWindow = { opened += 1 }
        shell.perform(.runCommand(.newLittleArcWindow))
        XCTAssertEqual(opened, 1)
        XCTAssertNil(shell.lastUnhandledCommand)
    }
}
