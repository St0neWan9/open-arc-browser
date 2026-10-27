import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// F1 step 2 dialog requests drawn by the shell (`docs/arc-spec/00-feature-inventory.md §A`,
/// inferred (analysis); looks unknown): the unresponsive-page prompt (C22).
final class EngineDialogsF1Tests: XCTestCase {
    private let profile = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

    private func makeTab(_ engine: FakeEngine, url: String = "https://stuck.example") async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: url)))
        return try XCTUnwrap(tab as? FakeTab)
    }

    private func take<T: Sendable>(_ count: Int, from stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        guard count > 0 else { return result }
        for await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: C22 unresponsive page ([00 §A] inferred (analysis): wait or leave)

    /// Waiting keeps the page: no crash, no navigation; the engine may ask again later.
    func testUnresponsivePageWaitKeepsThePage() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulateUnresponsivePage()
        let requests = await take(1, from: stream)
        guard case .unresponsivePage(let prompt) = requests.first else { return XCTFail("expected the prompt") }
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.origin?.displayHost, "stuck.example")
        XCTAssertTrue(prompt.reply.send(.wait))
        XCTAssertEqual(tab.dialogAnswers[id], .unresponsivePage(.wait))
        let state = await tab.currentState()
        XCTAssertFalse(state.isCrashed)
        XCTAssertEqual(state.url?.host, "stuck.example")
    }

    /// Leaving stops the renderer and goes back to the previous page when there is one.
    func testUnresponsivePageLeaveGoesBack() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine, url: "https://before.example")
        try await tab.load(try XCTUnwrap(URL(string: "https://stuck.example")))
        let events = tab.events()
        let stream = tab.dialogRequests()
        let id = tab.simulateUnresponsivePage()
        guard case .unresponsivePage(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the prompt") }
        prompt.reply.send(.leave)
        XCTAssertEqual(tab.dialogAnswers[id], .unresponsivePage(.leave))
        var sawCrash = false
        for await event in events {
            if case .renderProcessGone = event { sawCrash = true }
            if case .urlChanged(let url) = event, url?.host == "before.example", sawCrash { break }
        }
        XCTAssertTrue(sawCrash)
        let state = await tab.currentState()
        XCTAssertEqual(state.url?.host, "before.example")
        XCTAssertFalse(state.isCrashed, "the previous page loads in a new renderer")
    }

    /// With nothing to go back to, leaving leaves the crashed page (the shell's Reload view).
    func testUnresponsivePageLeaveWithoutHistoryStaysCrashed() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        tab.simulateUnresponsivePage()
        guard case .unresponsivePage(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the prompt") }
        prompt.reply.send(.leave)
        let state = await tab.currentState()
        XCTAssertTrue(state.isCrashed)
    }

    /// The page answering again withdraws the prompt (`.dialogCancelled`); a late answer is ignored.
    func testResponsivePageWithdrawsThePrompt() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        let stream = tab.dialogRequests()
        let id = tab.simulateUnresponsivePage()
        guard case .unresponsivePage(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the prompt") }
        tab.simulatePageResponsive()
        var cancelled = false
        for await event in events {
            if case .dialogCancelled(let cancelledID) = event, cancelledID == id { cancelled = true; break }
        }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(prompt.reply.isFinished)
        XCTAssertFalse(prompt.reply.send(.leave))
        XCTAssertNil(tab.dialogAnswers[id])
        let state = await tab.currentState()
        XCTAssertFalse(state.isCrashed)
    }

    /// Dropped unanswered, the prompt waits (its default).
    func testUnresponsivePageDefaultIsWait() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        // No subscriber: the request is released at once and answered with its default.
        let id = tab.simulateUnresponsivePage()
        try await waitUntil { tab.dialogAnswers[id] != nil }
        XCTAssertEqual(tab.dialogAnswers[id], .unresponsivePage(.wait))
    }
}
