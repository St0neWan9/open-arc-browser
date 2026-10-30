import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan C7b, shell side: tabs opened and closed by pages, dialog requests, page commands.
/// Spec: [06 §13] observed new tabs at the top of Today; [06 §4] observed a Shift-click opening a
/// new window with the tab in Today; [01 §View] observed Force Refresh the Page and the three Zoom
/// items, [02] their keys. Placement next to the opener, popups as Today tabs, archiving on
/// `window.close()`, per-tab dialog queues and the permission bubble placement are inferred
/// (chromium-bridge/SWIFT_PROTOCOL_CHANGES.md §1–§4, WorkspaceController+PageRequests.swift).
@MainActor
final class PageRequestTests: XCTestCase {
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
        spaceID = try XCTUnwrap(model.selectedSpaceID)
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var controller: WorkspaceController { model.controller }
    private var todayIDs: [UUID] { model.workspace.today(spaceID: spaceID).map(\.id) }

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    /// Opens a tab and returns its id and engine tab.
    private func openPage(_ address: String) async throws -> (UUID, FakeTab) {
        let opened = try await model.openNewTab(url: try url(address))
        let id = try XCTUnwrap(opened)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        return (id, live)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: - Web notifications (plan C24)

    /// Plan C24, `docs/arc-spec/00-feature-inventory.md` §A inferred (analysis): web notifications
    /// reach Notification Center; clicking one brings its tab forward.
    func testNotificationClickSelectsItsTab() async throws {
        let (pageID, page) = try await openPage("https://chat.example")
        let (otherID, _) = try await openPage("https://other.example")
        XCTAssertEqual(model.selectedTabID, otherID)
        page.simulateNotificationClick()
        try await waitUntil { self.model.selectedTabID == pageID }
    }

    /// Plan C24: a click on a notification whose page is gone opens its site in a new tab of the
    /// current Space, selected (Chromium's own fallback; inferred).
    func testNotificationClickWithoutItsPageOpensTheSite() async throws {
        let before = todayIDs
        let origin = try url("https://chat.example")
        engine.simulateNotificationClickWithoutPage(origin: origin)
        try await waitUntil { self.todayIDs.count == before.count + 1 }
        let opened = try XCTUnwrap(todayIDs.first { !before.contains($0) })
        XCTAssertEqual(model.workspace.tabs[opened]?.url, origin)
        XCTAssertEqual(model.selectedTabID, opened)
    }

    // MARK: - Engine-created tabs (§1)

    func testWindowOpenAdoptsTheEngineTabBelowTheOpenerAndSelectsIt() async throws {
        let (opener, openerLive) = try await openPage("https://app.example")
        let token = try XCTUnwrap(engine.simulateWindowOpen(from: openerLive.id, url: try url("https://auth.example/login")))
        try await waitUntil { self.todayIDs.count == 4 && self.model.selectedTabID != opener }
        let child = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(Array(todayIDs.prefix(2)), [opener, child], "right below the opener (inferred)")
        try await waitUntil { self.model.sidebar.liveTab(for: child) != nil }
        let live = try XCTUnwrap(model.sidebar.liveTab(for: child) as? FakeTab)
        XCTAssertEqual(live.opener, openerLive.id, "adopted, so window.opener survives")
        XCTAssertFalse(engine.pendingTabTokens.contains(token))
        XCTAssertEqual(engine.tabIDs.count, 2, "no second engine tab for the child")
        XCTAssertEqual(model.workspace.tabs[child]?.url, try url("https://auth.example/login"))
    }

    func testLaterChildrenGoBelowThePreviousChild() async throws {
        let (opener, openerLive) = try await openPage("https://app.example")
        engine.simulateNewTabRequest(NewTabRequest(opener: openerLive.id, url: try url("https://one.example"), disposition: .backgroundTab, hasUserGesture: true))
        try await waitUntil { self.todayIDs.count == 4 }
        engine.simulateNewTabRequest(NewTabRequest(opener: openerLive.id, url: try url("https://two.example"), disposition: .backgroundTab, hasUserGesture: true))
        try await waitUntil { self.todayIDs.count == 5 }
        let urls = model.workspace.today(spaceID: spaceID).prefix(3).map(\.url)
        XCTAssertEqual(urls, [try url("https://app.example"), try url("https://one.example"), try url("https://two.example")])
        XCTAssertEqual(model.selectedTabID, opener, "background tabs are not selected")
    }

    /// A background tab is made live right away, with its opener (URL request, no pending tab).
    func testBackgroundRequestLoadsWithItsOpener() async throws {
        let (_, openerLive) = try await openPage("https://app.example")
        engine.simulateNewTabRequest(NewTabRequest(opener: openerLive.id, url: try url("https://bg.example"), disposition: .backgroundTab, hasUserGesture: true))
        try await waitUntil { self.engine.tabIDs.count == 2 }
        let child = try XCTUnwrap(todayIDs.dropFirst().first)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: child) as? FakeTab)
        XCTAssertEqual(live.opener, openerLive.id)
    }

    /// A pinned opener puts its child at the top of Today ([06 §13] observed for new tabs).
    func testChildOfAPinnedTabGoesToTheTopOfToday() async throws {
        let (pinned, live) = try await openPage("https://pinned.example")
        model.sidebar.pinTab(pinned)
        XCTAssertEqual(todayIDs.count, 2)
        engine.simulateWindowOpen(from: live.id, url: try url("https://popup.example"), disposition: .popup)
        try await waitUntil { self.todayIDs.count == 3 && self.model.selectedTabID != pinned }
        XCTAssertEqual(model.workspace.today(spaceID: spaceID).first?.url, try url("https://popup.example"))
        XCTAssertEqual(model.selectedTabID, todayIDs.first, "a popup opens like a foreground tab (inferred)")
    }

    func testNewWindowRequestOpensAWindowOnTheNewTab() async throws {
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }
        let (opener, openerLive) = try await openPage("https://app.example")
        engine.simulateNewTabRequest(NewTabRequest(opener: openerLive.id, url: try url("https://w.example"), disposition: .newWindow, hasUserGesture: true))
        try await waitUntil { requests.count == 1 }
        let child = try XCTUnwrap(requests.first?.tabID)
        XCTAssertEqual(requests.first?.kind, .newWindow)
        XCTAssertEqual(requests.first?.spaceID, spaceID)
        XCTAssertEqual(model.workspace.tabs[child]?.location, .today(spaceID: spaceID), "[06 §4] observed: the tab is in Today")
        XCTAssertEqual(model.selectedTabID, opener)
        let window = ShellModel.window(for: try XCTUnwrap(requests.first), on: controller)
        defer { window.stop() }
        XCTAssertEqual(window.selectedTabID, child)
    }

    func testRequestFromAnUnknownOpenerIsLeftAlone() async throws {
        let other = FakeEngine()
        let stranger = try await other.makeTab(TabConfiguration(profileID: UUID()))
        let before = todayIDs
        engine.simulateNewTabRequest(NewTabRequest(opener: stranger.id, url: try url("https://x.example"), disposition: .foregroundTab, hasUserGesture: true))
        await controller.settleEngineWork()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(todayIDs, before)
    }

    // MARK: - Page-initiated close (§2)

    func testWindowCloseArchivesTheTabAndSelectsTheOpener() async throws {
        let (opener, openerLive) = try await openPage("https://app.example")
        engine.simulateWindowOpen(from: openerLive.id, url: try url("https://auth.example"), disposition: .popup)
        try await waitUntil { self.model.selectedTabID != opener && self.model.selectedLiveTab != nil }
        let child = try XCTUnwrap(model.selectedTabID)
        let childLive = try XCTUnwrap(model.selectedLiveTab as? FakeTab)
        childLive.simulateWindowClose()
        try await waitUntil { self.model.workspace.tabs[child]?.meta.isTombstone == true }
        XCTAssertEqual(model.workspace.archive[child]?.reason, .closed, "⇧⌘T can bring it back (inferred)")
        XCTAssertEqual(model.selectedTabID, opener, "back to the page that opened it")
        try await waitUntil { !self.engine.tabIDs.contains(childLive.id) }
    }

    func testWindowCloseOnAnUnselectedTabArchivesIt() async throws {
        let (first, firstLive) = try await openPage("https://first.example")
        let (second, _) = try await openPage("https://second.example")
        XCTAssertEqual(model.selectedTabID, second)
        firstLive.simulateWindowClose()
        try await waitUntil { self.model.workspace.tabs[first]?.meta.isTombstone == true }
        XCTAssertEqual(model.selectedTabID, second)
    }

    func testWindowCloseOnAPinnedTabKeepsThePin() async throws {
        let (id, live) = try await openPage("https://pin.example")
        model.sidebar.pinTab(id)
        live.simulateWindowClose()
        try await waitUntil { self.model.sidebar.liveTab(for: id) == nil }
        XCTAssertEqual(model.workspace.tabs[id]?.meta.isTombstone, false)
        XCTAssertNotEqual(model.selectedTabID, id, "unloaded like the pinned row's button")
    }

    // MARK: - Dialogs (§3)

    func testEachDialogKindQueuesShowsAndReachesTheEngine() async throws {
        let (_, live) = try await openPage("https://dialogs.example")
        let center = controller.dialogs
        let alert = live.simulateJavaScriptDialog(.alert, message: "Hello")
        let confirm = live.simulateJavaScriptDialog(.confirm, message: "Sure?")
        let prompt = live.simulateJavaScriptDialog(.prompt, message: "Name?", defaultPromptText: "Ada")
        let auth = live.simulateAuthentication(realm: "Staff")
        let permission = live.simulatePermissionPrompt([.camera, .microphone])
        let chooser = live.simulateFileChooser(.open)
        let external = live.simulateExternalProtocol(try url("zoommtg://join"), handlerApplicationName: "Zoom")
        try await waitUntil { center.pendingCount(for: live.id) == 7 }

        // FIFO per tab; each head is shown with its presentation.
        var request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(request.id, alert)
        XCTAssertEqual(DialogPresentation(request).title, "dialogs.example says")
        XCTAssertEqual(DialogPresentation(request).buttons, ["OK"])
        center.answer(alert, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))

        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(request.id, confirm)
        XCTAssertEqual(DialogPresentation(request).buttons, ["Cancel", "OK"])
        center.answer(confirm, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))

        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).fields, [.text(placeholder: "", initial: "Ada")])
        center.answer(prompt, with: DialogPresentation.answer(for: request, button: 1, fieldValues: ["Grace"], checkbox: false))

        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).style, .sheet)
        XCTAssertEqual(DialogPresentation(request).fields.count, 2)
        center.answer(auth, with: DialogPresentation.answer(for: request, button: 1, fieldValues: ["u", "p"], checkbox: false))

        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).style, .permissionBubble)
        XCTAssertEqual(DialogPresentation(request).message, "Use your camera\nUse your microphone")
        center.answer(permission, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false))

        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).style, .filePanel)
        let file = try url("file:///tmp/a.txt")
        center.answer(chooser, with: .fileChooser(.select([file])))

        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).title, "Open “Zoom”?")
        center.answer(external, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: true))

        XCTAssertNil(center.current(for: live.id))
        XCTAssertEqual(live.dialogAnswers[alert], .javaScript(JavaScriptDialogReply(accepted: true)))
        XCTAssertEqual(live.dialogAnswers[confirm], .javaScript(JavaScriptDialogReply(accepted: false)))
        XCTAssertEqual(live.dialogAnswers[prompt], .javaScript(JavaScriptDialogReply(accepted: true, promptText: "Grace")))
        XCTAssertEqual(live.dialogAnswers[auth], .authentication(.proceed(username: "u", password: "p")))
        XCTAssertEqual(live.dialogAnswers[permission], .permission(.allow(remember: false)))
        XCTAssertEqual(live.dialogAnswers[chooser], .fileChooser(.select([file])))
        XCTAssertEqual(live.dialogAnswers[external], .externalProtocol(.open(rememberForOrigin: true)))
    }

    func testDismissingAndWrongAnswersUseTheDefault() async throws {
        let (_, live) = try await openPage("https://dialogs.example")
        let center = controller.dialogs
        let id = live.simulatePermissionPrompt([.location])
        try await waitUntil { center.current(for: live.id) != nil }
        XCTAssertFalse(center.answer(id, with: .fileChooser(.cancel)), "wrong kind is ignored")
        XCTAssertNotNil(center.current(for: live.id))
        center.dismiss(id)
        XCTAssertNil(center.current(for: live.id))
        XCTAssertEqual(live.dialogAnswers[id], .permission(.dismiss))
    }

    /// The bridge's rule: a request the page loses (tab archived) gets its default answer.
    func testArchivingTheTabAnswersQueuedDialogsWithDefaults() async throws {
        let (id, live) = try await openPage("https://dialogs.example")
        let center = controller.dialogs
        let confirm = live.simulateJavaScriptDialog(.confirm, message: "?")
        let auth = live.simulateAuthentication(realm: "r")
        try await waitUntil { center.pendingCount(for: live.id) == 2 }
        model.sidebar.closeTab(id)
        XCTAssertNil(center.current(for: live.id))
        XCTAssertEqual(live.dialogAnswers[confirm], .javaScript(.dismissed))
        XCTAssertEqual(live.dialogAnswers[auth], .authentication(.cancel))
    }

    func testEngineWithdrawalRemovesTheDialog() async throws {
        let (_, live) = try await openPage("https://dialogs.example")
        let center = controller.dialogs
        let id = live.simulateJavaScriptDialog(.alert, message: "Hi")
        try await waitUntil { center.current(for: live.id) != nil }
        live.simulateDialogCancel(id)
        try await waitUntil { center.current(for: live.id) == nil }
        XCTAssertNil(live.dialogAnswers[id])
    }

    func testDialogsArePerTab() async throws {
        let (_, first) = try await openPage("https://first.example")
        let (_, second) = try await openPage("https://second.example")
        let center = controller.dialogs
        first.simulateJavaScriptDialog(.alert, message: "1")
        try await waitUntil { center.current(for: first.id) != nil }
        XCTAssertNil(center.current(for: second.id))
    }

    /// The beforeunload confirm comes through the same queue; Leave closes the page.
    func testBeforeUnloadConfirmThenCloseArchives() async throws {
        let (id, live) = try await openPage("https://form.example")
        live.simulateBeforeUnloadHandler()
        await live.requestClose()
        let center = controller.dialogs
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).buttons, ["Cancel", "Leave"])
        center.answer(request.id, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false))
        try await waitUntil { self.model.workspace.tabs[id]?.meta.isTombstone == true }
    }

    /// The selected tab's permission prompt goes under the URL box while the sidebar shows;
    /// otherwise it stays in the panel. inferred.
    func testPermissionBubblePlacement() {
        let tab = UUID(), other = UUID()
        XCTAssertTrue(PermissionPromptPlacement.isUnderURLBox(tabID: tab, selectedTabID: tab, isSidebarVisible: true))
        XCTAssertFalse(PermissionPromptPlacement.isUnderURLBox(tabID: tab, selectedTabID: tab, isSidebarVisible: false))
        XCTAssertFalse(PermissionPromptPlacement.isUnderURLBox(tabID: other, selectedTabID: tab, isSidebarVisible: true))
        let layout = MainWindowLayout(windowSize: CGSize(width: 1280, height: 800))
        let origin = PermissionPromptPlacement.originUnderURLBox(in: layout)
        XCTAssertEqual(origin.x, layout.addressFieldFrame.minX)
        XCTAssertEqual(origin.y, layout.addressFieldFrame.maxY + PermissionPromptPlacement.gap)
    }

    // MARK: - Page commands (§4, View menu)

    /// [01 §View] observed Zoom In / Zoom Out / Zoom to Actual Size; [02] ⌘+ / ⌘- / ⌘0.
    func testZoomMenuItemsCallTheSelectedTab() async throws {
        let (_, live) = try await openPage("https://zoom.example")
        XCTAssertFalse(model.canResetZoom)
        model.zoomIn()
        try await waitUntil { self.model.selectedPageState?.zoomFactor == 1.1 }
        XCTAssertTrue(model.canResetZoom)
        model.zoomOut()
        model.zoomOut()
        try await waitUntil { self.model.selectedPageState?.zoomFactor == 0.9 }
        model.resetZoom()
        try await waitUntil { self.model.selectedPageState?.zoomFactor == 1 }
        XCTAssertEqual(live.commands, [.zoomIn, .zoomOut, .zoomOut, .resetZoom])
    }

    /// [01 §View] observed Force Refresh the Page; [02] ⇧⌘R.
    func testForceRefreshBypassesTheCache() async throws {
        let (_, live) = try await openPage("https://reload.example")
        model.forceReload()
        await controller.settleEngineWork()
        // ⌘R is Stop while the page loads [06 §13]; wait until the forced reload finished.
        try await waitUntil { self.model.selectedPageState?.isLoading == false }
        model.sidebar.reloadOrStop()
        await controller.settleEngineWork()
        XCTAssertEqual(live.commands, [.reload(bypassingCache: true), .reload(bypassingCache: false)])
    }

    /// [02 §页面与导航] ⌘R, [01 §View] observed items (F5-5): Refresh the Page reloads also while
    /// the page loads; Stop Loading (⌘.) and the toolbar button stop. The menu items, the ⌘R
    /// command and the toolbar button are checked on the same page.
    func testRefreshAlwaysReloadsAndStopStays() async throws {
        let (id, live) = try await openPage("https://loading.example")
        live.simulateLoadState(LoadState(isLoading: true, progress: 0.3))
        try await waitUntil { self.model.sidebar.reloadMode == .stop }
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let menu = NSHostingMenu(rootView: ViewMenuItems(model: model, hasWindow: true))
        menu.update()
        let refresh = try XCTUnwrap(menu.items.first { $0.title == "Refresh the Page" })
        XCTAssertEqual(refresh.keyEquivalent, "r")
        _ = (try XCTUnwrap(refresh.target) as AnyObject).perform(try XCTUnwrap(refresh.action), with: refresh)
        await controller.settleEngineWork()
        XCTAssertEqual(live.commands, [.reload(bypassingCache: false)], "a reload, not a stop, during the load")
        // The command bar's Refresh the Page row does the same.
        live.simulateLoadState(LoadState(isLoading: true, progress: 0.3))
        try await waitUntil { self.model.sidebar.reloadMode == .stop }
        model.run(.reload)
        await controller.settleEngineWork()
        XCTAssertEqual(live.commands, [.reload(bypassingCache: false), .reload(bypassingCache: false)])
        // The toolbar's button still stops while loading.
        live.simulateLoadState(LoadState(isLoading: true, progress: 0.3))
        try await waitUntil { self.model.sidebar.reloadMode == .stop }
        model.webToolbarReload(id)
        await controller.settleEngineWork()
        XCTAssertEqual(live.commands.count, 2, "the toolbar button stopped instead of reloading")
        let stop = try XCTUnwrap(menu.items.first { $0.title == "Stop Loading" })
        XCTAssertEqual(stop.keyEquivalent, ".")
    }

    func testExtraTabStateReachesTheLiveState() async throws {
        let (id, live) = try await openPage("https://state.example")
        live.simulateThemeColor(RGBAColor(hex: 0x112233))
        live.simulateFullscreen(true)
        try await waitUntil { self.model.sidebar.liveState(for: id)?.isFullscreen == true }
        let state = try XCTUnwrap(model.sidebar.liveState(for: id))
        XCTAssertEqual(state.themeColor, RGBAColor(hex: 0x112233))
        XCTAssertEqual(state.committedURL, try url("https://state.example"))
        XCTAssertEqual(state.security, .secure)
    }
}
