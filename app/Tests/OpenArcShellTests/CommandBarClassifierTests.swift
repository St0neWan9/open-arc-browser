import XCTest
@testable import OpenArcShell

/// URL-versus-search classification. [05 §command bar] observed: one entry for new tab, search and
/// commands. The concrete rules are inferred.
final class CommandBarClassifierTests: XCTestCase {
    private func url(_ s: String) -> CommandBarInputKind {
        .url(URL(string: s)!)
    }

    /// [05 §command bar] inferred: empty text means no URL/search row.
    func testEmptyInput() {
        XCTAssertEqual(CommandBarInputClassifier.classify(""), .empty)
        XCTAssertEqual(CommandBarInputClassifier.classify("   "), .empty)
    }

    /// [05 §command bar] inferred: a dotted host is a URL (https).
    func testDomainsBecomeHTTPSURLs() {
        XCTAssertEqual(CommandBarInputClassifier.classify("example.com"), url("https://example.com"))
        XCTAssertEqual(CommandBarInputClassifier.classify("  news.example.co.uk/path?q=1 "), url("https://news.example.co.uk/path?q=1"))
        XCTAssertEqual(CommandBarInputClassifier.classify("example.com:8443/x"), url("https://example.com:8443/x"))
    }

    /// [05 §command bar] inferred: an explicit supported scheme is kept.
    func testExplicitSchemeIsKept() {
        XCTAssertEqual(CommandBarInputClassifier.classify("http://example.com"), url("http://example.com"))
        XCTAssertEqual(CommandBarInputClassifier.classify("https://a.b/c"), url("https://a.b/c"))
        XCTAssertEqual(CommandBarInputClassifier.classify("file:///tmp/x.html"), url("file:///tmp/x.html"))
        XCTAssertEqual(CommandBarInputClassifier.classify("about:blank"), url("about:blank"))
    }

    /// [05 §command bar] inferred: unsupported schemes are never navigated.
    func testUnsupportedSchemeIsASearch() {
        XCTAssertEqual(CommandBarInputClassifier.classify("javascript://alert(1)"), .search("javascript://alert(1)"))
    }

    /// [05 §command bar] inferred: localhost / IPs use http.
    func testLocalhostAndIPAddressesUseHTTP() {
        XCTAssertEqual(CommandBarInputClassifier.classify("localhost"), url("http://localhost"))
        XCTAssertEqual(CommandBarInputClassifier.classify("localhost:3000"), url("http://localhost:3000"))
        XCTAssertEqual(CommandBarInputClassifier.classify("192.168.1.10:8080/app"), url("http://192.168.1.10:8080/app"))
        XCTAssertEqual(CommandBarInputClassifier.classify("[::1]:3000"), url("http://[::1]:3000"))
    }

    /// [05 §command bar] inferred: malformed IPs are searches.
    func testInvalidIPAddressIsASearch() {
        XCTAssertEqual(CommandBarInputClassifier.classify("256.1.1.1"), .search("256.1.1.1"))
        XCTAssertEqual(CommandBarInputClassifier.classify("1.2.3"), .search("1.2.3"))
    }

    /// [05 §command bar] inferred: whitespace means search.
    func testTextWithSpacesIsASearch() {
        XCTAssertEqual(CommandBarInputClassifier.classify("example.com login"), .search("example.com login"))
        XCTAssertEqual(CommandBarInputClassifier.classify("how to tie a tie"), .search("how to tie a tie"))
    }

    /// [05 §command bar] inferred: bare words are searches.
    func testBareWordsAndOddInputAreSearches() {
        XCTAssertEqual(CommandBarInputClassifier.classify("swift"), .search("swift"))
        XCTAssertEqual(CommandBarInputClassifier.classify("foo/bar"), .search("foo/bar"))
        XCTAssertEqual(CommandBarInputClassifier.classify("e.g."), .search("e.g."))
        XCTAssertEqual(CommandBarInputClassifier.classify("foo:3000"), .search("foo:3000"))
        XCTAssertEqual(CommandBarInputClassifier.classify("a.b"), .search("a.b"))
    }
}
