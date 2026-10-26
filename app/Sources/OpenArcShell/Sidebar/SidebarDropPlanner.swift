import Foundation
import CoreGraphics
import OpenArcModel

// Drop-target decisions for the sidebar. Everything here is a pure function of the dragged item,
// the hovered target and the workspace; the view model applies the resulting plan through
// `TreeOps`. Spec: [06 §12] "Hover and drag results".

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
    case above
    /// Only meaningful on folder rows: drop into the folder.
    case into
    case below

    /// Zone for a pointer at `y` (row-relative). Folder rows have a middle "into" band; tab rows
    /// split in half. The band size is unknown ([06 §12] only shows the "into" result).
    static func zone(forY y: CGFloat, rowHeight: CGFloat, allowsInto: Bool) -> SidebarDropZone {
        guard rowHeight > 0 else { return .below }
        let t = y / rowHeight
        if allowsInto {
            if t < SidebarLocalTokens.dropEdgeBand { return .above }
            if t > 1 - SidebarLocalTokens.dropEdgeBand { return .below }
            return .into
        }
        return t < 0.5 ? .above : .below
    }
}

/// What the pointer is over.
enum SidebarDropTarget: Hashable {
    /// A tab or folder row (pinned or Today).
    case row(UUID, SidebarDropZone)
    /// Above the first pinned row.
    case pinnedAreaTop
    /// Below the last pinned row, including the divider and an empty pinned area.
    case pinnedAreaEnd
    /// Below the last Today row, including the "+ New Tab" row.
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
    }

    var action: Action
    /// Folder that must be expanded after the drop. [06 §12] observed: dropping into a folder
    /// expands it and indents the tab.
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
            // [06 §12] observed: a Today tab dragged above the first pinned row becomes a pinned
            // tab placed before the folders.
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
            // Dropping on a dock icon moves the item to that space (cross-space move,
            // [06 §12] lists it as untested; behavior inferred). Favorites are shared.
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
            case .into:
                // [06 §12] observed: onto a folder row → inside, folder expands.
                // Position inside the folder (end) is inferred.
                var plan = placement(item, in: .pinned(spaceID: spaceID, folderID: folder.id), position: .last, env: env)
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
        let position: InsertPosition = zone == .above ? .before(row.id) : .after(row.id)
        switch row.location {
        case .favorite:
            return nil
        case .pinned, .today:
            return placement(item, in: row.location, position: position, env: env)
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
