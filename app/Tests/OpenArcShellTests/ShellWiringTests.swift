import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcDesign
@testable import OpenArcShell

/// The main window wires the sidebar and the command bar through `ShellModel`.
@MainActor
final class ShellWiringTests: XCTestCase {
    private func makeModel() -> ShellModel {
        // A fixed clock equal to the demo's creation time keeps launch auto-archive from expiring it.
        ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)), now: { Date(timeIntervalSince1970: 0) })
    }

    /// The sidebar view model is the single owner of the workspace; the shell forwards it.
    func testShellForwardsSidebarState() throws {
        let model = makeModel()
        XCTAssertEqual(model.workspace, model.sidebar.workspace)
        XCTAssertEqual(model.selectedSpaceID, model.sidebar.selectedSpaceID)
        let id = try XCTUnwrap(model.sidebar.newTab(url: URL(string: "https://a.example")))
        XCTAssertEqual(model.selectedTabID, id)
        XCTAssertNotNil(model.workspace.tabs[id])
    }

    /// "+ New Tab" row and the URL box open the command bar. [05 §command bar] observed.
    func testSidebarRequestsOpenTheCommandBar() {
        let model = makeModel()
        model.sidebar.newTabRowClicked()
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBar.mode, .newTab)
        model.dismissCommandBar()
        XCTAssertFalse(model.isCommandBarPresented)
        model.sidebar.openCommandBar(.currentTab)
        XCTAssertEqual(model.commandBar.mode, .currentTab)
    }

    /// ⌘L prefills the current address. [02] observed.
    func testCurrentTabModePrefillsSelectedURL() async throws {
        let model = makeModel()
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let tabID = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: tabID)
        model.presentCommandBar(.currentTab)
        XCTAssertEqual(model.commandBar.queryText, model.workspace.tabs[tabID]?.url?.absoluteString)
        XCTAssertTrue(model.commandBar.isPrefillUnedited)
    }

    /// ⌘T + URL opens a new tab at the top of Today and closes the bar. [02, 06 §13] observed.
    func testOpenURLInNewTab() throws {
        let model = makeModel()
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        model.presentCommandBar(.newTab)
        model.perform(.openURL(URL(string: "https://new.example")!, target: .newTab))
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(model.workspace.today(spaceID: spaceID).first?.url, URL(string: "https://new.example"))
    }

    /// ⌘L + URL navigates the selected tab instead of opening a new one. [02] observed.
    func testOpenURLInCurrentTabNavigates() async throws {
        let model = makeModel()
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let tabID = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        try await model.activate(tabID: tabID)
        let count = model.workspace.today(spaceID: spaceID).count
        model.perform(.openURL(URL(string: "https://moved.example")!, target: .currentTab))
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.workspace.today(spaceID: spaceID).count, count)
        let state = await model.selectedLiveTab?.currentState()
        XCTAssertEqual(state?.url, URL(string: "https://moved.example"))
    }

    /// Searches go to the default search engine (Google). [03 §Profile] observed.
    func testSearchBuildsGoogleURL() {
        let model = makeModel()
        XCTAssertEqual(model.searchURL(for: "arc browser")?.absoluteString, "https://www.google.com/search?q=arc%20browser")
    }

    func testSwitchToTabSelectsIt() throws {
        let model = makeModel()
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let tabID = try XCTUnwrap(model.workspace.today(spaceID: spaceID).last?.id)
        model.perform(.switchToTab(tabID: tabID))
        XCTAssertEqual(model.selectedTabID, tabID)
    }

    func testCommandsRouteToSidebarOrShell() {
        let model = makeModel()
        model.perform(.runCommand(.toggleSidebar))
        XCTAssertFalse(model.isSidebarVisible)
        model.perform(.runCommand(.newFolder))
        XCTAssertTrue(model.sidebar.isNewFolderSheetPresented)
        model.perform(.runCommand(.openSettings))
        XCTAssertEqual(model.lastUnhandledCommand, .openSettings)
    }

    /// The command bar sources read the live workspace at query time.
    func testCommandBarFindsTabsOpenedAfterLaunch() async throws {
        let model = makeModel()
        model.sidebar.newTab(url: URL(string: "https://zebra-unique.example"), title: "Zebra unique")
        model.presentCommandBar(.newTab)
        model.commandBar.queryText = "Zebra unique"
        await model.commandBar.waitForRefresh()
        XCTAssertTrue(model.commandBar.results.contains { $0.title == "Zebra unique" })
    }

    /// The full window with the command bar open lays out at the reference size.
    func testWindowWithCommandBarLaysOut() {
        let model = makeModel()
        model.presentCommandBar(.newTab)
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1920, height: 985)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(model.isCommandBarPresented)
    }
}

