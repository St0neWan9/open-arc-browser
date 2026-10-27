import Foundation
import CoreGraphics

// Pure point -> drop-target mapping for the sidebar. The root drop delegate feeds the pointer
// location (sidebar root coordinate space) and the frames the views report; everything else here
// is arithmetic, so it is covered by unit tests instead of real mouse interaction.
// Spec: [06 §12] "Hover and drag results", [06 §15] drag-and-drop details (E9, observed bands).

/// Non-row regions the views report their frames for.
enum SidebarDropRegion: Hashable {
    /// The visible viewport of the scrolling list.
    case list
    /// The Space-name row above the pinned area. [06 §15.4] observed: a drop target.
    case spaceName
    /// The divider row between the pinned area and Today.
    case divider
    /// The "+ New Tab" row.
    case newTabRow
    /// The favorites block.
    case favorites
    /// One Space icon in the dock.
    case dock(UUID)
}

/// Everything the hit-test needs. Built from the snapshot (order, kinds) and the reported frames.
struct SidebarDropGeometry: Equatable {

    /// One vertical entry of the scrolling list, in display order.
    struct Entry: Equatable {
        enum Kind: Equatable {
            /// A tab, folder or split-group row and how it divides into drop bands.
            case row(UUID, style: SidebarRowDropStyle)
            case divider
            case newTabRow
        }
        var kind: Kind
        var frame: CGRect
        /// Folder depth of the insertion line drawn on this entry's top edge.
        var depthAbove: Int = 0
        /// Folder depth of the insertion line drawn on its bottom edge: one deeper below an
        /// expanded folder with children (the slot is the folder's first child). [06 §15.3] observed.
        var depthBelow: Int = 0
    }

    struct DockItem: Equatable {
        var spaceID: UUID
        var frame: CGRect
    }

    /// Visible viewport of the list. Points outside it (and outside favorites, the Space-name
    /// row and the dock) hit nothing.
    var list: CGRect
    var entries: [Entry]
    var favorites: CGRect
    var favoriteCount: Int
    var dockItems: [DockItem]
    /// The Space-name row (`.null` when not reported).
    var spaceName: CGRect = .null
    /// Sidebar width, for the edge Space switching. [06 §15.6] observed.
    var width: CGFloat = 0
    /// Index of the favorite being dragged (reordering), nil for any other drag. The grid then
    /// keeps its tile count and the slot under the pointer is the new place. [06 §21.4] B55.
    var favoriteDraggedIndex: Int? = nil

    /// Assembles the geometry from the snapshot and the reported frames. Entries whose frame has
    /// not been reported yet are skipped.
    static func make(
        snapshot: SidebarSnapshot,
        dockSpaceIDs: [UUID],
        rowFrames: [UUID: CGRect],
        regions: [SidebarDropRegion: CGRect],
        width: CGFloat = 0
    ) -> SidebarDropGeometry {
        var entries: [Entry] = []
        func append(_ item: SidebarItemModel) {
            guard let frame = rowFrames[item.id] else { return }
            let style: SidebarRowDropStyle
            var depthBelow = item.depth
            switch item.kind {
            case .tab:
                style = .tab
            case .splitGroup:
                // A split-group row is one unit: a drop lands before or after the whole group.
                // [06 §5] observed (one group); halves inferred.
                style = .halves
            case .folder(let folder):
                // [06 §15.3] observed: an expanded folder with children has no "into" band; its
                // lower half is the folder's first slot (line indented one level).
                if folder.isExpanded && snapshot.hasVisibleChildren(folderID: folder.id) {
                    style = .halves
                    depthBelow += 1
                } else {
                    style = .folder
                }
            }
            entries.append(Entry(kind: .row(item.id, style: style), frame: frame, depthAbove: item.depth, depthBelow: depthBelow))
        }
        // Display order: pinned, divider, "+ New Tab" (top of Today), Today. [07 §4] observed.
        snapshot.pinned.forEach(append)
        if snapshot.showsDivider, let frame = regions[.divider] {
            entries.append(Entry(kind: .divider, frame: frame))
        }
        if let frame = regions[.newTabRow] {
            entries.append(Entry(kind: .newTabRow, frame: frame))
        }
        snapshot.today.forEach(append)
        return SidebarDropGeometry(
            list: regions[.list] ?? .null,
            entries: entries,
            favorites: regions[.favorites] ?? .null,
            favoriteCount: snapshot.favorites.count,
            dockItems: dockSpaceIDs.compactMap { id in regions[.dock(id)].map { DockItem(spaceID: id, frame: $0) } },
            spaceName: regions[.spaceName] ?? .null,
            width: width
        )
    }

