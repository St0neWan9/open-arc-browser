import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan B148 (user report on 0.1.3: choosing a saved password on Google's sign-in page went wrong).
/// The page follows the shape of a two-step sign-in: an identifier page whose field asks for
/// `username webauthn` (a conditional passkey request runs beside the password suggestions; with
/// the test keychain its passkeys join the dropdown a moment later), then, on the same document, a
/// password page with a hidden username and a `current-password` field. A credential for the site
/// is saved through the CSV import; the dropdown offers it on both steps; choosing it fills the
/// form and closes the dropdown.
///
/// Regression: on the password step the dropdown is shown again for new rows, and the engine
/// re-armed its accidental-click guard only when it first showed. A choice then filled nothing
/// more, and the dropdown stayed open over the page, taking every later click (patch 0070). Run
/// from `testChromiumEngineConformance`.
enum PasswordFillTestPage {
    /// `step()` swaps the identifier form for the password form, as a two-step sign-in does
    /// without a navigation. `values()` reports the fields' values.
    static let html = """
    <!doctype html><meta charset="utf-8"><title>signin</title>
    <style>body{margin:20px;font:15px -apple-system}input{display:block;width:300px;height:32px;margin:8px 0}</style>
    <body>
    <form id="identifier" action="/signin/next" onsubmit="return false">
      <input type="email" name="identifier" id="identifierId" autocomplete="username webauthn" spellcheck="false">
      <button type="submit">Next</button>
    </form>
    </body>
    <script>
    if (window.PublicKeyCredential && PublicKeyCredential.isConditionalMediationAvailable) {
      PublicKeyCredential.isConditionalMediationAvailable().then((ok) => {
        if (!ok) return;
        navigator.credentials.get({mediation: 'conditional', publicKey: {
          challenge: crypto.getRandomValues(new Uint8Array(32)), allowCredentials: []}}).catch(() => {});
      });
    }
    function focusField(id) { document.getElementById(id).focus(); return 'focused'; }
    function step() {
      const id = document.getElementById('identifierId').value;
      history.pushState({}, '', '/signin/challenge/pwd');
      document.body.innerHTML = '<form id="password" method="post" action="/signin/done">'
        + '<input type="email" name="identifier" autocomplete="username" value="' + id + '" hidden>'
        + '<input type="password" name="Passwd" id="Passwd" autocomplete="current-password">'
        + '<button type="submit">Next</button></form>';
      return 'stepped';
    }
    function values() {
      return Array.from(document.querySelectorAll('input')).map((i) => i.name + '=' + i.value).join('&');
    }
    </script>
    """
}

/// A window for the tab's page view: autofill needs a visible, focused page.
@MainActor
private final class FillTestSurfaceHost: SurfaceHost {
    let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 520, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Open Arc B148 test"
        window.level = .floating
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
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

/// Collects a tab's autofill dropdowns on the main actor.
@MainActor
private final class AutofillInbox {
    private(set) var popups: [AutofillPopup] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<EngineDialogRequest>) {
        task = Task { @MainActor [weak self] in
            for await request in stream {
                if case .autofillPopup(let popup) = request { self?.popups.append(popup) }
            }
        }
    }

    func stop() { task?.cancel() }
}

extension ChromiumEngineConformanceTests {
    @MainActor
    func checkPasswordFill(_ engine: ChromiumEngine, server: ProfileIsolationServer, profileID: UUID) async throws {
        let origin = "http://localhost:\(server.port)"
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openarc-b148-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let csv = root.appendingPathComponent("Passwords.csv")
        try Data("""
        name,url,username,password,note
        B148,\(origin)/signin,test@example.com,not-a-real-password,

        """.utf8).write(to: csv)
        let imported = await engine.importer.importData(.passwords, from: .exportFile(csv), into: profileID)
        XCTAssertEqual(imported.passwordStatus, .success)
        XCTAssertEqual(imported.passwordCount, 1)

        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID))
        let host = FillTestSurfaceHost()
        tab.surface.attach(to: host)
        defer {
            tab.surface.detach()
            host.window.close()
        }
        let inbox = AutofillInbox(tab.dialogRequests())
        defer { inbox.stop() }
        try await tab.load(try XCTUnwrap(URL(string: "\(origin)/signin")))
        try await waitForState(tab) { $0.title == "signin" && !$0.loadState.isLoading }
        tab.surface.setFocused(true)

        // Step 1: the identifier field offers the saved username.
        let first = try await passwordDropdown(tab, inbox, field: "identifierId", after: 0)
        try await choosePassword(in: first)
        try await waitForValues(tab, contains: "identifier=test@example.com")

        // Step 2: the password field on the same document offers it again; choosing fills it.
        _ = try await tab.evaluateJavaScript("step()")
        let second = try await passwordDropdown(tab, inbox, field: "Passwd", after: inbox.popups.count)
        try await choosePassword(in: second)
        try await waitForValues(tab, contains: "Passwd=not-a-real-password")

        // The browser is still alive and the page still answers.
        let title = try await tab.evaluateJavaScript("document.title")
        XCTAssertEqual(title, "signin")
        await engine.closeTab(tab.id)
    }

    /// Focuses `field` (clicking it until the dropdown with a password row appears) and returns it.
    @MainActor
    private func passwordDropdown(
        _ tab: any BrowserTab, _ inbox: AutofillInbox, field: String, after count: Int
    ) async throws -> AutofillPopup {
        let deadline = Date().addingTimeInterval(30)
        var lastFocus = Date.distantPast
        while Date() < deadline {
            if let popup = inbox.popups.dropFirst(count).last(where: { !$0.reply.isFinished }),
               popup.session.state.suggestions.contains(where: { $0.kind == .password }) {
                return popup
            }
            if Date().timeIntervalSince(lastFocus) > 2 {
                // A focus by script does not open the dropdown; a click on the field does.
                _ = try await tab.evaluateJavaScript("focusField('\(field)')")
                try await clickField(tab, id: field)
                try await pressArrowDown()
                lastFocus = Date()
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("no password dropdown for \(field); dropdowns: \(inbox.popups.map(\.session.state))")
        throw CancellationError()
    }

    /// Clicks the middle of the element with `id`, through the page's render widget view.
    @MainActor
    private func clickField(_ tab: any BrowserTab, id: String) async throws {
        let rect = try await tab.evaluateJavaScript(
            "(() => { const r = document.getElementById('\(id)').getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2].join(','); })()"
        )
        let parts = rect.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2, let window = NSApp.windows.first(where: { $0.title == "Open Arc B148 test" }),
              let content = window.contentView, let view = Self.renderWidgetView(in: content) else { return }
        let local = NSPoint(x: parts[0], y: view.isFlipped ? parts[1] : view.bounds.height - parts[1])
        let point = view.convert(local, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    /// ↓ in the focused field (Chrome opens the dropdown for it too).
    @MainActor
    private func pressArrowDown() async throws {
        guard let window = NSApp.windows.first(where: { $0.title == "Open Arc B148 test" }),
              let content = window.contentView, let view = Self.renderWidgetView(in: content) else { return }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125
            ) else { continue }
            if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
        }
    }

    @MainActor
    private static func renderWidgetView(in view: NSView) -> NSView? {
        if String(describing: type(of: view)).contains("RenderWidgetHostViewCocoa") { return view }
        for subview in view.subviews { if let found = renderWidgetView(in: subview) { return found } }
        return nil
    }

    /// Chooses the saved credential's row as a pointer would: hover (select), then click (accept)
    /// after Chromium's half-second guard.
    @MainActor
    private func choosePassword(in popup: AutofillPopup) async throws {
        let index = try XCTUnwrap(popup.session.state.suggestions.firstIndex { $0.kind == .password })
        XCTAssertEqual(popup.session.state.suggestions[index].mainText, "test@example.com")
        popup.session.send(.pointerInside(true))
        popup.session.send(.select(index))
        try await Task.sleep(nanoseconds: 700_000_000)
        popup.session.send(.accept(index))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !popup.reply.isFinished {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(popup.reply.isFinished, "choosing a row closes the dropdown")
    }

    @MainActor
    private func waitForValues(_ tab: any BrowserTab, contains expected: String) async throws {
        let deadline = Date().addingTimeInterval(20)
        var values = ""
        while Date() < deadline {
            values = try await tab.evaluateJavaScript("values()")
            if values.contains(expected) { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("form values: \(values); expected \(expected)")
    }
}
