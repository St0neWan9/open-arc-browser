import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Site Control Center and URL box copy link. [06 §12] observed: hovering the URL box shows copy
/// link and site controls; the bubble has 4 tool buttons, "Extensions", "Settings" (Developer
/// Mode Off, Automatic Picture-In-Picture Allowed), a "Secure" pill and "⋯"; it closes when the
/// pointer leaves.
@MainActor
final class SiteControlsTests: XCTestCase {
    private var model: ShellModel!
    private var provider: FakeSiteSettingsProvider!
    private var pasteboard: RecordingPasteboardWriter!
    private let site = SiteOrigin(scheme: "https", host: "example.com")

    override func setUp() async throws {
        model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)), now: { Date(timeIntervalSince1970: 0) })
        provider = FakeSiteSettingsProvider()
        pasteboard = RecordingPasteboardWriter()
        model.siteControls.provider = provider
        model.siteControls.pasteboard = pasteboard
        model.siteControls.pointerLeaveGrace = 0
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
    }

    /// Selects the demo's example.com tab and waits for its engine tab.
    @discardableResult
    private func selectExampleTab() async throws -> UUID {
        let id = try XCTUnwrap(model.workspace.tabs.values.first { $0.url?.host == "example.com" }?.id)
        try await model.activate(tabID: id)
        return id
    }

    /// 06 §12: the site-controls icon sends `showSiteControls`; the shell opens the bubble for
    /// the selected tab with the observed defaults.
    func testShowSiteControlsRequestOpensBubble() async throws {
        let id = try await selectExampleTab()
        model.sidebar.requestFromMenu(.showSiteControls)
        let sc = model.siteControls
        XCTAssertTrue(sc.isPresented)
        XCTAssertEqual(sc.tabID, id)
        XCTAssertEqual(sc.site, site)
        await sc.settle()
        XCTAssertEqual(sc.settingRows.map(\.title), ["Developer Mode", "Automatic Picture-In-Picture"])
        XCTAssertEqual(sc.settingRows.map(\.status), ["Off", "Allowed"])
        XCTAssertEqual(sc.securityLabel, "Secure")
        XCTAssertEqual(SiteControlsTool.allCases.map(\.title), ["Share", "New Boost", "Capture Area", "Capture Full Page"])
        XCTAssertFalse(sc.showsManageExtensions)
    }

    /// 06 §12: no page, no icon; the request does nothing without a site.
    func testNoBubbleWithoutPage() {
        let spaceID = model.selectedSpaceID!
        _ = model.sidebar.newTab(url: nil, title: "New Tab")
        XCTAssertEqual(model.selectedSpaceID, spaceID)
        model.sidebar.requestFromMenu(.showSiteControls)
        XCTAssertFalse(model.siteControls.isPresented)
    }

    /// 06 §12: copy link writes the current URL; "Copied" feedback is inferred and clears itself.
    func testCopyLinkWritesURLAndShowsFeedback() async throws {
        try await selectExampleTab()
        let sc = model.siteControls
        sc.copiedFeedbackDuration = 0.01
        sc.copyLink()
        XCTAssertEqual(pasteboard.written, [URL(string: "https://example.com")!])
        XCTAssertTrue(sc.isLinkCopied)
        for _ in 0..<200 where sc.isLinkCopied { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(sc.isLinkCopied)
    }

    /// 06 §12 "Settings" rows reflect the engine's site settings (fake provider until C12/C14/C16).
    func testRowsReflectFakeSiteSettings() async throws {
        try await selectExampleTab()
        provider.set(SiteSettingsState(
            permissions: [.camera: .allow, .notifications: .block],
            isDeveloperModeOn: true,
            isAutomaticPictureInPictureAllowed: false,
            zoomPercent: 125,
            cookieCount: 3,
            isAdBlockingOn: true,
            extensions: [SiteExtensionAction(id: "ext1", name: "Blocker")]
        ), for: site, profileID: model.sidebar.currentProfileID)
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        let rows = Dictionary(uniqueKeysWithValues: sc.settingRows.map { ($0.kind, $0.status) })
        XCTAssertEqual(rows[.developerMode], "On")
        XCTAssertEqual(rows[.automaticPictureInPicture], "Blocked")
        XCTAssertEqual(rows[.permission(.camera)], "Allowed")
        XCTAssertEqual(rows[.permission(.notifications)], "Blocked")
        XCTAssertNil(rows[.permission(.microphone)])
        XCTAssertEqual(rows[.cookies], "3 cookies")
        XCTAssertEqual(rows[.zoom], "125%")
        XCTAssertEqual(rows[.adBlocking], "On")
        XCTAssertTrue(sc.showsManageExtensions)
        sc.runExtension("ext1")
        await sc.settle()
        XCTAssertEqual(provider.extensionActionsRun, ["ext1"])
    }

    /// 06 §12: toggling a row goes through the site settings protocol and the row updates.
    func testTogglingCallsProvider() async throws {
        try await selectExampleTab()
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        sc.setPermission(.location, .allow)
        await sc.settle()
        XCTAssertEqual(provider.appliedChanges, [.permission(.location, .allow)])
        XCTAssertEqual(sc.settings.decision(for: .location), .allow)
        sc.activate(.permission(.location))
        sc.activate(.developerMode)
        await sc.settle()
        XCTAssertEqual(provider.appliedChanges.suffix(2), [.permission(.location, .block), .developerMode(true)])
        XCTAssertEqual(sc.settingRows.first { $0.kind == .developerMode }?.status, "On")
    }

    /// 06 §12 bubble with an audible tab: the Sound row mutes through the sidebar's engine path.
    func testMuteRowUsesToggleMute() async throws {
        let id = try await selectExampleTab()
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        let sc = model.siteControls
        sc.present()
        XCTAssertFalse(sc.settingRows.contains { $0.kind == .sound })
        live.simulateAudio(true)
        try await waitUntil { sc.settingRows.contains { $0.kind == .sound } }
        XCTAssertEqual(sc.settingRows.first { $0.kind == .sound }?.status, "Playing")
        sc.activate(.sound)
        await model.sidebar.settleEngineWork()
        try await waitUntil { sc.settingRows.first { $0.kind == .sound }?.status == "Muted" }
        let state = await live.currentState()
        XCTAssertTrue(state.audio.isMuted)
    }

    /// 06 §12: the bubble closes when the pointer leaves (observed); Escape, a click outside and
    /// a tab change close it too (inferred). Re-entering within the grace period keeps it open.
    func testCloseRules() async throws {
        try await selectExampleTab()
        let sc = model.siteControls
        sc.present()
        sc.pointerExited()
        XCTAssertFalse(sc.isPresented)
        XCTAssertEqual(sc.lastCloseReason, .pointerLeft)

        sc.present()
        sc.close(.escape)
        XCTAssertEqual(sc.lastCloseReason, .escape)

        sc.present()
        sc.close(.clickOutside)
        XCTAssertEqual(sc.lastCloseReason, .clickOutside)

        sc.present()
        let other = try XCTUnwrap(model.workspace.tabs.values.first { $0.url?.host == "example.org" }?.id)
        model.sidebar.selectTab(other)
        XCTAssertFalse(sc.isPresented)
        XCTAssertEqual(sc.lastCloseReason, .tabChanged)

        sc.pointerLeaveGrace = 0.05
        sc.present()
        sc.pointerExited()
        sc.pointerEntered()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(sc.isPresented)
        sc.pointerExited()
        try await waitUntil { !sc.isPresented }
        XCTAssertEqual(sc.lastCloseReason, .pointerLeft)
    }

    /// 06 §12 tool buttons: the capture buttons are disabled without a handler; with one, they run
    /// and close the bubble. The shell installs the capture handler (B51). Share and New Boost are
    /// the bubble's own and stay enabled (B80).
    func testToolButtons() async throws {
        let id = try await selectExampleTab()
        let sc = model.siteControls
        sc.present()
        XCTAssertTrue(sc.canRunTools)
        sc.toolHandler = nil
        XCTAssertFalse(sc.canRunTools)
        XCTAssertFalse(sc.canRun(.captureArea))
        XCTAssertTrue(sc.canRun(.share))
        XCTAssertTrue(sc.canRun(.newBoost))
        var ran: [(SiteControlsTool, UUID)] = []
        sc.toolHandler = { ran.append(($0, $1)) }
        sc.run(.captureArea)
        XCTAssertEqual(ran.first?.0, .captureArea)
        XCTAssertEqual(ran.first?.1, id)
        XCTAssertEqual(sc.lastCloseReason, .action)
    }

    /// The pill reads the scheme. [06 §12] observed "Secure"; [06 §17.3] observed "Insecure".
    func testSecurityLabel() async throws {
        let id = try XCTUnwrap(model.sidebar.newTab(url: URL(string: "http://plain.example"), title: "plain"))
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.selectedTabID, id)
        model.siteControls.present()
        XCTAssertEqual(model.siteControls.securityLabel, "Insecure")
    }

    /// 06 §19.1 observed: the "⋯" menu is Clear Cache · Clear Cookies ‖ Manage Boosts… · New Boost… ‖
    /// Manage Extensions… · Add Extension… ‖ All Site Settings…, nothing else (B80).
    func testMenuOrder() {
        XCTAssertEqual(SiteControlsMenuItem.groups.map { $0.map(\.title) }, [
            ["Clear Cache", "Clear Cookies"],
            ["Manage Boosts…", "New Boost…"],
            ["Manage Extensions…", "Add Extension…"],
            ["All Site Settings…"],
        ])
        XCTAssertEqual(SiteControlsMenuItem.groups.flatMap { $0 }, SiteControlsMenuItem.allCases)
    }

    /// 06 §19.1 menu items: each one's effect (inferred targets). New Boost… is inert (Boosts are
    /// out of v1); Manage Boosts… opens Library ▸ Boosts; All Site Settings… opens the site's
    /// settings page; Clear Cache reloads bypassing the cache; Clear Cookies clears site data.
    func testMenuItems() async throws {
        let id = try await selectExampleTab()
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        let sc = model.siteControls
        sc.present()
        XCTAssertTrue(SiteControlsMenuItem.allCases.allSatisfy(sc.isEnabled))

        sc.perform(.newBoost)
        sc.run(.newBoost)
        XCTAssertTrue(sc.isPresented)
        XCTAssertNil(model.library.section)

        sc.perform(.clearCache)
        await sc.settle()
        XCTAssertTrue(live.commands.contains(.reload(bypassingCache: true)))
        sc.perform(.clearCookies)
        await sc.settle()
        XCTAssertEqual(provider.appliedChanges, [.clearSiteData])
        XCTAssertTrue(sc.isPresented)

        sc.perform(.manageBoosts)
        XCTAssertFalse(sc.isPresented)
        XCTAssertEqual(model.library.section, .boosts)
        model.exitLibrary()

        try await model.activate(tabID: id)
        sc.present()
        sc.perform(.allSiteSettings)
        XCTAssertFalse(sc.isPresented)
        let opened = try XCTUnwrap(model.selectedTabID.flatMap { model.workspace.tabs[$0]?.url })
        XCTAssertEqual(opened.absoluteString, "chrome://settings/content/siteDetails?site=https%3A%2F%2Fexample.com")

        sc.manageBoostsHandler = nil
        XCTAssertFalse(sc.isEnabled(.manageBoosts))
    }

    /// 06 §12 / §17.3 Share button (B80): asks for the system share picker with the page's link and
    /// keeps the bubble open while it is up (also when the pointer leaves for the picker); the
    /// bubble closes when the picker finishes. A stale picker's answer is ignored.
    func testShareOpensSystemPicker() async throws {
        let id = try await selectExampleTab()
        let sc = model.siteControls
        var captured: [SiteControlsTool] = []
        sc.toolHandler = { tool, _ in captured.append(tool) }
        sc.present()
        sc.run(.share)
        let request = try XCTUnwrap(sc.shareRequest)
        XCTAssertEqual(request.tabID, id)
        XCTAssertEqual(request.url, URL(string: "https://example.com"))
        XCTAssertTrue(captured.isEmpty)
        XCTAssertTrue(sc.isPresented)
        sc.pointerExited()
        XCTAssertTrue(sc.isPresented)

        sc.finishShare(serial: request.serial - 1)
        XCTAssertNotNil(sc.shareRequest)
        sc.finishShare(serial: request.serial)
        XCTAssertNil(sc.shareRequest)
        XCTAssertFalse(sc.isPresented)
        XCTAssertEqual(sc.lastCloseReason, .action)

        // Closing the bubble drops a pending picker request; a new one gets a new serial.
        sc.present()
        sc.run(.share)
        let second = try XCTUnwrap(sc.shareRequest)
        XCTAssertGreaterThan(second.serial, request.serial)
        sc.close(.escape)
        XCTAssertNil(sc.shareRequest)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }
}

