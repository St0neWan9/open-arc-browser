import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcChromium

/// Plan B138 (docs/f5-review.md F5-7, decision: follow Chrome): the app's core keys are reserved.
/// They reach the app before the page, so a page that calls preventDefault() on ⌘T or ⌘L cannot
/// block them; every other key goes to the page first and reaches the app only when the page leaves
/// it unhandled. [02 §其他] observed: Arc lets the user choose who gets a key first; the default
/// is unknown, and the choice is deferred (plan Q17). Run from `testChromiumEngineConformance`.
///
/// The app's menus are stood in for by a main menu with four items: ⌘T and ⌘L (reserved), ⌘B and
/// ⌘J (not reserved). The page cancels every ⌘ key except ⌘J. Key events go to the page's view as
/// AppKit would deliver them (`keyDown:` on the render widget view, which has the keyboard).
enum ReservedKeysTestPage {
    /// `window.seen` lists the ⌘ keys the page received.
    static let html = """
    <!doctype html><meta charset="utf-8"><title>keys</title><body>B138</body>
    <script>
    window.seen = [];
    addEventListener('keydown', (e) => {
      if (!e.metaKey) return;
      seen.push(e.key);
      if (e.key !== 'j') e.preventDefault();
    }, true);
    </script>
    """
}

/// Counts the stand-in menu items the main menu fired, by key.
@MainActor
private final class MenuKeyRecorder: NSObject {
    private(set) var fired: [String: Int] = [:]

    @objc func fire(_ sender: NSMenuItem) {
        fired[sender.keyEquivalent, default: 0] += 1
    }

    func count(_ key: String) -> Int { fired[key] ?? 0 }
}

/// A real window for the tab's page view, so the page can take the keyboard.
@MainActor
private final class KeyTestSurfaceHost: SurfaceHost {
    let window: NSWindow

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 60, y: 60, width: 480, height: 320),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Open Arc B138 test"
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

    /// Chromium's render widget view (it takes the page's key events).
    func renderWidgetView() -> NSView? {
        func find(_ view: NSView) -> NSView? {
            if String(describing: type(of: view)).contains("RenderWidgetHostViewCocoa") { return view }
            for subview in view.subviews { if let found = find(subview) { return found } }
            return nil
        }
        return window.contentView.flatMap(find)
    }
}

extension ChromiumEngineConformanceTests {
    @MainActor
    func checkReservedKeys(_ engine: ChromiumEngine) async throws {
        let recorder = MenuKeyRecorder()
        let previousMenu = NSApp.mainMenu
        NSApp.mainMenu = Self.standInMenu(recorder)
        defer { NSApp.mainMenu = previousMenu }

        let tab = try await engine.makeTab(TabConfiguration(profileID: UUID()))
        let host = KeyTestSurfaceHost()
        tab.surface.attach(to: host)
        defer {
            tab.surface.detach()
            host.window.close()
        }
        let encoded = ReservedKeysTestPage.html.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await tab.load(try XCTUnwrap(URL(string: "data:text/html;charset=utf-8," + encoded)))
        try await waitForState(tab) { $0.title == "keys" && !$0.loadState.isLoading }
        tab.surface.setFocused(true)
        let view = try XCTUnwrap(host.renderWidgetView(), "the page's render widget view")

        // ⌘T, ⌘L: reserved, cancelled by the page, still the app's. ⌘D: reserved, but no menu item
        // takes it, so it goes on to the page. ⌘B: not reserved, cancelled by the page, so the app
        // never sees it. ⌘J: not reserved, left alone by the page, so it reaches the app after it.
        for (character, keyCode) in [("t", 17), ("l", 37), ("d", 2), ("b", 11), ("j", 38)] as [(String, UInt16)] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: .command,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: host.window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: keyCode
                ))
                if type == .keyDown { view.keyDown(with: event) } else { view.keyUp(with: event) }
            }
        }

        // The page's answers come back asynchronously; ⌘J is the last key, so once the app saw it,
        // the page has answered every key before it.
        var seen = ""
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            seen = try await tab.evaluateJavaScript("seen.join(',')")
            if recorder.count("j") > 0 && seen.contains("j") { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(recorder.count("t"), 1, "⌘T is reserved: the app gets it although the page cancels it")
        XCTAssertEqual(recorder.count("l"), 1, "⌘L is reserved: the app gets it although the page cancels it")
        XCTAssertEqual(recorder.count("b"), 0, "⌘B is not reserved: the page cancelled it first")
        XCTAssertEqual(recorder.count("j"), 1, "⌘J is not reserved: the page left it, so the app gets it after")
        XCTAssertEqual(seen, "d,b,j", "the page never sees the reserved keys the app took")

        await engine.closeTab(tab.id)
    }

    /// The app's menus for this check: ⌘T, ⌘L, ⌘B and ⌘J items that record their key.
    @MainActor
    private static func standInMenu(_ recorder: MenuKeyRecorder) -> NSMenu {
        let main = NSMenu(title: "Main")
        let top = NSMenuItem(title: "Keys", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Keys")
        for key in ["t", "l", "b", "j"] {
            let item = NSMenuItem(title: "Key \(key)", action: #selector(MenuKeyRecorder.fire(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.target = recorder
            menu.addItem(item)
        }
        top.submenu = menu
        main.addItem(top)
        return main
    }
}
