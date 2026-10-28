import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan C26, `docs/arc-spec/00-feature-inventory.md` §A inferred (analysis): extension keyboard
/// commands work, and extension runtime errors are surfaced.
final class ExtensionCommandsC26Tests: XCTestCase {
    private let profile = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

    private func makeTab(_ engine: FakeEngine) async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://page.example")))
        return try XCTUnwrap(tab as? FakeTab)
    }

    /// The first `count` elements (the streams here stay open; the elements must come).
    private func take<T: Sendable>(_ count: Int, from stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        for await value in stream {
            result.append(value)
            if result.count == count { break }
        }
        return result
    }

    /// A named command's shortcut goes to its extension with the tab that had the keyboard; other
    /// keys and disabled extensions are left alone.
    func testNamedCommandReachesItsExtension() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let fakes = engine.fakeExtensionService
        fakes.simulateInstalled(EngineExtensionInfo(id: "cmd", name: "Commands"), profileID: profile)
        fakes.simulateCommands(["c26-run": "⇧⌘Y"], extensionID: "cmd")
        let handled = await fakes.simulateShortcut("⇧⌘Y", tabID: tab.id)
        XCTAssertTrue(handled)
        XCTAssertEqual(fakes.commandsSent, ["cmd:c26-run@\(tab.id)"])
        let other = await fakes.simulateShortcut("⇧⌘U", tabID: tab.id)
        XCTAssertFalse(other, "a key no command has goes to the page")
        await fakes.setEnabled(false, extensionID: "cmd", profileID: profile)
        let disabled = await fakes.simulateShortcut("⇧⌘Y", tabID: tab.id)
        XCTAssertFalse(disabled)
        XCTAssertEqual(fakes.commandsSent.count, 1)
    }

    /// `_execute_action` runs the action on the tab; a popup it opens comes out for the shell.
    func testExecuteActionOpensThePopupForTheShell() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let fakes = engine.fakeExtensionService
        fakes.simulateInstalled(EngineExtensionInfo(id: "pop", name: "Pop", hasPopup: true), profileID: profile)
        fakes.simulateCommands(["_execute_action": "⌥⇧P"], extensionID: "pop")
        let popups = engine.extensions.popupsOpenedFromKeyboard()
        let handled = await fakes.simulateShortcut("⌥⇧P", tabID: tab.id)
        XCTAssertTrue(handled)
        XCTAssertEqual(fakes.actionsRun, ["pop@\(tab.id)"])
        let opened = await take(1, from: popups)
        XCTAssertEqual(opened.first?.popup.extensionID, "pop")
        XCTAssertEqual(opened.first?.popup.tabID, tab.id)
    }

    /// An extension's error count is part of its info and its changes are events.
    func testErrorCountIsReported() async throws {
        let engine = FakeEngine()
        let fakes = engine.fakeExtensionService
        fakes.simulateInstalled(EngineExtensionInfo(id: "bad", name: "Bad", isUnpacked: true), profileID: profile)
        let events = engine.extensions.events(profileID: profile)
        fakes.simulateErrors(count: 2, extensionID: "bad", profileID: profile)
        let received = await take(1, from: events)
        XCTAssertEqual(received, [.errorsChanged(extensionID: "bad")])
        let installed = await engine.extensions.installed(profileID: profile)
        XCTAssertEqual(installed.first?.errorCount, 2)
    }
}
