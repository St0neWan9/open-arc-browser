import SwiftUI
import AppKit
import QuartzCore
import OpenArcModel
import OpenArcDesign

// The seam between the sidebar and the web panel: hovering shows the system left-right resize
// cursor, dragging resizes the sidebar live (B144). The drag area, limits, snap and collapse are
// Arc's, inferred: `Metrics.Sidebar.resizeHandle*`, `SidebarWidth`. AppKit, not a
// SwiftUI gesture, so the cursor is the real system cursor and the drag never reaches the web view
// under it (like `SplitDividerHandle`, B58). A line in the theme's strongest tone shows on the
// seam while it is hovered or dragged and pulses when the drag snaps to the default width (B157,
// `Metrics.Sidebar.resizeIndicator*`).

/// Hosts `SidebarResizeHandleView` over the seam.
struct SidebarResizeHandle: NSViewRepresentable {
    /// The seam line's color (`ThemePalette.seamIndicator`), drawn at the indicator opacity.
    let indicatorColor: RGBAColor
    /// Changes each time a drag snaps to the default width (`ShellModel.sidebarResizeSnapCount`).
    let snapCount: Int
    let onBegin: () -> Void
    /// The horizontal distance the pointer moved since the press, in points (right is positive).
    let onDrag: (Double) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        update(view)
        view.snapCount = snapCount
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        update(nsView)
        if nsView.snapCount != snapCount {
            nsView.snapCount = snapCount
            nsView.pulseIndicator()
        }
    }

    private func update(_ view: SidebarResizeHandleView) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
        view.indicatorColor = NSColor(srgbRed: indicatorColor.red, green: indicatorColor.green,
                                      blue: indicatorColor.blue, alpha: indicatorColor.alpha)
    }
}

final class SidebarResizeHandleView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((Double) -> Void)?
    var onEnd: (() -> Void)?
    var snapCount = 0
    var indicatorColor: NSColor = .clear {
        didSet { indicator.backgroundColor = indicatorColor.cgColor }
    }

    /// The press location in screen coordinates: the translation is measured on screen, so it
    /// does not depend on this view, which moves with the seam while the sidebar resizes.
    private var pressOnScreen: NSPoint?
    private var didMove = false
    private var tracking: NSTrackingArea?
    private(set) var isHovered = false
    private var pendingShow: DispatchWorkItem?

    /// The seam line. It is centered on this view's left edge, so half of it lies outside the view.
    let indicator = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        clipsToBounds = false
        indicator.opacity = 0
        indicator.isHidden = true
        indicator.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(indicator)
        layoutIndicator()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let cursor: NSCursor = .resizeLeftRight

    /// The line's frame in this view: `resizeIndicatorWidth` wide around x = 0, inset
    /// `resizeIndicatorEndInset` from the top and bottom. [07 §1] inferred, B157.
    static func indicatorFrame(in bounds: CGRect) -> CGRect {
        let s = Metrics.Sidebar.self
        let width = s.resizeIndicatorWidth, inset = s.resizeIndicatorEndInset
        return CGRect(x: bounds.minX - width / 2, y: bounds.minY + inset,
                      width: width, height: max(0, bounds.height - 2 * inset))
    }

    private func layoutIndicator() {
        let frame = Self.indicatorFrame(in: bounds)
        indicator.bounds = CGRect(origin: .zero, size: frame.size)
        indicator.position = CGPoint(x: frame.midX, y: frame.midY)
        indicator.cornerRadius = frame.width / 2
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
        layoutIndicator()
    }

    // A cursor rect alone is not enough: the views under the seam (the engine's page view and the
    // sidebar's scroll view) get mouse-moved events through their own tracking areas and set their
    // cursor on each one. The seam sets its cursor on every move as well, and once more after the
    // event is handled, so it wins over them.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate,
                                                         .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        claimCursor()
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(false)
    }

    override func mouseMoved(with event: NSEvent) { claimCursor() }
    override func cursorUpdate(with event: NSEvent) { claimCursor() }

    private func claimCursor() {
        Self.cursor.set()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isPointerInside else { return }
            Self.cursor.set()
        }
    }

    private var isPointerInside: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point)
    }

    // MARK: Indicator (B157)

    /// Hover in shows the line after a short delay with a fade; hover out fades it at once. Hover
    /// changes during a drag only update the state, so the line stays while dragging.
    private func setHovered(_ hovered: Bool) {
        isHovered = hovered
        guard pressOnScreen == nil else { return }
        pendingShow?.cancel()
        pendingShow = nil
        if hovered {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.isHovered, self.pressOnScreen == nil else { return }
                self.fadeIndicator(visible: true)
            }
            pendingShow = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Metrics.Sidebar.resizeIndicatorHoverDelay, execute: work)
        } else {
            fadeIndicator(visible: false)
        }
    }

    private func fadeIndicator(visible: Bool) {
        let target = Float(visible ? Metrics.Sidebar.resizeIndicatorOpacity : 0)
        let current = indicator.presentation()?.opacity ?? indicator.opacity
        indicator.removeAnimation(forKey: "fade")
        if visible { indicator.isHidden = false }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = indicator.isHidden ? 0 : current
        fade.toValue = target
        fade.duration = Metrics.Sidebar.resizeIndicatorFadeDuration
        fade.timingFunction = CAMediaTimingFunction(name: .linear)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !visible {
            CATransaction.setCompletionBlock { [weak self] in
                guard let self, self.indicator.opacity == 0 else { return }
                self.indicator.isHidden = true
            }
        }
        indicator.opacity = target
        indicator.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    /// A press shows the line at once.
    private func showIndicatorNow() {
        pendingShow?.cancel()
        pendingShow = nil
        indicator.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        indicator.isHidden = false
        indicator.opacity = Float(Metrics.Sidebar.resizeIndicatorOpacity)
        CATransaction.commit()
    }

    /// The drag snapped to the default width: the line widens and back, with a haptic tap.
    func pulseIndicator() {
        let s = Metrics.Sidebar.self
        let pulse = CABasicAnimation(keyPath: "transform.scale.x")
        pulse.fromValue = 1
        pulse.toValue = s.resizeIndicatorSnapScale
        pulse.duration = s.resizeIndicatorSnapHalfDuration
        pulse.autoreverses = true
        pulse.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
        indicator.add(pulse, forKey: "snap")
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    // MARK: Drag

    override func mouseDown(with event: NSEvent) {
        pressOnScreen = screenPoint(event)
        didMove = false
        showIndicatorNow()
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = pressOnScreen, let now = screenPoint(event) else { return }
        Self.cursor.set()
        didMove = true
        onDrag?(Self.translation(from: start, to: now))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressOnScreen = nil; didMove = false }
        guard pressOnScreen != nil else { return }
        onEnd?()
        // The line stays while the pointer is still on the seam, else it fades out.
        isHovered = isPointerInside
        if !isHovered { fadeIndicator(visible: false) }
    }

    /// Horizontal movement between two screen points (screen x grows to the right).
    static func translation(from start: NSPoint, to now: NSPoint) -> Double {
        Double(now.x - start.x)
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint? {
        guard let window = event.window ?? window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
}
