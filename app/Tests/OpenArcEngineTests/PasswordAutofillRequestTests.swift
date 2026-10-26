import XCTest
import OpenArcModel
import OpenArcEngine

/// Plan C13: the password save prompt and the autofill dropdown as engine dialog requests, run
/// against FakeEngine. `docs/arc-spec/00-feature-inventory.md §A` records the feature as inherited
/// from the engine with shell-drawn prompts whose style was not captured (observed); the request
/// semantics are Chromium's (inferred).
final class PasswordAutofillRequestTests: XCTestCase {
    private let profile = UUID()

    private func take<S: AsyncSequence>(_ count: Int, from stream: S) async rethrows -> [S.Element] {
        var result: [S.Element] = []
        guard count > 0 else { return result }
        for try await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    private func makeTab(_ engine: FakeEngine) async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://login.example/")))
        return try XCTUnwrap(tab as? FakeTab)
    }

    func testPasswordSavePromptIsSingleShotAndCarriesNoPassword() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulatePasswordSavePrompt(username: "ada", passwordLength: 6)
        let requests = await take(1, from: stream)
        guard case .passwordSave(let prompt)? = requests.first else { return XCTFail("expected a save prompt") }
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.username, "ada")
        XCTAssertEqual(prompt.passwordLength, 6)
        XCTAssertEqual(prompt.kind, .save)
        XCTAssertEqual(prompt.origin, SiteOrigin(scheme: "https", host: "login.example"))
        XCTAssertTrue(prompt.reply.send(.save(username: "grace")))
        XCTAssertFalse(prompt.reply.send(.decline), "single-shot")
        XCTAssertEqual(tab.dialogAnswers[id], .passwordSave(.save(username: "grace")))
    }

    func testPasswordSavePromptDefaultsToDismiss() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulatePasswordSavePrompt(username: "ada")
        let requests = await take(1, from: stream)
        XCTAssertTrue(requests.first?.answerWithDefault() ?? false)
        XCTAssertEqual(tab.dialogAnswers[id], .passwordSave(.dismiss))
    }

    func testAutofillSessionCarriesUpdatesAndCommands() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let rows = [
            AutofillSuggestion(kind: .password, mainText: "ada", label: "••••••"),
            AutofillSuggestion(kind: .separator, mainText: "", isSelectable: false, isAcceptable: false),
            AutofillSuggestion(kind: .action, mainText: "Manage passwords…"),
        ]
        let bounds = EngineRect(x: 10, y: 40, width: 200, height: 24)
        let (id, session) = tab.simulateAutofillPopup(AutofillPopupState(suggestions: rows, elementBounds: bounds))
        let requests = await take(1, from: stream)
        guard case .autofillPopup(let popup)? = requests.first else { return XCTFail("expected a dropdown") }
        XCTAssertEqual(popup.id, id)
        XCTAssertTrue(popup.session === session)

        // Updates while open (the user typed / pressed ↓ in the page): the stream starts with the
        // current state.
        let updates = popup.session.updates()
        var highlighted = popup.session.state
        highlighted.selectedIndex = 0
        session.update(highlighted)
        let seen = await take(2, from: updates)
        XCTAssertEqual(seen.map(\.selectedIndex), [nil, 0])

        popup.session.send(.select(2))
        popup.session.send(.accept(0))
        XCTAssertEqual(tab.autofillCommands, [.select(2), .accept(0)])
        // Choosing a row withdraws the dropdown, as the engine does after filling.
        XCTAssertTrue(popup.reply.isFinished)
        XCTAssertNil(tab.dialogAnswers[id], "withdrawn, not answered")
    }

    func testAutofillDismissEndsTheSession() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let (id, session) = tab.simulateAutofillPopup(AutofillPopupState(
            suggestions: [AutofillSuggestion(kind: .autocomplete, mainText: "earlier")],
            elementBounds: EngineRect(x: 0, y: 0, width: 100, height: 20)
        ))
        let requests = await take(1, from: stream)
        let updates = session.updates()
        XCTAssertTrue(requests.first?.answerWithDefault() ?? false)
        XCTAssertEqual(tab.dialogAnswers[id], .autofillPopup(.dismiss))
        // The stream holds the initial state and then ends (bounded).
        let all = await take(5, from: updates)
        XCTAssertEqual(all.count, 1)
    }
}
