import CoreGraphics
import OpenArcModel
import OpenArcDesign

// Pure placement of the floating bubbles (theme bubble, Site Control Center, hover card) and of
// the Little Arc window. [07 §12] observed. Rectangles are top-left based (y grows downward):
// window content coordinates for the bubbles, flipped screen coordinates for the hover card and
// Little Arc.

/// Side of its anchor a bubble opens on. The arrow sits on the bubble edge facing the anchor.
enum FloatingBubbleSide: Equatable, Sendable {
    /// Right of the anchor, vertically centered on it ("Choose a Theme"). [07 §12] observed.
    case trailing
    /// Below the anchor, horizontally centered on it (Site Control Center). [07 §12] observed.
    case below
}

/// The arrow of an attached bubble.
struct FloatingBubbleArrow: Equatable, Sendable {
    enum Edge: Equatable, Sendable { case leading, top }
    /// Bubble edge carrying the arrow.
    var edge: Edge
    /// Distance of the arrow's center from the bubble's top (leading edge) or left (top edge).
    var position: CGFloat
}

/// Where a bubble goes: its visible rectangle and its arrow, if any.
struct FloatingBubbleFrame: Equatable, Sendable {
    var bubble: CGRect
    var arrow: FloatingBubbleArrow?

    /// The bubble plus the room its arrow takes: the frame of the window that draws both.
    var outerFrame: CGRect {
        guard let arrow else { return bubble }
        let height = CGFloat(Metrics.FloatingBubble.arrowHeight)
        switch arrow.edge {
        case .leading: return CGRect(x: bubble.minX - height, y: bubble.minY, width: bubble.width + height, height: bubble.height)
        case .top: return CGRect(x: bubble.minX, y: bubble.minY - height, width: bubble.width, height: bubble.height + height)
        }
    }
}

/// Where the bubble is anchored, in window content coordinates (top-left origin).
enum FloatingBubblePlacement: Equatable, Sendable {
    /// Attached to `anchor` with an arrow ("Choose a Theme", Site Control Center).
    case attached(anchor: CGRect, side: FloatingBubbleSide)
    /// Edit Theme… from a menu: no arrow, next to the web panel, centered on the pointer's height.
    case editTheme(pointerY: CGFloat, webPanelMinX: CGFloat)
}

enum FloatingBubbleLayout {
    private typealias B = Metrics.FloatingBubble

    static func frame(for placement: FloatingBubblePlacement, size: CGSize, container: CGRect,
                      cornerRadius: CGFloat) -> FloatingBubbleFrame {
        switch placement {
        case let .attached(anchor, side):
            return attached(anchor: anchor, side: side, size: size, container: container, cornerRadius: cornerRadius)
        case let .editTheme(pointerY, webPanelMinX):
            return editTheme(pointerY: pointerY, webPanelMinX: webPanelMinX, size: size, container: container)
        }
    }

    /// A bubble attached to `anchor` with an arrow pointing at it, kept `windowMargin` inside
    /// `container`. The arrow follows the anchor's center but never enters the rounded corners.
    /// [07 §12] observed: the bubble edge is 13 pt right of / 12 pt below the anchor edge and
    /// centered on the anchor; behavior near the container edges inferred (clamped).
    static func attached(anchor: CGRect, side: FloatingBubbleSide, size: CGSize, container: CGRect,
                         cornerRadius: CGFloat) -> FloatingBubbleFrame {
        let margin = CGFloat(B.windowMargin)
        var origin: CGPoint
        switch side {
        case .trailing:
            origin = CGPoint(x: anchor.maxX + CGFloat(B.gapTrailing), y: anchor.midY - size.height / 2)
        case .below:
            origin = CGPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + CGFloat(B.gapBelow))
        }
        origin = clamp(origin, size: size, into: container.insetBy(dx: margin, dy: margin))
        let bubble = CGRect(origin: origin, size: size)
        let arrowLimit = cornerRadius + CGFloat(B.arrowBaseWidth) / 2
        switch side {
        case .trailing:
            let y = clamp(anchor.midY - bubble.minY, lower: arrowLimit, upper: size.height - arrowLimit)
            return FloatingBubbleFrame(bubble: bubble, arrow: FloatingBubbleArrow(edge: .leading, position: y))
        case .below:
            let x = clamp(anchor.midX - bubble.minX, lower: arrowLimit, upper: size.width - arrowLimit)
            return FloatingBubbleFrame(bubble: bubble, arrow: FloatingBubbleArrow(edge: .top, position: x))
        }
    }

    /// Edit Theme… (Spaces menu, Space context menu): no arrow; the bubble's left edge is 13 pt
    /// right of the web panel's left edge and it is vertically centered on the pointer, kept 13 pt
    /// inside the window. [07 §12] observed (six pointer heights, both clamps).
    static func editTheme(pointerY: CGFloat, webPanelMinX: CGFloat, size: CGSize, container: CGRect) -> FloatingBubbleFrame {
        let margin = CGFloat(B.windowMargin)
        let origin = CGPoint(x: webPanelMinX + CGFloat(B.editThemeLeadingInset), y: pointerY - size.height / 2)
        let bubble = CGRect(origin: clamp(origin, size: size, into: container.insetBy(dx: margin, dy: margin)), size: size)
        return FloatingBubbleFrame(bubble: bubble, arrow: nil)
    }

    /// The tab hover card: at the pointer (not at the row), offset (11.5, 5.5), kept inside
    /// `screen` (visible frame, flipped). [07 §12] observed; the screen clamp is inferred.
    static func hoverCard(pointer: CGPoint, size: CGSize, screen: CGRect) -> CGRect {
        let h = Metrics.HoverCard.self
        let origin = CGPoint(x: pointer.x + CGFloat(h.pointerOffsetX), y: pointer.y + CGFloat(h.pointerOffsetY))
        return CGRect(origin: clamp(origin, size: size, into: screen), size: size)
    }

    /// Little Arc opens at the top right of the screen's visible area, 20 pt in from its right and
    /// top edges. [07 §12] observed. `visible` is flipped (top-left origin).
    static func littleArcOrigin(size: CGSize, visible: CGRect) -> CGPoint {
        let margin = CGFloat(Metrics.LittleArc.screenMargin)
        return clamp(CGPoint(x: visible.maxX - margin - size.width, y: visible.minY + margin), size: size, into: visible)
    }

    // MARK: Helpers

    /// Moves `origin` so a rectangle of `size` stays inside `bounds`; a rectangle larger than
    /// `bounds` keeps its top-left edge inside.
    static func clamp(_ origin: CGPoint, size: CGSize, into bounds: CGRect) -> CGPoint {
        CGPoint(
            x: clamp(origin.x, lower: bounds.minX, upper: bounds.maxX - size.width),
            y: clamp(origin.y, lower: bounds.minY, upper: bounds.maxY - size.height)
        )
    }

    private static func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        max(lower, min(value, max(lower, upper)))
    }

    /// Converts a top-left based rectangle inside a bottom-left based space of height `height`
    /// (and back: the conversion is its own inverse).
    static func flip(_ rect: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
    }
}
