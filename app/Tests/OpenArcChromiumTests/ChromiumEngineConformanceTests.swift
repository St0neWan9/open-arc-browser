import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Conformance test of the Chromium engine (plan C8) against the `BrowserEngine` contract the
/// FakeEngine tests check: `.snapshot` first, URL/title/navigation events, back/forward, JavaScript
/// dialogs through `dialogRequests()`, close, shutdown.
///
/// Runs only when `OPENARC_ENGINE_TESTS=1` (it starts a real Chromium browser process, renderer
/// and GPU helpers). Chromium starts once per process, so everything is one test. Pages are
/// `data:` URLs, so no network is needed.
final class ChromiumEngineConformanceTests: XCTestCase {
    private let profile = UUID()

    @MainActor
    func testChromiumEngineConformance() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["OPENARC_ENGINE_TESTS"] == "1",
            "Set OPENARC_ENGINE_TESTS=1 to run the Chromium engine test."
        )
        ChromiumEngine.installApplicationClass()
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openarc-chromium-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        // --no-sandbox: the helpers' seatbelt profile only lets them read inside the main bundle
        // (Open Arc.app, which embeds the framework), and under xctest the framework lives
        // outside it. The app run checks the sandboxed path (plan C8 report).
        let engine = ChromiumEngine(userDataDirectory: dataDirectory, additionalSwitches: ["--no-sandbox"])
        XCTAssertTrue(engine.engineVersion.hasPrefix("Chromium "))

        // Creating a tab starts the engine and loads the page.
        let first = try XCTUnwrap(URL(string: "data:text/html,<title>First</title>first"))
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: first))
        let events = tab.events()
        var iterator = events.makeAsyncIterator()
        guard case .snapshot = await iterator.next() else { return XCTFail("first event must be .snapshot") }

        try await waitForState(tab) { $0.title == "First" && !$0.loadState.isLoading }
        let state = await tab.currentState()
        XCTAssertEqual(state.committedURL, first)

        // Navigation and back.
        let second = try XCTUnwrap(URL(string: "data:text/html,<title>Second</title>second"))
        try await tab.load(second)
        try await waitForState(tab) { $0.title == "Second" && $0.navigation.canGoBack }
        try await tab.goBack()
        try await waitForState(tab) { $0.title == "First" && $0.navigation.canGoForward }

        // A JavaScript alert reaches the dialog stream; answering it lets the page continue.
        let dialogs = tab.dialogRequests()
        let alertPage = try XCTUnwrap(URL(string: "data:text/html,<script>alert('hello');document.title='Done'</script>"))
        try await tab.load(alertPage)
        let request = try await withTimeout(seconds: 20) { () -> EngineDialogRequest? in
            for await request in dialogs { return request }
            return nil
        }
        guard case .javaScript(let dialog)? = request else { return XCTFail("expected a JavaScript dialog") }
        XCTAssertEqual(dialog.kind, .alert)
        XCTAssertEqual(dialog.message, "hello")
        XCTAssertTrue(dialog.reply.send(JavaScriptDialogReply(accepted: true)))
        try await waitForState(tab) { $0.title == "Done" }

        // Closing ends the tab's stream; shutdown makes new tabs fail.
        await engine.closeTab(tab.id)
        let closedLookup = await engine.tab(for: tab.id)
        XCTAssertNil(closedLookup)
        await engine.shutdown()
        do {
            _ = try await engine.makeTab(TabConfiguration(profileID: profile))
            XCTFail("makeTab after shutdown must throw")
        } catch {
            XCTAssertEqual(error as? EngineError, .shuttingDown)
        }
    }

    /// Polls the tab's state until `condition` holds, at most 20 s. The main run loop keeps
    /// turning, which Chromium's UI thread needs.
    @MainActor
    private func waitForState(_ tab: any BrowserTab, _ condition: (BrowserTabState) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if condition(await tab.currentState()) { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let state = await tab.currentState()
        XCTFail("timed out; last state: \(state.title) \(String(describing: state.url))")
    }
}

/// Runs `operation`, failing with `CancellationError` after `seconds`.
private func withTimeout<T: Sendable>(
    seconds: Double, _ operation: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
