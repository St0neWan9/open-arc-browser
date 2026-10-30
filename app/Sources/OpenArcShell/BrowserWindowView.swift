import SwiftUI
import AppKit
import Combine
import OpenArcModel

// SwiftUI side of browser windows (B14): the window root that owns its `ShellModel`, the AppKit
// observer that reports focus and closing, and the opener the scene installs on the controller.

/// Scene id of the browser window group.
public enum BrowserWindowScene {
    public static let id = "browser"
}

/// Root view of one browser window. Owns its `ShellModel` for the window's lifetime.
struct BrowserWindowRoot: View {
    @StateObject private var model: ShellModel
    @Environment(\.openWindow) private var openWindow
    private let externalOpenInbox: ExternalOpenInbox?

    init(controller: WorkspaceController, request: BrowserWindowRequest, externalOpenInbox: ExternalOpenInbox? = nil) {
        self.externalOpenInbox = externalOpenInbox
        // A value this run did not hand out (a window macOS restored on its own) reopens a window
        // of the last session instead. inferred.
        let resolved = controller.wasIssued(request) ? request : BrowserWindowRequest(id: request.id, kind: .restore)
        _model = StateObject(wrappedValue: ShellModel.window(for: resolved, on: controller))
    }

    var body: some View {
        MainWindowView(model: model)
            .installsLittleArcOpener(model)
            .installsSettingsOpener(model)
            .focusedSceneObject(model)
            // The menu bar observes this, not the model (B103).
            .focusedSceneObject(model.menuBar)
            .background(BrowserWindowObserver(model: model))
            .background(MainWindowChromeConfigurator(placement: model.windowButtonPlacement))
            .frame(minWidth: 800, minHeight: 500)
            .onAppear(perform: appeared)
    }

    /// Installs the window opener and, for the first window of the launch, opens the other windows
    /// of the last session. [03 §Advanced] observed setting; the restore itself is inferred.
    private func appeared() {
        let controller = model.controller
        let open = openWindow
        controller.installWindowOpener { request in open(id: BrowserWindowScene.id, value: request) }
        for _ in 0..<controller.takeAdditionalRestoreCount() {
            controller.openBrowserWindow?(BrowserWindowRequest(kind: .restore))
        }
        // Links and files from other apps (D2), including the ones that launched the app. An
        // incognito window has its own controller and never takes them.
        if !controller.isOffTheRecord {
            externalOpenInbox?.connect { [weak controller] urls in controller?.openExternal(urls) }
        }
    }
}

