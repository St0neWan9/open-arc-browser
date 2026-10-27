import Foundation
import AppKit
import OpenArcModel
import OpenArcEngine

// AppleScript support (plan B70). Spec: docs/arc-spec/06-flows.md §29 (observed: the dictionary's
// classes, properties, commands and codes; inferred: their runtime behavior, which was never run
// against Arc). The dictionary is app/Bundle/OpenArc.sdef; Info.plist turns scripting on
// (NSAppleScriptEnabled, OSAScriptingDefinition).
//
// Layers:
// - `ScriptingHost` (this file): the browser windows scripts can see, each with a text id, and
//   the JavaScript gate and runner. Browser windows register when their `NSWindow` is known
//   (`BrowserWindowObserver`).
// - `ScriptingActions` (ScriptingActions.swift): what each command and property does, on
//   `ShellModel` / `WorkspaceController`; every tree change goes through `TreeOps` (directly in a
//   `WorkspaceController.mutate`, or through an existing sidebar intent). No AppKit scripting
//   types there, so tests drive it directly.
// - ScriptingObjects.swift / ScriptingCommands.swift: the Cocoa scripting classes the sdef names
//   (KVC element accessors, `objectSpecifier`, command handlers). Thin: they resolve ids and call
//   `ScriptingActions`.

/// A failure reported to the script as an AppleScript error (number and message). The numbers are
/// the standard Apple Event error codes; the messages are our own words (the spec records none,
/// [06 §29.3] unknown).
public struct ScriptingFailure: Error, Equatable, Sendable {
    public let number: Int
    public let message: String

    public init(number: Int, message: String) {
        self.number = number
        self.message = message
    }

    /// errAEEventFailed.
    static let eventFailedNumber = -10000
    /// errAEPrivilegeError.
    static let privilegeNumber = -10004
    /// errAEWriteDenied (errAENotModifiable is -10003 too).
    static let notModifiableNumber = -10003
    /// errAENoSuchObject.
    static let noSuchObjectNumber = -1728

    /// `execute` while View ▸ Developer ▸ Allow JavaScript from Apple Events is off.
    /// [06 §29.4] inferred: a script error that points at the menu item.
    public static let javaScriptNotAllowed = ScriptingFailure(
        number: privilegeNumber,
        message: "Running JavaScript from Apple Events is turned off. Turn it on with View ▸ Developer ▸ Allow JavaScript from Apple Events."
    )

    /// The engine build cannot run JavaScript in a page (`EngineError.unsupported`, for example a
    /// Chromium framework built before plan B71).
    public static let javaScriptUnavailable = ScriptingFailure(
        number: eventFailedNumber,
        message: "This version of Open Arc cannot run JavaScript in a page."
    )

    /// A URL the tab cannot load. [06 §29.3] observed that Arc has its own message; its words are unknown.
    public static func invalidURL(_ text: String) -> ScriptingFailure {
        ScriptingFailure(number: eventFailedNumber, message: "“\(text)” is not a valid URL.")
    }

    /// The page's script threw or its promise rejected; the message is the page's exception text.
    /// [06 §29.3] unknown (Arc's error); inferred: a script error with the exception text.
    public static func javaScriptException(_ message: String) -> ScriptingFailure {
        ScriptingFailure(number: eventFailedNumber, message: "The JavaScript failed: \(message)")
    }

    /// The script's failure as the script sees it (plan B71).
    static func javaScript(_ error: any Error) -> ScriptingFailure {
        switch error {
        case let failure as ScriptingFailure: failure
        case EngineError.javaScriptException(let message): .javaScriptException(message)
        case EngineError.unsupported: .javaScriptUnavailable
        case EngineError.tabClosed, EngineError.tabNotFound: .noSuchObject("tab")
        default: .failed("The JavaScript failed: \(error)")
        }
    }

    static func noSuchObject(_ what: String) -> ScriptingFailure {
        ScriptingFailure(number: noSuchObjectNumber, message: "The \(what) does not exist any more.")
    }

    static func notModifiable(_ what: String) -> ScriptingFailure {
        ScriptingFailure(number: notModifiableNumber, message: what)
    }

    static func failed(_ message: String) -> ScriptingFailure {
        ScriptingFailure(number: eventFailedNumber, message: message)
    }
}

/// Runs JavaScript in a live page and returns its result as text.
public typealias ScriptJavaScriptEvaluator = @MainActor (any BrowserTab, String) async throws -> String

