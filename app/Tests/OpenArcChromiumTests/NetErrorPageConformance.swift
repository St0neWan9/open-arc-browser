import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan C36 (Chromium 157 helpers that need a tab): the engine's network error pages and the image
/// menu's search item. Run from `testChromiumEngineConformance`.
///
/// - A name-resolution error page ends with the plain network error. The engine's error-page
///   helper answers the page's DNS probe question; DNS probes are off (plan C27), so it answers
///   "not run" and the page shows `ERR_NAME_NOT_RESOLVED`. Without the helper (157 before C36)
///   the page stayed on "Diagnosing the problem" (`DNS_PROBE_POSSIBLE`) for good.
/// - An error page reloads by itself once the site answers again (Chromium's auto-reload: 1 s,
///   then 5 s, 30 s, ...).
/// - Image menu: the target carries the image's web address, from which the shell builds
///   "Search <engine> for Image" (B139, `PageImageSearch`; the engine offers no item of its own).
enum NetErrorPageTestPage {
    /// Mapped to "not found" by the test engine's `--host-resolver-rules`.
    static let unresolvableHost = "c36-unresolvable.invalid"

    static let imageHTML = """
    <!doctype html><meta charset="utf-8"><title>image</title>
    <style>body{margin:0}img{display:block;width:200px;height:200px}</style>
    <img id="img" src="/favicon.ico">
    """
}

extension ChromiumEngineConformanceTests {
    @MainActor
    func checkNetErrorPages(_ engine: ChromiumEngine, server: ProfileIsolationServer, profileID: UUID) async throws {
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID))
        // Auto-reload runs only for a visible page.
        let host = FillTestSurfaceHost(title: "Open Arc C36 error page test")
        tab.surface.attach(to: host)
        defer {
            tab.surface.detach()
            host.window.close()
        }

        // Name-resolution error: the helper's "probe not run" brings back the plain error.
        try await tab.load(try XCTUnwrap(URL(string: "http://\(NetErrorPageTestPage.unresolvableHost)/")))
        let dnsCode = try await waitForErrorCode(tab) { $0 == "ERR_NAME_NOT_RESOLVED" }
        XCTAssertEqual(dnsCode, "ERR_NAME_NOT_RESOLVED", "the DNS error page is not left on 'Diagnosing the problem'")

        // Auto-reload: a page whose server is down shows an error, then loads once it is back.
        let probe = try ProfileIsolationServer()
        try await probe.start()
        let port = probe.port
        probe.stop()
        try await Task.sleep(nanoseconds: 200_000_000)
        let downURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/login"))
        try await tab.load(downURL)
        let refused = try await waitForErrorCode(tab) { $0 == "ERR_CONNECTION_REFUSED" }
        XCTAssertEqual(refused, "ERR_CONNECTION_REFUSED")
        let back = try ProfileIsolationServer(port: port)
        try await back.start()
        defer { back.stop() }
        XCTAssertEqual(back.port, port)
        try await waitForState(tab) { $0.title == "login" && !$0.loadState.isLoading }

        // Image menu: the image's address reaches the shell.
        try await tab.load(server.url(path: "/image"))
        try await waitForState(tab) { $0.title == "image" && !$0.loadState.isLoading }
        let chromiumTab = try XCTUnwrap(tab as? ChromiumTab)
        let events = tab.events()
        let menu = try await withTimeout(seconds: 20) { () -> PageContextMenu? in
            await chromiumTab.requestContextMenu(x: 100, y: 100)
            for await event in events { if case .contextMenuRequested(let menu) = event { return menu } }
            return nil
        }
        let image = try XCTUnwrap(menu, "no image menu")
        XCTAssertTrue(image.target.isImage)
        XCTAssertEqual(image.target.sourceURL, server.url(path: "/favicon.ico"))
        XCTAssertNotNil(image.item(.copyImageAddress))
        image.session.close()
        await engine.closeTab(tab.id)
    }

    /// Polls the page's error code (the error page's `.error-code` text) until `condition` holds,
    /// at most 20 s; returns the last code read.
    @MainActor
    private func waitForErrorCode(_ tab: any BrowserTab, _ condition: (String) -> Bool) async throws -> String {
        let deadline = Date().addingTimeInterval(20)
        var code = ""
        while Date() < deadline {
            // Fails while the error page is being committed; the next poll reads it.
            code = (try? await tab.evaluateJavaScript(
                "(document.querySelector('.error-code') || {textContent: ''}).textContent.trim()"
            )) ?? ""
            if condition(code) { return code }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return code
    }
}
