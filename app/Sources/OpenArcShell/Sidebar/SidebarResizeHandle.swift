import SwiftUI
import AppKit
import OpenArcDesign

// The seam between the sidebar and the web panel: hovering shows the system left-right resize
// cursor, dragging resizes the sidebar live (B144). The drag area, limits, snap and collapse are
// Arc's, inferred: `Metrics.Sidebar.resizeHandle*`, `SidebarWidth`. AppKit, not a
// SwiftUI gesture, so the cursor is the real system cursor and the drag never reaches the web view
// under it (like `SplitDividerHandle`, B58).

/// Hosts `SidebarResizeHandleView` over the seam.
struct SidebarResizeHandle: NSViewRepresentable {
    let onBegin: () -> Void
    /// The horizontal distance the pointer moved since the press, in points (right is positive).
    let onDrag: (Double) -> Void
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: SidebarResizeHandleView) {
        view.onBegin = onBegin
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

final class SidebarResizeHandleView: NSView {
    var onBegin: (() -> Void)?
    var onDrag: ((Double) -> Void)?
    var onEnd: (() -> Void)?

    /// The press location in screen coordinates: the translation is measured on screen, so it
    /// does not depend on this view, which moves with the seam while the sidebar resizes.
    private var pressOnScreen: NSPoint?
    private var didMove = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static let cursor: NSCursor = .resizeLeftRight

    private var tracking: NSTrackingArea?

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
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

    override func mouseEntered(with event: NSEvent) { claimCursor() }
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

    override func mouseDown(with event: NSEvent) {
        pressOnScreen = screenPoint(event)
        didMove = false
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
