import Foundation
import OpenArcModel
import OpenArcDesign

// Pure geometry of the Easel canvas (plan B56): hit testing, resize handles, normalizing arrow and
// pen points into a frame, flipping them when a resize crosses over. No UI framework, so tests can
// drive it directly. Values come from `Metrics.Easel` (inferred tokens).

/// A corner handle of the selected element. Handles are our own (unknown in [06 §9]).
enum EaselHandle: CaseIterable, Hashable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    var isRight: Bool { self == .topRight || self == .bottomRight }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }

    /// The handle's point on `frame`.
    func point(on frame: EaselRect) -> EaselPoint {
        EaselPoint(x: isRight ? frame.maxX : frame.x, y: isBottom ? frame.maxY : frame.y)
    }

    /// The corner that stays put while this handle moves.
    func fixedCorner(of frame: EaselRect) -> EaselPoint {
        EaselPoint(x: isRight ? frame.x : frame.maxX, y: isBottom ? frame.y : frame.maxY)
    }
}

enum EaselGeometry {
    static func distance(_ a: EaselPoint, _ b: EaselPoint) -> Double {
        ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
    }

    /// Distance from `p` to the segment `a`–`b`.
    static func distance(_ p: EaselPoint, toSegment a: EaselPoint, _ b: EaselPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return distance(p, EaselPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    /// A normalized point (0...1 inside `frame`) in canvas coordinates.
    static func denormalize(_ p: EaselPoint, in frame: EaselRect) -> EaselPoint {
        EaselPoint(x: frame.x + p.x * frame.width, y: frame.y + p.y * frame.height)
    }

    /// A canvas point as 0...1 inside `frame` (0.5 on a degenerate axis).
    static func normalize(_ p: EaselPoint, in frame: EaselRect) -> EaselPoint {
        EaselPoint(
            x: frame.width > 0 ? (p.x - frame.x) / frame.width : 0.5,
            y: frame.height > 0 ? (p.y - frame.y) / frame.height : 0.5
        )
    }

    /// The bounding box of `points`, grown around its center so no side is below `minimumSide`.
    static func boundingFrame(_ points: [EaselPoint], minimumSide: Double = Metrics.Easel.minimumElementSide) -> EaselRect {
        guard let first = points.first else { return EaselRect(x: 0, y: 0, width: minimumSide, height: minimumSide) }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return grown(EaselRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), minimumSide: minimumSide)
    }

    /// `rect` grown around its center so no side is below `minimumSide`.
    static func grown(_ rect: EaselRect, minimumSide: Double = Metrics.Easel.minimumElementSide) -> EaselRect {
        var r = rect
        if r.width < minimumSide { r.x -= (minimumSide - r.width) / 2; r.width = minimumSide }
        if r.height < minimumSide { r.y -= (minimumSide - r.height) / 2; r.height = minimumSide }
        return r
    }

    /// A frame of `size` centered on `center`.
    static func frame(centeredAt center: EaselPoint, size: Size2D) -> EaselRect {
        EaselRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// Whether `p` hits `element`: inside its frame (grown by `slop`) for filled kinds, near the
    /// line for arrows and pen strokes.
    static func hits(_ element: EaselElement, at p: EaselPoint, slop: Double = Metrics.Easel.hitSlop) -> Bool {
        let frame = element.frame
        let reach = slop + element.style.strokeWidth / 2
        switch element.content {
        case .arrow(let start, let end):
            return distance(p, toSegment: denormalize(start, in: frame), denormalize(end, in: frame)) <= reach
        case .pen(let points):
            let canvas = points.map { denormalize($0, in: frame) }
            guard canvas.count > 1 else { return canvas.first.map { distance(p, $0) <= reach } ?? false }
            return zip(canvas, canvas.dropFirst()).contains { distance(p, toSegment: $0, $1) <= reach }
        case .circle:
            // Inside the ellipse grown by the reach.
            let rx = frame.width / 2 + reach, ry = frame.height / 2 + reach
            guard rx > 0, ry > 0 else { return false }
            let c = frame.center
            let nx = (p.x - c.x) / rx, ny = (p.y - c.y) / ry
            return nx * nx + ny * ny <= 1
        case .text, .image, .rectangle:
            return EaselRect(x: frame.x - slop, y: frame.y - slop, width: frame.width + 2 * slop, height: frame.height + 2 * slop).contains(p)
        }
    }

    /// The handle of `frame` under `p`, if any.
    static func handle(at p: EaselPoint, on frame: EaselRect) -> EaselHandle? {
        let reach = Metrics.Easel.handleSize / 2 + Metrics.Easel.hitSlop / 2
        return EaselHandle.allCases.first { handle in
            let h = handle.point(on: frame)
            return abs(h.x - p.x) <= reach && abs(h.y - p.y) <= reach
        }
    }

    /// The frame a resize drag gives, and whether it crossed over the fixed corner on each axis.
    static func resized(_ frame: EaselRect, handle: EaselHandle, to p: EaselPoint) -> (frame: EaselRect, flipX: Bool, flipY: Bool) {
        let fixed = handle.fixedCorner(of: frame)
        let minimum = Metrics.Easel.minimumElementSide
        let flipX = (p.x < fixed.x) == handle.isRight && p.x != fixed.x
        let flipY = (p.y < fixed.y) == handle.isBottom && p.y != fixed.y
        var r = EaselRect(corner: fixed, p)
        if r.width < minimum {
            r.width = minimum
            if p.x < fixed.x { r.x = fixed.x - minimum }
        }
        if r.height < minimum {
            r.height = minimum
            if p.y < fixed.y { r.y = fixed.y - minimum }
        }
        return (r, flipX, flipY)
    }

    /// Mirrors the normalized points of arrows and pen strokes (a resize crossed over).
    static func flipped(_ content: EaselElementContent, x: Bool, y: Bool) -> EaselElementContent {
        guard x || y else { return content }
        func flip(_ p: EaselPoint) -> EaselPoint { EaselPoint(x: x ? 1 - p.x : p.x, y: y ? 1 - p.y : p.y) }
        switch content {
        case .arrow(let start, let end): return .arrow(start: flip(start), end: flip(end))
        case .pen(let points): return .pen(points: points.map(flip))
        default: return content
        }
    }

    /// The canvas size: at least the default, and big enough to keep a margin past every element.
    static func canvasSize(for elements: [EaselElement], viewport: Size2D) -> Size2D {
        let m = Metrics.Easel.self
        var width = max(m.canvasSize.width, viewport.width)
        var height = max(m.canvasSize.height, viewport.height)
        for element in elements {
            width = max(width, element.frame.maxX + m.canvasGrowthMargin)
            height = max(height, element.frame.maxY + m.canvasGrowthMargin)
        }
        return Size2D(width: width, height: height)
    }
}
