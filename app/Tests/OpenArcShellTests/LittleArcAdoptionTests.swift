import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// B29: "Open in Open Arc" must leave the adopted tab selected in a frontmost browser window, and
/// keys typed right after ⌥⌘N / ⌘N must not be lost while the new window is not key yet.
/// [06 §7] observed: Little Arc is a command-bar-only window opened with ⌥⌘N [02]; what adoption
/// does to the main window is inferred (the spec does not record it).
@MainActor
final class LittleArcAdoptionTests: XCTestCase {
    private func makeController(_ f: SidebarFixture = SidebarFixture()) -> WorkspaceController {
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now.addingTimeInterval(10) }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID?) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    // MARK: Adoption

    /// No browser window is open (the last one was closed with ⇧⌘W): adoption requests a window,
    /// and the window that registers selects the adopted tab and comes to the front.
    func testAdoptWithNoBrowserWindowOpensOneAndSelectsTab() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let closed = window(controller, space: f.work)
        closed.windowDidClose()
        XCTAssertNil(controller.activeWindow)

        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }
        let host = controller.littleArcHost()
        let url = try XCTUnwrap(URL(string: "https://example.edu"))
        let adopted = try XCTUnwrap(host.adoptLittleArcTab(url: url, title: "example.edu"))
        XCTAssertEqual(requests.count, 1, "a browser window is requested")
        XCTAssertEqual(requests.first?.kind, .newWindow)
        XCTAssertEqual(requests.first?.tabID, adopted)
        XCTAssertEqual(controller.pendingRevealTabID, adopted)

        // A second adoption before the window arrives requests no second window.
        let again = try XCTUnwrap(host.adoptLittleArcTab(url: url, title: "example.edu"))
        XCTAssertEqual(requests.count, 1)

        // The requested window registers before its AppKit window is known.
        let opened = ShellModel.window(for: try XCTUnwrap(requests.first), on: controller)
        addTeardownBlock { @MainActor in opened.stop() }
        XCTAssertEqual(opened.selectedTabID, again, "the window shows the last adopted tab")
        XCTAssertEqual(controller.workspace.tabs[again]?.location.spaceID, host.selectedSpaceID)
        XCTAssertEqual(opened.selectedSpaceID, host.selectedSpaceID)
        XCTAssertNil(controller.pendingRevealTabID)
        XCTAssertEqual(opened.revealRequestCount, 1)
        XCTAssertTrue(opened.takeFocusOnAttach(), "the window comes forward once it has an AppKit window")
        XCTAssertFalse(opened.takeFocusOnAttach(), "consumed")
        _ = adopted
    }

    /// A browser window is open (perhaps behind others or minimized): it selects the adopted tab and
    /// is asked to come to the front; no new window is requested.
    func testAdoptWithWindowOpenSelectsTabAndBringsWindowForward() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let main = window(controller, space: f.home)
        var focused = 0
        main.focusWindow = { focused += 1 }
        main.library.open(.spaces)
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }

        let little = LittleArcModel(shell: controller.littleArcHost())
        XCTAssertTrue(controller.littleArcHost() === main)
        little.open(try XCTUnwrap(URL(string: "https://example.edu")))
        let adopted = try XCTUnwrap(little.adopt())
        XCTAssertEqual(main.selectedTabID, adopted)
        XCTAssertEqual(main.workspace.today(spaceID: f.home).first?.id, adopted, "top of Today [06 §13] observed")
        XCTAssertEqual(focused, 1, "the window is brought to the front")
        XCTAssertFalse(main.library.isActive, "the window leaves the Library so the tab is on screen")
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(little.phase, .closed)
    }

    /// Bringing a window to the front also restores it from the Dock.
    func testBringToFrontDeminiaturizes() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        BrowserWindowObserver.bringToFront(window)
        XCTAssertTrue(window.isVisible)
        XCTAssertFalse(window.isMiniaturized)
    }

    /// A browser window opener taken from the scene's commands is not replaced by a window's own.
    func testSceneWindowOpenerIsKept() {
        let controller = makeController()
        var scene = 0, fromWindow = 0
        controller.installWindowOpener(sceneLevel: true) { _ in scene += 1 }
        controller.installWindowOpener { _ in fromWindow += 1 }
        controller.openBrowserWindow?(BrowserWindowRequest(kind: .newWindow))
        XCTAssertEqual(scene, 1)
        XCTAssertEqual(fromWindow, 0)
    }

    // MARK: Focus of a new Little Arc window

    /// Showing a Little Arc window makes it key and gives its field the keyboard within one
    /// run-loop turn, with no click. [06 §7] observed: the window is the command bar.
    func testShownLittleArcWindowIsKeyWithFieldFocused() async throws {
        let previous = LittleArcWindowConfigurator.appIsActive
        LittleArcWindowConfigurator.appIsActive = { true }
        defer { LittleArcWindowConfigurator.appIsActive = previous }
        let f = SidebarFixture()
        let controller = makeController(f)
        let shell = window(controller, space: f.home)
        let model = LittleArcModel(shell: shell)

        // Another window is key first, as the browser window is when ⌥⌘N is pressed.
        let other = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        other.makeKeyAndOrderFront(nil)
        addTeardownBlock { @MainActor in other.close() }

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: model.windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        LittleArcWindowConfigurator.diagnostics = .init()
        window.contentView = NSHostingView(rootView: LittleArcWindowView(model: model))
        window.orderFront(nil)
        // One turn for the configurator pass (scheduled from the view update), one for its work.
        try await Task.sleep(nanoseconds: 50_000_000)

        // A test runner is never the active app, so AppKit may refuse to make any window key:
        // check that the window asked to be key, and that it is whenever AppKit allows.
        XCTAssertEqual(LittleArcWindowConfigurator.diagnostics.keyRequestCount, 1, "the new window is made key once")
        if NSApp.keyWindow != nil { XCTAssertTrue(window.isKeyWindow, "the new Little Arc window is key") }
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView, "the field has the keyboard")
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertTrue((editor.delegate as AnyObject?) is CommandBarNSTextField)
    }

    // MARK: Type-ahead

    private func key(_ characters: String, flags: NSEvent.ModifierFlags = [], window: NSWindow? = nil) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0
        ))
    }

    /// Keys typed after ⌥⌘N, before the Little Arc field has the keyboard, reach it in order once
    /// it does ("example.edu" must not become "mple.edu").
    func testKeysTypedBeforeLittleArcFieldIsReadyAreDelivered() async throws {
        let buffer = NewWindowTypeAhead()
        buffer.installsMonitor = false
        var sent: [(String, Int)] = []
        buffer.send = { event, target in sent.append((event.characters ?? "", target?.windowNumber ?? 0)) }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }

        XCTAssertFalse(buffer.capture(try key("x")), "nothing is held unless a window is on its way")
        buffer.begin(.littleArc)
        for c in ["e", "x", "a"] { XCTAssertTrue(buffer.capture(try key(c))) }
        // A browser window becoming key does not take keys meant for Little Arc.
        buffer.browserWindowIsReady(window) { _ in false }
        buffer.commandBarFieldIsReady(in: window, isLittleArc: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(sent.isEmpty)

        buffer.commandBarFieldIsReady(in: window, isLittleArc: true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sent.map(\.0), ["e", "x", "a"])
        XCTAssertEqual(Set(sent.map(\.1)), [window.windowNumber], "addressed to the new window")
        XCTAssertNil(buffer.target)
        XCTAssertFalse(buffer.capture(try key("m")), "keys typed after delivery flow normally")
    }

    /// ⌘N then ⌘T and a URL: ⌘T opens the command bar in the new window, and the letters wait for
    /// its field. [02] observed: ⌘N New Window, ⌘T New Tab….
    func testShortcutHeldForNewBrowserWindowRunsThereAndLettersWaitForField() async throws {
        let buffer = NewWindowTypeAhead()
        buffer.installsMonitor = false
        var sent: [String] = []
        buffer.send = { event, _ in sent.append(event.characters ?? "") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }

        buffer.begin(.browserWindow)
        buffer.capture(try key("t", flags: .command))
        for c in ["e", "x"] { buffer.capture(try key(c)) }
        var performed: [CommandBarMode] = []
        buffer.browserWindowIsReady(window) { event in
            guard let mode = BrowserWindowObserver.commandBarMode(for: event) else { return false }
            performed.append(mode)
            return true
        }
        XCTAssertEqual(performed, [.newTab])
        XCTAssertTrue(sent.isEmpty, "letters wait for the command bar field")
        XCTAssertEqual(buffer.target, .commandBarField)

        buffer.commandBarFieldIsReady(in: window, isLittleArc: false)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(sent, ["e", "x"])
        XCTAssertNil(buffer.target)
    }

    /// Held keys never wait forever: without a ready window they go out after the timeout.
    func testHeldKeysAreReleasedAfterTimeout() async throws {
        let buffer = NewWindowTypeAhead()
        buffer.installsMonitor = false
        var sent: [String] = []
        buffer.send = { event, _ in sent.append(event.characters ?? "") }
        buffer.begin(.commandBarField)
        buffer.capture(try key("q"))
        try await Task.sleep(nanoseconds: UInt64((NewWindowTypeAheadTiming.fieldTimeout + 0.3) * 1_000_000_000))
        XCTAssertEqual(sent, ["q"])
        XCTAssertNil(buffer.target)
    }

    func testCommandBarShortcutMapping() throws {
        XCTAssertEqual(BrowserWindowObserver.commandBarMode(for: try key("t", flags: .command)), .newTab)
        XCTAssertEqual(BrowserWindowObserver.commandBarMode(for: try key("l", flags: .command)), .currentTab)
        XCTAssertNil(BrowserWindowObserver.commandBarMode(for: try key("t", flags: [.command, .shift])))
        XCTAssertNil(BrowserWindowObserver.commandBarMode(for: try key("t")))
    }
}
