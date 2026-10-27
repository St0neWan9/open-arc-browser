import CoreGraphics
import Foundation
import OpenArcModel

// Split view intents of the window. The workspace changes only through `TreeOps` (via the
// sidebar view model); this file adds selection, focus and expand handling around it.
//
// Spec sources (docs/arc-spec/):
//   [06 §5]  observed: ⌃⇧= adds a pane (current tab left, new tab right, command bar in the new
//            pane); ⌃⇧- closes the current pane and returns to a single page.
//   [01 §View] observed: Add Split View, Close this Split Pane, Separate Page from Split View,
//            Expand Current Split; these are available only while a split exists.
//   [06 §21.6] observed: Expand Current Split makes the current pane maximal and the other the
//            220 pt minimum, and running it again changes nothing; View ▸ Show Toolbar is
//            disabled while a split is shown (B79).

extension ShellModel {
    /// The split layout the selected tab belongs to, if any.
    public var activeSplitLayout: SplitLayout? {
        SplitPaneLayout.activeLayout(in: workspace, containing: selectedTabID)
    }

    /// Whether the split items of the View menu are available. [01 §View] observed.
    public var hasActiveSplit: Bool { activeSplitLayout != nil }

    /// Whether Expand Current Split is in effect for the shown split.
    public var isSplitExpandedNow: Bool { activeSplitExpansion != nil }

    /// The expansion of the shown split, if any (an expansion of another layout does not count).
    var activeSplitExpansion: SplitExpansion? {
        guard let expansion = splitExpansion, let layout = activeSplitLayout,
              expansion.layoutID == layout.id, layout.root.tabIDs.contains(expansion.tabID) else { return nil }
        return expansion
    }

    /// View ▸ Show Toolbar can be toggled: not while a split is shown. [06 §21.6] observed.
    public var canToggleWebToolbar: Bool { !hasActiveSplit }

    /// Pane frames for the selected tab's split inside `container` (the web panel area, origin
    /// at its top-left). Empty when the selected tab is not in a split.
    public func splitPaneFrames(in container: CGRect) -> [SplitPaneFrame] {
        guard let layout = activeSplitLayout else { return [] }
        return SplitPaneLayout.frames(for: displayedSplitRoot(layout, in: container), in: container)
    }

    /// The tree to draw: the live drag preview while a divider of this layout is dragged, else
    /// the stored tree with Expand Current Split applied for `container`.
    func displayedSplitRoot(_ layout: SplitLayout, in container: CGRect) -> SplitNode {
        if let preview = splitResizePreview, preview.layoutID == layout.id { return preview.root }
        if let expansion = activeSplitExpansion {
            return SplitPaneLayout.expandedRoot(layout.root, focusedTabID: expansion.tabID, in: container)
        }
        return layout.root
    }

    /// Divider frames for the selected tab's split inside `container`. [06 §21.6] observed: the
    /// 10 pt gap between panes is the divider; it stays draggable after Expand Current Split
    /// (inferred: the panes are still side by side).
    public func splitDividerFrames(in container: CGRect) -> [SplitDividerFrame] {
        guard let layout = activeSplitLayout else { return [] }
        return SplitPaneLayout.dividers(for: displayedSplitRoot(layout, in: container), in: container)
    }

    /// One drag step of `divider`: `pointer` is the pointer along the divider's axis, measured
    /// from the leading edge of the divider's split node. The panes follow at once; nothing is
    /// stored until `endSplitDividerDrag()`. [06 §21.6] observed: live resize, the gap's center
    /// follows the pointer, a 50 / 50 snap within ≈ 10 pt, 220 pt minimum per pane.
    /// `container` is the web panel area the dividers were laid out in; an expanded split is
    /// dragged from its expanded sizes, and the release stores them (the expansion ends).
    public func dragSplitDivider(_ divider: SplitDividerFrame, pointer: Double, in container: CGRect) {
        guard let layout = activeSplitLayout else { return }
        let root = displayedSplitRoot(layout, in: container)
        guard let split = root.node(at: divider.path) else { return }
        let length = divider.axis == .horizontal ? divider.splitFrame.width : divider.splitFrame.height
        guard let fractions = SplitDividerDrag.fractions(for: split, dividerIndex: divider.index,
                                                         splitLength: length, pointer: pointer),
              let next = root.replacingFractions(at: divider.path, with: fractions) else { return }
        splitResizePreview = SplitResizePreview(layoutID: layout.id, path: divider.path, root: next)
    }

