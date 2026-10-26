import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// B24: the Links setting "Open links from other apps in Little Arc". [03 §Links] observed toggle;
/// its default is not recorded, so off (inferred). With it on, a web link from another app opens
/// in a new Little Arc window that is already expanded on the page ([06 §7] observed expansion
/// after a page opens); no model tab exists until "Open in Open Arc". Local files still open as
/// Today tabs (inferred).
@MainActor
final class LittleArcExternalTests: XCTestCase {
    private let link = URL(string: "https://mail-link.example.com/article")!
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        try await super.tearDown()
    }

    private func makeController(_ f: SidebarFixture, preferences: AppPreferences, engine: FakeEngine = FakeEngine()) -> WorkspaceController {
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: preferences)
        var counter = 1_000
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now.addingTimeInterval(10) },
            makeID: { counter += 1; return SidebarFixture.id(counter) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID?) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// Records the ids of the Little Arc windows the controller asks the scene to open.
    private func installLittleArcOpener(_ controller: WorkspaceController) -> () -> [UUID] {
        var opened: [UUID] = []
        controller.openLittleArcWindow = { opened.append($0) }
        return { opened }
    }

    /// [03 §Links] the toggle exists, is live, and is off by default (inferred).
    func testSettingIsLiveAndOffByDefault() {
        let control = SettingsCatalog.control("links.littleArcExternal")
        XCTAssertTrue(control.isEnabled)
        XCTAssertEqual(control.kind, .toggle(defaultValue: false))
        XCTAssertFalse(AppPreferences.inMemory().opensExternalLinksInLittleArc)
    }

    /// Setting off: D2 behavior, the link becomes a Today tab in the frontmost window; no Little
    /// Arc window is opened.
    func testSettingOffOpensTodayTab() throws {
        let f = SidebarFixture()
        let controller = makeController(f, preferences: .inMemory())
        let opened = installLittleArcOpener(controller)
        let model = window(controller, space: f.home)

        controller.openExternal([link])

        XCTAssertEqual(opened(), [])
        XCTAssertEqual(controller.workspace.tabs[try XCTUnwrap(model.selectedTabID)]?.url, link)
        XCTAssertEqual(controller.externalLinkRouter.destination(for: link, in: controller.workspace), .frontmostWindow)
    }

    /// Setting on: the router picks `.littleArc`; one Little Arc window opens per link; its model
    /// starts expanded, loads the URL in an engine tab, and no model tab is created.
    func testSettingOnOpensExpandedLittleArcWithoutModelTab() async throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.opensExternalLinksInLittleArc = true
        let engine = FakeEngine()
        let controller = makeController(f, preferences: preferences, engine: engine)
        let opened = installLittleArcOpener(controller)
        let model = window(controller, space: f.home)
        let tabsBefore = controller.workspace.tabs.count
        var focused = 0
        model.focusWindow = { focused += 1 }

        XCTAssertEqual(controller.externalLinkRouter.destination(for: link, in: controller.workspace), .littleArc)
        controller.openExternal([link])

        let windowID = try XCTUnwrap(opened().first)
        XCTAssertEqual(opened().count, 1)
        XCTAssertEqual(controller.workspace.tabs.count, tabsBefore, "no model tab")
        XCTAssertNil(model.selectedTabID, "the browser window is untouched")
        XCTAssertEqual(focused, 0, "the browser window is not brought to the front")

        // The scene builds the window: it takes the launch URL once.
        let launchURL = controller.takeLittleArcLaunchURL(for: windowID)
        XCTAssertEqual(launchURL, link)
        XCTAssertNil(controller.takeLittleArcLaunchURL(for: windowID), "consumed")

        let littleArc = LittleArcModel(shell: controller.littleArcHost(), initialURL: launchURL)
        XCTAssertEqual(littleArc.phase, .expanded, "skips the compact command bar")
        XCTAssertEqual(littleArc.windowSize, LittleArcTokens.expandedSize)
        XCTAssertEqual(littleArc.currentURL, link)
        await littleArc.settleEngineWork()
        XCTAssertNotNil(littleArc.liveTab)
        XCTAssertEqual(engine.tabIDs.count, 1)
        XCTAssertEqual(controller.workspace.tabs.count, tabsBefore, "still no model tab")
        littleArc.close()
        await littleArc.settleEngineWork()
    }

    /// Setting on: local files still open as Today tabs; only the web link goes to Little Arc.
    func testFilesStillOpenAsTodayTabs() throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.opensExternalLinksInLittleArc = true
        let controller = makeController(f, preferences: preferences)
        let opened = installLittleArcOpener(controller)
        let model = window(controller, space: f.home)
        let pdf = URL(fileURLWithPath: "/tmp/Report.pdf")

        XCTAssertEqual(controller.externalLinkRouter.destination(for: pdf, in: controller.workspace), .frontmostWindow)
        controller.openExternal([pdf, link])

        XCTAssertEqual(opened().count, 1)
        XCTAssertEqual(controller.workspace.tabs[try XCTUnwrap(model.selectedTabID)]?.url, pdf)
        XCTAssertFalse(controller.workspace.today(spaceID: f.home).contains { $0.url == link })
    }

    /// Setting on but no Little Arc opener installed yet: the link is not lost, it opens as a
    /// Today tab. inferred.
    func testWithoutOpenerFallsBackToTodayTab() throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.opensExternalLinksInLittleArc = true
        let controller = makeController(f, preferences: preferences)
        let model = window(controller, space: f.home)

        controller.openExternal([link])

        XCTAssertEqual(controller.workspace.tabs[try XCTUnwrap(model.selectedTabID)]?.url, link)
    }

    /// Setting on with no browser window open: a Little Arc window opens and no browser window is
    /// requested.
    func testNoBrowserWindowOpensOnlyLittleArc() {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.opensExternalLinksInLittleArc = true
        let controller = makeController(f, preferences: preferences)
        let opened = installLittleArcOpener(controller)
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }

        controller.openExternal([link])

        XCTAssertEqual(opened().count, 1)
        XCTAssertEqual(requests, [])
        XCTAssertTrue(controller.pendingExternalURLs.isEmpty)
    }

    /// A Little Arc window opened without a launch URL (⌥⌘N) still starts compact.
    func testWindowWithoutLaunchURLStartsCompact() {
        let f = SidebarFixture()
        let controller = makeController(f, preferences: .inMemory())
        XCTAssertNil(controller.takeLittleArcLaunchURL(for: UUID()))
        let littleArc = LittleArcModel(shell: controller.littleArcHost(), initialURL: nil)
        XCTAssertEqual(littleArc.phase, .compact)
        littleArc.close()
    }

    /// The setting persists in the preferences suite and is read through the Settings model.
    func testSettingPersistsViaPreferencesSuite() throws {
        let suite = "org.openarc.tests.b24.\(UUID().uuidString)"
        suiteNames.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let f = SidebarFixture()
        let controller = makeController(f, preferences: AppPreferences(defaults: defaults))
        let settings = SettingsModel(shell: controller.appHost())
        XCTAssertFalse(settings.opensExternalLinksInLittleArc)

        settings.opensExternalLinksInLittleArc = true

        let reopened = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertTrue(reopened.opensExternalLinksInLittleArc)
        XCTAssertEqual(controller.externalLinkRouter.destination(for: link, in: controller.workspace), .littleArc,
                       "the router reads the current value")
    }
}
