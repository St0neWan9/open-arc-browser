import Foundation
import CoreGraphics
import OpenArcModel

// Drop-target decisions for the sidebar. Everything here is a pure function of the dragged item,
// the hovered target and the workspace; the view model applies the resulting plan through
// `TreeOps`. Spec: [06 §12] "Hover and drag results", [06 §15] drag-and-drop details (E9).

/// What is being dragged.
enum SidebarDragItem: Hashable {
    case tab(UUID)
    case folder(UUID)
    /// A split-group row (the id is the `SplitLayout` id). It drags as a unit: every member moves.
    /// [06 §5] observed that the sidebar treats the split tabs as one group.
    case splitGroup(UUID)

    var id: UUID {
        switch self {
        case .tab(let id), .folder(let id), .splitGroup(let id): return id
        }
    }
}

/// Where inside a row the pointer is.
enum SidebarDropZone: Hashable {
    /// Insert before the row (the line sits on the row's top edge).
    case above
    /// Only on collapsed or empty folder rows: drop into the folder (first position).
    case into
    /// Insert after the row (the line sits on the row's bottom edge).
    case below
    /// Middle band of a plain tab row: form a split with that tab, the dropped tab on `side`
    /// (the pointer's half of the row). [06 §15.2] observed.
    case split(SplitSide)

    /// Zone for a pointer at row-relative `y` (and `x`) in a row of `style`.
    ///
    /// - `.tab`: the top `tabRowAboveBand` and bottom `tabRowBelowBand` insert; the middle band
    ///   (≈ 20 pt) is a split target when `allowsSplit`, else the row splits in half.
    ///   [06 §15.2] observed (≈ 21 pt around each boundary inserts, ≈ 20 pt in the middle splits).
    /// - `.folder` (collapsed or empty): top ≈ 11 pt above, bottom ≈ 8 pt below, middle into.
    ///   [06 §15.3] observed.
    /// - `.halves` (expanded folder with children, split-group row): upper half above, lower half
    ///   below. [06 §15.3] observed for the folder; inferred for the group row.
    static func zone(
        forY y: CGFloat,
        x: CGFloat = 0,
        rowWidth: CGFloat = 0,
        rowHeight: CGFloat,
        style: SidebarRowDropStyle,
        allowsSplit: Bool = true
    ) -> SidebarDropZone {
        guard rowHeight > 0 else { return .below }
        let halves: SidebarDropZone = y < rowHeight / 2 ? .above : .below
        switch style {
        case .halves:
            return halves
        case .folder:
            let top = SidebarLocalTokens.folderRowAboveBand, bottom = SidebarLocalTokens.folderRowBelowBand
            guard rowHeight > top + bottom else { return halves }
            if y < top { return .above }
            if y >= rowHeight - bottom { return .below }
            return .into
        case .tab:
            let top = SidebarLocalTokens.tabRowAboveBand, bottom = SidebarLocalTokens.tabRowBelowBand
            guard rowHeight > top + bottom else { return halves }
            if y < top { return .above }
            if y >= rowHeight - bottom { return .below }
            guard allowsSplit else { return halves }
            return .split(x < rowWidth / 2 ? .leading : .trailing)
        }
    }
}

/// How a row divides into drop bands (see `SidebarDropZone.zone`).
enum SidebarRowDropStyle: Hashable {
    /// A plain tab row: insert bands at the edges, split band in the middle.
    case tab
    /// A collapsed (or empty) folder row: insert bands at the edges, "into" in the middle.
    case folder
    /// Upper half above, lower half below (expanded folder with children, split-group row).
    case halves
}

/// What the pointer is over.
enum SidebarDropTarget: Hashable {
    /// A tab or folder row (pinned or Today).
    case row(UUID, SidebarDropZone)
    /// The Space-name row above the pinned area: the item becomes the first pinned item.
    /// [06 §15.4] observed.
    case pinnedAreaTop
    /// End of an empty pinned area (the divider when no pinned row exists).
    case pinnedAreaEnd
    /// End of Today when Today has no rows (lower half of "+ New Tab", the space below it).
    case todayAreaEnd
    /// A gap in the favorites block (0...count).
    case favoriteGap(Int)
    /// A Space icon in the dock.
    case dockSpace(UUID)
}