    func entry(forRow id: UUID) -> Entry? {
        entries.first { if case .row(let rowID, _) = $0.kind { return rowID == id } else { return false } }
    }
}

enum SidebarDropHitTester {

    /// The drop target under `point`, or nil when the point is over no drop region.
    ///
    /// - Dock icon: move to that Space. [06 §15.6] observed.
    /// - Favorites block: insertion gap of the grid slot under the pointer (the block accepts drops
    ///   even when empty, inferred). [06 §21.4] B55.
    /// - Space-name row: first pinned item. [06 §15.4] observed.
    /// - Row: bands of `SidebarDropZone.zone`. `allowsSplit` is false while dragging something
    ///   that cannot form a split (a folder, a split group, a favorite): the middle of a tab row
    ///   then splits in half. The ≈ 21 pt around a row boundary is ONE insertion slot: the lower
    ///   row's "above" band reports the upper row's "below", so the line and the result do not
    ///   change while the pointer crosses the boundary ([06 §15.3] observed: below the last child of
    ///   a folder only the indented line shows).
    /// - Divider: upper half = end of the pinned area (after the last pinned row, inside an
    ///   expanded last folder). [06 §15.4] observed.
    /// - Lower half of the divider and upper half of "+ New Tab": no target (dead zone).
    ///   [06 §15.4] observed (≈ 29 pt).
    /// - Lower half of "+ New Tab": top of Today. [06 §15.4] observed.
    /// - Below the last row: end of Today. [06 §15.2] observed.
    static func target(at point: CGPoint, in geometry: SidebarDropGeometry, allowsSplit: Bool = true) -> SidebarDropTarget? {
        if let item = geometry.dockItems.first(where: { $0.frame.contains(point) }) {
            return .dockSpace(item.spaceID)
        }
        if geometry.favorites.contains(point) {
            // The grid slot under the pointer, row by row. [06 §21.3, §21.4] B55.
            return .favoriteGap(SidebarFavoritesGrid.dropGap(
                at: CGPoint(x: point.x - geometry.favorites.minX, y: point.y - geometry.favorites.minY),
                favoriteCount: geometry.favoriteCount,
                draggedIndex: geometry.favoriteDraggedIndex,
                width: geometry.favorites.width
            ))
        }
        if geometry.spaceName.contains(point) { return .pinnedAreaTop }
        guard geometry.list.contains(point), let first = geometry.entries.first, let last = geometry.entries.last else {
            // Inside the list viewport but nothing is listed: append to Today.
            return geometry.list.contains(point) ? .todayAreaEnd : nil
        }

        if point.y < first.frame.minY { return aboveFirst(first) }
        if point.y >= last.frame.maxY {
            if case .row(let id, _) = last.kind { return .row(id, .below) }
            return .todayAreaEnd
        }

        guard let index = geometry.entries.firstIndex(where: { point.y >= $0.frame.minY && point.y < $0.frame.maxY }) else {
            return nil
        }
        let entry = geometry.entries[index]
        switch entry.kind {
        case .row(let id, let style):
            let zone = SidebarDropZone.zone(
                forY: point.y - entry.frame.minY, x: point.x - entry.frame.minX,
                rowWidth: entry.frame.width, rowHeight: entry.frame.height,
                style: style, allowsSplit: allowsSplit
            )
            if zone == .above, let previous = previousRow(before: index, in: geometry) {
                return .row(previous, .below)
            }
            return .row(id, zone)
        case .divider:
            guard point.y < entry.frame.midY else { return nil }
            if let previous = previousRow(before: index, in: geometry) { return .row(previous, .below) }
            return .pinnedAreaEnd
        case .newTabRow:
            guard point.y >= entry.frame.midY else { return nil }
            return topOfToday(after: index, in: geometry)
        }
    }

