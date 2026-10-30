import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan B132 against the real engine. Run from `testChromiumEngineConformance`.
///
/// - Site icons ([05 §命令栏] observed: site rows carry the site's icon, also for never visited
///   sites): `EngineAutocomplete.siteIcon` answers the site's `/favicon.ico` (a 64 px PNG served by
///   the test site), decoded and scaled to at most 32 px, for a site the profile never visited.
/// - Page menu ([05 §右键菜单] E29 observed: Speech ▸ and Services ▸ end the selection menu; macOS
///   adds Services ▸ for the view the menu is shown for): with text selected, the page's render
///   widget view (the view the bridge now shows the menu for) answers the Services requestor
///   check for plain text, and a menu shown through the session opens and closes.
enum SiteIconTestImage {
    /// A 64 × 64 opaque PNG.
    static let png: Data = {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 64, height: 64).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }()

    /// A page with one large link at its top left.
    static let linkHTML = """
    <!doctype html><meta charset="utf-8"><title>Link</title>
    <a href="https://example.com/next" style="position:absolute;left:0;top:0;font-size:40px">next page</a>
    """
}

/// Puts a tab's page view into a real window, so it has a render widget view in a window.
@MainActor
private final class MenuWindowHost: SurfaceHost {
    let window: NSWindow

    init() {
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Open Arc B132 test"
        window.level = .floating
        window.orderFrontRegardless()
    }

    func show(_ content: SurfaceContent) {
        guard case .native(let object) = content, let view = object as? NSView, let contentView = window.contentView else { return }
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
    }

