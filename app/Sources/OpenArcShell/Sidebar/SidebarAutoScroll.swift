import CoreGraphics

// Auto-scroll of the sidebar list while a drag hovers near its top or bottom edge.
// Spec: [06 §12] covers drag results only; auto-scroll is not described there, so the whole
// behavior and its numbers are inferred (standard macOS list behavior).

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

    /// Signed scroll velocity in points per second (negative = toward the top, positive = toward
    /// the bottom) for a pointer at `pointerY`.
    ///
    /// - `viewport`: visible list area in the same coordinate space as `pointerY`.
    /// - Zero outside the viewport, outside both edge bands, and when the list cannot scroll
    ///   further in that direction (no scrolling past either content end).
    /// - Inside a band the speed grows linearly from 0 at the band's inner edge to `maxSpeed`
    ///   at the viewport edge. inferred.
    /// - The band is capped at half the viewport height so the two bands never overlap.
    static func velocity(
        pointerY: CGFloat,
        viewport: CGRect,
        metrics: SidebarScrollMetrics,
        band: CGFloat = SidebarLocalTokens.autoScrollEdgeBand,
        maxSpeed: CGFloat = SidebarLocalTokens.autoScrollMaxSpeed
    ) -> CGFloat {
        guard !viewport.isNull, viewport.height > 0, band > 0, maxSpeed > 0,
              pointerY >= viewport.minY, pointerY <= viewport.maxY else { return 0 }
        let band = min(band, viewport.height / 2)

        let fromTop = pointerY - viewport.minY
        if fromTop < band {
            guard metrics.offset > 0 else { return 0 }
            return -maxSpeed * (1 - fromTop / band)
        }
        let fromBottom = viewport.maxY - pointerY
        if fromBottom < band {
            guard metrics.offset < metrics.maxOffset else { return 0 }
            return maxSpeed * (1 - fromBottom / band)
        }
        return 0
    }

    /// Offset after scrolling at `velocity` for `elapsed` seconds, clamped to the content ends.
    static func offset(after elapsed: Double, velocity: CGFloat, from metrics: SidebarScrollMetrics) -> CGFloat {
        let next = metrics.offset + velocity * CGFloat(max(0, elapsed))
        return min(max(next, 0), metrics.maxOffset)
    }
}
