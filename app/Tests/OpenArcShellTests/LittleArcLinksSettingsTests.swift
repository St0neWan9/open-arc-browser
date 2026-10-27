import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B82: the Little Arc and Peek settings of Settings ▸ Links that were inert.
/// Spec: [03 §Links] observed the Little Arc switches (⌥⌘N in any app, ⌥⌘-click a link) and the
/// "Archive Little Arcs after" dropdown (default 6 hours); [03 §对复刻的含义] observed that the tab
/// archive (12 h) and the Little Arc archive (6 h) are separate timers; [02 §tabs] observed ⌘O
/// "Open Little Arc or Peek in…"; [06 §21.7] observed what ⌘O does in Little Arc (the page becomes
/// the selected top Today tab of the Space, the window switches to it).
@MainActor
final class LittleArcLinksSettingsTests: XCTestCase {
    private let hour: TimeInterval = 3600
    private let link = URL(string: "https://option-command.example/article")!

    /// A controller whose clock the test moves.
    private final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Setup {
        let controller: WorkspaceController
        let clock: Clock
        let ticker: ManualTicker
        let hotKeys: RecordingGlobalHotKeyService
        let engine: FakeEngine
        let preferences: AppPreferences
    }

    private func makeSetup(_ f: SidebarFixture = SidebarFixture(), configure: (AppPreferences) -> Void = { _ in }) -> Setup {
        let preferences = AppPreferences.inMemory()
        configure(preferences)
        let engine = FakeEngine()
        let hotKeys = RecordingGlobalHotKeyService()
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: preferences, globalHotKeys: hotKeys)
        let clock = Clock(f.now.addingTimeInterval(10))
        let ticker = ManualTicker()
        var counter = 5_000
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { clock.now },
            makeID: { counter += 1; return SidebarFixture.id(counter) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ticker
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return Setup(controller: controller, clock: clock, ticker: ticker, hotKeys: hotKeys, engine: engine, preferences: preferences)
    }