/// The change a drop would make.
struct SidebarDropPlan: Equatable {
    enum Action: Equatable {
        case moveTab(id: UUID, to: TabLocation, position: InsertPosition)
        /// Moves several tabs in one step, keeping their relative order (`ids` is in sidebar order).
        case moveTabs(ids: [UUID], to: TabLocation, position: InsertPosition)
        case moveFolder(id: UUID, toSpace: UUID, parent: UUID?, position: InsertPosition)
        /// Moves a whole split group (its member tabs and the layout itself) into another Space's Today area.
        case moveSplitLayout(id: UUID, toSpace: UUID, position: InsertPosition)
        /// Forms a split of tab `id` with `target`, the dropped tab on `side`; with
        /// `moveNextToTarget` it also moves next to the target row. [06 §15.2] observed (row
        /// middle band), [06 §15.7] observed (web panel).
        case splitTab(id: UUID, target: UUID, side: SplitSide, moveNextToTarget: Bool)
        /// Opens a copy of `source` (a pinned tab or favorite, which stays where it is) in Space
        /// `spaceID` and splits it with `target`. [06 §15.7] observed for a pinned tab dropped on
        /// the web panel ("the pinned original stays; Today gets a new split row").
        case splitCopy(source: UUID, target: UUID, side: SplitSide, spaceID: UUID)

        /// Whether applying the action creates a split layout (it needs a fresh layout id).
        var needsLayoutID: Bool {
            switch self {
            case .splitTab, .splitCopy: return true
            case .moveTab, .moveTabs, .moveFolder, .moveSplitLayout: return false
            }
        }

        /// Whether applying the action opens a new tab (it needs a fresh tab id).
        var needsCopyID: Bool {
            if case .splitCopy = self { return true }
            return false
        }
    }

    var action: Action
    /// Folder that must be expanded after the drop. [06 §12], [06 §15.3] observed: dropping into
    /// a folder expands it and indents the tab.
    var expandFolderID: UUID?
}

enum SidebarDropPlanner {

    /// The per-tab moves that realize "put `ids` (in order) at `position`": applying them one after
    /// the other leaves the tabs next to each other, in `ids` order, at the requested spot.
    static func moveSteps(ids: [UUID], position: InsertPosition) -> [(id: UUID, position: InsertPosition)] {
        switch position {
        case .first:
            // Each move goes to the front, so the last member is moved first.
            return ids.reversed().map { ($0, .first) }
        case .last:
            return ids.map { ($0, .last) }
        case .before(let anchor):
            return ids.map { ($0, .before(anchor)) }
        case .after(let anchor):
            var previous = anchor
            return ids.map { id in
                defer { previous = id }
                return (id, .after(previous))
            }
        }
    }

