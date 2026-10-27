import Foundation

// Split repair after remote changes (plan B67, review F1 #5). Local archive and delete clean
// splits at once (`removeFromSplits`), but a tab tombstoned or archived on another device can
// reach this device while a split layout still names it: the tab's tombstone and the layout's
// update travel as separate records, and under field-group LWW a newer concurrent edit of the
// layout (a divider drag) keeps the old pane list. Same rules as `TreeOps`: pure, `now` comes
// from the caller, only the changed field groups are stamped, deletion tombstones.
//
// Spec: [06 §5] observed: closing a pane leaves the other one as a single page, and the sidebar
// treats the tabs of a split as a group. [06 §21.6] observed: Separate All Tabs turns each pane
// into a plain Today row and ends the split; the stored ratio is relative, not a pixel width.
// Dropping dead panes the same way is inferred.

extension WorkspaceState {
    /// Whether `tabID` is known to be gone: its tab record is a tombstone, or a live archive item
    /// carries its id (an archive item uses the archived tab's id; delete wins, so the archive item
    /// counts even if the tab's own tombstone has not arrived yet). A tab with no record at all is
    /// not "removed": it may simply not have arrived yet.
    public func isRemovedTab(_ tabID: UUID) -> Bool {
        if tabs[tabID]?.meta.isTombstone == true { return true }
        if let item = archive[tabID], !item.meta.isTombstone { return true }
        return false
    }

    /// Whether `tabID` can be shown as a split pane: the tab record exists and is not removed.
    public func isLiveSplitPane(_ tabID: UUID) -> Bool {
        tabs[tabID] != nil && !isRemovedTab(tabID)
    }

    /// `root` without the panes that cannot be shown. With `dropMissing` false only removed tabs
    /// (`isRemovedTab`) are dropped; with true, panes whose tab record is missing go too
    /// (`isLiveSplitPane`). Siblings of a dropped pane are renormalized in proportion to their
    /// fractions and single-child splits collapse (`SplitNode.removing`). Nil when no pane is left.
    public func livePanes(of root: SplitNode, dropMissing: Bool) -> SplitNode? {
        var node: SplitNode? = root
        for tabID in root.tabIDs where dropMissing ? !isLiveSplitPane(tabID) : isRemovedTab(tabID) {
            node = node?.removing(tabID)
        }
        return node
    }
}

extension TreeOps {
    /// Repairs every live split layout that names tabs another device deleted or archived. Run it
    /// after remote changes are merged.
    /// - Removed panes (`WorkspaceState.isRemovedTab`) are dropped; the remaining fractions are
    ///   renormalized in proportion, so the surviving panes keep their relative sizes
    ///   ([06 §21.6] observed: the ratio is relative).
    /// - A layout left with fewer than two panes is tombstoned (delete wins); the remaining tab is
    ///   untouched and shows as a normal row again ([06 §5], [06 §21.6] observed for local close
    ///   and Separate All Tabs; inferred for remote deletes).
    /// - A pane whose tab record is missing is kept: sync can deliver a new layout before its tab
    ///   records, and a tombstone cannot be undone. The window lookup hides such panes instead
    ///   (inferred; our own decision).
    /// Stamps only the layout's `layout` group, and only for layouts that change; tabs are never
    /// touched. Idempotent: a repaired workspace is returned unchanged.
    public static func repairSplits(_ state: WorkspaceState, now: Date) -> WorkspaceState {
        var s = state
        for layout in state.splits.values where !layout.meta.isTombstone {
            guard layout.root.tabIDs.contains(where: state.isRemovedTab) else { continue }
            if let root = state.livePanes(of: layout.root, dropMissing: false), root.tabIDs.count > 1 {
                s.splits[layout.id]?.root = root
                s.splits[layout.id]?.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
            } else {
                s.splits[layout.id]?.meta.markDeleted(at: now)
            }
        }
        return s
    }
}
