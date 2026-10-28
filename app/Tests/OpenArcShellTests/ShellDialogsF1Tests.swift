import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// F1 step 2 dialogs drawn by the shell (`docs/arc-spec/00-feature-inventory.md §A`, inferred
/// (analysis); looks and wording are ours: unknown): the unresponsive-page sheet (C22), the
/// client-certificate picker (C25) and the passkey / security-key sheet (C21).
@MainActor
final class ShellDialogsF1Tests: XCTestCase {
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

    // MARK: C22 unresponsive page

    /// A tab-modal sheet: "Leave Page" on the left, "Wait" as the default (Return) button.
    func testUnresponsivePageSheetOffersWaitAndLeave() async throws {
        let live = try await openPage("https://stuck.example")
        let center = model.controller.dialogs
        let id = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .sheet)
        XCTAssertEqual(presentation.buttons, ["Leave Page", "Wait"])
        XCTAssertTrue(presentation.message.contains("stuck.example"))
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false),
                       .unresponsivePage(.wait))
        XCTAssertTrue(center.answer(id, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false)))
        XCTAssertEqual(live.dialogAnswers[id], .unresponsivePage(.wait))
        XCTAssertNil(center.current(for: live.id))
    }

    /// "Leave Page" leaves: the renderer stops and the tab goes back.
    func testLeavePageButtonLeaves() async throws {
        let live = try await openPage("https://before.example")
        try await live.load(try XCTUnwrap(URL(string: "https://stuck.example")))
        let center = model.controller.dialogs
        let id = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        center.answer(id, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .unresponsivePage(.leave))
        for _ in 0..<400 {
            if await live.currentState().url?.host == "before.example" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let state = await live.currentState()
        XCTAssertEqual(state.url?.host, "before.example")
    }

    /// Escape (dismiss without a choice) waits; the page answering again removes the sheet.
    func testDismissWaitsAndResponsivePageRemovesTheSheet() async throws {
        let live = try await openPage("https://stuck.example")
        let center = model.controller.dialogs
        let first = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id) != nil }
        center.dismiss(first)
        XCTAssertEqual(live.dialogAnswers[first], .unresponsivePage(.wait))

        let second = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id)?.id == second }
        live.simulatePageResponsive()
        try await waitUntil { center.current(for: live.id) == nil }
        XCTAssertNil(live.dialogAnswers[second])
    }

    // MARK: C25 client certificate

    /// A sheet listing the identities; OK sends the chosen one, Cancel continues without one.
    func testClientCertificateSheet() async throws {
        let live = try await openPage("https://secure.example")
        let center = model.controller.dialogs
        let expiry = Date(timeIntervalSince1970: 2_000_000_000)
        let id = live.simulateClientCertificateRequest(hostPort: "secure.example:443", certificates: [
            ClientCertificate(subjectName: "Alice", issuerName: "Test CA", validUntil: expiry),
            ClientCertificate(subjectName: "Bob", issuerName: "Other CA", validUntil: expiry),
        ])
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .sheet)
        XCTAssertEqual(presentation.buttons, ["Cancel", "OK"])
        XCTAssertEqual(presentation.choices.map(\.title), ["Alice", "Bob"])
        XCTAssertTrue(presentation.choices[1].detail.contains("Other CA"))
        XCTAssertTrue(presentation.message.contains("secure.example:443"))
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false, selection: 1),
                       .clientCertificate(.continueWithout))
        let ok = DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false, selection: 1)
        XCTAssertEqual(ok, .clientCertificate(.select(index: 1)))
        XCTAssertTrue(center.answer(id, with: ok))
        XCTAssertEqual(live.dialogAnswers[id], .clientCertificate(.select(index: 1)))
    }

    /// Escape continues without a certificate.
    func testClientCertificateDismissContinuesWithout() async throws {
        let live = try await openPage("https://secure.example")
        let center = model.controller.dialogs
        let id = live.simulateClientCertificateRequest(hostPort: "secure.example:443", certificates: [
            ClientCertificate(subjectName: "Alice", issuerName: "Test CA", validUntil: Date(timeIntervalSince1970: 2_000_000_000)),
        ])
        try await waitUntil { center.current(for: live.id) != nil }
        center.dismiss(id)
        XCTAssertEqual(live.dialogAnswers[id], .clientCertificate(.continueWithout))
    }

    // MARK: C21 WebAuthn

    /// The sheet follows the flow: method list, PIN entry (new PINs compared in the shell), errors
    /// with Try Again; Cancel answers the request.
    func testWebAuthnPresentationFollowsTheSteps() {
        var state = WebAuthnState(
            operation: .create, relyingPartyID: "webauthn.io", userName: "alice", step: .chooseMethod,
            mechanisms: [.init(kind: .thisMac), .init(kind: .securityKey)]
        )
        var presentation = WebAuthnPresentation(state)
        XCTAssertEqual(presentation.title, "Create a passkey for webauthn.io")
        XCTAssertEqual(presentation.rows.map(\.title), ["This Mac", "Security key"])
        XCTAssertNil(presentation.acceptTitle)
        XCTAssertEqual(WebAuthnPresentation.rowCommand(for: state, row: 1), .selectMechanism(1))
        XCTAssertNil(WebAuthnPresentation.rowCommand(for: state, row: 5))

        state.step = .confirmMethod
        state.priorityMechanismIndex = 0
        presentation = WebAuthnPresentation(state)
        XCTAssertEqual(presentation.rows.map(\.title), ["This Mac"])
        XCTAssertEqual(presentation.acceptTitle, "Continue")

        state.step = .securityKey
        presentation = WebAuthnPresentation(state)
        XCTAssertTrue(presentation.showsProgress)
        XCTAssertNil(presentation.acceptTitle)

        state.step = .enterPIN
        state.pinError = .wrongPIN
        state.pinAttemptsRemaining = 2
        presentation = WebAuthnPresentation(state)
        XCTAssertEqual(presentation.input, .pin)
        XCTAssertEqual(presentation.errorText, "Incorrect PIN.")
        XCTAssertTrue(presentation.message.contains("2 attempts"))
        XCTAssertEqual(try WebAuthnPresentation.acceptCommand(for: state, pin: "1234", confirmation: "").get(), .providePIN("1234"))

        state.step = .setPIN
        state.pinError = .none
        XCTAssertEqual(WebAuthnPresentation(state).input, .newPIN)
        XCTAssertThrowsError(try WebAuthnPresentation.acceptCommand(for: state, pin: "1234", confirmation: "4321").get())
        XCTAssertEqual(try WebAuthnPresentation.acceptCommand(for: state, pin: "1234", confirmation: "1234").get(), .providePIN("1234"))

        state.step = .error(.keyNotRegistered)
        state.canRetry = true
        presentation = WebAuthnPresentation(state)
        XCTAssertEqual(presentation.acceptTitle, "Try Again")
        XCTAssertTrue(presentation.message.contains("webauthn.io"))

        state.step = .chooseAccount
        state.accounts = [.init(name: "alice@example.com", displayName: "Alice")]
        presentation = WebAuthnPresentation(state)
        XCTAssertEqual(presentation.rows.first?.title, "alice@example.com")
        XCTAssertEqual(WebAuthnPresentation.rowCommand(for: state, row: 0), .selectAccount(0))
    }

    /// The live sheet: queued like the other tab-modal dialogs, Cancel answers it, and the engine
    /// withdrawing it (macOS took over) removes it.
    func testWebAuthnSheetInTheQueue() async throws {
        let live = try await openPage("https://webauthn.io")
        let center = model.controller.dialogs
        let (first, _) = live.simulateWebAuthnDialog(WebAuthnState(operation: .signIn, relyingPartyID: "webauthn.io", step: .securityKey))
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        XCTAssertEqual(DialogPresentation(request).style, .webAuthn)
        XCTAssertTrue(center.answer(first, with: .webAuthn(.cancel)))
        XCTAssertEqual(live.dialogAnswers[first], .webAuthn(.cancel))

        let (second, _) = live.simulateWebAuthnDialog(WebAuthnState(operation: .create, relyingPartyID: "webauthn.io", step: .createPasskey))
        try await waitUntil { center.current(for: live.id)?.id == second }
        live.simulateDialogCancel(second)
        try await waitUntil { center.current(for: live.id) == nil }
        XCTAssertNil(live.dialogAnswers[second])
    }

    // MARK: C23 engine info bars

    /// Plan C23, `docs/arc-spec/00-feature-inventory.md` §A inferred (analysis): info bars are
    /// strips above the page, not queued: they show beside a queued sheet, all of them at once.
    func testInfoBarsShowBesideDialogsAndStack() async throws {
        let live = try await openPage("https://bars.example")
        let center = model.controller.dialogs
        let first = live.simulateInfoBar(message: "First bar", buttons: [.ok, .cancel], okTitle: "Allow", cancelTitle: "Deny")
        let second = live.simulateInfoBar(message: "Second bar")
        let sheet = live.simulateUnresponsivePage()
        try await waitUntil { center.infoBars(for: live.id).count == 2 && center.current(for: live.id) != nil }
        XCTAssertEqual(center.infoBars(for: live.id).map(\.id), [first, second], "oldest on top")
        XCTAssertEqual(center.current(for: live.id)?.id, sheet, "the sheet is not held up by the bars")
        let bar = try XCTUnwrap(center.infoBars(for: live.id).first)
        let presentation = DialogPresentation(.infoBar(bar))
        XCTAssertEqual(presentation.style, .infoBar)
        XCTAssertEqual(presentation.message, "First bar")
        XCTAssertEqual(presentation.buttons, ["Deny", "Allow"])
        XCTAssertEqual(DialogPresentation.answer(for: .infoBar(bar), button: 0, fieldValues: [], checkbox: false), .infoBar(.decline))
        XCTAssertEqual(DialogPresentation.answer(for: .infoBar(bar), button: 1, fieldValues: [], checkbox: false), .infoBar(.accept))
    }

    /// Plan C23: the close button dismisses the bar in the engine and removes the strip.
    func testInfoBarCloseRemovesIt() async throws {
        let live = try await openPage("https://bars.example")
        let center = model.controller.dialogs
        let id = live.simulateInfoBar(message: "Dismiss me")
        try await waitUntil { !center.infoBars(for: live.id).isEmpty }
        XCTAssertTrue(center.answer(id, with: .infoBar(.close)))
        XCTAssertEqual(live.dialogAnswers[id], .infoBar(.close))
        XCTAssertTrue(center.infoBars(for: live.id).isEmpty)
    }

    /// Plan C23: a bar the engine keeps after an answer comes back as a new request; a bar the
    /// engine withdraws disappears.
    func testInfoBarKeptOrWithdrawnByTheEngine() async throws {
        let live = try await openPage("https://bars.example")
        let center = model.controller.dialogs
        let kept = live.simulateInfoBar(message: "Stays", buttons: [.ok], okTitle: "Apply", keepsOpenOn: [.accept])
        try await waitUntil { center.infoBars(for: live.id).first?.id == kept }
        XCTAssertTrue(center.answer(kept, with: .infoBar(.accept)))
        try await waitUntil { center.infoBars(for: live.id).count == 1 && center.infoBars(for: live.id).first?.id != kept }
        let again = try XCTUnwrap(center.infoBars(for: live.id).first)
        XCTAssertEqual(again.message, "Stays")
        live.simulateDialogCancel(again.id)
        try await waitUntil { center.infoBars(for: live.id).isEmpty }
    }
}
