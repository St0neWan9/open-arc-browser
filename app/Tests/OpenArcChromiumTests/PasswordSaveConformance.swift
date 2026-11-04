import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan C13 (save a password on a test page), regression for Chromium 157: the user types a
/// username and password into a login form and submits it; the engine offers to save the login
/// through `EngineDialogRequest.passwordSave`. On 157 the save prompt never came, because the
/// engine's password UI controller was only created for tabs of a Chrome window. Run from
/// `testChromiumEngineConformance`.
enum PasswordSaveTestPage {
    static let loginHTML = """
    <!doctype html><meta charset="utf-8"><title>login</title>
    <style>body{margin:20px;font:15px -apple-system}input{display:block;width:300px;height:32px;margin:8px 0}</style>
    <form id="login" method="post" action="/login/done">
      <input type="text" name="user" id="user" autocomplete="username">
      <input type="password" name="pass" id="pass" autocomplete="current-password">
      <button type="submit">Sign in</button>
    </form>
    <script>
    function focusField(id) { document.getElementById(id).focus(); return 'focused'; }
    function values() {
      return Array.from(document.querySelectorAll('input')).map((i) => i.name + '=' + i.value).join('&');
    }
    function submitLogin() { document.getElementById('login').requestSubmit(); return 'submitted'; }
    </script>
    """

    static let doneHTML = """
    <!doctype html><meta charset="utf-8"><title>welcome</title>signed in
    """
}

extension ChromiumEngineConformanceTests {
    @MainActor
    func checkPasswordSavePrompt(_ engine: ChromiumEngine, server: ProfileIsolationServer, profileID: UUID) async throws {
        let windowTitle = "Open Arc C13 save test"
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID))
        let host = FillTestSurfaceHost(title: windowTitle)
        tab.surface.attach(to: host)
        let requests = tab.dialogRequests()
        defer {
            tab.surface.detach()
            host.window.close()
        }
        try await tab.load(server.url(path: "/login"))
        try await waitForState(tab) { $0.title == "login" && !$0.loadState.isLoading }
        tab.surface.setFocused(true)

        // Typed, as a user would: text input through the page view, not values set by script.
        try await type("c13-user", into: "user", tab: tab, windowTitle: windowTitle)
        try await type("made-up-secret", into: "pass", tab: tab, windowTitle: windowTitle)
        let values = try await tab.evaluateJavaScript("values()")
        XCTAssertEqual(values, "user=c13-user&pass=made-up-secret")

        _ = try await tab.evaluateJavaScript("submitLogin()")
        try await waitForState(tab) { $0.title == "welcome" && !$0.loadState.isLoading }

        let prompt = try await withTimeout(seconds: 20) { @MainActor () -> PasswordSavePrompt? in
            for await request in requests {
                if case .passwordSave(let prompt) = request { return prompt }
            }
            return nil
        }
        let save = try XCTUnwrap(prompt, "submitting a typed login offers to save it")
        XCTAssertEqual(save.kind, .save)
        XCTAssertEqual(save.username, "c13-user")
        XCTAssertEqual(save.passwordLength, "made-up-secret".count)
        XCTAssertEqual(save.origin?.host, "127.0.0.1")
        XCTAssertTrue(save.reply.send(.save(username: nil)))

        // The page still answers after the answer went back to the engine.
        let title = try await tab.evaluateJavaScript("document.title")
        XCTAssertEqual(title, "welcome")
        await engine.closeTab(tab.id)
    }

    /// Focuses the field `id` and commits `text` through the page view's text input. Text sent
    /// before the page has focus is dropped, so it waits for focus and retries an empty field.
    @MainActor
    private func type(_ text: String, into id: String, tab: any BrowserTab, windowTitle: String) async throws {
        let window = try XCTUnwrap(NSApp.windows.first { $0.title == windowTitle })
        let view = try XCTUnwrap(Self.renderWidgetView(in: window.contentView))
        let input = try XCTUnwrap(view as? NSTextInputClient)
        window.makeKey()
        window.makeFirstResponder(view)
        let deadline = Date().addingTimeInterval(15)
        var lastInsert = Date.distantPast
        while Date() < deadline {
            let current = try await tab.evaluateJavaScript("document.getElementById('\(id)').value")
            if current == text { return }
            let focused = try await tab.evaluateJavaScript(
                "(focusField('\(id)'), document.hasFocus() && document.activeElement.id === '\(id)') ? 'yes' : 'no'"
            )
            if current.isEmpty, focused == "yes", Date().timeIntervalSince(lastInsert) > 1 {
                input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                lastInsert = Date()
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("field \(id) did not receive the typed text")
    }
}
