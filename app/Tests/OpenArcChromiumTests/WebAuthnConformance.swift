import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan B130 (docs/passkey-entitlement.md §4–5): iCloud Keychain passkeys in the real engine,
/// without Apple's browser passkey entitlement. The conformance engine starts with
/// `--openarc-fake-icloud-keychain`, which replaces macOS's iCloud Keychain API with the bridge's
/// stand-in (oac_webauthn_test_keychain.mm): two passkeys for any site, alice@ and bob@; create()
/// fails as for an excluded credential, get() as for "no passkeys". Run from
/// `testChromiumEngineConformance`.
///
/// What it shows:
/// - the tab's window reaches //chrome (patch 0065): device/fido creates the iCloud Keychain
///   discovery only with a window, so iCloud Keychain rows in the dialog prove it;
/// - iCloud Keychain passkeys and the generic iCloud Keychain method reach the Swift dialog
///   (`passkeyInICloudKeychain`, `iCloudKeychain`);
/// - choosing one hands over to macOS: the engine withdraws the dialog, and what macOS answers
///   reaches the page (and, for "no passkeys", a new error step in the dialog).
/// [00 §A] inferred (analysis): the passkey dialog exists and the shell draws it.
enum WebAuthnTestPage {
    /// `runGet()` / `runCreate()` start a request and put its outcome in the title
    /// ("get:<result or error name>", "create:<…>").
    static let html = """
    <!doctype html><meta charset="utf-8"><title>webauthn</title><body>B130</body>
    <script>
    const challenge = () => crypto.getRandomValues(new Uint8Array(32));
    function report(prefix, promise) {
      promise.then(() => { document.title = prefix + 'ok'; },
                   (e) => { document.title = prefix + e.name; });
    }
    function runGet() {
      report('get:', navigator.credentials.get({publicKey: {
        challenge: challenge(), rpId: 'localhost', allowCredentials: [], userVerification: 'preferred'}}));
      return 'started';
    }
    function runCreate() {
      report('create:', navigator.credentials.create({publicKey: {
        challenge: challenge(), rp: {id: 'localhost', name: 'B130'},
        user: {id: new Uint8Array([7]), name: 'carol@example.com', displayName: 'Carol'},
        pubKeyCredParams: [{type: 'public-key', alg: -7}],
        authenticatorSelection: {residentKey: 'required', userVerification: 'preferred'}}}));
      return 'started';
    }
    </script>
    """
}

/// Puts a tab's page view into a real window (the shell's `SurfaceHost`): WebAuthn needs a
/// visible page, and the iCloud Keychain path needs the page's NSWindow.
@MainActor
private final class WindowSurfaceHost: SurfaceHost {
    let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Open Arc B130 test"
        // Above other apps' windows, so the page is never occluded (occluded pages are not
        // "focused", and WebAuthn refuses them).
        window.level = .floating
        window.orderFrontRegardless()
    }

    func show(_ content: SurfaceContent) {
        guard case .native(let object) = content, let view = object as? NSView,
              let contentView = window.contentView else { return }
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
    }

    func clear() {
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Collects a tab's dialog requests on the main actor, for polling.
@MainActor
private final class DialogInbox {
    private(set) var received: [EngineDialogRequest] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<EngineDialogRequest>) {
        task = Task { @MainActor [weak self] in
            for await request in stream { self?.received.append(request) }
        }
    }

    func stop() { task?.cancel() }
}

