import SwiftUI
import AppKit
import OpenArcDesign

// The seam between the sidebar and the web panel: hovering shows the system left-right resize
// cursor, dragging resizes the sidebar live (B144). The drag area, limits, snap and collapse are
// Arc's, inferred (analysis): `Metrics.Sidebar.resizeHandle*`, `SidebarWidth`. AppKit, not a
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: Self.cursor)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
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