    /// The divider was released: the dragged fractions are stored in the layout (one `layout`
    /// stamp per drag, not per step). [06 §21.6] observed: the new ratio is kept after release.
    public func endSplitDividerDrag() {
        guard let preview = splitResizePreview else { return }
        splitResizePreview = nil
        // The preview started from the expanded sizes; from now on the stored ratio is shown.
        if splitExpansion?.layoutID == preview.layoutID { splitExpansion = nil }
        guard case .split(_, let children)? = preview.root.node(at: preview.path) else { return }
        setSplitFractions(layoutID: preview.layoutID, path: preview.path, fractions: children.map(\.fraction))
    }

    /// Stores the fractions a divider drag ended on, for the split node at `path` of layout
    /// `layoutID`. [06 §21.6] observed: the ratio is kept after release, across tab switches and
    /// with the sidebar hidden. Returns whether the workspace accepted it.
    @discardableResult
    public func setSplitFractions(layoutID: UUID, path: [Int], fractions: [Double]) -> Bool {
        let now = controller.now()
        do {
            try controller.mutate(origin: sidebar) {
                try TreeOps.setSplitFractions($0, layoutID: layoutID, path: path, fractions: fractions, now: now)
            }
            return true
        } catch {
            return false
        }
    }

    /// Clicking a pane focuses it, which selects its tab. A pane command bar belongs to its own
    /// pane, so focusing another pane dismisses it. [06 §5] observed that panes have an active state.
    public func focusPane(_ tabID: UUID) {
        if let barPane = commandBarPaneTabID, barPane != tabID { dismissCommandBar() }
        guard selectedTabID != tabID else { return }
        sidebar.selectTab(tabID)
    }

    /// Add Split View (⌃⇧=). The sidebar creates the pane and asks the shell to open the bar.
    public func addSplitView() {
        splitExpansion = nil
        sidebar.addSplitView()
    }

    /// Close this Split Pane (⌃⇧-): the focused pane's tab is closed (archived) and the neighbor
    /// pane takes focus. A layout left with one pane disappears, which is the single page again.
    /// [06 §5] observed that the pane closes; archiving its tab is inferred.
    public func closeSplitPane() {
        guard let layout = activeSplitLayout, let focused = selectedTabID else { return }
        let next = SplitPaneLayout.neighborPane(of: focused, in: layout.root)
        if commandBarPaneTabID == focused { dismissCommandBar() }
        splitExpansion = nil
        sidebar.closeTab(focused)
        if let next { sidebar.selectTab(next) }
    }

    /// Separate Page from Split View: the focused tab leaves the layout but stays open and
    /// selected, shown as a single page. [01 §View] observed the item; the exact behavior is inferred.
    public func separatePageFromSplitView() {
        guard hasActiveSplit, let focused = selectedTabID else { return }
        if commandBarPaneTabID != nil { dismissCommandBar() }
        splitExpansion = nil
        sidebar.separateFromSplit(focused)
    }

    /// View ▸ Expand Current Split: the focused pane becomes as large as it can be and the other
    /// pane(s) the 220 pt minimum. Not a toggle: running it again changes nothing. [06 §21.6]
    /// observed. With another pane focused, that pane is expanded instead (the "current" pane).
    public func expandCurrentSplit() {
        guard let layout = activeSplitLayout, let focused = selectedTabID else { return }
        let expansion = SplitExpansion(layoutID: layout.id, tabID: focused)
        guard splitExpansion != expansion else { return }
        splitResizePreview = nil
        splitExpansion = expansion
    }
}