/// Finds the hosting `NSWindow` and reports key and close events to the model; installs the
/// focus action used by the one-window-per-tab rule.
struct BrowserWindowObserver: NSViewRepresentable {
    let model: ShellModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    /// The command bar a held shortcut opens: ⌘T a new tab, ⌘L the current address. [02] observed.
    static func commandBarMode(for event: NSEvent) -> CommandBarMode? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.subtracting(.capsLock) == .command else { return nil }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "t": return .newTab
        case "l": return .currentTab
        default: return nil
        }
    }

    /// Sets `window`'s title to the model's (Space name, then page title), only when it changed.
    /// [06 §1, §20.1] observed (B74).
    @MainActor
    static func applyTitle(of model: ShellModel, to window: NSWindow) {
        let title = model.windowTitle
        if window.title != title { window.title = title }
    }

    /// How long a model change waits before the window title follows it. Own value (B102): setting
    /// an `NSWindow` title costs a few milliseconds on the main thread (AppKit lays the title bar
    /// out again, updates the window server and rebuilds the Window menu's window list), so it
    /// runs in its own turn after the change has drawn, and a burst of changes (selecting through
    /// tabs, a page loading) costs one title update. The title bar is hidden; the title shows in
    /// the Window menu, Mission Control and AppleScript, where this delay is not noticeable.
    static let titleCoalescingDelay: TimeInterval = 0.1

    /// Brings `window` to the front and makes it key, also from the Dock (minimized). B29.
    @MainActor
    static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let model: ShellModel
        private weak var window: NSWindow?
        private var titleChanges: AnyCancellable?
        /// True while a title update is scheduled (`scheduleTitleUpdate`).
        private var isTitleUpdateScheduled = false

        init(model: ShellModel) {
            self.model = model
        }

        func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            // The app restores its own windows from `ui-state.json` (and never an incognito one),
            // so AppKit's window restoration stays off.
            window.isRestorable = false
            // An incognito window lies exactly over the window it was opened from. [06 §20.1]
            // observed (F5-41).
            if let frame = model.takeOpeningFrame() { window.setFrame(frame, display: true) }
            // An incognito window carries no badge, not even in its title; its appearance comes from
            // its palette like any window (`WindowAppearanceApplier`). [06 §20.1] observed (B48).
            model.focusWindow = { [weak window] in window.map(BrowserWindowObserver.bringToFront) }
            // The title follows the Space, then the page. [06 §1, §20.1] observed (B74).
            // `objectWillChange` fires before the change lands: the title is read later, once per
            // burst of changes (`scheduleTitleUpdate`). The window stays in the Window menu's
            // window list, as in Arc ([01 §Window] observed).
            BrowserWindowObserver.applyTitle(of: model, to: window)
            titleChanges = model.objectWillChange
                .sink { [weak self] _ in
                    // The model is main-actor isolated and publishes on the main thread.
                    MainActor.assumeIsolated { self?.scheduleTitleUpdate() }
                }
            // Window ▸ Stay On Top (B72): floating above other apps' windows while on.
            model.applyWindowLevel = { [weak window] floating in window?.level = floating ? .floating : .normal }
            if model.staysOnTop { window.level = .floating }
            // AppleScript sees the window from now on (B70).
            ScriptingHost.shared.register(model, window: window)
            if window.isKeyWindow { model.windowDidBecomeKey() }
            // A tab was revealed in this window before it had an AppKit window (B29).
            if model.takeFocusOnAttach() { BrowserWindowObserver.bringToFront(window) }
            if window.isKeyWindow { deliverTypeAhead(to: window) }
            // Selector-based observers are removed automatically when the coordinator goes away.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(didBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(willClose(_:)), name: NSWindow.willCloseNotification, object: window)
            // Extensions see the window's focus and bounds (plan B126).
            center.addObserver(self, selector: #selector(didResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
            center.addObserver(self, selector: #selector(frameDidChange(_:)), name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(frameDidChange(_:)), name: NSWindow.didResizeNotification, object: window)
            reportFrame(of: window)
        }

        @objc private func didResignKey(_ notification: Notification) {
            model.windowDidResignKey()
        }

        @objc private func frameDidChange(_ notification: Notification) {
            if let window { reportFrame(of: window) }
        }

        private func reportFrame(of window: NSWindow) {
            let frame = window.frame
            model.windowFrameDidChange(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height)
        }

        /// Applies the model's title `titleCoalescingDelay` after the first change of a burst; the
        /// changes that follow within that time ride along.
        private func scheduleTitleUpdate() {
            guard !isTitleUpdateScheduled else { return }
            isTitleUpdateScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + BrowserWindowObserver.titleCoalescingDelay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isTitleUpdateScheduled = false
                    if let window = self.window { BrowserWindowObserver.applyTitle(of: self.model, to: window) }
                }
            }
        }

        @objc private func didBecomeKey(_ notification: Notification) {
            model.windowDidBecomeKey()
            if let window { deliverTypeAhead(to: window) }
        }

        /// Keys typed while this window was opening (B29). ⌘T and ⌘L run on this window's model
        /// directly: the menus may still point at the previous key window.
        private func deliverTypeAhead(to window: NSWindow) {
            let model = self.model
            NewWindowTypeAhead.shared.browserWindowIsReady(window) { event in
                guard let mode = BrowserWindowObserver.commandBarMode(for: event) else { return false }
                model.presentCommandBar(mode)
                return true
            }
        }

        @objc private func willClose(_ notification: Notification) {
            titleChanges = nil
            model.focusWindow = nil
            model.applyWindowLevel = nil
            model.windowDidClose()
        }
    }
}
