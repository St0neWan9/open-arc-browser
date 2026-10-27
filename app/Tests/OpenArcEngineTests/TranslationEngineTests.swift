import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan B47: page translation in the engine protocol, exercised on `FakeEngine`.
/// docs/arc-spec/06-flows.md §19 (observed): an offer when the page language differs, translate,
/// "Use Original", "Never Translate This Site"; [03 §Advanced] "Reset Translated-site Prompts".
final class TranslationEngineTests: XCTestCase {
    private let profileID = UUID()
    private let german = TranslationLanguage(code: "de", name: "German")
    private let english = TranslationLanguage(code: "en", name: "English")

    private func state(_ tab: FakeTab) async -> BrowserTabState { await tab.currentState() }

    private func makeTab() async throws -> (FakeEngine, FakeTab) {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID, initialURL: URL(string: "http://localhost/de")))
        return (engine, try XCTUnwrap(tab as? FakeTab))
    }

    /// [06 §19.1] observed: a page in another language offers translation; [06 §19.4] translating
    /// then shows it translated (the fake finishes at once, after `.translating`).
    func testOfferTranslateAndRevert() async throws {
        let (_, tab) = try await makeTab()
        let value1 = await state(tab).translation
        XCTAssertEqual(value1, .unavailable)
        tab.simulatePageLanguage(german)
        let value2 = await state(tab).translation.status
        XCTAssertEqual(value2, .available)
        let value3 = await state(tab).translation.targetLanguage
        XCTAssertEqual(value3, english)

        await tab.translate(to: nil)
        let translated = await tab.currentState().translation
        XCTAssertEqual(translated.status, .translated)
        XCTAssertEqual(translated.sourceLanguage, german)
        XCTAssertEqual(translated.targetLanguage, english)

        await tab.revertTranslation()
        let value4 = await state(tab).translation.status
        XCTAssertEqual(value4, .available)
        XCTAssertEqual(tab.commands, [.translate(nil), .revertTranslation])
    }

    /// The event stream reports each change once, ending with the translated state. Bounded: the
    /// stream is read until the expected element.
    func testTranslationEvents() async throws {
        let (_, tab) = try await makeTab()
        let stream = tab.events()
        tab.simulatePageLanguage(german)
        await tab.translate(to: "fr")
        var statuses: [PageTranslation.Status] = []
        for await event in stream {
            guard case .translationChanged(let value) = event else { continue }
            statuses.append(value.status)
            if value.status == .translated {
                XCTAssertEqual(value.targetLanguage?.code, "fr", "[06 §19.3] Choose Another Language")
                break
            }
        }
        XCTAssertEqual(statuses, [.available, .translating, .translated])
    }

    /// Ignored without a known page language, like the engine.
    func testTranslateWithoutLanguageDoesNothing() async throws {
        let (_, tab) = try await makeTab()
        await tab.translate(to: nil)
        let value5 = await state(tab).translation
        XCTAssertEqual(value5, .unavailable)
    }

    /// A failure keeps the offer so the user can retry. [06 §19.6] failure UI unknown; inferred.
    func testFailureThenRetry() async throws {
        let (_, tab) = try await makeTab()
        tab.simulatePageLanguage(german)
        tab.simulateTranslationFailure(.network)
        await tab.translate(to: nil)
        let failed = await tab.currentState().translation
        XCTAssertEqual(failed.status, .failed(.network))
        XCTAssertTrue(failed.hasEntry)
        await tab.translate(to: nil)
        let value6 = await state(tab).translation.status
        XCTAssertEqual(value6, .translated)
    }

    /// [06 §19.3] observed "Never Translate This Site": the offer goes away.
    func testNeverTranslateSiteWithdrawsTheOffer() async throws {
        let (_, tab) = try await makeTab()
        tab.simulatePageLanguage(german)
        await tab.translate(to: nil)
        await tab.neverTranslateSite()
        let value7 = await state(tab).translation
        XCTAssertEqual(value7, .unavailable)
    }

    /// A navigation starts over: the new page's language is detected anew.
    func testNavigationResetsTranslation() async throws {
        let (_, tab) = try await makeTab()
        tab.simulatePageLanguage(german)
        try await tab.load(try XCTUnwrap(URL(string: "http://localhost/en")))
        let value8 = await state(tab).translation
        XCTAssertEqual(value8, .unavailable)
    }

    /// [06 §19.3] observed: target languages alphabetical by name; [03 §Advanced] the reset.
    func testServiceLanguagesAndReset() async throws {
        let engine = FakeEngine()
        let names = await engine.translation.targetLanguages().map(\.name)
        XCTAssertEqual(names, names.sorted())
        XCTAssertTrue(names.contains("German"))
        await engine.translation.resetDecisions(profileID: profileID)
        XCTAssertEqual(engine.fakeTranslationService.resetProfileIDs, [profileID])
    }

    /// Engines without translation report nothing.
    func testUnavailableTranslation() async {
        let service = UnavailableTranslation.shared
        let languages = await service.targetLanguages()
        XCTAssertTrue(languages.isEmpty)
    }
}
