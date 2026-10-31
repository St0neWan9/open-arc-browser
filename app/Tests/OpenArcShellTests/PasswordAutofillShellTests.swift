import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcDesign
@testable import OpenArcShell

/// Plan C13: the shell draws the password save prompt and the autofill dropdown.
/// `docs/arc-spec/00-feature-inventory.md §A`, observed: passwords and autofill are inherited from
/// the engine and their prompts are drawn by the shell, style not captured. Placement and wording
/// are ours (inferred from Chromium's behavior; look unknown).
@MainActor
final class PasswordAutofillShellTests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private func openPage(_ address: String) async throws -> FakeTab {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: address)))
        let id = try XCTUnwrap(opened)
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: Save prompt

    /// [00 §A] observed (shell-drawn); wording and buttons inferred from Chromium's save bubble.
    func testSavePromptHangsUnderTheURLBoxAndSavesTheEditedUsername() async throws {
        let live = try await openPage("https://login.example")
        let center = model.controller.dialogs
        let id = live.simulatePasswordSavePrompt(username: "ada", passwordLength: 4)
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .permissionBubble, "bubble under the URL box, like Chrome's anchored bubble")
        XCTAssertEqual(presentation.title, "Save password?")
        XCTAssertEqual(presentation.message, "Password: ••••")
        XCTAssertEqual(presentation.fields, [.text(placeholder: "Username", initial: "ada")])
        XCTAssertEqual(presentation.buttons, ["Never", "Not Now", "Save"])
        center.answer(id, with: DialogPresentation.answer(for: request, button: 2, fieldValues: [" grace "], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .passwordSave(.save(username: "grace")))
        XCTAssertNil(center.current(for: live.id))
    }

    func testSavePromptButtons() async throws {
        let live = try await openPage("https://login.example")
        let center = model.controller.dialogs
        let save = live.simulatePasswordSavePrompt(username: "ada")
        try await waitUntil { center.current(for: live.id)?.id == save }
        var request = try XCTUnwrap(center.current(for: live.id))
        // Unchanged username: nil (keep the submitted one).
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 2, fieldValues: ["ada"], checkbox: false), .passwordSave(.save(username: nil)))
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 1, fieldValues: ["ada"], checkbox: false), .passwordSave(.decline))
        center.answer(save, with: DialogPresentation.answer(for: request, button: 0, fieldValues: ["ada"], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[save], .passwordSave(.neverForThisSite))

        let update = live.simulatePasswordSavePrompt(username: "ada", kind: .update)
        try await waitUntil { center.current(for: live.id)?.id == update }
        request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).title, "Update password?")
        XCTAssertEqual(DialogPresentation(request).buttons, ["Not Now", "Update"])
        center.dismiss(update)
        XCTAssertEqual(live.dialogAnswers[update], .passwordSave(.dismiss))
    }

    // MARK: Address and card save prompts (C30)

    /// Plan C30, [00 §A] observed (shell-drawn, style not captured): the address prompt hangs under
    /// the URL box like the password prompt; Save stores the address and the next address field
    /// offers it. Wording is ours (unknown).
    func testAddressPromptSavesAndIsOfferedNextTime() async throws {
        let live = try await openPage("https://shop.example")
        let center = model.controller.dialogs
        let address = FakeAddress(name: "Ada Lovelace", street: "12 Example Street", city: "Springfield", postalCode: "12345",
                                  email: "ada@example.test")
        let id = try XCTUnwrap(live.simulateAddressSubmission(address))
        try await waitUntil { center.current(for: live.id)?.id == id }
        let request = try XCTUnwrap(center.current(for: live.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .permissionBubble)
        XCTAssertEqual(presentation.title, "Save address?")
        XCTAssertTrue(presentation.message.contains("12 Example Street"))
        XCTAssertTrue(presentation.message.contains("ada@example.test"))
        XCTAssertEqual(presentation.buttons, ["No Thanks", "Save"])
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false), .addressSave(.decline))
        center.answer(id, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .addressSave(.save))
        XCTAssertNil(center.current(for: live.id))
        XCTAssertNotNil(live.simulateAutofillFieldFocus(.address))
        try await waitUntil { center.autofillPopup(for: live.id)?.session.state.suggestions.first?.kind == .address }
    }

    /// Plan C30: an update prompt lists old → new values.
    func testAddressUpdatePromptListsChanges() async throws {
        let live = try await openPage("https://shop.example")
        let center = model.controller.dialogs
        var address = FakeAddress(name: "Ada Lovelace", street: "12 Example Street", city: "Springfield", postalCode: "12345")
        let first = try XCTUnwrap(live.simulateAddressSubmission(address))
        try await waitUntil { center.current(for: live.id)?.id == first }
        center.answer(first, with: .addressSave(.save))
        address.phone = "+1 555 0100"
        let update = try XCTUnwrap(live.simulateAddressSubmission(address))
        try await waitUntil { center.current(for: live.id)?.id == update }
        let presentation = DialogPresentation(try XCTUnwrap(center.current(for: live.id)))
        XCTAssertEqual(presentation.title, "Update address?")
        XCTAssertEqual(presentation.message, "Phone: +1 555 0100")
        XCTAssertEqual(presentation.buttons, ["No Thanks", "Update"])
    }

    /// Plan C30: the card prompt shows network, last four digits and expiry, never the number;
    /// No Thanks saves nothing; Escape (dismiss) answers `.ignore`.
    func testCardPrompt() async throws {
        let live = try await openPage("https://shop.example")
        let center = model.controller.dialogs
        let card = FakeCard(number: "4111111111111111", expirationMonth: 4, expirationYear: 2031, cardholderName: "Ada Lovelace")
        let id = try XCTUnwrap(live.simulateCardSubmission(card))
        try await waitUntil { center.current(for: live.id)?.id == id }
        let request = try XCTUnwrap(center.current(for: live.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .permissionBubble)
        XCTAssertEqual(presentation.title, "Save card?")
        XCTAssertEqual(presentation.message, "Visa ••••1111\nExpires 04/31\nAda Lovelace")
        XCTAssertFalse(presentation.message.contains("4111111111111111"))
        center.answer(id, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .cardSave(.decline))
        XCTAssertTrue(engine.fakeAutofill.savedCards(profileID: live.profileID).isEmpty)

        let again = try XCTUnwrap(live.simulateCardSubmission(card))
        try await waitUntil { center.current(for: live.id)?.id == again }
        center.dismiss(again)
        XCTAssertEqual(live.dialogAnswers[again], .cardSave(.ignore))
    }

    // MARK: Autofill dropdown

    /// Not queued: it shows beside a queued dialog, a newer one replaces it, and withdrawing it
    /// removes it.
    func testAutofillDropdownIsNotQueued() async throws {
        let live = try await openPage("https://login.example")
        let center = model.controller.dialogs
        let alert = live.simulateJavaScriptDialog(.alert, message: "hi")
        let state = AutofillPopupState(
            suggestions: [AutofillSuggestion(kind: .password, mainText: "ada", label: "••••")],
            elementBounds: EngineRect(x: 20, y: 100, width: 240, height: 28)
        )
        let (first, _) = live.simulateAutofillPopup(state)
        try await waitUntil { center.autofillPopup(for: live.id)?.id == first }
        XCTAssertEqual(center.current(for: live.id)?.id, alert, "the queued dialog is unaffected")
        XCTAssertEqual(center.pendingCount(for: live.id), 1)

        let (second, session) = live.simulateAutofillPopup(state)
        try await waitUntil { center.autofillPopup(for: live.id)?.id == second }

        // Choosing a row: the engine fills and withdraws the dropdown.
        session.send(.accept(0))
        try await waitUntil { center.autofillPopup(for: live.id) == nil }
        XCTAssertEqual(live.autofillCommands, [.accept(0)])
    }

    func testClosingTheTabDismissesTheDropdown() async throws {
        let live = try await openPage("https://login.example")
        let center = model.controller.dialogs
        let (id, _) = live.simulateAutofillPopup(AutofillPopupState(
            suggestions: [AutofillSuggestion(kind: .autocomplete, mainText: "x")],
            elementBounds: EngineRect(x: 0, y: 0, width: 100, height: 20)
        ))
        try await waitUntil { center.autofillPopup(for: live.id) != nil }
        center.stopObserving(live.id)
        XCTAssertNil(center.autofillPopup(for: live.id))
        XCTAssertEqual(live.dialogAnswers[id], .autofillPopup(.dismiss))
    }

    /// Under the field; above it when there is no room below; right-aligned for right-to-left
    /// fields; never outside the panel. inferred (Chromium's popup placement).
    func testDropdownPlacement() {
        let rows = [AutofillSuggestion(kind: .password, mainText: "ada", label: "••••")]
        let panel = CGSize(width: 800, height: 600)
        var state = AutofillPopupState(suggestions: rows, elementBounds: EngineRect(x: 20, y: 100, width: 300, height: 28))
        var frame = AutofillDropdownPlacement.frame(for: state, in: panel)
        XCTAssertEqual(frame.minX, 20)
        XCTAssertEqual(frame.minY, 128 + AutofillDropdownTokens.gap)
        XCTAssertEqual(frame.width, 300)

        state.elementBounds = EngineRect(x: 20, y: 570, width: 100, height: 24)
        frame = AutofillDropdownPlacement.frame(for: state, in: panel)
        XCTAssertEqual(frame.width, AutofillDropdownTokens.minWidth, "at least the minimum width")
        XCTAssertEqual(frame.maxY, 570 - AutofillDropdownTokens.gap, accuracy: 0.001, "above the field near the bottom")

        state.elementBounds = EngineRect(x: 700, y: 100, width: 90, height: 24)
        state.isRightToLeft = true
        frame = AutofillDropdownPlacement.frame(for: state, in: panel)
        XCTAssertEqual(frame.maxX, 790, accuracy: 0.001, "right-aligned to the field")

        state.isRightToLeft = false
        frame = AutofillDropdownPlacement.frame(for: state, in: panel)
        XCTAssertLessThanOrEqual(frame.maxX, panel.width, "kept inside the panel")
    }

    func testDropdownHeightCountsSeparatorsAndCapsRows() {
        let row = AutofillSuggestion(kind: .autocomplete, mainText: "x")
        let separator = AutofillSuggestion(kind: .separator, mainText: "", isSelectable: false, isAcceptable: false)
        XCTAssertEqual(
            AutofillDropdownPlacement.height(of: [row, separator, row]),
            2 * AutofillDropdownTokens.singleLineRowHeight + AutofillDropdownTokens.separatorHeight + 2 * AutofillDropdownTokens.padding
        )
        let credential = AutofillSuggestion(kind: .password, mainText: "ada", label: "••••")
        XCTAssertEqual(AutofillDropdownPlacement.rowHeight(of: credential), AutofillDropdownTokens.rowHeight)
        let many = Array(repeating: row, count: 20)
        XCTAssertEqual(
            AutofillDropdownPlacement.height(of: many),
            CGFloat(AutofillDropdownTokens.maxVisibleRows) * AutofillDropdownTokens.singleLineRowHeight + 2 * AutofillDropdownTokens.padding
        )
    }

    /// Plan B148: the dropdown looks like the engine's own, which Arc ships ([00 §A]: prompts drawn
    /// for the engine; the popup views are in Arc's engine framework, inferred (analysis)): an
    /// 8 pt card with a 4 pt inset, 36 pt one-line rows and 52 pt two-line rows, 156–456 pt wide,
    /// 1 pt below the field, Medium 13 credentials over a Regular 13 secondary line.
    func testDropdownMetricsFollowTheEnginePopup() {
        XCTAssertEqual(AutofillDropdownTokens.cornerRadius, 8)
        XCTAssertEqual(AutofillDropdownTokens.padding, 4)
        XCTAssertEqual(AutofillDropdownTokens.rowCornerRadius, 4)
        XCTAssertEqual(AutofillDropdownTokens.singleLineRowHeight, 36)
        XCTAssertEqual(AutofillDropdownTokens.rowHeight, 52)
        XCTAssertEqual(AutofillDropdownTokens.minWidth, 156)
        XCTAssertEqual(AutofillDropdownTokens.maxWidth, 456)
        XCTAssertEqual(AutofillDropdownTokens.gap, 1)
        XCTAssertEqual(AutofillDropdownTokens.iconSize, 16)
        XCTAssertEqual(AutofillDropdownTokens.mainText, TextStyle(size: 13, weight: .medium))
        XCTAssertEqual(AutofillDropdownTokens.secondaryText, TextStyle(size: 13))

        // A sign-in dropdown: a password, a passkey (a command with a second line), a divider and
        // a footer action. Credentials show the site globe; footer actions a gear and lighter text.
        let password = AutofillSuggestion(kind: .password, mainText: "ada@example.com", label: "••••••")
        let passkey = AutofillSuggestion(kind: .action, mainText: "ada@example.com", label: "Passkey")
        let footer = AutofillSuggestion(kind: .action, mainText: "Manage Passwords…")
        XCTAssertEqual(AutofillDropdownView.symbol(for: password), "globe")
        XCTAssertEqual(AutofillDropdownView.symbol(for: passkey), "globe")
        XCTAssertEqual(AutofillDropdownView.symbol(for: footer), "gearshape")
        XCTAssertFalse(AutofillDropdownView.isFooter(passkey))
        XCTAssertTrue(AutofillDropdownView.isFooter(footer))
    }

    /// Plan B148, inferred (analysis): with no room below the field the dropdown opens above it
    /// only when there is more room above; otherwise it stays below (and scrolls).
    func testDropdownOpensAboveOnlyWithMoreRoomThere() {
        let rows = Array(repeating: AutofillSuggestion(kind: .password, mainText: "ada", label: "••••"), count: 6)
        let panel = CGSize(width: 800, height: 400)
        var state = AutofillPopupState(suggestions: rows, elementBounds: EngineRect(x: 20, y: 120, width: 300, height: 30))
        XCTAssertEqual(AutofillDropdownPlacement.frame(for: state, in: panel).minY, 150 + AutofillDropdownTokens.gap, "more room below")
        state.elementBounds = EngineRect(x: 20, y: 330, width: 300, height: 30)
        let frame = AutofillDropdownPlacement.frame(for: state, in: panel)
        XCTAssertEqual(frame.maxY, 330 - AutofillDropdownTokens.gap, accuracy: 0.001, "more room above")
    }
}
