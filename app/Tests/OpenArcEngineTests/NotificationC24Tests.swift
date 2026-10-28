import XCTest
import OpenArcEngine
import OpenArcModel

/// Plan C24, `docs/arc-spec/00-feature-inventory.md` §A inferred (analysis): web notifications
/// reach Notification Center, and a click brings their page forward.
final class NotificationC24Tests: XCTestCase {
    private let profile = UUID()

    /// The first element of `stream` that matches (the streams here never end on their own, so
    /// the match must come).
    private func first<S: AsyncSequence>(of stream: S, where match: (S.Element) -> Bool) async throws -> S.Element? {
        for try await element in stream where match(element) { return element }
        return nil
    }

    /// A click on a notification its page showed: the tab asks to be shown.
    func testClickOnANotificationOfAnOpenPageRequestsActivation() async throws {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://chat.example")))
        let fake = try XCTUnwrap(tab as? FakeTab)
        let events = tab.events()
        fake.simulateNotificationClick()
        let event = try await first(of: events) { $0 == .activationRequested }
        XCTAssertEqual(event, .activationRequested)
    }

    /// A click whose page is gone: a foreground tab on the origin, asked for from outside any tab.
    func testClickWithoutItsPageRequestsANewTabOnTheOrigin() async throws {
        let engine = FakeEngine()
        let events = engine.events()
        let origin = try XCTUnwrap(URL(string: "https://chat.example"))
        engine.simulateNotificationClickWithoutPage(origin: origin)
        let event = try await first(of: events) { if case .newTabRequested = $0 { return true } else { return false } }
        XCTAssertEqual(event, .newTabRequested(NewTabRequest(opener: nil, url: origin, disposition: .foregroundTab, hasUserGesture: true)))
    }
}
