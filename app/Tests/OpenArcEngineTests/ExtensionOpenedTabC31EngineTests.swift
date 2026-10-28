import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan C31 (`docs/f1-review-final.md` 09 #17; `docs/arc-spec/00-feature-inventory.md` §A observed:
/// extensions are inherited from the engine): extension APIs that need a window reach the shell as
/// opener-less new-tab requests that carry the tab the engine made and the extension's profile.
final class ExtensionOpenedTabC31EngineTests: XCTestCase {
    private let profile = UUID()

    /// The first engine event that is a new-tab request.
    private func firstRequest(_ stream: AsyncStream<EngineEvent>) async -> NewTabRequest? {
        for await event in stream {
            if case .newTabRequested(let request) = event { return request }
        }
        return nil
    }

    func testRequestCarriesThePendingTabAndProfile() async throws {
        let engine = FakeEngine()
        let events = engine.events()
        let page = try XCTUnwrap(URL(string: "https://docs.example"))
        let token = engine.simulateExtensionOpensTab(url: page, profileID: profile, disposition: .newWindow)
        let received = await firstRequest(events)
        let request = try XCTUnwrap(received)
        XCTAssertNil(request.opener)
        XCTAssertEqual(request.url, page)
        XCTAssertEqual(request.disposition, .newWindow)
        XCTAssertEqual(request.pendingTab, token)
        XCTAssertEqual(request.profileID, profile)
        XCTAssertTrue(engine.pendingTabTokens.contains(token))
    }

    /// Adopting gives the extension's tab (its profile, its URL, no opener); declining drops it.
    func testAdoptAndDecline() async throws {
        let engine = FakeEngine()
        let page = try XCTUnwrap(URL(string: "https://docs.example"))
        let token = engine.simulateExtensionOpensTab(url: page, profileID: profile)
        let adoptedTab = try await engine.adoptTab(token, requestedID: nil)
        let adopted = try XCTUnwrap(adoptedTab as? FakeTab)
        XCTAssertEqual(adopted.profileID, profile)
        XCTAssertNil(adopted.opener)
        let state = await adopted.currentState()
        XCTAssertEqual(state.url, page)

        let other = engine.simulateExtensionOpensTab(url: page, profileID: profile)
        await engine.declineTab(other)
        XCTAssertTrue(engine.pendingTabTokens.isEmpty)
    }
}
