import CoreGraphics
import Foundation
import OpenArcModel
import OpenArcDesign

// Pure geometry and lookups for split view rendering (points, top-left origin).
//
// Spec sources (docs/arc-spec/):
//   [06 §5]  observed: the current tab goes to the left pane, the new tab to the right; the panes
//            sit side by side with a gap of about 10 pt (`Metrics.SplitView.paneGap`).
//   [06 §21.6] observed: a divider drag stores the ratio in `SplitChild.fraction` (B58, see
//            `SplitDivider.swift`); new splits start at equal widths.
//   [06 §21.6] observed: View ▸ Expand Current Split makes the current pane as large as it can be
//            and the other pane the 220 pt minimum; running it again changes nothing (B79).

/// Where one pane's tab surface goes.
public struct SplitPaneFrame: Equatable, Sendable {
    public var tabID: UUID
    public var frame: CGRect

    public init(tabID: UUID, frame: CGRect) {
        self.tabID = tabID
        self.frame = frame
    }
}

/// View ▸ Expand Current Split is in effect: the pane of `tabID` in layout `layoutID` is drawn
/// as large as it can be. Window-local and not stored; a divider drag turns it into stored
/// fractions. [06 §21.6] observed behavior; keeping it unstored until a drag is inferred.
public struct SplitExpansion: Equatable, Sendable {
    public var layoutID: UUID
    public var tabID: UUID

    public init(layoutID: UUID, tabID: UUID) {
        self.layoutID = layoutID
        self.tabID = tabID
    }
}

/// Local look tokens of a pane. The spec does not record a focus indicator, so both values are
/// placeholders. [06 §5] says only that the inactive pane's top bar is fainter.
public enum SplitPaneStyle {
    /// Width of the ring around the focused pane. unknown.
    public static let focusRingWidth: Double = 2
    /// Opacity of the focus ring color (the space accent). unknown.
    public static let focusRingOpacity: Double = 0.9
}

public enum SplitPaneLayout {
    /// Frames of every pane of `root` inside `container`, in display order.
    /// Siblings share the container minus `gap` between neighbors, in proportion to their
    /// `fraction` (normalized, so fractions that do not sum to 1 still fill the container).
    /// Horizontal splits go left to right, vertical splits top to bottom. [06 §5] observed for
    /// the horizontal case; vertical is inferred.
    public static func frames(
        for root: SplitNode,
        in container: CGRect,
        gap: Double = Metrics.SplitView.paneGap
    ) -> [SplitPaneFrame] {
        switch root {
        case .pane(let id):
            return [SplitPaneFrame(tabID: id, frame: container)]
        case .split(let axis, let children):
            guard !children.isEmpty else { return [] }
            let count = Double(children.count)
            let total = axis == .horizontal ? container.width : container.height
            let available = max(0, total - gap * (count - 1))
            let sum = children.reduce(0) { $0 + max(0, $1.fraction) }
            var offset = 0.0
            var result: [SplitPaneFrame] = []
            for child in children {
                let share = sum > 0 ? max(0, child.fraction) / sum : 1 / count
                let length = available * share
                let childFrame: CGRect
                switch axis {
                case .horizontal:
                    childFrame = CGRect(x: container.minX + offset, y: container.minY, width: length, height: container.height)
                case .vertical:
                    childFrame = CGRect(x: container.minX, y: container.minY + offset, width: container.width, height: length)
                }
                result += frames(for: child.node, in: childFrame, gap: gap)
                offset += length + gap
            }
            return result
        }
    }

    /// "Expand Current Split": `root` with the pane `focusedTabID` as large as `container` allows
    /// and every other pane at the minimum length (220 pt) along the axis it competes on.
    /// [06 §21.6] observed for two side-by-side panes (current pane maximal, the other 220 pt).
    /// Nested and stacked splits follow the same rule along each axis (inferred); panes that do
    /// not compete with the focused one along an axis keep their stored ratio there (inferred).
    /// Returns `root` unchanged when the container is too small for the minimums or `focusedTabID`
    /// is not in `root`. Idempotent: the result depends only on the tree shape and the container.
    public static func expandedRoot(
        _ root: SplitNode,
        focusedTabID: UUID,
        in container: CGRect,
        gap: Double = Metrics.SplitView.paneGap,
        minLength: Double = Metrics.SplitDivider.minPaneLength
    ) -> SplitNode {
        expanding(root, focused: focusedTabID, size: container.size, gap: gap, minLength: minLength) ?? root
    }

