import XCTest
import OpenArcModel
import OpenArcEngine

/// Plan C30: Autofill's address and payment-card save prompts as engine dialog requests, run
/// against FakeEngine. `docs/arc-spec/00-feature-inventory.md §A` observed: passwords, autofill
/// and payments are inherited from the engine and their prompts are drawn by the shell (style not
/// captured). When to offer, and what saving does, are Chromium's rules (inferred).
final class AutofillSavePromptC30Tests: XCTestCase {
    private let profile = UUID()

    private let address = FakeAddress(
        name: "Ada Lovelace", street: "12 Example Street", city: "Springfield", postalCode: "12345",
        email: "ada@example.test", phone: "+1 555 0100"
    )
    private let card = FakeCard(number: "4111 1111 1111 1111", expirationMonth: 4, expirationYear: 2031, cardholderName: "Ada Lovelace")

    private func makeTab(_ engine: FakeEngine, url: String = "https://shop.example/checkout", offTheRecord: Bool = false) async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(
            profileID: profile, initialURL: URL(string: url), isOffTheRecord: offTheRecord
        ))
        return try XCTUnwrap(tab as? FakeTab)
    }

    /// The first `count` elements (the streams stay open; the elements must come).
    private func take<T: Sendable>(_ count: Int, from stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        for await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    // MARK: Address

    /// Submitting a new address offers to save it; Save stores it, and the next address field
    /// offers it in the dropdown.
    func testSavedAddressIsOfferedNextTime() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        XCTAssertNil(tab.simulateAutofillFieldFocus(.address), "nothing saved yet: no dropdown")
        let id = try XCTUnwrap(tab.simulateAddressSubmission(address))
        guard case .addressSave(let prompt) = await take(1, from: stream).first else { return XCTFail("expected an address prompt") }
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.kind, .save)
        XCTAssertEqual(prompt.origin?.displayHost, "shop.example")
        XCTAssertTrue(prompt.addressSummary.contains("Ada Lovelace"))
        XCTAssertTrue(prompt.addressSummary.contains("12 Example Street"))
        XCTAssertEqual(prompt.email, "ada@example.test")
        XCTAssertTrue(prompt.changes.isEmpty)
        XCTAssertTrue(prompt.reply.send(.save))
        XCTAssertFalse(prompt.reply.send(.decline), "single-shot")
        XCTAssertEqual(tab.dialogAnswers[id], .addressSave(.save))
        XCTAssertEqual(engine.fakeAutofill.savedAddresses(profileID: profile), [address])

        // Next visit: the dropdown offers the saved address, and the same address is not offered again.
        let next = try await makeTab(engine, url: "https://other.example/form")
        let popup = try XCTUnwrap(next.simulateAutofillFieldFocus(.address))
        XCTAssertEqual(popup.session.state.suggestions.map(\.kind), [.address])
        XCTAssertEqual(popup.session.state.suggestions.first?.mainText, "Ada Lovelace")
        XCTAssertNil(next.simulateAddressSubmission(address), "already saved: no prompt")
    }

    /// New values for a saved person are an update prompt that lists what changes.
    func testChangedAddressIsAnUpdateListingTheChanges() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        tab.simulateAddressSubmission(address)
        guard case .addressSave(let first) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
        first.reply.send(.save)
        var moved = address
        moved.street = "1 New Road"
        moved.phone = "+1 555 0199"
        tab.simulateAddressSubmission(moved)
        guard case .addressSave(let update) = await take(1, from: stream).first else { return XCTFail("expected an update") }
        XCTAssertEqual(update.kind, .update)
        XCTAssertEqual(update.changes.map(\.field), [.address, .phone])
        XCTAssertEqual(update.changes.last?.oldValue, "+1 555 0100")
        XCTAssertEqual(update.changes.last?.newValue, "+1 555 0199")
        update.reply.send(.save)
        XCTAssertEqual(engine.fakeAutofill.savedAddresses(profileID: profile), [moved], "updated in place")
    }

    /// Declining saves nothing; after the strike limit the site is not asked again. Dropping the
    /// prompt answers `.ignore` (no strike).
    func testDeclineSavesNothingAndStopsAfterTheLimit() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        for _ in 0..<FakeAutofillStore.maximumStrikes {
            let id = try XCTUnwrap(tab.simulateAddressSubmission(address))
            guard case .addressSave(let prompt) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
            XCTAssertTrue(prompt.reply.send(.decline))
            XCTAssertEqual(tab.dialogAnswers[id], .addressSave(.decline))
        }
        XCTAssertTrue(engine.fakeAutofill.savedAddresses(profileID: profile).isEmpty)
        XCTAssertNil(tab.simulateAddressSubmission(address), "site blocked after repeated declines")
    }

    func testDroppedPromptIsIgnored() async throws {
        let tab = try await makeTab(FakeEngine())
        let stream = tab.dialogRequests()
        let id = try XCTUnwrap(tab.simulateAddressSubmission(address))
        guard case .addressSave(let prompt) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
        XCTAssertTrue(EngineDialogRequest.addressSave(prompt).answerWithDefault())
        XCTAssertEqual(tab.dialogAnswers[id], .addressSave(.ignore))
    }

    /// Off the record, Autofill imports nothing (Chromium).
    func testNothingOfferedOffTheRecord() async throws {
        let tab = try await makeTab(FakeEngine(), offTheRecord: true)
        XCTAssertNil(tab.simulateAddressSubmission(address))
        XCTAssertNil(tab.simulateCardSubmission(card))
    }

    // MARK: Card

    /// A new card is offered without its number (last four digits, network, expiry); Save stores it
    /// and the next card field offers it.
    func testSavedCardIsOfferedNextTime() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = try XCTUnwrap(tab.simulateCardSubmission(card))
        guard case .cardSave(let prompt) = await take(1, from: stream).first else { return XCTFail("expected a card prompt") }
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.kind, .card)
        XCTAssertEqual(prompt.network, "Visa")
        XCTAssertEqual(prompt.lastFourDigits, "1111")
        XCTAssertEqual(prompt.expiration, "04/31")
        XCTAssertEqual(prompt.cardholderName, "Ada Lovelace")
        XCTAssertTrue(prompt.reply.send(.save))
        XCTAssertEqual(tab.dialogAnswers[id], .cardSave(.save))

        let popup = try XCTUnwrap(tab.simulateAutofillFieldFocus(.card))
        XCTAssertEqual(popup.session.state.suggestions.map(\.kind), [.creditCard])
        XCTAssertEqual(popup.session.state.suggestions.first?.mainText, "Visa ••••1111")
        XCTAssertNil(tab.simulateCardSubmission(card), "already saved: no prompt")
    }

    /// A card submitted with its security code offers both; the code of a saved card without one
    /// is a security-code-only prompt.
    func testSecurityCodeKinds() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        var withCode = card
        withCode.securityCode = "123"
        tab.simulateCardSubmission(card)
        guard case .cardSave(let plain) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
        plain.reply.send(.save)
        tab.simulateCardSubmission(withCode)
        guard case .cardSave(let codeOnly) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
        XCTAssertEqual(codeOnly.kind, .securityCodeOnly)
        codeOnly.reply.send(.decline)

        let other = FakeCard(number: "5555 5555 5555 4444", expirationMonth: 1, expirationYear: 2030, securityCode: "999")
        tab.simulateCardSubmission(other)
        guard case .cardSave(let both) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
        XCTAssertEqual(both.kind, .cardWithSecurityCode)
        XCTAssertEqual(both.network, "Mastercard")
    }

    /// Declining saves nothing; a card declined repeatedly is no longer offered.
    func testDeclinedCardStopsAfterTheLimit() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        for _ in 0..<FakeAutofillStore.maximumStrikes {
            tab.simulateCardSubmission(card)
            guard case .cardSave(let prompt) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
            prompt.reply.send(.decline)
        }
        XCTAssertTrue(engine.fakeAutofill.savedCards(profileID: profile).isEmpty)
        XCTAssertNil(tab.simulateCardSubmission(card))
    }

    /// The engine withdraws a prompt (navigation, tab closed); later answers are ignored.
    func testWithdrawnPromptIgnoresAnswers() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = try XCTUnwrap(tab.simulateCardSubmission(card))
        guard case .cardSave(let prompt) = await take(1, from: stream).first else { return XCTFail("expected a prompt") }
        tab.simulateDialogCancel(id)
        XCTAssertFalse(prompt.reply.send(.save))
        XCTAssertTrue(engine.fakeAutofill.savedCards(profileID: profile).isEmpty)
    }
}
