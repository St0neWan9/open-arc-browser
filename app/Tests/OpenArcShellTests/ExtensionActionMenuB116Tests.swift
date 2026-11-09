import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B116: an extension action's right-click menu in the Site Control Center's "Extensions"
/// section. [06 §12] observed the section (its buttons, "+", "Manage"); the spec records no
/// right-click menu on an action, so the items (Manage Extension, Remove…) and the confirmation
/// before Remove are inferred, taken from what Chrome's toolbar action offers without a window.
@MainActor
final class ExtensionActionMenuB116Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!
    private var removalQuestions: [String] = []
    private var removalAnswer = true

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
        model.siteControls.pointerLeaveGrace = 0
        removalQuestions = []
        removalAnswer = true
        // The app asks with an app-modal alert; the test answers instead.
        model.siteControls.confirmExtensionRemoval = { [unowned self] name in
            self.removalQuestions.append(name)
            return self.removalAnswer
        }
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var profileID: UUID { model.sidebar.currentProfileID! }

    @discardableResult
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

    /// Opens a page, installs one extension with a popup and opens the Site Control Center.
    private func presentWithExtension(_ id: String = "pop", name: String = "Pop") async throws -> SiteControlsModel {
        try await openPage("https://site.example")
        engine.fakeExtensionService.simulateInstalled(EngineExtensionInfo(id: id, name: name, hasPopup: true), profileID: profileID)
        let sc = model.siteControls
        sc.present()
        try await waitUntil { sc.settings.extensions.count == 1 }
        return sc
    }

    /// B116 (`06 §12` section observed; menu inferred): an action's menu has Manage Extension and
    /// Remove, titled with the extension's name; an extension not in the section has no menu.
    func testActionMenuItems() async throws {
        let sc = try await presentWithExtension(name: "Pop Blocker")
        XCTAssertEqual(sc.extensionMenuItems(for: "pop"), [.manage, .remove])
        XCTAssertEqual(SiteExtensionMenuItem.manage.title(extensionName: "Pop Blocker"), "Manage Extension")
        XCTAssertEqual(SiteExtensionMenuItem.remove.title(extensionName: "Pop Blocker"), "Remove “Pop Blocker”…")
        XCTAssertTrue(sc.isEnabled(.manage, extensionID: "pop"))
        XCTAssertTrue(sc.isEnabled(.remove, extensionID: "pop"))
        XCTAssertEqual(sc.extensionMenuItems(for: "missing"), [])
    }

    /// B116: Manage Extension closes the bubble and opens that extension's details page in a new
    /// tab (inferred destination, like "Manage Extensions…").
    func testManageOpensDetailsPage() async throws {
        let sc = try await presentWithExtension()
        sc.perform(.manage, extensionID: "pop")
        XCTAssertFalse(sc.isPresented)
        XCTAssertEqual(sc.lastCloseReason, .action)
        XCTAssertEqual(model.sidebar.selectedURL, URL(string: "chrome://extensions/?id=pop"))
    }

    /// B116: Remove asks first; Cancel keeps the extension. The bubble closes before the question,
    /// which is a card in the window (`06 §31` observed, B197).
    func testRemoveCancelledKeepsExtension() async throws {
        let sc = try await presentWithExtension(name: "Pop Blocker")
        removalAnswer = false
        sc.perform(.remove, extensionID: "pop")
        await sc.settle()
        XCTAssertEqual(removalQuestions, ["Pop Blocker"])
        XCTAssertFalse(sc.isPresented)
        let installed = await engine.fakeExtensionService.installed(profileID: profileID)
        XCTAssertEqual(installed.map(\.id), ["pop"])
    }

    /// B197 (`06 §31` observed): the app's question is the window's removal card. Remove waits
    /// for its answer: "Remove Extension" uninstalls, a newer question or closing the window
    /// answers "keep".
    func testRemovalCardQuestion() async throws {
        let sc = try await presentWithExtension(name: "Pop Blocker")
        sc.confirmExtensionRemoval = { [weak sc] name in await sc?.askToRemoveExtension(name) ?? false }
        sc.perform(.remove, extensionID: "pop")
        try await waitForQuestion(sc) { $0 != nil }
        XCTAssertEqual(sc.extensionRemovalQuestion?.extensionName, "Pop Blocker")
        XCTAssertEqual(ExtensionRemovalCard.title(extensionName: "Pop Blocker"), "Remove “Pop Blocker” extension from Open Arc?")
        XCTAssertEqual(ExtensionRemovalCard.removeButton, "Remove Extension")
        XCTAssertFalse(sc.isPresented, "the bubble closed first")
        var installed = await engine.fakeExtensionService.installed(profileID: profileID)
        XCTAssertEqual(installed.map(\.id), ["pop"], "nothing removed before the answer")

        // A second question answers the first with "keep".
        var first: Bool?
        let pending = Task { first = await sc.askToRemoveExtension("A") }
        try await waitForQuestion(sc) { $0?.extensionName == "A" }
        sc.answerExtensionRemoval(false)
        await pending.value
        XCTAssertEqual(first, false)

        sc.perform(.remove, extensionID: "pop")
        try await waitForQuestion(sc) { $0 != nil }
        sc.answerExtensionRemoval(true)
        await sc.settle()
        installed = await engine.fakeExtensionService.installed(profileID: profileID)
        XCTAssertEqual(installed.map(\.id), [])
        XCTAssertNil(sc.extensionRemovalQuestion)
    }

    /// Polls the removal question without `settle()`, whose wait includes the removal task that
    /// is waiting for this very answer.
    private func waitForQuestion(_ sc: SiteControlsModel, _ condition: (ExtensionRemovalQuestion?) -> Bool,
                                 file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition(sc.extensionRemovalQuestion) { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("question not shown", file: file, line: line)
    }

    /// B116: Remove, confirmed, closes the bubble and the extension's open popup, and uninstalls
    /// it from the profile; the section is empty when the bubble opens again.
    func testRemoveConfirmedUninstalls() async throws {
        let sc = try await presentWithExtension()
        sc.runExtension("pop")
        try await waitUntil { sc.extensionPopup != nil }
        let popup = try XCTUnwrap(engine.fakeExtensionService.popup)
        sc.present()
        try await waitUntil { sc.settings.extensions.count == 1 }

        sc.perform(.remove, extensionID: "pop")
        await sc.settle()
        XCTAssertEqual(removalQuestions, ["Pop"])
        XCTAssertFalse(sc.isPresented)
        XCTAssertNil(sc.extensionPopup)
        try await waitUntil { popup.isClosed }
        let installed = await engine.fakeExtensionService.installed(profileID: profileID)
        XCTAssertTrue(installed.isEmpty)

        sc.present()
        await sc.settle()
        XCTAssertTrue(sc.settings.extensions.isEmpty)
        XCTAssertFalse(sc.showsManageExtensions)
    }

    /// B116: without a confirmation handler (incognito windows) Remove is disabled and does nothing.
    func testRemoveDisabledWithoutConfirmation() async throws {
        let sc = try await presentWithExtension()
        sc.confirmExtensionRemoval = nil
        XCTAssertFalse(sc.isEnabled(.remove, extensionID: "pop"))
        sc.perform(.remove, extensionID: "pop")
        await sc.settle()
        XCTAssertTrue(sc.isPresented)
        let installed = await engine.fakeExtensionService.installed(profileID: profileID)
        XCTAssertEqual(installed.map(\.id), ["pop"])
    }
}
