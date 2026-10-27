import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan B49: the link preview hook of the engine protocol (Peek), on `FakeEngine`.
/// docs/arc-spec/06-flows.md §22.1 (observed): in a favorite a plain click on a link to another
/// site opens Peek and a same-site link navigates the favorite; in a Today tab a plain click
/// navigates and a Shift-click opens Peek. The engine drops the click and reports it before the
/// tab navigates.
final class LinkPreviewEngineTests: XCTestCase {
    private let profileID = UUID()

    private func makeTab(_ address: String = "https://source.example/page") async throws -> (FakeEngine, FakeTab) {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID, initialURL: URL(string: address)))
        return (engine, try XCTUnwrap(tab as? FakeTab))
    }

    /// The link preview requests of `stream`, read after closing the tab (the stream finishes with
    /// `.closed`, so the read is bounded).
    private func previewRequests(_ stream: AsyncStream<TabEvent>, closing tab: FakeTab, in engine: FakeEngine) async -> [LinkPreviewRequest] {
        await engine.closeTab(tab.id)
        var requests: [LinkPreviewRequest] = []
        for await event in stream {
            if case .linkPreviewRequested(let request) = event { requests.append(request) }
        }
        return requests
    }

    /// 06 §22.1 observed: no triggers, so a plain click navigates and nothing is intercepted.
    func testWithoutTriggersAClickNavigates() async throws {
        let (_, tab) = try await makeTab()
        let target = try XCTUnwrap(URL(string: "https://other.example/"))
        try await tab.simulateLinkClick(to: target)
        let url = await tab.currentState().url
        XCTAssertEqual(url, target)
    }

    /// 06 §22.1 observed: a favorite's link to another site is reported, not navigated.
    func testOtherSiteLinkIsInterceptedAndThePageStays() async throws {
        let (engine, tab) = try await makeTab()
        await tab.setLinkPreviewTriggers(.otherSiteLink)
        let stream = tab.events()
        let target = try XCTUnwrap(URL(string: "https://www.iana.org/domains"))
        try await tab.simulateLinkClick(to: target)
        let url = await tab.currentState().url
        XCTAssertEqual(url?.host, "source.example", "the source page stays (06 §22.3 observed)")
        let requests = await previewRequests(stream, closing: tab, in: engine)
        XCTAssertEqual(requests, [LinkPreviewRequest(url: target, trigger: .otherSiteLink)])
    }

    /// 06 §22.1 observed: a same-site link navigates the favorite itself.
    func testSameSiteLinkNavigates() async throws {
        let (_, tab) = try await makeTab("https://www.source.example/a")
        await tab.setLinkPreviewTriggers(.otherSiteLink)
        let target = try XCTUnwrap(URL(string: "https://docs.source.example/b"))
        try await tab.simulateLinkClick(to: target)
        let url = await tab.currentState().url
        XCTAssertEqual(url, target)
    }

    /// 06 §22.1 observed: Shift-click opens Peek when the tab intercepts Shift-clicks…
    func testShiftClickIsIntercepted() async throws {
        let (engine, tab) = try await makeTab()
        await tab.setLinkPreviewTriggers(.shiftClick)
        let stream = tab.events()
        let target = try XCTUnwrap(URL(string: "https://source.example/next"))
        try await tab.simulateLinkClick(to: target, shift: true)
        let requests = await previewRequests(stream, closing: tab, in: engine)
        XCTAssertEqual(requests.map(\.trigger), [.shiftClick], "even a same-site link")
    }

    /// …and asks for a new window otherwise ([06 §4] observed before Peek existed).
    func testShiftClickWithoutTriggerAsksForANewWindow() async throws {
        let (engine, tab) = try await makeTab()
        let stream = engine.events()
        let target = try XCTUnwrap(URL(string: "https://other.example/"))
        try await tab.simulateLinkClick(to: target, shift: true)
        // Take one element: the click's request is the only engine event here.
        var iterator = stream.makeAsyncIterator()
        let event = await iterator.next()
        guard case .newTabRequested(let request) = event else { return XCTFail("expected a new tab request, got \(String(describing: event))") }
        XCTAssertEqual(request.disposition, .newWindow)
    }

    /// The fake's site rule: registrable domain by the last two labels (three for short
    /// second-level labels such as co.uk). inferred, see LinkPreview.swift.
    func testSameSiteRule() throws {
        func url(_ s: String) throws -> URL { try XCTUnwrap(URL(string: s)) }
        XCTAssertTrue(LinkPreviewTriggers.isSameSite(try url("https://a.example.com"), try url("http://b.example.com/x")))
        XCTAssertFalse(LinkPreviewTriggers.isSameSite(try url("https://example.com"), try url("https://example.org")))
        XCTAssertTrue(LinkPreviewTriggers.isSameSite(try url("https://news.bbc.co.uk"), try url("https://www.bbc.co.uk")))
        XCTAssertFalse(LinkPreviewTriggers.isSameSite(try url("https://a.co.uk"), try url("https://b.co.uk")))
        XCTAssertFalse(LinkPreviewTriggers.isSameSite(try url("about:blank"), try url("https://example.com")))
    }
}
