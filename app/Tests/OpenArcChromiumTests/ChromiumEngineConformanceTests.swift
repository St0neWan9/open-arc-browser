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
        // --use-mock-keychain: the cookie store's key comes from a mock keychain (no keychain prompt
        // for a test process).
        let engine = ChromiumEngine(userDataDirectory: dataDirectory, additionalSwitches: [
            "--no-sandbox", "--autoplay-policy=no-user-gesture-required", "--use-mock-keychain",
        ])
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

        // C9: the favicon's PNG reaches the tab state (the bridge decodes it; the wrapper re-reads
        // the state after the load settles, see `ChromiumTabCore.settleResyncDelays`).
        let pixel = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
        let iconPage = try XCTUnwrap(URL(string: "data:text/html,<title>Icon</title><link rel=icon href='data:image/png;base64,\(pixel)'>icon"))
        try await tab.load(iconPage)
        try await waitForState(tab) { $0.title == "Icon" && $0.favicon?.pngData?.isEmpty == false }

        // C9: audio from the page is reported, and mute reaches the engine.
        let tone = "<title>Tone</title><script>const c=new AudioContext();const o=c.createOscillator();const g=c.createGain();"
            + "g.gain.value=0.01;o.connect(g);g.connect(c.destination);o.start();</script>tone"
        let tonePage = try XCTUnwrap(URL(string: "data:text/html," + (tone.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")))
        try await tab.load(tonePage)
        try await waitForState(tab) { $0.audio.isAudible }
        await tab.setMuted(true)
        try await waitForState(tab) { $0.audio.isMuted }
        await tab.setMuted(false)

        // C14 / [06 §18.1] observed: Arc sends Chromium's own reduced UA and brands, with no
        // product token and no "Google Chrome" brand; Open Arc must send the same.
        let identityServer = try ProfileIsolationServer()
        try await identityServer.start()
        defer { identityServer.stop() }
        try await tab.load(identityServer.url(path: "/ua"))
        try await waitForState(tab) { $0.title.hasPrefix("ID:") }
        let identity = String(await tab.currentState().title.dropFirst(3)).components(separatedBy: "|")
        XCTAssertEqual(identity.count, 3)
        XCTAssertEqual(identity.first, BrowserIdentity.expectedUserAgent)
        XCTAssertEqual(identity.dropFirst().first, "Google Inc.")
        XCTAssertEqual(identity.last.map { Set($0.split(separator: "+").map(String.init)) }, BrowserIdentity.expectedBrands)

        // C9: a renderer crash is reported (`isCrashed` and `.renderProcessGone`); a reload brings
        // the page back in a new renderer.
        let crashEvents = tab.events()
        try await tab.load(try XCTUnwrap(URL(string: "chrome://crash")))
        let gone = try await withTimeout(seconds: 20) { () -> Bool in
            for await event in crashEvents { if case .renderProcessGone = event { return true } }
            return false
        }
        XCTAssertTrue(gone)
        try await waitForState(tab) { $0.isCrashed }
        try await tab.load(first)
        try await waitForState(tab) { !$0.isCrashed && $0.title == "First" }

        // C11: two profiles and incognito keep their data apart; clearing and deleting a profile.
        try await checkProfileIsolation(engine, dataDirectory: dataDirectory, defaultProfile: profile)

        // D3b: history and passwords imported from made-up Chrome, CSV and Safari sources.
        try await checkImport(engine, profileID: UUID())

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
    func waitForState(_ tab: any BrowserTab, _ condition: (BrowserTabState) -> Bool) async throws {
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
func withTimeout<T: Sendable>(
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

/// What Arc 1.170.0 sends ([06 §18.1] observed), for the Chromium version of this build: Chromium's
/// reduced user agent (frozen macOS 10_15_7, major version only) and the brands Not:A-Brand and
/// Chromium, nothing else.
enum BrowserIdentity {
    static let majorVersion = "156"
    static let expectedUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/\(majorVersion).0.0.0 Safari/537.36"
    static let expectedBrands: Set<String> = ["Not:A-Brand", "Chromium"]
}
