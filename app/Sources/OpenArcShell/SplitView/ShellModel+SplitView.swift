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

extension ShellModel {
    /// The split layout the selected tab belongs to, if any.
    public var activeSplitLayout: SplitLayout? {
        SplitPaneLayout.activeLayout(in: workspace, containing: selectedTabID)
    }

    /// Whether the split items of the View menu are available. [01 §View] observed.
    public var hasActiveSplit: Bool { activeSplitLayout != nil }

    /// Expand only counts while a split exists.
    public var isSplitExpandedNow: Bool { isSplitExpanded && hasActiveSplit }

    /// Pane frames for the selected tab's split inside `container` (the web panel area, origin
    /// at its top-left). Empty when the selected tab is not in a split.
    public func splitPaneFrames(in container: CGRect) -> [SplitPaneFrame] {
        guard let layout = activeSplitLayout, let focused = selectedTabID else { return [] }
        if isSplitExpanded { return SplitPaneLayout.expandedFrames(focusedTabID: focused, in: container) }
        return SplitPaneLayout.frames(for: layout.root, in: container)
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
        isSplitExpanded = false
        sidebar.addSplitView()
    }

    /// Close this Split Pane (⌃⇧-): the focused pane's tab is closed (archived) and the neighbor
    /// pane takes focus. A layout left with one pane disappears, which is the single page again.
    /// [06 §5] observed that the pane closes; archiving its tab is inferred.
    public func closeSplitPane() {
        guard let layout = activeSplitLayout, let focused = selectedTabID else { return }
        let next = SplitPaneLayout.neighborPane(of: focused, in: layout.root)
        if commandBarPaneTabID == focused { dismissCommandBar() }
        isSplitExpanded = false
        sidebar.closeTab(focused)
        if let next { sidebar.selectTab(next) }
    }

    /// Separate Page from Split View: the focused tab leaves the layout but stays open and
    /// selected, shown as a single page. [01 §View] observed the item; the exact behavior is inferred.
    public func separatePageFromSplitView() {
        guard hasActiveSplit, let focused = selectedTabID else { return }
        if commandBarPaneTabID != nil { dismissCommandBar() }
        isSplitExpanded = false
        sidebar.separateFromSplit(focused)
    }

    /// Expand Current Split: temporarily show only the focused pane; choosing it again shows all
    /// panes. inferred (the spec only lists the menu item).
    public func toggleExpandCurrentSplit() {
        guard hasActiveSplit else { return }
        isSplitExpanded.toggle()
    }
}