/// Keyboard navigation intents behind the Tabs menu. [02 §tabs] observed keys.
@MainActor
final class SidebarKeyboardTests: XCTestCase {
    func testGoToSidebarItemAndLast() {
        let f = SidebarFixture()
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: f.ws, selectedSpaceID: f.home, now: { f.now })
        let order = vm.keyboardTabOrder
        XCTAssertEqual(order.first, f.fav1)
        vm.goToSidebarItem(number: 1)
        XCTAssertEqual(vm.selectedTabID, order[0])
        vm.goToSidebarItem(number: 9)
        XCTAssertEqual(vm.selectedTabID, order.last)
        vm.goToSidebarItem(number: order.count + 1 < 9 ? order.count + 1 : 8)
        XCTAssertNotNil(vm.selectedTabID)
        vm.stop()
    }

    func testStepTabWraps() {
        let f = SidebarFixture()
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: f.ws, selectedSpaceID: f.home, now: { f.now })
        let order = vm.keyboardTabOrder
        vm.stepTab(by: 1)
        XCTAssertEqual(vm.selectedTabID, order.first)
        vm.stepTab(by: -1)
        XCTAssertEqual(vm.selectedTabID, order.last)
        vm.stepTab(by: 1)
        XCTAssertEqual(vm.selectedTabID, order.first)
        vm.stop()
    }
}

/// Audio and pinned-URL intents. [05 §context menus] observed menu items.
@MainActor
final class SidebarAudioAndPinTests: XCTestCase {
    func testAudioStateFlowsFromEngineAndMuteToggles() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let vm = SidebarViewModel(engine: engine, workspace: f.ws, selectedSpaceID: f.home, now: { f.now })
        vm.selectTab(f.today1)
        await vm.settleEngineWork()
        let live = try XCTUnwrap(vm.liveTab(for: f.today1) as? FakeTab)
        live.simulateAudio(true)
        try await waitUntil { vm.liveState(for: f.today1)?.isAudible == true }
        vm.toggleMute(f.today1)
        await vm.settleEngineWork()
        try await waitUntil { vm.liveState(for: f.today1)?.isMuted == true }
        let state = await live.currentState()
        XCTAssertTrue(state.audio.isMuted)
        vm.stop()
    }

    func testResetToPinnedURLLoadsIt() async throws {
        let f = SidebarFixture()
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: f.ws, selectedSpaceID: f.home, now: { f.now })
        vm.selectTab(f.pinnedTab)
        await vm.settleEngineWork()
        vm.navigateSelectedTab(to: URL(string: "https://elsewhere.example")!)
        await vm.settleEngineWork()
        try await waitUntil { vm.workspace.tabs[f.pinnedTab]?.url == URL(string: "https://elsewhere.example") }
        vm.resetTabToPinnedURL(f.pinnedTab)
        await vm.settleEngineWork()
        let pinned = vm.workspace.tabs[f.pinnedTab]?.pinnedURL
        XCTAssertNotNil(pinned)
        // Engine events from the earlier navigation arrive asynchronously; the model settles on the pinned URL.
        try await waitUntil { vm.workspace.tabs[f.pinnedTab]?.url == pinned }
        let state = await vm.liveTab(for: f.pinnedTab)?.currentState()
        XCTAssertEqual(state?.url, pinned)
        vm.stop()
    }

    func testCreateProfile() {
        let f = SidebarFixture()
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: f.ws, selectedSpaceID: f.home, now: { f.now })
        let id = vm.createProfile(name: "Work")
        XCTAssertEqual(vm.workspace.profiles[id]?.name, "Work")
    }

    /// Polls the main actor briefly; event delivery from the engine stream is asynchronous.
    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }
}
