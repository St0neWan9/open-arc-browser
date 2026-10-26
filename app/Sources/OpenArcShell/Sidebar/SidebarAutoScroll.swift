import CoreGraphics

// Auto-scroll of the sidebar list while a drag hovers near its top or bottom edge.
// Spec: [06 §15.8] (E9): only at the top and bottom edges of the visible list; starts ≈ 13 pt from
// the edge (21 pt does not) after ≈ 0.3–0.5 s in the band (observed); speed grows with depth into
// the band and with time, from ≈ 25 pt/s to hundreds of pt/s (inferred); stops at the ends (observed).

/// Vertical scroll state of the list, as the scroll hook reports it.
struct SidebarScrollMetrics: Equatable {
    /// Distance from the top of the content to the top of the visible area (0 = scrolled to top).
    var offset: CGFloat
    /// Full height of the scrolled content.
    var contentHeight: CGFloat
    /// Height of the visible area.
    var viewportHeight: CGFloat

    /// Largest valid offset (the content's bottom is at the viewport's bottom).
    var maxOffset: CGFloat { max(0, contentHeight - viewportHeight) }
}

/// The scroll hook of the list view. The view model drives it during a drag; tests use a fake.
@MainActor
protocol SidebarListScrolling: AnyObject {
    /// Current metrics, or nil while the list is not on screen.
    var metrics: SidebarScrollMetrics? { get }
    /// Scrolls so that `offset` (top of content to top of visible area) is at the top.
    func scroll(toOffset offset: CGFloat)
}

/// Pure decisions of the auto-scroll: velocity for a pointer position and the next offset.
enum SidebarAutoScroll {

    /// Where the pointer is in an edge band: the direction (-1 = toward the top, +1 = toward the
    /// bottom) and the depth (0 at the band's inner edge, 1 at the viewport edge). Nil outside the
    /// viewport, outside both bands, and when the list cannot scroll further that way.
    /// The band is capped at half the viewport height so the two bands never overlap.
    static func edge(
        pointerY: CGFloat,
        viewport: CGRect,
        metrics: SidebarScrollMetrics,
        band: CGFloat = SidebarLocalTokens.autoScrollEdgeBand
    ) -> (direction: CGFloat, depth: CGFloat)? {
        guard !viewport.isNull, viewport.height > 0, band > 0,
              pointerY >= viewport.minY, pointerY <= viewport.maxY else { return nil }
        let band = min(band, viewport.height / 2)
        let fromTop = pointerY - viewport.minY
        if fromTop < band {
            guard metrics.offset > 0 else { return nil }
            return (-1, 1 - fromTop / band)
        }
        let fromBottom = viewport.maxY - pointerY
        if fromBottom < band {
            guard metrics.offset < metrics.maxOffset else { return nil }
            return (1, 1 - fromBottom / band)
        }
        return nil
    }

    /// Signed scroll velocity in points per second (negative = toward the top) for a pointer at
    /// `pointerY` that has been in the band for `timeInBand` seconds.
    ///
    /// - Zero wherever `edge` is nil, and during the first `dwell` seconds in the band.
    ///   [06 §15.8] observed (≈ 0.3–0.5 s).
    /// - Speed = (min + (max − min) · depth²) · (1 + rate · min(t, cap)), t = time since the dwell
    ///   ended: slow at the inner edge, much faster at the viewport edge and the longer it runs.
    ///   [06 §15.8] inferred (≈ 25 pt/s to hundreds of pt/s).
    static func velocity(
        pointerY: CGFloat,
        viewport: CGRect,
        metrics: SidebarScrollMetrics,
        timeInBand: Double,
        band: CGFloat = SidebarLocalTokens.autoScrollEdgeBand,
        dwell: Double = SidebarLocalTokens.autoScrollDwell,
        minSpeed: CGFloat = SidebarLocalTokens.autoScrollMinSpeed,
        maxSpeed: CGFloat = SidebarLocalTokens.autoScrollMaxSpeed
    ) -> CGFloat {
        guard let edge = edge(pointerY: pointerY, viewport: viewport, metrics: metrics, band: band),
              timeInBand >= dwell else { return 0 }
        let running = min(timeInBand - dwell, SidebarLocalTokens.autoScrollRampCap)
        let ramp = 1 + CGFloat(SidebarLocalTokens.autoScrollRampPerSecond * running)
        let base = minSpeed + (maxSpeed - minSpeed) * edge.depth * edge.depth
        return edge.direction * base * ramp
    }

    /// Offset after scrolling at `velocity` for `elapsed` seconds, clamped to the content ends.
    static func offset(after elapsed: Double, velocity: CGFloat, from metrics: SidebarScrollMetrics) -> CGFloat {
        let next = metrics.offset + velocity * CGFloat(max(0, elapsed))
        return min(max(next, 0), metrics.maxOffset)
    }
}
