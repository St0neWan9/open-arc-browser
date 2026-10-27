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

/// Where one pane's tab surface goes.
public struct SplitPaneFrame: Equatable, Sendable {
    public var tabID: UUID
    public var frame: CGRect

    public init(tabID: UUID, frame: CGRect) {
        self.tabID = tabID
        self.frame = frame
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

    /// "Expand Current Split": only the focused pane is shown, filling the container.
    /// [01 §View] observed the menu item; the behavior is inferred.
    public static func expandedFrames(focusedTabID: UUID, in container: CGRect) -> [SplitPaneFrame] {
        [SplitPaneFrame(tabID: focusedTabID, frame: container)]
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