/// Plan C16: the Site Control Center's ad blocking row is backed by the engine's ad blocker
/// (`BrowserEngine.adBlocking`). inferred: the spec records no such row ([00 §A] "广告拦截":
/// settings toggle known, blocking UI not captured).
@MainActor
final class SiteControlsAdBlockingTests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private let site = SiteOrigin(scheme: "https", host: "example.com")

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        model.siteControls.pointerLeaveGrace = 0
        let id = try XCTUnwrap(model.workspace.tabs.values.first { $0.url?.host == "example.com" }?.id)
        try await model.activate(tabID: id)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
    }

    private func adBlockingRow() -> String? {
        model.siteControls.settingRows.first { $0.kind == .adBlocking }?.status
    }

    func testRowShowsAndTogglesTheSitesAllowListEntry() async throws {
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        XCTAssertEqual(adBlockingRow(), "On")
        sc.activate(.adBlocking)
        await sc.settle()
        XCTAssertEqual(adBlockingRow(), "Off")
        let profile = try XCTUnwrap(model.sidebar.currentProfileID)
        let siteOn = await engine.adBlocking.isEnabled(forOrigin: site, profileID: profile)
        XCTAssertFalse(siteOn)
        sc.activate(.adBlocking)
        await sc.settle()
        XCTAssertEqual(adBlockingRow(), "On")
        XCTAssertEqual(engine.fakeAdBlockingService.changes, ["site:example.com:off", "site:example.com:on"])
    }

    func testGlobalSwitchOffShowsOffAndTurningTheRowOnRestoresIt() async {
        await engine.adBlocking.setEnabled(false)
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        XCTAssertEqual(adBlockingRow(), "Off")
        sc.activate(.adBlocking)
        await sc.settle()
        XCTAssertEqual(adBlockingRow(), "On")
        let global = await engine.adBlocking.isEnabled()
        XCTAssertTrue(global)
    }

    func testNoRowWithoutARuleset() async {
        engine.fakeAdBlockingService.simulateRuleset(nil)
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        XCTAssertNil(adBlockingRow())
    }

    /// Settings ▸ Advanced: the global switch reads and writes the engine.
    func testSettingsSwitchDrivesTheEngine() async {
        let settings = SettingsModel(shell: model)
        await settings.loadAdBlocking()
        XCTAssertEqual(settings.adBlockingRulesetVersion, "fake-ruleset")
        XCTAssertTrue(settings.isAdBlockingOn)
        await settings.setAdBlocking(false)
        XCTAssertFalse(settings.isAdBlockingOn)
        let global = await engine.adBlocking.isEnabled()
        XCTAssertFalse(global)
        XCTAssertEqual(SettingsCatalog.control("advanced.adBlocking").kind, .toggle(defaultValue: true))
    }

    /// Plan C19: a filter-list update applied without a restart shows its version in Settings at
    /// once ([00 §已定的服务策略] observed: the project hosts the merged rules; display inferred).
    func testSettingsShowsALiveRulesetUpdate() async throws {
        let settings = SettingsModel(shell: model)
        let follow = Task { await settings.followAdBlockingRulesetVersion() }
        defer { follow.cancel() }
        try await waitFor { settings.adBlockingRulesetVersion == "fake-ruleset" }
        engine.fakeAdBlockingService.simulateRuleset("20261028-0123456789ab")
        try await waitFor { settings.adBlockingRulesetVersion == "20261028-0123456789ab" }
    }

    private func waitFor(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}
