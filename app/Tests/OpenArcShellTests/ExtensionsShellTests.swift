import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan C14 in the shell. Spec: [06 §12] observed the Site Control Center "Extensions" section ("+"
/// button, "Manage" when extensions exist); [06 §17.2] observed that the web toolbar has no extension
/// buttons; [01 §Extensions] observed "Add Extension…" and "Manage Extensions…"; [02] observed
/// "Open Extensions" ⌘E. Popup placement and the install confirmation are inferred.
@MainActor
final class ExtensionsShellTests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        model.siteControls.pointerLeaveGrace = 0
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var profileID: UUID { model.sidebar.currentProfileID! }

    private func openPage(_ address: String) async throws -> FakeTab {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: address)))
        let id = try XCTUnwrap(opened)
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            await model.siteControls.settle()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    /// [06 §12]: the "Extensions" section lists the engine's actions for the tab, with icon, badge
    /// and title, and "Manage" shows once an extension exists.
    func testSectionListsEngineActions() async throws {
        _ = try await openPage("https://site.example")
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        XCTAssertTrue(sc.settings.extensions.isEmpty)
        XCTAssertFalse(sc.showsManageExtensions)

        let icon = Data([0x89, 0x50, 0x4E, 0x47])
        engine.fakeExtensionService.simulateInstalled(
            EngineExtensionInfo(id: "blocker", name: "Blocker", iconPNGData: icon, badgeText: "12",
                                actionTitle: "Blocker: 12 blocked", hasPopup: true),
            profileID: profileID
        )
        try await waitUntil { sc.settings.extensions.count == 1 }
        let action = try XCTUnwrap(sc.settings.extensions.first)
        XCTAssertEqual(action.id, "blocker")
        XCTAssertEqual(action.iconPNGData, icon)
        XCTAssertEqual(action.badgeText, "12")
        XCTAssertEqual(action.title, "Blocker: 12 blocked")
        XCTAssertTrue(action.hasPopup)
        XCTAssertTrue(sc.showsManageExtensions)
    }

    /// An extension without an action on this page still shows "Manage" (inferred).
    func testManageShowsForInstalledExtensionWithoutAction() async throws {
        _ = try await openPage("https://site.example")
        engine.fakeExtensionService.simulateInstalled(EngineExtensionInfo(id: "x", name: "X", isEnabled: false), profileID: profileID)
        let sc = model.siteControls
        sc.present()
        await sc.settle()
        XCTAssertTrue(sc.settings.extensions.isEmpty)
        XCTAssertTrue(sc.showsManageExtensions)
    }

    /// Running an action with a popup closes the Site Control Center; the popup bubble shows once
    /// the page loaded and takes the page's size within Chromium's limits. Closing it, or the page
    /// closing itself, clears it. Popup placement inferred.
    func testRunActionOpensPopupWhenLoaded() async throws {
        let tab = try await openPage("https://site.example")
        engine.fakeExtensionService.simulateInstalled(EngineExtensionInfo(id: "pop", name: "Pop", hasPopup: true), profileID: profileID)
        let sc = model.siteControls
        sc.present()
        try await waitUntil { sc.settings.extensions.count == 1 }
        sc.runExtension("pop")
        XCTAssertFalse(sc.isPresented)
        XCTAssertEqual(sc.lastCloseReason, .action)
        try await waitUntil { sc.extensionPopup != nil }
        XCTAssertEqual(engine.fakeExtensionService.actionsRun, ["pop@\(tab.id)"])
        XCTAssertEqual(sc.extensionPopup?.isLoaded, false)
        let popup = try XCTUnwrap(engine.fakeExtensionService.popup)
        popup.simulateResize(width: 2000, height: 10)
        popup.simulateLoad()
        try await waitUntil { sc.extensionPopup?.isLoaded == true && sc.extensionPopup?.width == 800 }
        XCTAssertEqual(sc.extensionPopup?.height, 25)
        XCTAssertEqual(sc.extensionPopup?.tabID, model.selectedTabID)

        popup.simulateClose()
        try await waitUntil { sc.extensionPopup == nil }
    }

    /// Switching tabs closes the popup (inferred, as Chrome closes it).
    func testTabSwitchClosesPopup() async throws {
        _ = try await openPage("https://site.example")
        let first = try XCTUnwrap(model.selectedTabID)
        engine.fakeExtensionService.simulateInstalled(EngineExtensionInfo(id: "pop", name: "Pop", hasPopup: true), profileID: profileID)
        let sc = model.siteControls
        sc.present()
        try await waitUntil { sc.settings.extensions.count == 1 }
        sc.runExtension("pop")
        try await waitUntil { sc.extensionPopup != nil }
        let popup = try XCTUnwrap(engine.fakeExtensionService.popup)
        _ = try await openPage("https://other.example")
        XCTAssertNotEqual(model.selectedTabID, first)
        XCTAssertNil(sc.extensionPopup)
        try await waitUntil { popup.isClosed }
    }

    /// [01 §Extensions] Add Extension… opens the Chrome Web Store and Manage Extensions… the
    /// extensions page, each in a new tab (destinations inferred); "+" and "Manage" in the Site
    /// Control Center do the same.
    func testMenuItemsOpenStoreAndManager() async throws {
        _ = try await openPage("https://site.example")
        model.openAddExtension()
        XCTAssertEqual(model.sidebar.selectedURL, ExtensionPages.webStore)
        model.siteControls.manageExtensionsHandler?()
        XCTAssertEqual(model.sidebar.selectedURL, ExtensionPages.manage)
        model.siteControls.addExtensionHandler?()
        XCTAssertEqual(model.sidebar.selectedURL, ExtensionPages.webStore)
    }

    /// [02] ⌘E "Open Extensions" opens the Site Control Center, where the actions are (inferred).
    func testOpenExtensionsTogglesSiteControls() async throws {
        _ = try await openPage("https://site.example")
        model.openExtensions()
        XCTAssertTrue(model.siteControls.isPresented)
        model.openExtensions()
        XCTAssertFalse(model.siteControls.isPresented)
    }

    /// The install confirmation is a tab-modal sheet; its last button adds (inferred wording).
    func testInstallConfirmationSheet() async throws {
        let tab = try await openPage("https://chromewebstore.google.com/detail/x")
        let center = model.controller.dialogs
        let id = tab.simulateExtensionInstallPrompt(extensionID: "x", name: "uBlock Origin Lite",
                                                    permissionWarnings: ["Read and change all your data on all websites"])
        try await waitUntil { center.current(for: tab.id) != nil }
        let request = try XCTUnwrap(center.current(for: tab.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .sheet)
        XCTAssertEqual(presentation.title, "Add “uBlock Origin Lite”?")
        XCTAssertTrue(presentation.message.contains("Read and change all your data on all websites"))
        XCTAssertEqual(presentation.buttons, ["Cancel", "Add Extension"])
        center.answer(id, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false))
        XCTAssertEqual(tab.dialogAnswers[id], .extensionInstall(.add))
    }
}
