import Foundation
import AppKit
import SwiftUI
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Records engine lifetime calls in order.
private actor LifetimeLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

/// Never runs autosave work: only the termination flush writes.
private struct NeverSaveScheduler: AutosaveScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {}
}

/// A FakeEngine whose `shutdown()` first runs `beforeShutdown` (to check what is on disk at that
/// moment) and can take `shutdownDelay` seconds, like a stuck engine. Everything else forwards.
private final class ShutdownProbeEngine: BrowserEngine {
    let base = FakeEngine()
    let beforeShutdown: @Sendable () async -> Void
    let shutdownDelay: TimeInterval

    init(shutdownDelay: TimeInterval = 0, beforeShutdown: @escaping @Sendable () async -> Void = {}) {
        self.shutdownDelay = shutdownDelay
        self.beforeShutdown = beforeShutdown
    }

    func makeTab(_ configuration: TabConfiguration) async throws -> any BrowserTab { try await base.makeTab(configuration) }
    func tab(for id: EngineTabID) async -> (any BrowserTab)? { await base.tab(for: id) }
    func closeTab(_ id: EngineTabID) async { await base.closeTab(id) }
    func events() -> AsyncStream<EngineEvent> { base.events() }
    func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) async throws -> any BrowserTab {
        try await base.adoptTab(token, requestedID: requestedID)
    }
    func declineTab(_ token: PendingTabToken) async { await base.declineTab(token) }
    var engineVersion: String { base.engineVersion }
    func shutdown() async {
        await beforeShutdown()
        if shutdownDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(shutdownDelay * 1_000_000_000)) }
        await base.shutdown()
    }
    func deleteProfileData(_ profileID: Profile.ID) async throws { try await base.deleteProfileData(profileID) }
    func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async {
        await base.clearBrowsingData(profileID, types: types, since: since)
    }
    var downloads: any EngineDownloads { base.downloads }
    var extensions: any EngineExtensions { base.extensions }
}