    /// Returns the plan for dropping `item` on `target`, or nil if the drop is not allowed (or
    /// would change nothing).
    ///
    /// - Parameters:
    ///   - spaceID: the space shown in the sidebar.
    ///   - profileID: profile of that space (favorites live per profile).
    static func plan(
        item: SidebarDragItem,
        target: SidebarDropTarget,
        workspace ws: WorkspaceState,
        spaceID: UUID,
        profileID: UUID?
    ) -> SidebarDropPlan? {
        let env = Env(ws: ws, spaceID: spaceID, profileID: profileID)
        switch item {
        case .tab(let id):
            guard let tab = ws.tabs[id], !tab.meta.isTombstone else { return nil }
        case .folder(let id):
            guard let folder = ws.folders[id], !folder.meta.isTombstone else { return nil }
        case .splitGroup(let id):
            guard env.snapshot.splitGroup(layoutID: id) != nil else { return nil }
        }

        switch target {
        case .row(let rowID, let zone):
            return planForRow(item: item, rowID: rowID, zone: zone, env: env)

        case .pinnedAreaTop:
            // [06 §15.4] observed: dropped on the Space-name row, the tab becomes the FIRST pinned
            // item, before every pinned tab and folder (as above the first pinned row, [06 §12]).
            return placement(item, in: .pinned(spaceID: spaceID, folderID: nil), position: .first, env: env)

        case .pinnedAreaEnd:
            return placement(item, in: .pinned(spaceID: spaceID, folderID: nil), position: .last, env: env)

        case .todayAreaEnd:
            // Folders cannot live in Today. inferred.
            if case .folder = item { return nil }
            return placement(item, in: .today(spaceID: spaceID), position: .last, env: env)

        case .favoriteGap(let gap):
            // Folders cannot be favorites; a split group stays a group, so it cannot either. inferred.
            guard case .tab(let id) = item, let profileID else { return nil }
            let others = ws.favorites(profileID: profileID).filter { $0.id != id }
            var index = gap
            if let current = ws.favorites(profileID: profileID).firstIndex(where: { $0.id == id }), current < gap {
                index -= 1
            }
            index = min(max(index, 0), others.count)
            let position: InsertPosition = index >= others.count ? .last : .before(others[index].id)
            return SidebarDropPlan(action: .moveTab(id: id, to: .favorite(profileID: profileID), position: position))

        case .dockSpace(let targetSpaceID):
            // [06 §15.6] observed: dropped on a Space dot, the tab moves to that Space's Today
            // (the position is unknown: the target was empty; the top is inferred, like a new tab
            // [06 §13]). Favorites are shared.
            guard let space = ws.spaces[targetSpaceID], !space.meta.isTombstone else { return nil }
            switch item {
            case .tab(let id):
                let tab = ws.tabs[id]!
                if case .favorite = tab.location { return nil }
                if tab.location.spaceID == targetSpaceID { return nil }
                return SidebarDropPlan(action: .moveTab(id: id, to: .today(spaceID: targetSpaceID), position: .first))
            case .folder(let id):
                if ws.folders[id]?.spaceID == targetSpaceID { return nil }
                return SidebarDropPlan(action: .moveFolder(id: id, toSpace: targetSpaceID, parent: nil, position: .last))
            case .splitGroup(let id):
                // The group moves as a unit, layout included, to the top of the target's Today area,
                // like a single tab (inferred; [06 §5] observed the group is one unit).
                guard let layout = ws.splits[id], layout.spaceID != targetSpaceID else { return nil }
                return SidebarDropPlan(action: .moveSplitLayout(id: id, toSpace: targetSpaceID, position: .first))
            }
        }
    }

    // MARK: Web panel

    /// The action for a sidebar tab dropped on the web panel, on `side` of the pane that shows
    /// `targetTabID`. [06 §15.7] observed: the two form a split, the dropped tab on the pointer's
    /// side; a pinned tab stays and a new split row appears in Today. A favorite is treated like a
    /// pinned tab (inferred). A Today tab joins the target and moves next to it when the target is
    /// in Today (inferred: the group row then sits where the target was).
    static func webPanelAction(tabID: UUID, targetTabID: UUID, side: SplitSide, spaceID: UUID, workspace ws: WorkspaceState) -> SidebarDropPlan.Action? {
        guard tabID != targetTabID,
              let tab = ws.tabs[tabID], !tab.meta.isTombstone,
              let target = ws.tabs[targetTabID], !target.meta.isTombstone else { return nil }
        switch tab.location {
        case .pinned, .favorite:
            return .splitCopy(source: tabID, target: targetTabID, side: side, spaceID: spaceID)
        case .today:
            let nextToTarget: Bool = if case .today = target.location { true } else { false }
            return .splitTab(id: tabID, target: targetTabID, side: side, moveNextToTarget: nextToTarget)
        }
    }

    // MARK: Applying

