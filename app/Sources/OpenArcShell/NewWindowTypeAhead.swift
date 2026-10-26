import AppKit

// B29: keys typed right after a keyboard command opened a new window (⌥⌘N, ⌘N…) arrive before
// that window exists or is key. AppKit hands them to the old key window (or to nobody), so the
// first letters of a URL typed right after ⌥⌘N were lost ("example.edu" became "mple.edu"), and
// ⌘T right after ⌘N opened the command bar in the old window.
//
// While a new window is on its way, this buffer holds every key-down. Once the window is ready
// (a browser window: registered and key; Little Arc: its command bar field has the keyboard), the
// keys are sent to it, in order. ⌘T / ⌘L held for a new browser window open its command bar, and
// the keys after them wait for that bar's field to take the keyboard. Nothing waits longer than
// the stage's timeout; then the keys go to whatever window is key.

enum NewWindowTypeAheadTiming {
    /// Longest time keys wait for a new window. Our own value.
    static let windowTimeout: TimeInterval = 1.0
    /// Longest time keys typed after a shortcut wait for a command bar field. Our own value.
    static let fieldTimeout: TimeInterval = 0.5
}

@MainActor
final class NewWindowTypeAhead {
    /// What the held keys wait for.
    enum Target: Equatable, Sendable {
        /// A new browser window (⌘N, ⌃⌘N, ⇧⌘N).
        case browserWindow
        /// A new Little Arc window (⌥⌘N): its command bar field.
        case littleArc
        /// A command bar field, after a shortcut was delivered (⌘N then ⌘T).
        case commandBarField
    }

    static let shared = NewWindowTypeAhead()

    /// What the held keys wait for; nil while nothing is held.
    private(set) var target: Target?
    private(set) var buffered: [NSEvent] = []
    /// Sends one released key: a shortcut (with ⌘) to the app, which offers it to the menus
    /// first; any other key straight to the window that waited for it (nil: the key window).
    /// Tests replace it.
    var send: (NSEvent, NSWindow?) -> Void = { event, window in
        if let window, !event.modifierFlags.contains(.command) {
            window.sendEvent(event)
        } else {
            NSApp?.sendEvent(event)
        }
    }
    /// Whether holding installs the app's key monitor (tests feed `capture` directly).
    var installsMonitor = true

    private var monitor: Any?
    private var generation = 0

    init() {}

    /// A command is opening a window of `target`'s kind: hold keys until it is ready. Keys
    /// already held stay first in line.
    func begin(_ target: Target) {
        hold(for: target, timeout: target == .commandBarField ? NewWindowTypeAheadTiming.fieldTimeout : NewWindowTypeAheadTiming.windowTimeout)
    }

    /// Holds `event` while something is on its way. Returns whether it was held.
    @discardableResult
    func capture(_ event: NSEvent) -> Bool {
        guard target != nil, event.type == .keyDown else { return false }
        buffered.append(event)
        return true
    }

    /// A new browser window is registered and key. `perform` runs a held shortcut on the window's
    /// model directly and returns whether it did (SwiftUI's menu commands follow the key window a
    /// moment late, so a menu shortcut sent now could still act on the old window).
    func browserWindowIsReady(_ window: NSWindow, perform: @escaping (NSEvent) -> Bool) {
        guard target == .browserWindow else { return }
        release(to: window, perform: perform)
    }

    /// A command bar field in `window` has the keyboard: a Little Arc window is ready
    /// (`isLittleArc`), and keys typed after a shortcut go into the field.
    /// Delivery runs on the next run-loop turn: the field may report focus from inside a SwiftUI
    /// view update, and typed text changes published state.
    func commandBarFieldIsReady(in window: NSWindow, isLittleArc: Bool) {
        guard Self.isWaiting(for: target, littleArc: isLittleArc) else { return }
        let current = generation
        DispatchQueue.main.async { [weak self, weak window] in
            MainActor.assumeIsolated {
                guard let self, let window, self.generation == current,
                      Self.isWaiting(for: self.target, littleArc: isLittleArc) else { return }
                self.release(to: window)
            }
        }
    }

    private static func isWaiting(for target: Target?, littleArc: Bool) -> Bool {
        switch target {
        case .littleArc: return littleArc
        case .commandBarField: return true
        case .browserWindow, nil: return false
        }
    }

    private func hold(for target: Target, timeout: TimeInterval) {
        self.target = target
        generation &+= 1
        installMonitor()
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == current, self.target != nil else { return }
                self.release(to: nil)
            }
        }
    }

    /// Sends the held keys to `window` (nil: unchanged, to the key window). A shortcut `perform`
    /// ran opened a command bar: the keys after it wait for its field.
    private func release(to window: NSWindow?, perform: ((NSEvent) -> Bool)? = nil) {
        removeMonitor()
        target = nil
        generation &+= 1
        while !buffered.isEmpty {
            let event = buffered.removeFirst()
            if event.modifierFlags.contains(.command), let perform, perform(event) {
                if !buffered.isEmpty { hold(for: .commandBarField, timeout: NewWindowTypeAheadTiming.fieldTimeout) }
                return
            }
            send(window.map { Self.retarget(event, to: $0) } ?? event, window)
            // The key may have started another wait (⌥⌘N, ⌘N): the later keys are for that.
            if target != nil { return }
        }
    }

    private func installMonitor() {
        guard installsMonitor, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let held = MainActor.assumeIsolated { self?.capture(event) ?? false }
            return held ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The same key, addressed to `window`.
    static func retarget(_ event: NSEvent, to window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: event.type,
            location: .zero,
            modifierFlags: event.modifierFlags,
            timestamp: event.timestamp,
            windowNumber: window.windowNumber,
            context: nil,
            characters: event.characters ?? "",
            charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
            isARepeat: event.isARepeat,
            keyCode: event.keyCode
        ) ?? event
    }
}