/// Plan B25: find in page, Print / Save Page As, View ▸ Developer ▸, and the engine shutdown on
/// quit. Spec: [01 §Edit] Find ▸ (Find… / Find Next / Find Previous / Use Selection to Find),
/// [01 §File] Save Page As / Print, [01 §View] Developer ▸ (View Source / Developer Tools /
/// Inspect Elements / JavaScript Console / Network Inspector / Allow JavaScript from Apple Events),
/// all observed item names; keys [02 §页面与导航] ⌘F / ⌘G / ⇧⌘G / ⌘P and [02 §开发者] ⌥⌘I / ⌥⌘C /
/// ⌥⌘J / ⌥⌘U observed. The find bar's look and behavior, one find state per tab, the toggle's
/// default and the quit ordering are inferred.
@MainActor
final class FindAndDeveloperTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: t0),
            now: { Date(timeIntervalSince1970: 0) },
            notificationCenter: NotificationCenter()
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var findBar: FindBarModel { model.findBar }

    /// Opens a page whose find text is `text` and returns its id and engine tab.
    private func openPage(_ address: String, text: String = "apple banana apple cherry apple") async throws -> (UUID, FakeTab) {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: address)))
        let id = try XCTUnwrap(opened)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        live.simulatePageText(text)
        return (id, live)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    private func findCommands(_ tab: FakeTab) -> [FakeTabCommand] {
        tab.commands.filter {
            switch $0 {
            case .find, .stopFinding: return true
            default: return false
            }
        }
    }

    // MARK: - Find bar ([01 §Edit] Find ▸, [02] ⌘F / ⌘G / ⇧⌘G)

    /// B19: after ⌘F the bar's field has the keyboard in a real window, so typing searches instead
    /// of going to the page; a second ⌘F selects the kept query. [02 §页面与导航] observed ⌘F.
    func testFindFieldTakesKeyboardInAWindow() async throws {
        let (id, _) = try await openPage("https://fruit.example")
        findBar.show()
        let host = NSHostingView(rootView: FindBarOverlay(host: FindBarHost(model: findBar, tabID: id)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }
        try await Task.sleep(nanoseconds: 50_000_000)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the find field must have the keyboard")
        XCTAssertTrue(editor.isFieldEditor)
        editor.insertText("apple", replacementRange: editor.selectedRange())
        XCTAssertEqual(findBar.state(for: id).query, "apple")

        window.makeFirstResponder(nil)
        findBar.show()
        try await Task.sleep(nanoseconds: 50_000_000)
        let again = try XCTUnwrap(window.firstResponder as? NSTextView, "⌘F again focuses the field")
        XCTAssertEqual(again.selectedRange(), NSRange(location: 0, length: 5), "the kept query is selected")

        // A bar rebuilt without a new ⌘F (tab switch, Library and back) leaves the keyboard alone.
        window.makeFirstResponder(nil)
        window.contentView = NSHostingView(rootView: FindBarOverlay(host: FindBarHost(model: findBar, tabID: id)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(window.firstResponder is NSTextView, "no ⌘F, no focus steal")
    }

    func testTypingSearchesAndShowsNOfM() async throws {
        let (id, live) = try await openPage("https://fruit.example")
        findBar.show()
        XCTAssertTrue(findBar.isVisible)
        XCTAssertNil(findBar.statusText(for: id), "nothing searched yet")

        findBar.updateQuery("apple")
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 3" }
        XCTAssertEqual(findCommands(live).last, .find("apple", FindOptions()))

        findBar.updateQuery("banana")
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 1" }

        findBar.updateQuery("kiwi")
        try await waitUntil { self.findBar.result(for: id)?.matches == 0 }
        XCTAssertEqual(findBar.statusText(for: id), "0 of 0")
    }

    /// Enter / ⌘G go to the next match, ⇧Enter / ⇧⌘G to the previous one, wrapping around.
    func testFindNextAndPreviousStepThroughMatches() async throws {
        let (id, live) = try await openPage("https://fruit.example")
        findBar.show()
        findBar.updateQuery("apple")
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 3" }

        findBar.findNext()
        try await waitUntil { self.findBar.statusText(for: id) == "2 of 3" }
        XCTAssertEqual(findCommands(live).last, .find("apple", FindOptions(backwards: false, findNext: true)))
        findBar.findNext()
        try await waitUntil { self.findBar.statusText(for: id) == "3 of 3" }
        findBar.findNext()
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 3" }
        findBar.findPrevious()
        try await waitUntil { self.findBar.statusText(for: id) == "3 of 3" }
        XCTAssertEqual(findCommands(live).last, .find("apple", FindOptions(backwards: true, findNext: true)))
    }

    /// Escape closes the bar and clears the highlights (`stopFinding`); the next ⌘F brings the
    /// query back and searches it again.
    func testEscapeClosesAndClearsHighlights() async throws {
        let (id, live) = try await openPage("https://fruit.example")
        findBar.show()
        findBar.updateQuery("apple")
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 3" }

        findBar.close()
        await model.controller.settleEngineWork()
        XCTAssertFalse(findBar.isVisible)
        XCTAssertEqual(findCommands(live).last, .stopFinding(keepSelection: false))
        XCTAssertNil(model.sidebar.liveState(for: id)?.findResult, "no stale result")
        XCTAssertNil(findBar.statusText(for: id))

        let focusBefore = findBar.focusRequest
        findBar.show()
        XCTAssertEqual(findBar.focusRequest, focusBefore + 1)
        XCTAssertEqual(findBar.state(for: id).query, "apple")
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 3" }
    }

    /// Clearing the text ends the search like Escape, but the bar stays open.
    func testClearingTheQueryStopsTheSearch() async throws {
        let (id, live) = try await openPage("https://fruit.example")
        findBar.show()
        findBar.updateQuery("apple")
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 3" }
        findBar.updateQuery("")
        await model.controller.settleEngineWork()
        XCTAssertTrue(findBar.isVisible)
        XCTAssertEqual(findCommands(live).last, .stopFinding(keepSelection: false))
        XCTAssertNil(findBar.statusText(for: id))
    }

    /// ⌘G without an open bar opens it (nothing to search yet).
    func testFindNextWithoutQueryOpensTheBar() async throws {
        let (_, live) = try await openPage("https://fruit.example")
        findBar.findNext()
        XCTAssertTrue(findBar.isVisible)
        await model.controller.settleEngineWork()
        XCTAssertTrue(findCommands(live).isEmpty)
    }

    /// One find state per tab: another tab has its own (closed) bar; coming back restores it.
    func testFindStateIsPerTab() async throws {
        let (first, _) = try await openPage("https://one.example")
        findBar.show()
        findBar.updateQuery("apple")
        try await waitUntil { self.findBar.statusText(for: first) == "1 of 3" }

        let (second, secondLive) = try await openPage("https://two.example")
        XCTAssertEqual(model.selectedTabID, second)
        XCTAssertFalse(findBar.isVisible, "the new tab has no open bar")
        XCTAssertEqual(findBar.state(for: second), FindBarState())
        XCTAssertFalse(findBar.isVisible(for: first), "a bar shows only over the selected tab")

        findBar.show()
        findBar.updateQuery("cherry")
        try await waitUntil { self.findBar.statusText(for: second) == "1 of 1" }
        XCTAssertEqual(findCommands(secondLive).last, .find("cherry", FindOptions()))

        try await model.activate(tabID: first)
        XCTAssertTrue(findBar.isVisible)
        XCTAssertEqual(findBar.state(for: first).query, "apple")
        XCTAssertEqual(findBar.statusText(for: first), "1 of 3")
    }

    /// Use Selection to Find: the page's selection becomes the query and is searched.
    func testUseSelectionToFind() async throws {
        let (id, live) = try await openPage("https://fruit.example")
        live.simulateSelection("cherry")
        findBar.useSelectionToFind()
        try await waitUntil { self.findBar.statusText(for: id) == "1 of 1" }
        XCTAssertTrue(findBar.isVisible)
        XCTAssertEqual(findBar.state(for: id).query, "cherry")
    }

    // MARK: - Split view: the bar acts on the focused pane

    func testFindTargetsTheFocusedSplitPane() async throws {
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let base = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: base)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        let pane = try XCTUnwrap(model.selectedTabID)
        model.dismissCommandBar()
        await model.sidebar.ensureLive(base)
        let baseLive = try XCTUnwrap(model.sidebar.liveTab(for: base) as? FakeTab)
        let paneLive = try XCTUnwrap(model.sidebar.liveTab(for: pane) as? FakeTab)
        baseLive.simulatePageText("left left")
        paneLive.simulatePageText("left right")

        // The right pane is focused (the new pane): find runs there.
        findBar.show()
        findBar.updateQuery("left")
        try await waitUntil { self.findBar.statusText(for: pane) == "1 of 1" }
        XCTAssertTrue(findBar.isVisible(for: pane))
        XCTAssertFalse(findBar.isVisible(for: base))
        XCTAssertTrue(findCommands(baseLive).isEmpty, "the other pane is not searched")

        // Focusing the left pane moves the bar's target there.
        model.focusPane(base)
        XCTAssertFalse(findBar.isVisible(for: pane), "the right pane's bar hides while it is not focused")
        findBar.show()
        findBar.updateQuery("left")
        try await waitUntil { self.findBar.statusText(for: base) == "1 of 2" }
        findBar.findNext()
        try await waitUntil { self.findBar.statusText(for: base) == "2 of 2" }
        XCTAssertEqual(findCommands(paneLive).count, 1, "the right pane got only its own search")
    }

    // MARK: - File ▸ Print / Save Page As, View ▸ Developer ▸

    func testPrintAndSavePageAsReachTheEngine() async throws {
        let (_, live) = try await openPage("https://doc.example")
        XCTAssertTrue(model.canRunPageCommands)
        model.printPage()
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.commands.last, .print)

        let target = URL(fileURLWithPath: "/tmp/openarc-b25/doc.html")
        var suggested: String?
        model.chooseSavePageLocation = { name in
            suggested = name
            return SavePageChoice(url: target)
        }
        model.savePageAs()
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.commands.last, .savePage(target, .complete))
        XCTAssertEqual(suggested, "doc.example.html", "the page title names the file")

        // Cancelling the panel saves nothing.
        model.chooseSavePageLocation = { _ in nil }
        model.savePageAs()
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.commands.filter { if case .savePage = $0 { return true } else { return false } }.count, 1)
    }

    /// Save Page As passes the chosen format to the engine. [01 §File] observed item; the formats
    /// and their names are Chromium's (inferred). C15.
    func testSavePageAsPassesTheFormat() async throws {
        let (_, live) = try await openPage("https://doc.example")
        let target = URL(fileURLWithPath: "/tmp/openarc-c15/doc.mhtml")
        model.chooseSavePageLocation = { _ in SavePageChoice(url: target, format: .singleFile) }
        model.savePageAs()
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.commands.last, .savePage(target, .singleFile))
        XCTAssertEqual(SavePageFormat.allCases.map(SavePagePanel.title(of:)),
                       ["Web Page, Complete", "Web Page, HTML Only", "Web Page, Single File"])
    }

    // MARK: - Picture in Picture (C15)

    /// Leaving a tab whose video plays puts it in Picture in Picture; coming back closes it.
    /// [03 §Advanced] observed "Enable Picture in Picture when you leave a video tab" (on).
    func testLeavingAVideoTabEntersPictureInPicture() async throws {
        let (videoID, video) = try await openPage("https://video.example")
        video.simulateVideo(playing: true)
        let (otherID, _) = try await openPage("https://other.example")
        try await waitUntil { video.commands.contains(.enterPictureInPicture(automatically: true)) }
        XCTAssertTrue(video.isPictureInPictureActive)

        model.sidebar.selectTab(videoID)
        try await waitUntil { video.commands.contains(.exitPictureInPicture) }
        XCTAssertFalse(video.isPictureInPictureActive)
        XCTAssertNotEqual(videoID, otherID)
    }

    /// The Advanced toggle off: leaving the tab leaves the video alone.
    func testAutomaticPictureInPictureFollowsTheSetting() async throws {
        model.dependencies.preferences.entersPictureInPictureOnLeavingVideoTab = false
        defer { model.dependencies.preferences.entersPictureInPictureOnLeavingVideoTab = true }
        let (_, video) = try await openPage("https://video.example")
        video.simulateVideo(playing: true)
        _ = try await openPage("https://other.example")
        await model.controller.settleEngineWork()
        XCTAssertFalse(video.commands.contains(.enterPictureInPicture(automatically: true)))
        XCTAssertFalse(video.isPictureInPictureActive)
    }

    /// "Back to tab" in the Picture in Picture window (`TabEvent.activationRequested`) selects
    /// the tab again. inferred.
    func testActivationRequestSelectsTheTab() async throws {
        let (videoID, video) = try await openPage("https://video.example")
        let (otherID, _) = try await openPage("https://other.example")
        XCTAssertEqual(model.selectedTabID, otherID)
        video.simulateActivationRequest()
        try await waitUntil { self.model.selectedTabID == videoID }
    }

    func testSuggestedFileName() {
        XCTAssertEqual(ShellModel.suggestedPageFileName(title: "A/B: C"), "A-B- C.html")
        XCTAssertEqual(ShellModel.suggestedPageFileName(title: "  "), "Untitled.html")
    }

    func testDeveloperItemsReachTheEngine() async throws {
        let (_, live) = try await openPage("https://dev.example")
        model.showDeveloperTools()
        model.inspectElements()
        model.showJavaScriptConsole()
        model.showNetworkInspector()
        await model.controller.settleEngineWork()
        let panels = live.commands.compactMap { command -> DevToolsPanel?? in
            if case .showDevTools(let panel) = command { return .some(panel) }
            return nil
        }
        XCTAssertEqual(panels, [nil, .elements, .console, .network])
    }

    /// View Source: the engine asks for a `view-source:` tab, which opens as a new tab.
    func testViewSourceOpensTheSourceTab() async throws {
        let (_, live) = try await openPage("https://dev.example")
        model.viewPageSource()
        try await waitUntil { self.model.workspace.tabs.values.contains { $0.url?.scheme == "view-source" } }
        XCTAssertTrue(live.commands.contains(.viewSource))
    }

    /// Without a selected page the commands do nothing (and their menu items are disabled).
    func testPageCommandsNeedALivePage() async throws {
        XCTAssertNil(model.selectedTabID, "a fresh window selects no tab")
        XCTAssertFalse(model.canRunPageCommands)
        model.printPage()
        model.showDeveloperTools()
        model.savePageAs()
        findBar.show()
        await model.controller.settleEngineWork()
        XCTAssertFalse(findBar.isVisible)
        XCTAssertTrue(engine.tabIDs.isEmpty)
    }

    /// Allow JavaScript from Apple Events: off by default (inferred), stored in `AppPreferences`.
    func testAllowJavaScriptFromAppleEventsToggle() {
        let preferences = model.dependencies.preferences
        XCTAssertFalse(model.allowsJavaScriptFromAppleEvents)
        XCTAssertFalse(preferences.allowsJavaScriptFromAppleEvents)
        model.allowsJavaScriptFromAppleEvents = true
        XCTAssertTrue(preferences.allowsJavaScriptFromAppleEvents)
        model.allowsJavaScriptFromAppleEvents = false
        XCTAssertFalse(preferences.allowsJavaScriptFromAppleEvents)

        let suite = "openarc.b25.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = AppPreferences(defaults: defaults)
        stored.allowsJavaScriptFromAppleEvents = true
        XCTAssertTrue(AppPreferences(defaults: defaults).allowsJavaScriptFromAppleEvents)
    }
}

