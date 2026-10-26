import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan C14: the engine's extensions (`EngineExtensions`): unpacked loading, popups and the install
/// confirmation request. Spec: [06 §12] observed the Site Control Center "Extensions" section;
/// popups and the install flow are not recorded (inferred, Chromium's behavior).
final class ExtensionsC14Tests: XCTestCase {
    private let profile = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    private func makeTab(_ engine: FakeEngine) async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://page.example")))
        return try XCTUnwrap(tab as? FakeTab)
    }

    /// Loading an unpacked folder lists the extension as unpacked (developer mode).
    func testLoadUnpackedListsTheExtension() async throws {
        let engine = FakeEngine()
        let id = try await engine.extensions.loadUnpacked(URL(fileURLWithPath: "/tmp/c14-test-ext"), profileID: profile)
        let installed = await engine.extensions.installed(profileID: profile)
        XCTAssertEqual(installed.map(\.id), [id])
        XCTAssertEqual(installed.first?.isUnpacked, true)
    }

    /// An action with a popup returns it; its events replay what happened (load, last size) and
    /// end with `.closed`. Running another action closes the open popup (one at a time).
    func testPopupEventsAndOnePopupAtATime() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let fakes = engine.fakeExtensionService
        fakes.simulateInstalled(EngineExtensionInfo(id: "pop", name: "Pop", hasPopup: true), profileID: profile)
        fakes.simulateInstalled(EngineExtensionInfo(id: "two", name: "Two", hasPopup: true), profileID: profile)
        let opened = await engine.extensions.runAction("pop", on: tab.id)
        let first = try XCTUnwrap(opened as? FakeExtensionPopup)
        XCTAssertEqual(first.extensionID, "pop")
        XCTAssertEqual(first.tabID, tab.id)
        first.simulateLoad()
        first.simulateResize(width: 100, height: 50)
        first.simulateResize(width: 300, height: 200)
        let replay = await take(2, from: first.events())
        XCTAssertEqual(replay, [.loaded, .resized(width: 300, height: 200)])

        let stream = first.events()
        let second = await engine.extensions.runAction("two", on: tab.id)
        XCTAssertNotNil(second)
        XCTAssertTrue(first.isClosed)
        let all = await collect(stream)
        XCTAssertEqual(all.last, .closed)
        XCTAssertTrue(engine.fakeExtensionService.popup === second)
    }

    /// The install confirmation is a single-shot request whose default is Cancel.
    func testInstallPromptReply() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let added = tab.simulateExtensionInstallPrompt(extensionID: "ublite", name: "uBlock Origin Lite",
                                                       permissionWarnings: ["Read and change all your data on all websites"])
        let cancelled = tab.simulateExtensionInstallPrompt(extensionID: "other", name: "Other")
        let requests = await take(2, from: stream)
        guard case .extensionInstall(let first) = requests[0], case .extensionInstall(let second) = requests[1] else {
            return XCTFail("expected install prompts")
        }
        XCTAssertEqual(first.extensionName, "uBlock Origin Lite")
        XCTAssertEqual(first.permissionWarnings.count, 1)
        XCTAssertTrue(first.reply.send(.add))
        XCTAssertFalse(first.reply.send(.cancel), "single-shot")
        XCTAssertTrue(second.reply.sendDefault())
        XCTAssertEqual(tab.dialogAnswers[added], .extensionInstall(.add))
        XCTAssertEqual(tab.dialogAnswers[cancelled], .extensionInstall(.cancel))
    }

    // MARK: Helpers

    private func take<T: Sendable>(_ count: Int, from stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        for await value in stream {
            result.append(value)
            if result.count == count { break }
        }
        return result
    }

    /// Every element of a stream that finishes.
    private func collect<T: Sendable>(_ stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        for await value in stream { result.append(value) }
        return result
    }
}