    private func window(_ controller: WorkspaceController, space: UUID?) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func recordLittleArcOpens(_ controller: WorkspaceController) -> () -> [UUID] {
        var opened: [UUID] = []
        controller.openLittleArcWindow = { opened.append($0) }
        return { opened }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    // MARK: - Catalog

    /// [03 §Links] observed: the three Little Arc controls are live; "Archive Little Arcs after"
    /// defaults to 6 hours; the two switches default to on (inferred, the spec records none).
    func testLinksControlsAreLiveWithTheirDefaults() {
        for id in ["links.littleArcHotKey", "links.littleArcModifierClick", "links.archiveLittleArcsAfter"] {
            XCTAssertTrue(SettingsCatalog.control(id).isEnabled, id)
        }
        XCTAssertEqual(SettingsCatalog.control("links.archiveLittleArcsAfter").kind, .picker(defaultValue: "6 hours"))
        let preferences = AppPreferences.inMemory()
        XCTAssertTrue(preferences.opensLittleArcWithGlobalHotKey)
        XCTAssertTrue(preferences.opensLittleArcOnOptionCommandClick)
        XCTAssertEqual(preferences.littleArcArchiveLifetime, .sixHours)
        XCTAssertEqual(LittleArcArchiveLifetime.default.interval, 6 * hour)
        XCTAssertEqual(LittleArcArchiveLifetime.default.displayName, "6 hours")
    }

    /// [03 §对复刻的含义] observed: the Little Arc archive is its own setting, apart from "Archive
    /// tabs after" (12 h). Stored per device; an unknown stored value reads as the default.
    func testArchiveLifetimeIsItsOwnPerDeviceSetting() throws {
        let suite = "openarc-b82-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.littleArcArchiveLifetime = .twentyFourHours
        XCTAssertEqual(AppPreferences(defaults: defaults).littleArcArchiveLifetime, .twentyFourHours)
        defaults.set("fortnight", forKey: AppPreferences.littleArcArchiveLifetimeKey)
        XCTAssertEqual(preferences.littleArcArchiveLifetime, .sixHours)
        XCTAssertNotEqual(AppPreferences.littleArcArchiveLifetimeKey, AppPreferences.legacyArchiveLifetimeKey(UUID()))
    }

    // MARK: - ⌥⌘N in any app

    /// [03 §Links] observed switch: on, the controller registers ⌥⌘N with the system at launch and
    /// a press opens a new (compact) Little Arc window; off removes the registration.
    func testHotKeyFollowsTheSwitchAndOpensLittleArc() {
        let s = makeSetup()
        let opened = recordLittleArcOpens(s.controller)
        XCTAssertTrue(s.hotKeys.isRegistered, "registered at launch (default on)")

        XCTAssertTrue(s.hotKeys.press())
        XCTAssertEqual(opened().count, 1)
        let windowID = opened()[0]
        XCTAssertTrue(s.controller.wasIssuedLittleArcWindow(windowID))
        XCTAssertNil(s.controller.takeLittleArcLaunchURL(for: windowID), "⌥⌘N opens the compact command bar")

        let settings = SettingsModel(shell: s.controller.appHost())
        settings.opensLittleArcWithGlobalHotKey = false
        XCTAssertFalse(s.hotKeys.isRegistered)
        XCTAssertFalse(s.hotKeys.press())
        XCTAssertEqual(opened().count, 1)
        XCTAssertFalse(s.preferences.opensLittleArcWithGlobalHotKey)

        settings.opensLittleArcWithGlobalHotKey = true
        XCTAssertTrue(s.hotKeys.isRegistered)
        XCTAssertTrue(s.hotKeys.press())
        XCTAssertEqual(opened().count, 2)
    }

    /// Switch off at launch: nothing is registered. The hot key lives only while the app runs:
    /// stopping the controller removes it.
    func testHotKeyOffAtLaunchAndRemovedOnStop() {
        let off = makeSetup { $0.opensLittleArcWithGlobalHotKey = false }
        XCTAssertFalse(off.hotKeys.isRegistered)
        XCTAssertEqual(off.hotKeys.registrationCount, 0)

        let on = makeSetup()
        XCTAssertTrue(on.hotKeys.isRegistered)
        on.controller.stop()
        XCTAssertFalse(on.hotKeys.isRegistered)
    }

    // MARK: - ⌥⌘-click a link

    /// [03 §Links] observed "⌥⌘-click a link opens Little Arc": the engine reports the click as a
    /// `.littleArc` request; a new Little Arc window opens already expanded on the link, and no
    /// model tab is made.
    func testOptionCommandClickOpensLittleArc() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f)
        let opened = recordLittleArcOpens(s.controller)
        let model = window(s.controller, space: f.home)
        model.sidebar.selectTab(f.today1)
        await s.controller.settleEngineWork()
        let live = try XCTUnwrap(s.controller.liveTab(for: f.today1) as? FakeTab)
        let tabsBefore = s.controller.workspace.tabs.count

        try await live.simulateLinkClick(to: link, optionCommand: true)
        let didOpen = await eventually { opened().count == 1 }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(s.controller.workspace.tabs.count, tabsBefore, "no model tab")
        XCTAssertEqual(model.selectedTabID, f.today1, "the source tab stays selected")

