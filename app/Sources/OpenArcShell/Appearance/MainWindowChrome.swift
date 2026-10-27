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
//
// B54: the buttons ride with the sidebar. With the sidebar hidden they sit where the collapsed
// floating panel keeps them, out of the window to the left (close x −274 = 17 − 291), and they
// come back inside the floating panel 5 pt right and down of their pinned spot (close (17, 21)).
// [06 §26.1, §26.2] observed. The moves use the motion of the surface they follow: ⌘S
// `Motion.sidebarToggle`, the peek `Motion.sidebarPeekSlide` ([07 §11], curves inferred / unknown).

/// Where the standard window buttons sit. [07 §2], [06 §26] observed.
enum WindowButtonPlacement: Equatable, Sendable {
    /// Next to the pinned sidebar's top bar. [07 §2] observed (close hit box at (12, 16)).
    case pinned
    /// The Library's own top bar: 3 right, 4 down. [07 §2] observed.
    case library
    /// Inside the floating sidebar: shifted with the panel by (5, 5), so they keep their spot
    /// relative to the sidebar. [06 §26.2] observed (close at (17, 21)).
    case peek
    /// Hidden sidebar: out of the window with the collapsed panel, close x −274, y as in the
    /// peek. [06 §26.1] observed; with the toolbar on too (the show-sidebar button leads the
    /// toolbar instead, [06 §17.2] observed).
    case hidden

    /// Offset from the pinned spot, in points (window coordinates, top-left origin).
    var offset: CGSize {
        switch self {
        case .pinned:
            return .zero
        case .library:
            return CGSize(width: Metrics.WindowButtons.libraryOffsetX, height: Metrics.WindowButtons.libraryOffsetY)
        case .peek:
            return CGSize(width: SidebarPeekTokens.panelInset, height: SidebarPeekTokens.panelInset)
        case .hidden:
            return CGSize(width: SidebarPeekTokens.panelInset - SidebarPeekTokens.collapsedOffset,
                          height: SidebarPeekTokens.panelInset)
        }
    }

    /// Whether the buttons are inside the window. Off-screen buttons are also hidden once they
    /// got there, so an AppKit title bar pass can never flash them over the web panel (inferred:
    /// [06 §26.2] observed no traffic lights at all while hidden).
    var isOnScreen: Bool { self != .hidden }

    /// The motion of a move between two placements: the surface the buttons follow. nil = no
    /// animation (Library switch: [07 §11] observed one-frame change; first placement).
    static func motion(from old: WindowButtonPlacement?, to new: WindowButtonPlacement) -> MotionToken? {
        guard let old, old != new else { return nil }
        switch (old, new) {
        case (.hidden, .peek), (.peek, .hidden):
            return Motion.sidebarPeekSlide
        case (.hidden, .pinned), (.pinned, .hidden), (.peek, .pinned):
            return Motion.sidebarToggle
        default:
            return nil
        }
    }
}

/// Pure geometry of the standard window buttons, in window coordinates (top-left origin).
enum WindowChromeLayout {
    /// Height of the title bar container while the buttons are moved: tall enough for the hit boxes
    /// (bottom at 32, 36 in the Library) plus the 8 pt grid. inferred (the reference's container
    /// is not exposed).
    static let titlebarHeight: CGFloat = 40

    /// Hit box of standard button `index` (0 close, 1 minimize, 2 zoom). [07 §2] observed.
    static func buttonFrame(index: Int, inLibrary: Bool) -> CGRect {
        buttonFrame(index: index, placement: inLibrary ? .library : .pinned)
    }

    /// Hit box of standard button `index` at `placement`. [07 §2], [06 §26] observed.
    static func buttonFrame(index: Int, placement: WindowButtonPlacement) -> CGRect {
        let origin = Metrics.WindowButtons.hitBoxOrigin(index: index)
        let size = CGFloat(Metrics.WindowButtons.hitBoxSize)
        return CGRect(x: origin.x + placement.offset.width, y: origin.y + placement.offset.height, width: size, height: size)
    }

    static let buttonTypes: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
}

/// Attach to the browser window's root view. `placement` says where the buttons go: next to the
/// sidebar, in the Library, inside the floating sidebar or out of the window with the hidden
/// sidebar ([06 §26] observed).
struct MainWindowChromeConfigurator: NSViewRepresentable {
    let placement: WindowButtonPlacement

    init(placement: WindowButtonPlacement) {
        self.placement = placement
    }

