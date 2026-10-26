import SwiftUI
import AppKit
import OpenArcDesign

// Places the window's standard buttons ("traffic lights") where the reference measures them:
// 16 pt hit boxes at (12, 16), (35, 16), (58, 16), circle centers (20, 24), (43, 24), (66, 24)
// [07 §2] observed; in the Library 3 pt right and 4 pt lower [07 §2] observed. The sidebar's own
// toolbar buttons are SwiftUI views at their measured frames (`SidebarTopBarView`).
//
// AppKit lays the title bar out again on resize, key changes, appearance changes and full screen,
// and puts the buttons back at its default spot. So the coordinator watches the buttons' and the
// title bar container's frames and the window notifications, and re-applies the layout. Following
// B28, it never writes from inside `updateNSView`, coalesces work into one pass per run-loop turn,
// and writes a frame only when it differs (so its own writes end the cycle). In full screen the
// system owns the title bar (it slides in from the top), so nothing is moved there.

/// Pure geometry of the standard window buttons, in window coordinates (top-left origin).
enum WindowChromeLayout {
    /// Height of the title bar container while the buttons are moved: tall enough for the hit boxes
    /// (bottom at 32, 36 in the Library) plus the 8 pt grid. inferred (the reference's container
    /// is not exposed).
    static let titlebarHeight: CGFloat = 40

    /// Hit box of standard button `index` (0 close, 1 minimize, 2 zoom). [07 §2] observed.
    static func buttonFrame(index: Int, inLibrary: Bool) -> CGRect {
        let origin = Metrics.WindowButtons.hitBoxOrigin(index: index, inLibrary: inLibrary)
        let size = CGFloat(Metrics.WindowButtons.hitBoxSize)
        return CGRect(x: origin.x, y: origin.y, width: size, height: size)
    }

    static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
}

/// Attach to the browser window's root view. `inLibrary` moves the buttons to the Library spot;
/// `showsButtons` false hides them (the hidden sidebar, [06 §14] observed).
struct MainWindowChromeConfigurator: NSViewRepresentable {
    let inLibrary: Bool
    var showsButtons: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        let coordinator = context.coordinator
        coordinator.probe = view
        view.onMoveToWindow = { [weak coordinator] in coordinator?.windowChanged() }
        coordinator.request(inLibrary: inLibrary, showsButtons: showsButtons)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.request(inLibrary: inLibrary, showsButtons: showsButtons)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var probe: NSView?
        private weak var window: NSWindow?
        private var inLibrary = false
        private var showsButtons = true
        private var isPassScheduled = false
        private var observedViews: [NSView] = []

        /// Passes run, and passes that moved at least one view (for tests: a settled window stops writing).
        private(set) var passCount = 0
        private(set) var writeCount = 0

        func request(inLibrary: Bool, showsButtons: Bool = true) {
            guard inLibrary != self.inLibrary || showsButtons != self.showsButtons || window == nil else { return }
            self.inLibrary = inLibrary
            self.showsButtons = showsButtons
            schedulePass()
        }

