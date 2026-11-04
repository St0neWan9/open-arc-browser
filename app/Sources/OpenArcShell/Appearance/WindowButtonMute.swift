import AppKit
import OpenArcDesign

// Muted traffic lights (B160). Arc shows the window's standard buttons as plain discs in a light
// shade of the window color while the window is active, not in red / yellow / green: black ≈ 8 %
// over the sidebar (#C9C9DB on #DBDBEE, 12 pt, no rim), the same as when it is inactive. [07 §2]
// observed (2026-11-04, active and inactive captures). Arc keeps a hover state for the button
// region, so the colored buttons come back while the pointer is over them (inferred:
// its binary tracks a traffic-light region hover state; the hover look itself was not captured).
//
// The standard buttons stay in place and clickable (they keep their accessibility and behavior);
// while muted they are fully transparent and a mouse-transparent view in the same title bar view
// draws the three discs over their circles. Hovering the group shows the real buttons.

/// Draws the three muted discs and watches the pointer over the button group.
final class WindowButtonMuteView: NSView {
    /// Disc centers in this view's coordinates, one per button.
    var discCenters: [CGPoint] = [] { didSet { needsDisplay = true } }
    /// Called with true when the pointer enters the group, false when it leaves.
    var onHover: ((Bool) -> Void)?
    private(set) var isHovered = false
    private var tracking: NSTrackingArea?

    static let identifier = NSUserInterfaceItemIdentifier("openarc.windowButtonMute")

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    func setHovered(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        needsDisplay = true
        onHover?(hovered)
    }

    /// Disc fill over the window: black ≈ 8 % in light ([07 §2] observed); white 12 % in dark
    /// (unknown, not captured).
    static func discColor(isDark: Bool) -> NSColor {
        isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.082)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHovered else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Self.discColor(isDark: isDark).setFill()
        let d = CGFloat(Metrics.WindowButtons.diameter)
        for c in discCenters {
            NSBezierPath(ovalIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)).fill()
        }
    }
}

extension MainWindowChromeConfigurator.Coordinator {
    /// Keeps the mute view over the buttons and the buttons' transparency in step with the hover.
    /// In full screen the system's title bar shows the normal buttons. `animated` moves the view
    /// with the buttons inside the caller's animation group.
    static func syncMute(in window: NSWindow, animated: Bool = false, targetOrigins: [CGPoint]? = nil) {
        let buttons = WindowChromeLayout.buttonTypes.compactMap { window.standardWindowButton($0) }
        guard buttons.count == 3, let parent = buttons[0].superview else { return }
        let mute = (parent.subviews.first { $0.identifier == WindowButtonMuteView.identifier } as? WindowButtonMuteView)
            ?? {
                let view = WindowButtonMuteView()
                view.identifier = WindowButtonMuteView.identifier
                view.wantsLayer = true
                parent.addSubview(view, positioned: .above, relativeTo: buttons[2])
                return view
            }()
        let fullScreen = window.styleMask.contains(.fullScreen)
        let hidden = fullScreen || buttons[0].isHidden
        // Mid-animation the buttons' frames lag: follow the frames they are moving to.
        let frames = buttons.enumerated().map { index, button in
            guard let origins = targetOrigins, index < origins.count else { return button.frame }
            return CGRect(origin: origins[index], size: button.frame.size)
        }
        let union = frames.dropFirst().reduce(frames[0]) { $0.union($1) }
        if mute.frame != union {
            if animated { mute.animator().frame = union } else { mute.frame = union }
        }
        mute.discCenters = frames.map { CGPoint(x: $0.midX - union.minX, y: $0.midY - union.minY) }
        mute.isHidden = hidden
        let showsReal = hidden || mute.isHovered
        let alpha: CGFloat = showsReal ? 1 : 0
        for button in buttons where button.alphaValue != alpha { button.alphaValue = alpha }
        mute.onHover = { [weak window] _ in
            guard let window else { return }
            MainActor.assumeIsolated { syncMute(in: window) }
        }
    }
}