    /// `inLibrary` moves the buttons to the Library spot; `showsButtons` false sends them out of
    /// the window (the hidden sidebar).
    init(inLibrary: Bool, showsButtons: Bool = true) {
        self.placement = inLibrary ? .library : (showsButtons ? .pinned : .hidden)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        let coordinator = context.coordinator
        coordinator.probe = view
        view.onMoveToWindow = { [weak coordinator] in coordinator?.windowChanged() }
        coordinator.request(placement)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        context.coordinator.request(placement)
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var probe: NSView?
        private weak var window: NSWindow?
        private var placement: WindowButtonPlacement = .pinned
        /// The placement the last pass laid out; nil before the first one (no animation then).
        private var appliedPlacement: WindowButtonPlacement?
        /// A move is animating: frame changes are ours, not AppKit's, until it completes.
        private var isAnimating = false
        /// Bumped per animated move, so an older move's completion does not end a newer one.
        private var animationGeneration = 0
        private var isPassScheduled = false
        private var observedViews: [NSView] = []

        /// Passes run, and passes that moved at least one view (for tests: a settled window stops writing).
        private(set) var passCount = 0
        private(set) var writeCount = 0

        func request(_ placement: WindowButtonPlacement) {
            guard placement != self.placement || window == nil else { return }
            self.placement = placement
            schedulePass()
        }

        func request(inLibrary: Bool, showsButtons: Bool = true) {
            request(inLibrary ? .library : (showsButtons ? .pinned : .hidden))
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
            let placement = self.placement
            var changed = false
            // Coming back: show the buttons first, then move them in.
            if placement.isOnScreen, Self.applyVisibility(to: window, showsButtons: true) { changed = true }
            let motion = WindowButtonPlacement.motion(from: appliedPlacement, to: placement)
            appliedPlacement = placement
            if let motion, motion.curve != .instant, !window.styleMask.contains(.fullScreen),
               Self.needsLayout(window, placement: placement) {
                isAnimating = true
                animationGeneration += 1
                let generation = animationGeneration
                changed = true
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = motion.curve.nominalDuration
                    context.timingFunction = motion.curve.mediaTimingFunction
                    Self.apply(to: window, placement: placement, animated: true)
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.animationGeneration == generation else { return }
                        self.isAnimating = false
                        // Settle (and hide the buttons once they are out of the window).
                        self.schedulePass()
                    }
                }
            } else if !isAnimating {
                if Self.apply(to: window, placement: placement) { changed = true }
                if !placement.isOnScreen, Self.applyVisibility(to: window, showsButtons: false) { changed = true }
            }
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
            guard let window, !isAnimating else { return }
            if Self.needsLayout(window, placement: placement) { schedulePass() }
        }

        /// Shows or hides the three buttons. In full screen the system owns them, so they stay.
        /// Returns whether anything changed. [06 §26.2] observed: no traffic lights while hidden.
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
            needsLayout(window, placement: inLibrary ? .library : .pinned)
        }

        static func needsLayout(_ window: NSWindow, placement: WindowButtonPlacement) -> Bool {
            guard !window.styleMask.contains(.fullScreen) else { return false }
            guard let container = titlebarContainer(of: window), let host = container.superview else { return false }
            if container.frame != containerFrame(in: host) { return true }
            for (index, type) in WindowChromeLayout.buttonTypes.enumerated() {
                guard let button = window.standardWindowButton(type), let parent = button.superview else { continue }
                if button.frame.origin != buttonOrigin(index: index, placement: placement, button: button, in: parent, window: window) {
                    return true
                }
            }
            return false
        }

        /// Moves the container and the buttons where they belong. Returns whether anything moved.
        @discardableResult
        static func apply(to window: NSWindow, inLibrary: Bool) -> Bool {
            apply(to: window, placement: inLibrary ? .library : .pinned)
        }

        /// Moves the container and the buttons to `placement`; `animated` moves the buttons
        /// through their animator inside the caller's `NSAnimationContext` group.
        @discardableResult
        static func apply(to window: NSWindow, placement: WindowButtonPlacement, animated: Bool = false) -> Bool {
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
                let origin = buttonOrigin(index: index, placement: placement, button: button, in: parent, window: window)
                if button.frame.origin != origin {
                    if animated { button.animator().setFrameOrigin(origin) } else { button.setFrameOrigin(origin) }
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
        static func buttonOrigin(index: Int, placement: WindowButtonPlacement, button: NSView, in parent: NSView, window: NSWindow) -> CGPoint {
            // The button view is smaller than the 16 pt box the accessibility tree reports for it
            // (14 × 14 on macOS 14–26, the box outset by 1): center the view on the measured
            // circle center rather than aligning its origin to the box.
            let box = WindowChromeLayout.buttonFrame(index: index, placement: placement)
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
