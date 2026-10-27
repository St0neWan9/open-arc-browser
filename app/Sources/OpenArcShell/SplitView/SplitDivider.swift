import CoreGraphics
import Foundation
import OpenArcModel
import OpenArcDesign

// Pure geometry of the dividers between split panes and of a divider drag (plan B58).
//
// Spec: docs/arc-spec/06-flows.md §21.6 "调整比例" (E19 capture), all observed unless noted:
//   - the divider is the 10 pt gap; inside it the pointer is the left-right resize cursor;
//   - dragging resizes live: the left pane's right edge = pointer x − 5 (the gap's center
//     follows the pointer); there is no preview line;
//   - one snap point, 50 / 50, within ≈ 10 pt of the equal position; no other snap points;
//   - a pane never gets narrower than 220 pt, on either side;
//   - double-click does nothing;
//   - the ratio is stored, so it survives tab switches and hiding the sidebar.
// Vertical splits use the same rules along y with the up-down cursor (inferred: only
// side-by-side splits were captured). With more than two children, a divider moves only its two
// neighbors and snaps to their equal size (inferred).

/// One divider: the gap between child `index` and child `index + 1` of the split node at `path`.
public struct SplitDividerFrame: Equatable, Sendable {
    /// Child indices from the layout root to the split node this divider belongs to.
    public var path: [Int]
    /// The divider sits after this child.
    public var index: Int
    public var axis: SplitAxis
    /// The gap itself (the hit and cursor area), in the container's coordinates.
    public var frame: CGRect
    /// The frame of the whole split node, in the container's coordinates.
    public var splitFrame: CGRect

    /// Stable while the divider is dragged (its frame changes, its place in the tree does not).
    public var id: String { (path + [index]).map(String.init).joined(separator: ".") }

    public init(path: [Int], index: Int, axis: SplitAxis, frame: CGRect, splitFrame: CGRect) {
        self.path = path
        self.index = index
        self.axis = axis
        self.frame = frame
        self.splitFrame = splitFrame
    }
}

extension SplitPaneLayout {
    /// Every divider of `root` inside `container`, outer splits first. Matches `frames(for:in:gap:)`.
    public static func dividers(
        for root: SplitNode,
        in container: CGRect,
        gap: Double = Metrics.SplitView.paneGap
    ) -> [SplitDividerFrame] {
        dividers(for: root, path: [], in: container, gap: gap)
    }

    private static func dividers(for node: SplitNode, path: [Int], in container: CGRect, gap: Double) -> [SplitDividerFrame] {
        guard case .split(let axis, let children) = node, !children.isEmpty else { return [] }
        let lengths = childLengths(children, total: axis == .horizontal ? container.width : container.height, gap: gap)
        var result: [SplitDividerFrame] = []
        var nested: [SplitDividerFrame] = []
        var offset = 0.0
        for (i, child) in children.enumerated() {
            let childFrame: CGRect
            switch axis {
            case .horizontal:
                childFrame = CGRect(x: container.minX + offset, y: container.minY, width: lengths[i], height: container.height)
            case .vertical:
                childFrame = CGRect(x: container.minX, y: container.minY + offset, width: container.width, height: lengths[i])
            }
            nested += dividers(for: child.node, path: path + [i], in: childFrame, gap: gap)
            offset += lengths[i]
            if i < children.count - 1 {
                let gapFrame: CGRect
                switch axis {
                case .horizontal:
                    gapFrame = CGRect(x: container.minX + offset, y: container.minY, width: gap, height: container.height)
                case .vertical:
                    gapFrame = CGRect(x: container.minX, y: container.minY + offset, width: container.width, height: gap)
                }
                result.append(SplitDividerFrame(path: path, index: i, axis: axis, frame: gapFrame, splitFrame: container))
            }
            offset += gap
        }
        return result + nested
    }

    /// Lengths of `children` along the split axis: the total minus the gaps, shared in
    /// proportion to the (normalized) fractions. Same rule as `frames(for:in:gap:)`.
    static func childLengths(_ children: [SplitChild], total: Double, gap: Double) -> [Double] {
        let count = Double(children.count)
        let available = max(0, total - gap * (count - 1))
        let sum = children.reduce(0) { $0 + max(0, $1.fraction) }
        return children.map { sum > 0 ? available * max(0, $0.fraction) / sum : available / count }
    }
}

/// The split tree shown while a divider is dragged, before it is stored. B58.
public struct SplitResizePreview: Equatable, Sendable {
    public var layoutID: UUID
    /// The split node whose divider is dragged.
    public var path: [Int]
    public var root: SplitNode
}

/// The new fractions while a divider is dragged.
public enum SplitDividerDrag {
    /// Fractions for the children of `split` (the node the divider belongs to, laid out in
    /// `splitLength` points along its axis) when the gap's center is at `pointer` points from the
    /// split's leading (left or top) edge. Only the divider's two neighbors change; the rest keep
    /// their size. Nil if `split` is not a split, `index` names no divider, or the two neighbors
    /// together are too small to honor the minimum on both sides.
    public static func fractions(
        for split: SplitNode,
        dividerIndex index: Int,
        splitLength: Double,
        pointer: Double,
        gap: Double = Metrics.SplitView.paneGap,
        minLength: Double = Metrics.SplitDivider.minPaneLength,
        snapDistance: Double = Metrics.SplitDivider.snapDistance
    ) -> [Double]? {
        guard case .split(_, let children) = split, index >= 0, index + 1 < children.count else { return nil }
        let lengths = SplitPaneLayout.childLengths(children, total: splitLength, gap: gap)
        let available = lengths.reduce(0, +)
        let pair = lengths[index] + lengths[index + 1]
        guard available > 0, pair >= 2 * minLength else { return nil }
        let start = lengths[..<index].reduce(0, +) + Double(index) * gap
        // The gap's center follows the pointer: the leading pane ends half a gap before it.
        var leading = pointer - gap / 2 - start
        // The single snap point: both neighbors equal.
        if abs(leading - pair / 2) <= snapDistance { leading = pair / 2 }
        leading = min(max(leading, minLength), pair - minLength)
        var result = lengths
        result[index] = leading
        result[index + 1] = pair - leading
        return result.map { $0 / available }
    }
}