    /// Pure: the workspace after `plan`, through `TreeOps`.
    ///
    /// - `newTabID`: for an external link, the id of the tab opened for it (it replaces the
    ///   scratch id of a tab move or split); for `.splitCopy`, the id of the copy.
    /// - `layoutID`: id of the split layout a split action creates (see `needsLayoutID`).
    /// - `copyURL`: page address of a `.splitCopy` (the live URL), else the stored one.
    /// A folder the tab is dropped into is expanded. [06 §12], [06 §15.3] observed.
    static func apply(
        _ plan: SidebarDropPlan,
        to ws: WorkspaceState,
        newTabID: UUID? = nil,
        layoutID: UUID? = nil,
        copyURL: URL? = nil,
        now: Date
    ) throws -> WorkspaceState {
        var result: WorkspaceState
        switch plan.action {
        case .moveTab(let id, let location, let position):
            result = try TreeOps.moveTab(ws, id: newTabID ?? id, to: location, position: position, now: now)
        case .moveFolder(let id, let space, let parent, let position):
            result = try TreeOps.moveFolder(ws, id: id, toSpace: space, parentFolderID: parent, position: position, now: now)
        case .moveTabs(let ids, let location, let position):
            // A split group moves as a unit: every member lands next to the others in one mutation.
            result = ws
            for step in moveSteps(ids: ids, position: position) {
                result = try TreeOps.moveTab(result, id: step.id, to: location, position: step.position, now: now)
            }
        case .moveSplitLayout(let id, let space, let position):
            result = try TreeOps.moveSplitLayout(ws, layoutID: id, toSpaceID: space, position: position, now: now)
        case .splitTab(let id, let target, let side, let moveNextToTarget):
            guard let layoutID else { throw TreeError.notFound(target) }
            result = try TreeOps.splitTab(ws, layoutID: layoutID, tabID: newTabID ?? id, targetTabID: target,
                                          side: side, moveNextToTarget: moveNextToTarget, now: now)
        case .splitCopy(let source, let target, let side, let spaceID):
            guard let layoutID, let copyID = newTabID else { throw TreeError.notFound(source) }
            guard let original = ws.tabs[source], !original.meta.isTombstone else { throw TreeError.notFound(source) }
            let opened = try TreeOps.openTab(ws, id: copyID, spaceID: spaceID, url: copyURL ?? original.url,
                                             title: original.displayTitle, now: now)
            let nextToTarget: Bool = if case .today = opened.tabs[target]?.location { true } else { false }
            result = try TreeOps.splitTab(opened, layoutID: layoutID, tabID: copyID, targetTabID: target,
                                          side: side, moveNextToTarget: nextToTarget, now: now)
        }
        if let folderID = plan.expandFolderID, result.folders[folderID]?.isExpanded == false {
            result = try TreeOps.setFolderExpanded(result, id: folderID, isExpanded: true, now: now)
        }
        return result
    }

    // MARK: Rows

    private static func planForRow(item: SidebarDragItem, rowID: UUID, zone: SidebarDropZone, env: Env) -> SidebarDropPlan? {
        let ws = env.ws
        guard rowID != item.id else { return nil }

        // A split-group row is one unit: a drop lands before or after the whole group, never
        // between its members ([06 §5] observed that the group is treated as one). inferred.
        if let group = env.snapshot.splitGroup(layoutID: rowID) {
            guard let anchor = ws.tabs[group.anchorID], !anchor.meta.isTombstone else { return nil }
            switch anchor.location {
            case .favorite:
                return nil
            case .pinned, .today:
                let position: InsertPosition = zone == .above
                    ? .before(anchor.id)
                    : .after(lastContiguousMember(of: group, in: ws))
                return placement(item, in: anchor.location, position: position, env: env)
            }
        }

        if let folder = ws.folders[rowID], !folder.meta.isTombstone {
            let spaceID = folder.spaceID
            switch zone {
            case .into, .split:
                // [06 §12] observed: onto a folder row → inside, folder expands. [06 §15.3]
                // observed: the tab becomes the folder's FIRST child (no spring-loading: a
                // collapsed folder only expands on the drop).
                var plan = placement(item, in: .pinned(spaceID: spaceID, folderID: folder.id), position: .first, env: env)
                plan?.expandFolderID = folder.id
                return plan
            case .above:
                return placement(item, in: .pinned(spaceID: spaceID, folderID: folder.parentFolderID), position: .before(folder.id), env: env)
            case .below:
                // Just below an expanded folder with children is the folder's first slot.
                if folder.isExpanded, !ws.pinnedChildren(spaceID: spaceID, folderID: folder.id).isEmpty {
                    return placement(item, in: .pinned(spaceID: spaceID, folderID: folder.id), position: .first, env: env)
                }
                return placement(item, in: .pinned(spaceID: spaceID, folderID: folder.parentFolderID), position: .after(folder.id), env: env)
            }
        }

        guard let row = ws.tabs[rowID], !row.meta.isTombstone else { return nil }
        if case .favorite = row.location { return nil }
        switch zone {
        case .split(let side):
            // [06 §15.2] observed: only a single tab forms a split; a folder or a split group has
            // no split band (the hit-tester gives them halves; refused here as well).
            guard case .tab(let id) = item, let tab = ws.tabs[id] else { return nil }
            if case .favorite = tab.location { return nil }
            return SidebarDropPlan(action: .splitTab(id: id, target: row.id, side: side, moveNextToTarget: true))
        case .above:
            return placement(item, in: row.location, position: .before(row.id), env: env)
        case .into, .below:
            return placement(item, in: row.location, position: .after(row.id), env: env)
        }
    }