extension ChromiumEngineConformanceTests {
    @MainActor
    func checkICloudKeychainPasskeys(_ engine: ChromiumEngine, server: ProfileIsolationServer) async throws {
        let tab = try await engine.makeTab(TabConfiguration(profileID: UUID()))
        let host = WindowSurfaceHost()
        tab.surface.attach(to: host)
        defer {
            tab.surface.detach()
            host.window.close()
        }
        // http://localhost is a secure context and may use the RP ID "localhost".
        let url = try XCTUnwrap(URL(string: "http://localhost:\(server.port)/webauthn"))
        try await tab.load(url)
        try await waitForState(tab) { $0.title == "webauthn" && !$0.loadState.isLoading }

        let inbox = DialogInbox(tab.dialogRequests())
        defer { inbox.stop() }

        // Sign in: both iCloud Keychain passkeys are rows of the method list.
        let started = try await tab.evaluateJavaScript("runGet()")
        XCTAssertEqual(started, "started")
        let first = try await nextWebAuthnDialog(inbox, after: 0)
        let state = first.session.state
        XCTAssertEqual(state.step, .chooseMethod, "two accounts: Chrome lists them")
        let passkeys = state.mechanisms.filter { $0.kind == .passkeyInICloudKeychain }
        XCTAssertEqual(passkeys.map(\.title).sorted(), ["alice@example.com", "bob@example.com"],
                       "iCloud Keychain passkeys reach the dialog (so the discovery had the tab's window): \(state)")
        XCTAssertTrue(passkeys.allSatisfy { $0.subtitle == "Open Arc Test Keychain" }, "\(passkeys)")

        // Choosing one hands over to macOS: the engine withdraws our dialog.
        let alice = try XCTUnwrap(state.mechanisms.firstIndex { $0.title == "alice@example.com" })
        first.session.send(.selectMechanism(alice))
        try await waitUntil("the engine withdraws the dialog when macOS takes over") { first.reply.isFinished }

        // macOS (the stand-in) has no passkey after all: //chrome shows its error in a new dialog.
        let error = try await nextWebAuthnDialog(inbox, after: 1)
        try await waitUntil("no-passkeys step: \(error.session.state.step)") {
            error.session.state.step == .error(.noPasskeys)
        }
        XCTAssertTrue(error.reply.send(.cancel))
        try await waitForState(tab) { $0.title == "get:NotAllowedError" }

        // Create: the generic iCloud Keychain method; choosing it hands over to macOS, whose answer
        // (an excluded credential) reaches the page as InvalidStateError.
        let creating = try await tab.evaluateJavaScript("runCreate()")
        XCTAssertEqual(creating, "started")
        let create = try await nextWebAuthnDialog(inbox, after: 2)
        try await chooseICloudKeychain(in: create)
        try await waitUntil("the engine withdraws the create dialog") { create.reply.isFinished }
        try await waitForState(tab) { $0.title == "create:InvalidStateError" }

        await engine.closeTab(tab.id)
    }

    /// Picks the generic iCloud Keychain method: from the list, or by going back to the list when
    /// //chrome showed another method first (for example passkeys on this Mac).
    @MainActor
    private func chooseICloudKeychain(in dialog: WebAuthnDialog) async throws {
        for _ in 0..<3 {
            let state = dialog.session.state
            if let index = state.mechanisms.firstIndex(where: { $0.kind == .iCloudKeychain }) {
                if state.step == .chooseMethod {
                    dialog.session.send(.selectMechanism(index))
                    return
                }
                if state.step == .confirmMethod, state.priorityMechanismIndex == index {
                    dialog.session.send(.accept)
                    return
                }
            }
            XCTAssertTrue(state.canChooseAnotherMethod, "no iCloud Keychain method in \(state)")
            dialog.session.send(.chooseAnotherMethod)
            try await waitUntil("back to the method list") { dialog.session.state.step == .chooseMethod }
        }
        XCTFail("no iCloud Keychain method; last state: \(dialog.session.state)")
    }

    /// The WebAuthn dialog that arrives after `count` earlier dialog requests.
    @MainActor
    private func nextWebAuthnDialog(_ inbox: DialogInbox, after count: Int) async throws -> WebAuthnDialog {
        try await waitUntil("dialog request #\(count + 1)") { inbox.received.count > count }
        guard case .webAuthn(let dialog) = inbox.received[count] else {
            XCTFail("expected a WebAuthn dialog, got \(inbox.received[count])")
            throw CancellationError()
        }
        return dialog
    }

    /// Polls `condition` on the main actor for at most 30 s.
    @MainActor
    private func waitUntil(_ what: @autoclosure () -> String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("timed out: \(what())")
        throw CancellationError()
    }
}