        let windowID = try XCTUnwrap(opened().first)
        let launchURL = s.controller.takeLittleArcLaunchURL(for: windowID)
        XCTAssertEqual(launchURL, link)
        let littleArc = LittleArcModel(shell: s.controller.littleArcHost(), initialURL: launchURL)
        XCTAssertEqual(littleArc.phase, .expanded)
        XCTAssertEqual(littleArc.currentURL, link)
        littleArc.close()
        await littleArc.settleEngineWork()
    }

    /// Switch off: a ⌥⌘-click does what ⌘-click does ([06 §22.1] observed: a background tab at the
    /// top of Today, the current tab unchanged).
    func testOptionCommandClickSwitchOffOpensBackgroundTab() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f) { $0.opensLittleArcOnOptionCommandClick = false }
        let opened = recordLittleArcOpens(s.controller)
        let model = window(s.controller, space: f.home)
        model.sidebar.selectTab(f.pinnedTab)
        await s.controller.settleEngineWork()
        let live = try XCTUnwrap(s.controller.liveTab(for: f.pinnedTab) as? FakeTab)

        try await live.simulateLinkClick(to: link, optionCommand: true)
        let didOpen = await eventually { s.controller.workspace.today(spaceID: f.home).first?.url == self.link }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(opened(), [])
        XCTAssertEqual(model.selectedTabID, f.pinnedTab, "background tab: selection unchanged")
    }

    /// A ⌥⌘-click inside a Little Arc page (no model tab) opens another Little Arc. inferred.
    func testOptionCommandClickInsideLittleArcOpensAnother() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f)
        let opened = recordLittleArcOpens(s.controller)
        _ = window(s.controller, space: f.home)
        let littleArc = LittleArcModel(shell: s.controller.littleArcHost(), initialURL: URL(string: "https://first.example")!)
        await littleArc.settleEngineWork()
        let live = try XCTUnwrap(littleArc.liveTab as? FakeTab)
        let tabsBefore = s.controller.workspace.tabs.count

        try await live.simulateLinkClick(to: link, optionCommand: true)
        let didOpen = await eventually { opened().count == 1 }
        XCTAssertTrue(didOpen)
        XCTAssertEqual(s.controller.takeLittleArcLaunchURL(for: try XCTUnwrap(opened().first)), link)
        XCTAssertEqual(s.controller.workspace.tabs.count, tabsBefore)
        littleArc.close()
        await littleArc.settleEngineWork()
    }

    // MARK: - Archive Little Arcs after

    /// [03 §Links] observed default 6 hours: an idle Little Arc window closes and its page becomes
    /// an archive item (TreeOps, reason auto-archived, in the Space "Open in" names). Injected clock
    /// and ticker; the window is not key.
    func testIdleLittleArcIsClosedAndArchivedAfterSixHours() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f)
        let model = window(s.controller, space: f.work)
        let littleArc = LittleArcModel(shell: model, initialURL: link)
        await littleArc.settleEngineWork()
        XCTAssertNotNil(littleArc.liveTab)
        XCTAssertTrue(s.controller.littleArcArchive.isRunning, "the timer runs while a Little Arc is open")
        XCTAssertTrue(s.ticker.requestedIntervals.contains(LittleArcArchiveState.checkInterval))
        let archiveBefore = s.controller.workspace.archive.count

        // Just under 6 h: still open.
        s.clock.now = s.clock.now.addingTimeInterval(6 * hour - 1)
        XCTAssertEqual(s.controller.archiveIdleLittleArcs(), [])
        XCTAssertEqual(littleArc.phase, .expanded)

        // 6 h: the next tick closes it and archives the page.
        s.clock.now = s.clock.now.addingTimeInterval(1)
        s.ticker.fire()
        let closed = await eventually { littleArc.phase == .closed }
        XCTAssertTrue(closed)
        let items = s.controller.workspace.archive.values.filter { $0.url == link }
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.reason, .autoArchived)
        XCTAssertEqual(item.spaceID, f.work)
        XCTAssertEqual(item.archivedAt, s.clock.now)
        XCTAssertEqual(s.controller.workspace.archive.count, archiveBefore + 1)
        await littleArc.settleEngineWork()
        XCTAssertTrue(s.engine.tabIDs.isEmpty, "the engine tab is closed")
        XCTAssertFalse(s.controller.littleArcArchive.isRunning, "no window left: the timer stops")
    }

    /// Activity resets the idle time; the key window is never archived; a compact window (no page)
    /// closes without an archive item; the setting is read at each check. inferred.
    func testActivityKeyWindowCompactAndSettingChange() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f)
        let model = window(s.controller, space: f.home)
        let page = LittleArcModel(shell: model, initialURL: link)
        let compact = LittleArcModel(shell: model)
        await page.settleEngineWork()
        let archiveBefore = s.controller.workspace.archive.count

        s.clock.now = s.clock.now.addingTimeInterval(5 * hour)
        page.open(URL(string: "https://option-command.example/next")!)
        s.clock.now = s.clock.now.addingTimeInterval(2 * hour)
        compact.windowKeyStateChanged(isKey: true)
        XCTAssertEqual(s.controller.archiveIdleLittleArcs(), [], "page used 2 h ago; compact is key")
        XCTAssertEqual(page.phase, .expanded)
        XCTAssertEqual(compact.phase, .compact)

        // Choosing 1 hour applies at once.
        let settings = SettingsModel(shell: s.controller.appHost())
        settings.littleArcArchiveLifetime = .oneHour
        XCTAssertEqual(page.phase, .closed)
        XCTAssertEqual(compact.phase, .compact, "the key window stays")
        XCTAssertEqual(s.controller.workspace.archive.count, archiveBefore + 1)

        // Leaving the key window starts its idle time; an hour later it closes with no item.
        compact.windowKeyStateChanged(isKey: false)
        s.clock.now = s.clock.now.addingTimeInterval(hour)
        XCTAssertEqual(s.controller.archiveIdleLittleArcs(), [])
        XCTAssertEqual(compact.phase, .closed)
        XCTAssertEqual(s.controller.workspace.archive.count, archiveBefore + 1, "a compact window has no page to archive")
        await page.settleEngineWork()
    }

    /// The two timers are separate ([03 §对复刻的含义] observed): the tab auto-archive leaves Little
    /// Arc windows alone, and the Little Arc archive leaves Today tabs alone.
    func testLittleArcArchiveAndTabArchiveAreSeparate() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f)
        let model = window(s.controller, space: f.home)
        let littleArc = LittleArcModel(shell: model, initialURL: link)
        await littleArc.settleEngineWork()
        let tabsBefore = s.controller.workspace.tabs.values.filter { !$0.meta.isTombstone }.count

        s.clock.now = s.clock.now.addingTimeInterval(7 * hour)
        s.controller.archiveIdleLittleArcs()
        XCTAssertEqual(littleArc.phase, .closed)
        XCTAssertEqual(s.controller.workspace.tabs.values.filter { !$0.meta.isTombstone }.count, tabsBefore, "Today tabs untouched at 7 h")
        await littleArc.settleEngineWork()
    }

    // MARK: - ⌘O in Peek

    /// [02 §tabs] observed ⌘O "Open Little Arc or Peek in…", [06 §21.7] observed for Little Arc:
    /// the Peek page becomes the selected top Today tab of the target Space and the window switches
    /// there; Peek closes and the source is unchanged. The engine tab is kept (no reload).
    func testCommandOInPeekOpensThePageInASpace() async throws {
        let f = SidebarFixture()
        let s = makeSetup(f)
        let model = window(s.controller, space: f.home)
        model.sidebar.selectTab(f.fav1)
        await s.controller.settleEngineWork()
        let peekURL = URL(string: "https://peeked.example/")!
        model.linkPeek.open(peekURL, from: f.fav1)
        await s.controller.settleEngineWork()
        let peekTab = try XCTUnwrap(model.linkPeek.liveTab)
        let engineTabsBefore = s.engine.tabIDs.count

        // Default target: the window's current Space (same as ⤢).
        let id = try XCTUnwrap(model.linkPeek.openInSpace(nil))
        XCTAssertNil(model.linkPeek.session)
        XCTAssertEqual(model.selectedTabID, id)
        XCTAssertEqual(s.controller.workspace.today(spaceID: f.home).first?.id, id)
        XCTAssertEqual(s.controller.workspace.tabs[id]?.url, peekURL)
        await s.controller.settleEngineWork()
        XCTAssertEqual(s.controller.liveTab(for: id)?.id, peekTab.id, "the Peek page's engine tab is kept")
        XCTAssertEqual(s.engine.tabIDs.count, engineTabsBefore)

        // A chosen Space: the window switches to it.
        model.sidebar.selectTab(f.fav1)
        model.linkPeek.open(URL(string: "https://second.example/")!, from: f.fav1)
        await s.controller.settleEngineWork()
        let moved = try XCTUnwrap(model.linkPeek.openInSpace(f.work))
        XCTAssertEqual(model.selectedSpaceID, f.work)
        XCTAssertEqual(model.selectedTabID, moved)
        XCTAssertEqual(s.controller.workspace.today(spaceID: f.work).first?.id, moved)
        XCTAssertEqual(s.controller.workspace.tabs[f.fav1].map { !$0.meta.isTombstone }, true, "source unchanged")
        await s.controller.settleEngineWork()
    }
}