/// The browser windows AppleScript sees, and the scripting settings. One per app (`shared`); tests
/// make their own.
@MainActor
public final class ScriptingHost {
    public static let shared = ScriptingHost()

    /// One registered browser window. The id is the window's scripting `id` (text, [06 §29.2]
    /// observed type); ours is a UUID made when the window registers, stable while it is open.
    struct Entry {
        let id: UUID
        weak var model: ShellModel?
        weak var window: NSWindow?
    }

    private var entries: [Entry] = []
    /// The app's workspace controller (not an incognito one): `make new window` and Little Arc tabs
    /// open through it. Taken from the first normal browser window that registers.
    private(set) weak var appController: WorkspaceController?
    /// `make new window` calls waiting for their window to register (see `waitForNewWindow`).
    private var windowWaiters: [(known: Set<UUID>, resume: (Entry?) -> Void)] = []
    private var closeObservers: [UUID: NSObjectProtocol] = [:]
    private let makeID: () -> UUID

    /// Runs `execute`'s JavaScript once the gate allows it: the engine's
    /// `BrowserTab.evaluateJavaScript` (plan B71), whose text result goes back to the script
    /// unchanged. Tests replace it.
    public var evaluateJavaScript: ScriptJavaScriptEvaluator = ScriptingHost.engineEvaluator

    /// The default runner: the tab's engine call ([06 §29.3] observed command, result as text).
    public static let engineEvaluator: ScriptJavaScriptEvaluator = { tab, source in
        try await tab.evaluateJavaScript(source)
    }

    init(makeID: @escaping () -> UUID = UUID.init) {
        self.makeID = makeID
    }

    // MARK: Windows

    /// A browser window's AppKit window is known: scripts can see it from now on. Idempotent.
    /// Its entry goes away when the window closes.
    public func register(_ model: ShellModel, window: NSWindow?) {
        prune()
        if let index = entries.firstIndex(where: { $0.model === model }) {
            if entries[index].window == nil, let window { entries[index].window = window }
            return
        }
        let entry = Entry(id: makeID(), model: model, window: window)
        entries.append(entry)
        if !model.isIncognito, appController == nil { appController = model.controller }
        if let window {
            let id = entry.id
            closeObservers[id] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.unregister(id) }
            }
        }
        if model.isBrowserWindow { ScriptingSelfTest.startIfRequested() }
        let waiters = windowWaiters
        windowWaiters.removeAll()
        for waiter in waiters {
            if waiter.known.contains(entry.id) { windowWaiters.append(waiter) } else { waiter.resume(entry) }
        }
    }

    /// Takes the app controller explicitly (tests, or a launch with only incognito windows).
    func attach(appController: WorkspaceController) {
        self.appController = appController
    }

    private func unregister(_ id: UUID) {
        entries.removeAll { $0.id == id }
        if let observer = closeObservers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(observer) }
    }

    private func prune() {
        for entry in entries where entry.model == nil { unregister(entry.id) }
    }

    /// Browser windows front to back ([06 §29.2] observed: "windows, in front-to-back order").
    /// Windows AppKit does not list (not on screen yet) come last, in registration order.
    var windows: [Entry] {
        prune()
        let order = NSApplication.shared.orderedWindows
        func rank(_ entry: Entry) -> Int {
            guard let window = entry.window, let index = order.firstIndex(where: { $0 === window }) else { return Int.max }
            return index
        }
        return entries.enumerated()
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
    }

    func window(withID id: UUID) -> Entry? { windows.first { $0.id == id } }

    func entry(for model: ShellModel) -> Entry? { windows.first { $0.model === model } }

    /// Calls `resume` with the next browser window that registers, or nil after `timeout` seconds.
    func waitForNewWindow(timeout: TimeInterval, _ resume: @escaping (Entry?) -> Void) {
        var done = false
        let once: (Entry?) -> Void = { entry in
            guard !done else { return }
            done = true
            resume(entry)
        }
        windowWaiters.append((known: Set(entries.map(\.id)), resume: once))
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
            MainActor.assumeIsolated { once(nil) }
        }
    }

    // MARK: JavaScript gate

    /// View ▸ Developer ▸ Allow JavaScript from Apple Events ([01 §View] observed item; off by
    /// default, [06 §29.4] inferred). Read at each `execute`, so the menu toggle applies at once.
    func allowsJavaScript(for controller: WorkspaceController) -> Bool {
        controller.dependencies.preferences.allowsJavaScriptFromAppleEvents
    }
}
