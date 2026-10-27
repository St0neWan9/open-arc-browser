import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The interactive divider in the gap between two split panes (plan B58).
// Spec: docs/arc-spec/06-flows.md §21.6 "调整比例" (E19 capture), observed: the 10 pt gap shows the
// system left-right resize cursor, a drag resizes the neighbors live, double-click does nothing,
// and a short grip (≈ 2 × 22 pt, ≈ #A7A2AA) sits centered in the gap. Up-down cursor for
// vertical splits: inferred.

/// The grip drawn centered in a divider's gap.
struct SplitDividerGrip: View {
    let axis: SplitAxis

    var body: some View {
        let t = Metrics.SplitDivider.self
        Capsule(style: .continuous)
            .fill(t.gripColor.swiftUI)
            .frame(width: axis == .horizontal ? t.gripThickness : t.gripLength,
                   height: axis == .horizontal ? t.gripLength : t.gripThickness)
            .allowsHitTesting(false)
    }
}

/// Hosts the AppKit view that owns the cursor and the drag. AppKit, not a SwiftUI gesture, so the
/// cursor is the real system resize cursor on macOS 14 and the drag never reaches the web views.
struct SplitDividerHandle: NSViewRepresentable {
    let axis: SplitAxis
    /// Where the press started along the axis, in the split node's coordinates, is the divider's
    /// leading edge plus the pointer's offset inside the gap; this is that leading edge.
    let dividerStart: Double
    /// Called on every drag step with the pointer position along the axis, in the split node's
    /// coordinates.
    let onDrag: (Double) -> Void
    /// Called when the button is released after the pointer moved.
    let onEnd: () -> Void

    func makeNSView(context: Context) -> SplitDividerHandleView {
        let view = SplitDividerHandleView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: SplitDividerHandleView, context: Context) {
        update(nsView)
    }

    private func update(_ view: SplitDividerHandleView) {
        if view.axis != axis {
            view.axis = axis
            view.window?.invalidateCursorRects(for: view)
        }
        view.dividerStart = dividerStart
        view.onDrag = onDrag
        view.onEnd = onEnd
    }
}

final class SplitDividerHandleView: NSView {
    var axis: SplitAxis = .horizontal
    var dividerStart: Double = 0
    var onDrag: ((Double) -> Void)?
    var onEnd: (() -> Void)?

    /// The pointer along the axis at the press, in the split's coordinates, and in the window.
    private var pressStart: (inSplit: Double, inWindow: NSPoint)?
    private var didMove = false

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cursor: NSCursor { axis == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        pressStart = (dividerStart + (axis == .horizontal ? local.x : local.y), event.locationInWindow)
        didMove = false
        // [06 §21.6] observed: double-click does nothing, so the click count is ignored.
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressStart else { return }
        cursor.set()
        didMove = true
        onDrag?(Self.pointer(pressInSplit: pressStart.inSplit, pressInWindow: pressStart.inWindow,
                             nowInWindow: event.locationInWindow, axis: axis))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressStart = nil; didMove = false }
        guard pressStart != nil, didMove else { return }
        onEnd?()
    }

    /// The pointer along the axis in the split's coordinates. Window coordinates grow upward, the
    /// split's downward. Measured from the press so the result does not depend on this view's own
    /// frame, which moves while the panes resize.
    static func pointer(pressInSplit: Double, pressInWindow: NSPoint, nowInWindow: NSPoint, axis: SplitAxis) -> Double {
        switch axis {
        case .horizontal: return pressInSplit + (nowInWindow.x - pressInWindow.x)
        case .vertical: return pressInSplit - (nowInWindow.y - pressInWindow.y)
        }
    }
}
