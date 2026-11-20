import XCTest
import OpenArcModel
@testable import OpenArcShell

/// Plan B233: sites' own search engines (OpenSearch descriptions) join "Tab to Search".
@MainActor
final class OpenSearchDiscoveryB233Tests: XCTestCase {
    private let page = URL(string: "https://www.example.org/docs/page")!

    private func description(_ template: String, name: String = "Example Docs") -> Data {
        Data("""
        <?xml version="1.0"?>
        <OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">
          <ShortName>\(name)</ShortName>
          <Url type="application/x-suggestions+json" template="https://example.org/suggest?q={searchTerms}"/>
          <Url type="text/html" method="get" template="\(template)"/>
        </OpenSearchDescription>
        """.utf8)
    }

    func testParsesAndConvertsTheTemplate() throws {
        let parsed = try XCTUnwrap(OpenSearchDescription.parse(description("https://example.org/search?q={searchTerms}&amp;page={startPage?}")))
        XCTAssertEqual(parsed.shortName, "Example Docs")
        XCTAssertEqual(parsed.searchTemplate(forPage: page), "https://example.org/search?q=%@&page=")
        // Another site, a required parameter we cannot fill, no search terms: unusable.
        XCTAssertNil(OpenSearchDescription(shortName: "x", template: "https://evil.example/s?q={searchTerms}").searchTemplate(forPage: page))
        XCTAssertNil(OpenSearchDescription(shortName: "x", template: "https://example.org/s?q={searchTerms}&l={language}").searchTemplate(forPage: page))
        XCTAssertNil(OpenSearchDescription(shortName: "x", template: "https://example.org/s").searchTemplate(forPage: page))
        XCTAssertNil(OpenSearchDescription(shortName: "x", template: "javascript:{searchTerms}").searchTemplate(forPage: page))
        XCTAssertNil(OpenSearchDescription.parse(Data("<OpenSearchDescription/>".utf8)))
    }

    func testDiscoversOncePerHostAndOffersTheSite() async throws {
        let preferences = AppPreferences.inMemory()
        let discovery = OpenSearchDiscovery(preferences: preferences)
        let data = description("https://example.org/search?q={searchTerms}")
        nonisolated(unsafe) var fetched: [URL] = []  // Test-only: written and read on the main actor.
        discovery.fetch = { url in fetched.append(url); return data }
        var scripts = 0
        let evaluate: @MainActor (String) async -> String? = { _ in scripts += 1; return "https://example.org/opensearch.xml" }
        discovery.pageLoaded(page, evaluate: evaluate)
        discovery.pageLoaded(page, evaluate: evaluate)
        for _ in 0..<100 where discovery.sites.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(scripts, 1, "one try per host")
        XCTAssertEqual(fetched, [URL(string: "https://example.org/opensearch.xml")!])
        let site = try XCTUnwrap(discovery.sites.first)
        XCTAssertEqual(site.host, "example.org")
        XCTAssertEqual(site.searchURL(for: "swift actors")?.absoluteString, "https://example.org/search?q=swift%20actors")
        XCTAssertEqual(CommandBarSearchSites.match(typed: "exam", sites: CommandBarSearchSites.builtIn + discovery.sites)?.name, "Example Docs")
        // Kept on this device.
        XCTAssertEqual(OpenSearchDiscovery(preferences: preferences).sites.map(\.host), ["example.org"])
    }

    func testIgnoresDescriptionsFromOtherSitesAndBuiltInSites() async throws {
        let discovery = OpenSearchDiscovery(preferences: .inMemory())
        nonisolated(unsafe) var fetches = 0  // Test-only: main actor.
        discovery.fetch = { _ in fetches += 1; return nil }
        discovery.pageLoaded(page) { _ in "https://tracker.example/opensearch.xml" }
        discovery.pageLoaded(URL(string: "https://www.youtube.com/watch")!) { _ in "https://youtube.com/o.xml" }
        discovery.pageLoaded(URL(string: "file:///tmp/a.html")!) { _ in "file:///tmp/o.xml" }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(fetches, 0)
        XCTAssertTrue(discovery.sites.isEmpty)
    }
}