    /// The last member of the run of group members that starts at the anchor and sits next to each
    /// other in the anchor's container. "After the group" anchors there, so the dropped item lands
    /// directly below the row even when members are far apart in the data order.
    private static func lastContiguousMember(of group: SidebarSplitGroup, in ws: WorkspaceState) -> UUID {
        guard let anchor = ws.tabs[group.anchorID] else { return group.anchorID }
        let siblings: [UUID]
        switch anchor.location {
        case .today(let spaceID):
            siblings = ws.today(spaceID: spaceID).map(\.id)
        case .pinned(let spaceID, let folderID):
            siblings = ws.pinnedChildren(spaceID: spaceID, folderID: folderID).map(\.id)
        case .favorite:
            return group.anchorID
        }
        guard var index = siblings.firstIndex(of: group.anchorID) else { return group.anchorID }
        while index + 1 < siblings.count, group.contains(siblings[index + 1]) { index += 1 }
        return siblings[index]
    }

    // MARK: Shared

    /// What a plan is computed against, plus the lazily derived snapshot used to find split groups.
    private struct Env {
        let ws: WorkspaceState
        let spaceID: UUID
        let profileID: UUID?

        var snapshot: SidebarSnapshot {
            SidebarSnapshot.make(workspace: ws, spaceID: spaceID, profileID: profileID)
        }
    }

    /// Builds the plan for putting `item` into `location`, rejecting impossible combinations.
    private static func placement(_ item: SidebarDragItem, in location: TabLocation, position: InsertPosition, env: Env) -> SidebarDropPlan? {
        let ws = env.ws
        switch item {
        case .tab(let id):
            return SidebarDropPlan(action: .moveTab(id: id, to: location, position: position))
        case .splitGroup(let id):
            // Every member moves, in sidebar order, in one plan. Favorites are not rows, so a
            // location that is a favorite block is refused.
            guard let group = env.snapshot.splitGroup(layoutID: id) else { return nil }
            if case .favorite = location { return nil }
            return SidebarDropPlan(action: .moveTabs(ids: group.sidebarOrder, to: location, position: position))
        case .folder(let id):
            // Folders only live in the pinned area, and never inside themselves or a descendant
            // (the model rejects it too; the planner refuses early so the UI shows no indicator).
            guard case .pinned(let spaceID, let parent) = location else { return nil }
            if let parent, ws.folder(parent, isWithin: id) { return nil }
            return SidebarDropPlan(action: .moveFolder(id: id, toSpace: spaceID, parent: parent, position: position))
        }
    }
}

/// Space switching at the sidebar's left and right edges while dragging. [06 §15.6] observed:
/// x < ≈ 20 pt goes to the previous Space, the right edge (fires 4 pt from the edge, not 20 pt) to
/// the next one.
enum SidebarEdgeSwitch {
    /// -1 (previous Space), +1 (next Space), or nil away from both edges.
    static func direction(
        x: CGFloat,
        sidebarWidth: CGFloat,
        leftBand: CGFloat = SidebarLocalTokens.edgeSwitchLeftBand,
        rightBand: CGFloat = SidebarLocalTokens.edgeSwitchRightBand
    ) -> Int? {
        guard sidebarWidth > leftBand + rightBand, x >= 0, x <= sidebarWidth else { return nil }
        if x < leftBand { return -1 }
        if x > sidebarWidth - rightBand { return 1 }
        return nil
    }
}

/// Where a sidebar tab dropped on the web panel goes: the pane under the pointer and the half of
/// that pane the pointer is in. [06 §15.7] observed (left half of the content area → left pane).
enum SidebarWebPanelDrop {
    struct Pane: Equatable {
        var tabID: UUID
        var frame: CGRect
    }

    static func target(at point: CGPoint, panes: [Pane]) -> (tabID: UUID, side: SplitSide)? {
        guard let pane = panes.first(where: { $0.frame.contains(point) }) else { return nil }
        return (pane.tabID, point.x < pane.frame.midX ? .leading : .trailing)
    }
}