    /// The row directly before entry `index`, if that entry is a row.
    private static func previousRow(before index: Int, in geometry: SidebarDropGeometry) -> UUID? {
        guard index > 0, case .row(let id, _) = geometry.entries[index - 1].kind else { return nil }
        return id
    }

    /// Above the first Today row that follows `index` (skipping the "+ New Tab" row), or the end of
    /// Today when Today is empty.
    private static func topOfToday(after index: Int, in geometry: SidebarDropGeometry) -> SidebarDropTarget {
        for entry in geometry.entries[(index + 1)...] {
            if case .row(let id, _) = entry.kind { return .row(id, .above) }
        }
        return .todayAreaEnd
    }

    private static func aboveFirst(_ first: SidebarDropGeometry.Entry) -> SidebarDropTarget {
        switch first.kind {
        case .row(let id, _): return .row(id, .above)
        case .divider: return .pinnedAreaEnd
        case .newTabRow: return .todayAreaEnd
        }
    }
}

/// Where the insertion line goes for a target (sidebar root space). [06 §15.2] observed: a 2 pt
/// line centered in the gap between two rows, starting at x ≈ 16 (+ 16 per folder level) with a
/// hollow ring at its left end, running to the content edge.
struct SidebarDropIndicatorLine: Equatable {
    /// Vertical center of the line.
    var y: CGFloat
    /// Left edge of the ring.
    var leading: CGFloat
    /// Right end of the line.
    var trailing: CGFloat

    /// Nil for targets drawn another way (folder into, split preview, Space-name band, favorites
    /// slot, dock) or for frames not on screen.
    static func make(for target: SidebarDropTarget?, in geometry: SidebarDropGeometry, contentTrailing: CGFloat) -> SidebarDropIndicatorLine? {
        guard let target else { return nil }
        // Our rows are 41 pt frames with the fill at y 2–38, so the gap between two fills is
        // centered half a point above the frame boundary.
        let gapOffset: CGFloat = -0.5
        func line(y: CGFloat, depth: Int) -> SidebarDropIndicatorLine {
            SidebarDropIndicatorLine(
                y: y + gapOffset,
                leading: SidebarLocalTokens.dropIndicatorLeading + CGFloat(depth) * SidebarLocalTokens.folderIndent,
                trailing: contentTrailing
            )
        }
        switch target {
        case .row(let id, .above):
            guard let entry = geometry.entry(forRow: id) else { return nil }
            return line(y: entry.frame.minY, depth: entry.depthAbove)
        case .row(let id, .below):
            guard let entry = geometry.entry(forRow: id) else { return nil }
            return line(y: entry.frame.maxY, depth: entry.depthBelow)
        case .pinnedAreaEnd:
            guard let divider = geometry.entries.first(where: { $0.kind == .divider }) else { return nil }
            return line(y: divider.frame.minY, depth: 0)
        case .todayAreaEnd:
            guard let newTab = geometry.entries.first(where: { $0.kind == .newTabRow }) else { return nil }
            return line(y: newTab.frame.maxY, depth: 0)
        case .row(_, .into), .row(_, .split), .pinnedAreaTop, .favoriteGap, .dockSpace:
            return nil
        }
    }
}