    func clear() {
        window.contentView?.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Closes a menu as soon as it opened, and records that it did.
@MainActor
private final class ClosingMenuDelegate: NSObject, NSMenuDelegate {
    private(set) var opened = false

    func menuWillOpen(_ menu: NSMenu) {
        opened = true
        // Runs in the menu's tracking run loop mode.
        menu.perform(#selector(NSMenu.cancelTrackingWithoutAnimation), with: nil, afterDelay: 0.2, inModes: [.common])
    }
}

extension ChromiumEngineConformanceTests {
    @MainActor
    func checkSmallGapsB132(_ engine: ChromiumEngine, server: ProfileIsolationServer, profileID: UUID) async throws {
        // Site icon of a never visited site: the database has none, so the bridge fetches
        // /favicon.ico and scales the 64 px image down to 32 px.
        let autocomplete = engine.autocomplete
        XCTAssertTrue(autocomplete.capabilities.contains(.siteIcons))
        let tab = try await engine.makeTab(TabConfiguration(profileID: profileID))
        let site = server.url(path: "/never-visited")
        let fetched = await autocomplete.siteIcon(for: site, profileID: profileID, isOffTheRecord: false)
        let icon = try XCTUnwrap(fetched, "no site icon")
        let image = try XCTUnwrap(NSBitmapImageRep(data: icon), "not an image")
        XCTAssertEqual(image.pixelsWide, 32)
        XCTAssertEqual(image.pixelsHigh, 32)
        let none = await autocomplete.siteIcon(for: URL(string: "file:///tmp/x")!, profileID: profileID, isOffTheRecord: false)
        XCTAssertNil(none)

        // Page menu for a selection: the render widget view serves the selection to Services.
        let host = MenuWindowHost()
        tab.surface.attach(to: host)
        defer {
            tab.surface.detach()
            host.window.close()
        }
        let page = try XCTUnwrap(URL(string: "data:text/html,<title>Sel</title><p id=p style='font-size:40px'>hello world</p>"))
        try await tab.load(page)
        try await waitForState(tab) { $0.title == "Sel" && !$0.loadState.isLoading }
        // The selection reaches the page view only while the page has keyboard focus, which needs
        // a key window in an active app.
        if NSApp.activationPolicy() == .prohibited { NSApp.setActivationPolicy(.accessory) }
        NSApp.activate(ignoringOtherApps: true)
        host.window.makeKey()
        tab.surface.setFocused(true)
        _ = try await tab.evaluateJavaScript(
            "getSelection().selectAllChildren(document.getElementById('p')); document.getElementById('p').focus(); 1"
        )
        let chromiumTab = try XCTUnwrap(tab as? ChromiumTab)
        let events = tab.events()
        let menu = try await withTimeout(seconds: 20) { () -> PageContextMenu? in
            await chromiumTab.requestContextMenu(x: 40, y: 40)
            for await event in events { if case .contextMenuRequested(let menu) = event { return menu } }
            return nil
        }
        let selection = try XCTUnwrap(menu, "no selection menu")
        XCTAssertEqual(selection.target.selectionText.trimmingCharacters(in: .whitespacesAndNewlines), "hello world")
        XCTAssertNotNil(selection.item(.speech), "Speech ▸ comes from the engine")

        let widget = try XCTUnwrap(Self.renderWidgetView(in: host.window.contentView), "no render widget view")
        host.window.makeFirstResponder(widget)
        // The page reports its selection to the view only while it has focus, which needs a key
        // window in an active app; an xctest run usually cannot activate, so the check runs only
        // when it could (the live check in the app covers it otherwise).
        if host.window.isKeyWindow {
            var requestor: Any?
            for _ in 0..<200 {
                requestor = widget.validRequestor(forSendType: .string, returnType: nil)
                if requestor != nil { break }
                try await Task.sleep(nanoseconds: 25_000_000)
            }
            XCTAssertTrue((requestor as AnyObject?) === widget, "the page view serves the selection to Services")
        } else {
            print("B132: test window is not key; Services requestor check skipped")
        }

        let nsMenu = NSMenu()
        nsMenu.addItem(withTitle: "B132", action: nil, keyEquivalent: "")
        let delegate = ClosingMenuDelegate()
        nsMenu.delegate = delegate
        XCTAssertTrue(selection.session.present(nsMenu))
        XCTAssertTrue(delegate.opened)

        // A mouse right-click on a link selects the link's text (Blink's Mac editing behavior),
        // so the link menu has Copy / Copy Link to Highlight / Search ([05 §右键菜单] E29 observed).
        let linkPage = server.url(path: "/link")
        try await tab.load(linkPage)
        try await waitForState(tab) { $0.title == "Link" && !$0.loadState.isLoading }
        let linkEvents = tab.events()
        let pageView = try XCTUnwrap(Self.renderWidgetView(in: host.window.contentView))
        let linkMenu = try await withTimeout(seconds: 20) { () -> PageContextMenu? in
            await MainActor.run { Self.rightClick(pageView, atTopLeftOffset: NSPoint(x: 30, y: 25)) }
            for await event in linkEvents { if case .contextMenuRequested(let menu) = event { return menu } }
            return nil
        }
        let link = try XCTUnwrap(linkMenu, "no link menu")
        XCTAssertEqual(link.target.linkURL, URL(string: "https://example.com/next"))
        XCTAssertEqual(link.target.selectionText.trimmingCharacters(in: .whitespacesAndNewlines), "next page",
                       "a right-click selects the link's text")
        XCTAssertNotNil(link.item(.copy))
        XCTAssertNotNil(link.item(.copyLinkToHighlight))
        link.session.close()
        await engine.closeTab(tab.id)
    }

    /// Sends a right mouse down and up to `view` at a point measured from its top left.
    @MainActor
    static func rightClick(_ view: NSView, atTopLeftOffset offset: NSPoint) {
        guard let window = view.window else { return }
        let local = NSPoint(x: offset.x, y: view.isFlipped ? offset.y : view.bounds.height - offset.y)
        let inWindow = view.convert(local, to: nil)
        for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { continue }
            if type == .rightMouseDown { view.rightMouseDown(with: event) } else { view.rightMouseUp(with: event) }
        }
    }

    /// The deepest view of Chromium's render widget class (the page's input view).
    @MainActor
    static func renderWidgetView(in root: NSView?) -> NSView? {
        guard let root else { return nil }
        if NSStringFromClass(type(of: root)).contains("RenderWidgetHostViewCocoa") { return root }
        for child in root.subviews {
            if let found = renderWidgetView(in: child) { return found }
        }
        return nil
    }
}
