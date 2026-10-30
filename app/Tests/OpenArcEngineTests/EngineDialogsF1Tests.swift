import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// F1 step 2 dialog requests drawn by the shell (`docs/arc-spec/00-feature-inventory.md §A`,
/// inferred (analysis); looks unknown): the unresponsive-page prompt (C22), the client-certificate
/// picker (C25) and the passkey / security-key dialog (C21).
final class EngineDialogsF1Tests: XCTestCase {
    private let profile = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

    private func makeTab(_ engine: FakeEngine, url: String = "https://stuck.example") async throws -> FakeTab {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: url)))
        return try XCTUnwrap(tab as? FakeTab)
    }

    private func take<T: Sendable>(_ count: Int, from stream: AsyncStream<T>) async -> [T] {
        var result: [T] = []
        guard count > 0 else { return result }
        for await element in stream {
            result.append(element)
            if result.count == count { break }
        }
        return result
    }

    private func waitUntil(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: C22 unresponsive page ([00 §A] inferred (analysis): wait or leave)

    /// Waiting keeps the page: no crash, no navigation; the engine may ask again later.
    func testUnresponsivePageWaitKeepsThePage() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulateUnresponsivePage()
        let requests = await take(1, from: stream)
        guard case .unresponsivePage(let prompt) = requests.first else { return XCTFail("expected the prompt") }
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.origin?.displayHost, "stuck.example")
        XCTAssertTrue(prompt.reply.send(.wait))
        XCTAssertEqual(tab.dialogAnswers[id], .unresponsivePage(.wait))
        let state = await tab.currentState()
        XCTAssertFalse(state.isCrashed)
        XCTAssertEqual(state.url?.host, "stuck.example")
    }

    /// Leaving stops the renderer and goes back to the previous page when there is one.
    func testUnresponsivePageLeaveGoesBack() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine, url: "https://before.example")
        try await tab.load(try XCTUnwrap(URL(string: "https://stuck.example")))
        let events = tab.events()
        let stream = tab.dialogRequests()
        let id = tab.simulateUnresponsivePage()
        guard case .unresponsivePage(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the prompt") }
        prompt.reply.send(.leave)
        XCTAssertEqual(tab.dialogAnswers[id], .unresponsivePage(.leave))
        var sawCrash = false
        for await event in events {
            if case .renderProcessGone = event { sawCrash = true }
            if case .urlChanged(let url) = event, url?.host == "before.example", sawCrash { break }
        }
        XCTAssertTrue(sawCrash)
        let state = await tab.currentState()
        XCTAssertEqual(state.url?.host, "before.example")
        XCTAssertFalse(state.isCrashed, "the previous page loads in a new renderer")
    }

    /// With nothing to go back to, leaving leaves the crashed page (the shell's Reload view).
    func testUnresponsivePageLeaveWithoutHistoryStaysCrashed() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        tab.simulateUnresponsivePage()
        guard case .unresponsivePage(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the prompt") }
        prompt.reply.send(.leave)
        let state = await tab.currentState()
        XCTAssertTrue(state.isCrashed)
    }

    /// The page answering again withdraws the prompt (`.dialogCancelled`); a late answer is ignored.
    func testResponsivePageWithdrawsThePrompt() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        let stream = tab.dialogRequests()
        let id = tab.simulateUnresponsivePage()
        guard case .unresponsivePage(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the prompt") }
        tab.simulatePageResponsive()
        var cancelled = false
        for await event in events {
            if case .dialogCancelled(let cancelledID) = event, cancelledID == id { cancelled = true; break }
        }
        XCTAssertTrue(cancelled)
        XCTAssertTrue(prompt.reply.isFinished)
        XCTAssertFalse(prompt.reply.send(.leave))
        XCTAssertNil(tab.dialogAnswers[id])
        let state = await tab.currentState()
        XCTAssertFalse(state.isCrashed)
    }

    /// Dropped unanswered, the prompt waits (its default).
    func testUnresponsivePageDefaultIsWait() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        // No subscriber: the request is released at once and answered with its default.
        let id = tab.simulateUnresponsivePage()
        try await waitUntil { tab.dialogAnswers[id] != nil }
        XCTAssertEqual(tab.dialogAnswers[id], .unresponsivePage(.wait))
    }

    // MARK: C25 client certificate ([00 §A] inferred (analysis): picker for sites that ask)

    private func certificates() -> [ClientCertificate] {
        [
            ClientCertificate(subjectName: "Alice", issuerName: "Test CA", validUntil: Date(timeIntervalSince1970: 2_000_000_000)),
            ClientCertificate(subjectName: "Bob", issuerName: "Test CA", validUntil: Date(timeIntervalSince1970: 2_000_000_000)),
        ]
    }

    /// The prompt lists the identities; choosing one sends its index.
    func testClientCertificateSelect() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulateClientCertificateRequest(hostPort: "localhost:8443", certificates: certificates())
        guard case .clientCertificate(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the picker") }
        XCTAssertEqual(prompt.id, id)
        XCTAssertEqual(prompt.hostPort, "localhost:8443")
        XCTAssertEqual(prompt.origin?.displayHost, "localhost:8443")
        XCTAssertEqual(prompt.certificates.map(\.subjectName), ["Alice", "Bob"])
        XCTAssertTrue(prompt.reply.send(.select(index: 1)))
        XCTAssertEqual(tab.dialogAnswers[id], .clientCertificate(.select(index: 1)))
    }

    /// Dropped unanswered (Cancel), the handshake continues without a certificate.
    func testClientCertificateDefaultContinuesWithout() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let id = tab.simulateClientCertificateRequest(hostPort: "localhost:8443", certificates: certificates())
        try await waitUntil { tab.dialogAnswers[id] != nil }
        XCTAssertEqual(tab.dialogAnswers[id], .clientCertificate(.continueWithout))
    }

    /// The engine withdraws the picker (another prompt for the host was answered); a late answer is
    /// ignored.
    func testClientCertificateWithdrawn() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let id = tab.simulateClientCertificateRequest(hostPort: "localhost:8443", certificates: certificates())
        guard case .clientCertificate(let prompt) = await take(1, from: stream).first else { return XCTFail("expected the picker") }
        tab.simulateDialogCancel(id)
        XCTAssertTrue(prompt.reply.isFinished)
        XCTAssertFalse(prompt.reply.send(.select(index: 0)))
        XCTAssertNil(tab.dialogAnswers[id])
    }

    // MARK: C21 WebAuthn ([00 §A] inferred (analysis): passkey / security-key dialog)

    /// The dialog carries the flow's step; the shell's choices go to the engine as commands, and
    /// later steps arrive on the same session.
    func testWebAuthnSessionCarriesStepsAndCommands() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine, url: "https://webauthn.example")
        let stream = tab.dialogRequests()
        let methods = WebAuthnState(
            operation: .create, relyingPartyID: "webauthn.example", userName: "alice", step: .chooseMethod,
            mechanisms: [.init(kind: .thisMac), .init(kind: .securityKey)]
        )
        let (id, session) = tab.simulateWebAuthnDialog(methods)
        guard case .webAuthn(let dialog) = await take(1, from: stream).first else { return XCTFail("expected the dialog") }
        XCTAssertEqual(dialog.id, id)
        XCTAssertEqual(dialog.origin?.displayHost, "webauthn.example")
        XCTAssertEqual(dialog.session.state, methods)

        let updates = dialog.session.updates()
        dialog.session.send(.selectMechanism(1))
        var pinStep = methods
        pinStep.step = .enterPIN
        pinStep.pinAttemptsRemaining = 8
        session.update(pinStep)
        dialog.session.send(.providePIN("1234"))
        let seen = await take(2, from: updates)
        XCTAssertEqual(seen.map(\.step), [.chooseMethod, .enterPIN])
        XCTAssertEqual(tab.webAuthnCommands, [.selectMechanism(1), .providePIN("1234")])
        XCTAssertFalse(dialog.reply.isFinished, "commands do not answer the request")
    }

    /// Cancel answers the request; the session ends.
    func testWebAuthnCancel() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let stream = tab.dialogRequests()
        let (id, _) = tab.simulateWebAuthnDialog(WebAuthnState(operation: .signIn, relyingPartyID: "stuck.example", step: .securityKey))
        guard case .webAuthn(let dialog) = await take(1, from: stream).first else { return XCTFail("expected the dialog") }
        let updates = dialog.session.updates()
        XCTAssertTrue(dialog.reply.send(.cancel))
        XCTAssertEqual(tab.dialogAnswers[id], .webAuthn(.cancel))
        var count = 0
        for await _ in updates { count += 1 }
        XCTAssertEqual(count, 1, "the stream finishes after the current state")
    }

    /// The engine withdraws the dialog when macOS takes over or the flow completes.
    func testWebAuthnWithdrawnByEngine() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine)
        let events = tab.events()
        let stream = tab.dialogRequests()
        let (id, _) = tab.simulateWebAuthnDialog(WebAuthnState(operation: .create, relyingPartyID: "stuck.example", step: .createPasskey))
        guard case .webAuthn(let dialog) = await take(1, from: stream).first else { return XCTFail("expected the dialog") }
        tab.simulateDialogCancel(id)
        for await event in events {
            if case .dialogCancelled(let cancelled) = event, cancelled == id { break }
        }
        XCTAssertTrue(dialog.reply.isFinished)
        XCTAssertNil(tab.dialogAnswers[id])
    }

    /// Plan B130 (passkey-entitlement.md §4.2; [00 §A] inferred (analysis)): iCloud Keychain
    /// methods and passkeys reach the shell; choosing one is a plain command, and macOS taking over
    /// withdraws the dialog without an answer.
    func testWebAuthnICloudKeychainMechanismsHandOverToMacOS() async throws {
        let engine = FakeEngine()
        let tab = try await makeTab(engine, url: "https://webauthn.example")
        let events = tab.events()
        let stream = tab.dialogRequests()
        let methods = WebAuthnState(
            operation: .signIn, relyingPartyID: "webauthn.example", step: .chooseMethod,
            mechanisms: [
                .init(kind: .passkeyInICloudKeychain, title: "alice@example.com", subtitle: "Passwords"),
                .init(kind: .iCloudKeychain),
                .init(kind: .securityKey),
            ]
        )
        let (id, _) = tab.simulateWebAuthnDialog(methods)
        guard case .webAuthn(let dialog) = await take(1, from: stream).first else { return XCTFail("expected the dialog") }
        XCTAssertEqual(dialog.session.state.mechanisms.map(\.kind), [.passkeyInICloudKeychain, .iCloudKeychain, .securityKey])
        XCTAssertEqual(dialog.session.state.mechanisms.first?.subtitle, "Passwords")

        dialog.session.send(.selectMechanism(0))
        XCTAssertEqual(tab.webAuthnCommands, [.selectMechanism(0)])
        tab.simulateDialogCancel(id)
        for await event in events {
            if case .dialogCancelled(let cancelled) = event, cancelled == id { break }
        }
        XCTAssertTrue(dialog.reply.isFinished)
        XCTAssertNil(tab.dialogAnswers[id], "macOS's sheet answers the page, not the shell")
    }
}
