import XCTest
import OpenArcModel
import OpenArcEngine

/// Plan B71: `BrowserTab.evaluateJavaScript(_:)` for the AppleScript `execute` command. Spec:
/// docs/arc-spec/06-flows.md §29.3 (observed: `execute` returns text; the value-to-text rules are
/// unknown there, inferred "serialized like Chrome, empty when there is no value").
final class JavaScriptEvaluationTests: XCTestCase {
    private func makeTab() async throws -> FakeTab {
        let tab = try await FakeEngine().makeTab(TabConfiguration(profileID: UUID(), initialURL: URL(string: "https://page.example")))
        return try XCTUnwrap(tab as? FakeTab)
    }

    // MARK: Text conversion ([06 §29.3] inferred)

    func testStringsComeBackAsIs() {
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: #""hello""#), "hello")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: #""line\nwith \"quotes\" and é""#), "line\nwith \"quotes\" and é")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: #""""#), "")
    }

    func testNullAndUndefinedGiveEmptyText() {
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: nil), "", "undefined")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "null"), "")
    }

    func testOtherValuesAreSerializedAsJSON() {
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "2"), "2")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "2.5"), "2.5")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "true"), "true")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "false"), "false")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "[1,\"a\",null]"), "[1,\"a\",null]")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: #"{"b":1,"a":"x/y"}"#), #"{"b":1,"a":"x/y"}"#)
    }

    /// Values JSON cannot hold arrive as their JavaScript literal (OACJavaScript.h) and pass through.
    func testUnserializableLiteralsPassThrough() {
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "NaN"), "NaN")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "-Infinity"), "-Infinity")
        XCTAssertEqual(JavaScriptResultText.text(fromJSON: "12n"), "12n")
    }

    // MARK: FakeEngine

    func testFakeTabReturnsTheCannedResultAsText() async throws {
        let tab = try await makeTab()
        let undefined = try await tab.evaluateJavaScript("void 0")
        XCTAssertEqual(undefined, "", "default outcome is undefined")
        tab.simulateJavaScriptOutcome(.value(json: #""Example Domain""#))
        let title = try await tab.evaluateJavaScript("document.title")
        XCTAssertEqual(title, "Example Domain")
        tab.simulateJavaScriptOutcome(.value(json: "2"))
        let sum = try await tab.evaluateJavaScript("1+1")
        XCTAssertEqual(sum, "2")
        XCTAssertEqual(tab.commands, [.evaluateJavaScript("void 0"), .evaluateJavaScript("document.title"), .evaluateJavaScript("1+1")])
    }

    func testFakeTabThrowsTheCannedError() async throws {
        let tab = try await makeTab()
        tab.simulateJavaScriptOutcome(.failure(.javaScriptException("ReferenceError: x is not defined")))
        do {
            _ = try await tab.evaluateJavaScript("x")
            XCTFail("expected the exception")
        } catch {
            XCTAssertEqual(error as? EngineError, .javaScriptException("ReferenceError: x is not defined"))
        }
        tab.simulateJavaScriptOutcome(.failure(.unsupported("evaluateJavaScript")))
        do {
            _ = try await tab.evaluateJavaScript("1")
            XCTFail("expected unsupported")
        } catch {
            XCTAssertEqual(error as? EngineError, .unsupported("evaluateJavaScript"))
        }
    }

    func testClosedTabRefuses() async throws {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: UUID()))
        await engine.closeTab(tab.id)
        do {
            _ = try await tab.evaluateJavaScript("1")
            XCTFail("expected tabClosed")
        } catch {
            XCTAssertEqual(error as? EngineError, .tabClosed(tab.id))
        }
    }
}