        func windowChanged() { schedulePass() }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            observedViews = []
            window = nil
        }

        private func schedulePass() {
            guard !isPassScheduled else { return }
            isPassScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.runPass() }
            }
        }

        private func runPass() {
            isPassScheduled = false
            guard let window = probe?.window else { return }
            attach(to: window)
            passCount += 1
            var changed = Self.apply(to: window, inLibrary: inLibrary)
            if Self.applyVisibility(to: window, showsButtons: showsButtons) { changed = true }
            if changed { writeCount += 1 }
        }

        private func attach(to window: NSWindow) {
            guard self.window !== window else { return }
            detach()
            self.window = window
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                NSWindow.didExitFullScreenNotification, NSWindow.didChangeBackingPropertiesNotification,
                NSWindow.didChangeScreenNotification,
            ]
            for name in names {
                center.addObserver(self, selector: #selector(windowDidChange(_:)), name: name, object: window)
            }
            // AppKit moves the buttons back during its own title bar layout: watch their frames.
            var views: [NSView] = WindowChromeLayout.buttonTypes.compactMap { window.standardWindowButton($0) }
            if let container = Self.titlebarContainer(of: window) { views.append(container) }
            for view in views {
                view.postsFrameChangedNotifications = true
                center.addObserver(self, selector: #selector(viewFrameDidChange(_:)), name: NSView.frameDidChangeNotification, object: view)
            }
            observedViews = views
        }

        @objc private func windowDidChange(_ notification: Notification) { schedulePass() }

        @objc private func viewFrameDidChange(_ notification: Notification) {
            // Only a frame that is not where we want it needs a pass; our own writes land here too.
            guard let window else { return }
            if Self.needsLayout(window, inLibrary: inLibrary) { schedulePass() }
        }

        /// Shows or hides the three buttons. In full screen the system owns them, so they stay.
        /// Returns whether anything changed. [06 §14] observed: hidden with the sidebar.
        @discardableResult
        static func applyVisibility(to window: NSWindow, showsButtons: Bool) -> Bool {
            let hidden = !showsButtons && !window.styleMask.contains(.fullScreen)
            var changed = false
            for type in WindowChromeLayout.buttonTypes {
                guard let button = window.standardWindowButton(type), button.isHidden != hidden else { continue }
                button.isHidden = hidden
                changed = true
            }
            return changed
        }

        /// The view that holds the title bar (the buttons' superview's superview).
        static func titlebarContainer(of window: NSWindow) -> NSView? {
            window.standardWindowButton(.closeButton)?.superview?.superview
        }

        /// Whether any button or the container is not at its wanted frame.
        static func needsLayout(_ window: NSWindow, inLibrary: Bool) -> Bool {
            guard !window.styleMask.contains(.fullScreen) else { return false }
            guard let container = titlebarContainer(of: window), let host = container.superview else { return false }
            if container.frame != containerFrame(in: host) { return true }
            for (index, type) in WindowChromeLayout.buttonTypes.enumerated() {
                guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
                if button.frame.origin != buttonOrigin(index: index, inLibrary: inLibrary, button: button, in: parent, window: window) {
                    return true
                }
            }
            return false
        }

        /// Moves the container and the buttons where they belong. Returns whether anything moved.
        @discardableResult
        static func apply(to window: NSWindow, inLibrary: Bool) -> Bool {
            guard !window.styleMask.contains(.fullScreen) else { return false }
            guard let container = titlebarContainer(of: window), let host = container.superview else { return false }
            var changed = false
            let wanted = containerFrame(in: host)
            if container.frame != wanted {
                container.frame = wanted
                changed = true
            }
            for (index, type) in WindowChromeLayout.buttonTypes.enumerated() {
                guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
                // The title bar view fills the container; make sure it was resized with it.
                if parent !== container, parent.frame != container.bounds {
                    parent.frame = container.bounds
                    changed = true
                }
                let origin = buttonOrigin(index: index, inLibrary: inLibrary, button: button, in: parent, window: window)
                if button.frame.origin != origin {
                    button.setFrameOrigin(origin)
                    changed = true
                }
            }
            return changed
        }

        /// The container across the window top, `titlebarHeight` tall, in its superview's coordinates.
        static func containerFrame(in host: NSView) -> CGRect {
            let height = WindowChromeLayout.titlebarHeight
            let y = host.isFlipped ? 0 : host.bounds.height - height
            return CGRect(x: 0, y: y, width: host.bounds.width, height: height)
        }

        /// Origin of a button in its superview, converted from the window-top-left hit box.
        static func buttonOrigin(index: Int, inLibrary: Bool, button: NSView, in parent: NSView, window: NSWindow) -> CGPoint {
            // The button view is smaller than the 16 pt box the accessibility tree reports for it
            // (14 × 14 on macOS 14–26, the box outset by 1): center the view on the measured
            // circle center rather than aligning its origin to the box.
            let box = WindowChromeLayout.buttonFrame(index: index, inLibrary: inLibrary)
            guard let theme = window.contentView?.superview else { return button.frame.origin }
            let size = button.frame.size
            let rectInTheme = CGRect(
                x: box.midX - size.width / 2,
                y: theme.isFlipped ? box.midY - size.height / 2 : theme.bounds.height - box.midY - size.height / 2,
                width: size.width, height: size.height
            )
            let origin = parent.convert(rectInTheme, from: theme).origin
            return CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        }
    }

    /// Tells the coordinator when it lands in a window. Transparent to the mouse.
    final class ProbeView: NSView {
        var onMoveToWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onMoveToWindow?() }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
