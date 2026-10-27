import SwiftUI
import AppKit
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
/// focus action used by the one-window-per-tab rule; gives incognito windows the dark appearance.
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

        init(model: ShellModel) {
            self.model = model
        }

        func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            // The app restores its own windows from `ui-state.json` (and never an incognito one),
            // so AppKit's window restoration stays off.
            window.isRestorable = false
            if model.isIncognito {
                // The incognito look: a dark window (spec gives none; inferred, local tokens).
                window.appearance = NSAppearance(named: .darkAqua)
                window.title = "\(AppIdentity.displayName) — \(IncognitoLocalTokens.windowTitle)"
            }
            model.focusWindow = { [weak window] in window.map(BrowserWindowObserver.bringToFront) }
            if window.isKeyWindow { model.windowDidBecomeKey() }
            // A tab was revealed in this window before it had an AppKit window (B29).
            if model.takeFocusOnAttach() { BrowserWindowObserver.bringToFront(window) }
            if window.isKeyWindow { deliverTypeAhead(to: window) }
            // Selector-based observers are removed automatically when the coordinator goes away.
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(didBecomeKey(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(willClose(_:)), name: NSWindow.willCloseNotification, object: window)
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
            model.focusWindow = nil
            model.windowDidClose()
        }
    }
}