// MARK: - Quit

/// B25: the termination path flushes the store, then shuts the engine down, bounded by a timeout.
@MainActor
final class EngineShutdownOnQuitTests: XCTestCase {
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b25-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(engine: any BrowserEngine, persistence: WorkspaceStore?, center: NotificationCenter) -> ShellModel {
        let model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), persistence: persistence),
            workspace: .firstLaunch(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) },
            notificationCenter: center
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// `willTerminate` writes the workspace first; the engine shuts down after that.
    func testShutdownRunsAfterTheFlush() async throws {
        let directory = self.directory
        let log = LifetimeLog()
        let engine = ShutdownProbeEngine {
            let saved = WorkspaceStore(directory: directory).loadResult.workspace
            let titles = saved.folders.values.map(\.title)
            await log.append(titles.contains("Last edit") ? "shutdown after flush" : "shutdown before flush")
        }
        // Autosave never fires: only the termination flush can write.
        let store = WorkspaceStore(directory: directory, scheduler: NeverSaveScheduler())
        let center = NotificationCenter()
        let model = makeModel(engine: engine, persistence: store, center: center)
        _ = try XCTUnwrap(model.sidebar.createFolder(title: "Last edit"))

        center.post(name: NSApplication.willTerminateNotification, object: nil)

        XCTAssertTrue(engine.base.shutdownCalled, "shutdown finished before willTerminate returned")
        let entries = await log.entries
        XCTAssertEqual(entries, ["shutdown after flush"])
    }

    /// Without a store (previews, `.fake()`), quitting still shuts the engine down.
    func testShutdownWithoutPersistence() {
        let engine = FakeEngine()
        let center = NotificationCenter()
        _ = makeModel(engine: engine, persistence: nil, center: center)
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertTrue(engine.shutdownCalled)
    }

    /// A stuck engine cannot hold up quitting: the wait ends at the timeout.
    func testShutdownIsBoundedByTimeout() {
        let engine = ShutdownProbeEngine(shutdownDelay: 5)
        let model = makeModel(engine: engine, persistence: nil, center: NotificationCenter())
        let start = Date()
        model.flushForTermination(engineShutdownTimeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.2)
        XCTAssertLessThan(elapsed, 2, "quit waited for the stuck engine")
        XCTAssertFalse(engine.base.shutdownCalled)
    }

    /// An incognito controller shares the app's engine and never shuts it down.
    func testIncognitoControllerDoesNotShutDownTheEngine() {
        let engine = FakeEngine()
        let model = makeModel(engine: engine, persistence: nil, center: NotificationCenter())
        let incognito = model.controller.makeIncognito()
        incognito.flushForTermination(engineShutdownTimeout: 0.2)
        XCTAssertFalse(engine.shutdownCalled)
        incognito.stop()
    }
}