    /// Pane frames of `root` with `focusedTabID` expanded (see `expandedRoot`).
    public static func expandedFrames(
        for root: SplitNode,
        focusedTabID: UUID,
        in container: CGRect,
        gap: Double = Metrics.SplitView.paneGap
    ) -> [SplitPaneFrame] {
        frames(for: expandedRoot(root, focusedTabID: focusedTabID, in: container, gap: gap), in: container, gap: gap)
    }

    private static func expanding(_ node: SplitNode, focused: UUID, size: CGSize, gap: Double, minLength: Double) -> SplitNode? {
        guard case .split(let axis, let children) = node else {
            return node.tabIDs == [focused] ? node : nil
        }
        guard let focusedIndex = children.firstIndex(where: { $0.node.tabIDs.contains(focused) }) else { return nil }
        let total = axis == .horizontal ? size.width : size.height
        let available = total - gap * Double(children.count - 1)
        var lengths = children.map { minimumLength(of: $0.node, along: axis, gap: gap, minLength: minLength) }
        let others = lengths.indices.filter { $0 != focusedIndex }.reduce(0) { $0 + lengths[$1] }
        let focusedLength = available - others
        guard focusedLength >= lengths[focusedIndex], focusedLength > 0 else { return nil }
        lengths[focusedIndex] = focusedLength
        var result = children
        for i in children.indices {
            result[i].fraction = lengths[i] / available
            if i == focusedIndex {
                let childSize = axis == .horizontal
                    ? CGSize(width: lengths[i], height: size.height)
                    : CGSize(width: size.width, height: lengths[i])
                guard let expanded = expanding(children[i].node, focused: focused, size: childSize, gap: gap, minLength: minLength) else { return nil }
                result[i].node = expanded
            } else {
                result[i].node = minimized(children[i].node, along: axis, gap: gap, minLength: minLength)
            }
        }
        return .split(axis: axis, children: result)
    }

    /// The smallest length `node` can take along `axis`: panes in a row along it add up (with
    /// the gaps), panes stacked across it need only the largest of them.
    static func minimumLength(of node: SplitNode, along axis: SplitAxis, gap: Double, minLength: Double) -> Double {
        switch node {
        case .pane:
            return minLength
        case .split(let nodeAxis, let children):
            let mins = children.map { minimumLength(of: $0.node, along: axis, gap: gap, minLength: minLength) }
            if nodeAxis == axis { return mins.reduce(0, +) + gap * Double(max(0, children.count - 1)) }
            return mins.max() ?? minLength
        }
    }

    /// `node` shrunk to its minimum length along `axis`: children along `axis` take their own
    /// minimums; across it they keep their stored ratio.
    private static func minimized(_ node: SplitNode, along axis: SplitAxis, gap: Double, minLength: Double) -> SplitNode {
        guard case .split(let nodeAxis, let children) = node else { return node }
        var result = children
        if nodeAxis == axis {
            let mins = children.map { minimumLength(of: $0.node, along: axis, gap: gap, minLength: minLength) }
            let sum = mins.reduce(0, +)
            for i in children.indices where sum > 0 { result[i].fraction = mins[i] / sum }
        }
        for i in children.indices {
            result[i].node = minimized(children[i].node, along: axis, gap: gap, minLength: minLength)
        }
        return .split(axis: nodeAxis, children: result)
    }

    /// The live split layout that contains `tabID`. [06 §5] observed: the sidebar and the web
    /// panel treat the tabs of a layout as a group.
    ///
    /// Defensive against layouts that still name tabs deleted or archived on another device (B67):
    /// the returned copy's `root` holds only live panes (tab record present and not removed), and a
    /// layout with fewer than two live panes, or a dead `tabID`, is not active. `TreeOps.repairSplits`
    /// fixes the stored layout after each remote merge, so the copy normally equals the stored one;
    /// a pane whose tab has not arrived yet is only hidden here, never removed from the layout.
    public static func activeLayout(in workspace: WorkspaceState, containing tabID: UUID?) -> SplitLayout? {
        guard let tabID, workspace.isLiveSplitPane(tabID) else { return nil }
        guard var layout = workspace.splits.values.first(where: {
            !$0.meta.isTombstone && $0.root.tabIDs.count > 1 && $0.root.tabIDs.contains(tabID)
        }) else { return nil }
        guard let root = workspace.livePanes(of: layout.root, dropMissing: true), root.tabIDs.count > 1 else { return nil }
        layout.root = root
        return layout
    }

    /// The pane to focus after `tabID` leaves `root`: the one before it, else the one after.
    /// inferred.
    public static func neighborPane(of tabID: UUID, in root: SplitNode) -> UUID? {
        let ids = root.tabIDs
        guard let index = ids.firstIndex(of: tabID), ids.count > 1 else { return nil }
        return index > 0 ? ids[index - 1] : ids[index + 1]
    }
}
