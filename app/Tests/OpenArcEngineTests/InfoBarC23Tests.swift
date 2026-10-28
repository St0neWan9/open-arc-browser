import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan C23, `docs/arc-spec/00-feature-inventory.md` §A inferred (analysis): engine info bars
/// (confirmation strips above the page) are requests the shell draws; look unknown.
final class InfoBarC23Tests: XCTestCase {
    private let profile = UUID()

    private func makeTab(_ engine: FakeEngine) async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://bar.example")))
        return try XCTUnwrap(tab as? FakeTab)
    }

    /// The first `count` elements (the streams here stay open; the elements must come).
    private func take<T: Sendable>(_ count: Int, from stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        for await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    /// The request carries the engine's texts and buttons; the close button dismisses it.
    func testInfoBarCarriesItsTextsAndClosing() async throws {
        let tab = try await makeTab(FakeEngine())
        let stream = tab.dialogRequests()
        let id = tab.simulateInfoBar(message: "Test Extension started debugging this browser", buttons: [.ok], okTitle: "Cancel")
        guard case .infoBar(let bar) = await take(1, from: stream).first else { return XCTFail("expected an info bar") }
        XCTAssertEqual(bar.id, id)
        XCTAssertEqual(bar.message, "Test Extension started debugging this browser")
        XCTAssertEqual(bar.buttons, [.ok])
        XCTAssertEqual(bar.okTitle, "Cancel")
        XCTAssertTrue(bar.isCloseable)
        XCTAssertTrue(bar.reply.send(.close))
        XCTAssertEqual(tab.dialogAnswers[id], .infoBar(.close))
        XCTAssertTrue(tab.outstandingDialogIDs.isEmpty)
    }

    /// Dropped unanswered, a bar stays open in the engine (the default does nothing).
    func testDefaultLeavesTheBarOpen() async throws {
        let tab = try await makeTab(FakeEngine())
        let stream = tab.dialogRequests()
        let id = tab.simulateInfoBar(message: "Reload to apply")
        guard case .infoBar(let bar) = await take(1, from: stream).first else { return XCTFail("expected an info bar") }
        XCTAssertTrue(bar.reply.sendDefault())
        XCTAssertEqual(tab.dialogAnswers[id], .infoBar(.leaveOpen))
    }

    /// The link asks for a new foreground tab and keeps the bar (a new request follows).
    func testLinkOpensATabAndKeepsTheBar() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = engine.events()
        let stream = tab.dialogRequests()
        let link = try XCTUnwrap(URL(string: "https://help.example/bars"))
        tab.simulateInfoBar(message: "Something happened", linkTitle: "Learn more", linkURL: link)
        guard case .infoBar(let bar) = await take(1, from: stream).first else { return XCTFail("expected an info bar") }
        XCTAssertEqual(bar.linkTitle, "Learn more")
        XCTAssertTrue(bar.reply.send(.openLink))
        var newTab: NewTabRequest?
        for await event in events {
            if case .newTabRequested(let request) = event {
                newTab = request
                break
            }
        }
        XCTAssertEqual(newTab?.url, link)
        XCTAssertEqual(newTab?.disposition, .foregroundTab)
        guard case .infoBar(let again) = await take(1, from: stream).first else { return XCTFail("expected the bar again") }
        XCTAssertEqual(again.message, "Something happened")
        XCTAssertNotEqual(again.id, bar.id)
    }

    /// The engine withdraws a bar that went away on its own; later answers are ignored.
    func testWithdrawnBarIgnoresAnswers() async throws {
        let tab = try await makeTab(FakeEngine())
        let stream = tab.dialogRequests()
        let id = tab.simulateInfoBar(message: "Gone soon")
        guard case .infoBar(let bar) = await take(1, from: stream).first else { return XCTFail("expected an info bar") }
        tab.simulateDialogCancel(id)
        XCTAssertFalse(bar.reply.send(.accept))
        XCTAssertNil(tab.dialogAnswers[id])
    }
}
