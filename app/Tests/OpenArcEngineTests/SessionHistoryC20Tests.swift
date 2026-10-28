import XCTest
import OpenArcEngine
import OpenArcModel

/// Plan C20: a tab's back/forward list survives a relaunch. `docs/arc-spec/03-settings.md`
/// §Advanced, inferred (analysis): with "restore windows from previous session" on, each restored
/// tab keeps its back/forward history, not only its URL.
final class SessionHistoryC20Tests: XCTestCase {
    private let profile = UUID()

    private func url(_ string: String) throws -> URL { try XCTUnwrap(URL(string: string)) }

    /// [03 §Advanced] inferred (analysis): the saved list restores the entries and the current
    /// position into a new tab on another engine instance; Back and Forward then work.
    func testSessionHistoryRoundTripsIntoANewEngine() async throws {
        let a = try url("https://a.example"), b = try url("https://b.example"), c = try url("https://c.example")
        let first = FakeEngine()
        let tab = try await first.makeTab(TabConfiguration(profileID: profile, initialURL: a))
        try await tab.load(b)
        try await tab.load(c)
        try await tab.goBack()
        let history = await tab.sessionHistory()
        let saved = try XCTUnwrap(history)

        let relaunched = FakeEngine()
        let restored = try await relaunched.makeTab(TabConfiguration(
            profileID: profile, initialURL: b, sessionHistory: saved
        ))
        var state = await restored.currentState()
        XCTAssertEqual(state.url, b, "the current entry is shown")
        XCTAssertEqual(state.navigation, NavigationState(canGoBack: true, canGoForward: true))
        try await restored.goBack()
        state = await restored.currentState()
        XCTAssertEqual(state.url, a)
        try await restored.goForward()
        try await restored.goForward()
        state = await restored.currentState()
        XCTAssertEqual(state.url, c)
        let again = await restored.sessionHistory()
        XCTAssertNotNil(again, "a restored tab can be saved again")
    }

    /// The saved list wins over `initialURL`; data the engine cannot read falls back to it.
    func testUnreadableSessionHistoryFallsBackToTheInitialURL() async throws {
        let a = try url("https://a.example")
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(
            profileID: profile, initialURL: a, sessionHistory: TabSessionHistory(data: Data("not ours".utf8))
        ))
        let state = await tab.currentState()
        XCTAssertEqual(state.url, a)
        XCTAssertEqual(state.navigation, .none)
    }

    /// Nothing to keep: a blank tab and a closed tab have no list.
    func testBlankAndClosedTabsHaveNoSessionHistory() async throws {
        let engine = FakeEngine()
        let blank = try await engine.makeTab(TabConfiguration(profileID: profile))
        let blankHistory = await blank.sessionHistory()
        XCTAssertNil(blankHistory)
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: try url("https://a.example")))
        await engine.closeTab(tab.id)
        let closedHistory = await tab.sessionHistory()
        XCTAssertNil(closedHistory)
    }
}
