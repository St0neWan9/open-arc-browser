import Foundation
import CoreGraphics

// Pure point -> drop-target mapping for the sidebar. The root drop delegate feeds the pointer
// location (sidebar root coordinate space) and the frames the views report; everything else here
// is arithmetic, so it is covered by unit tests instead of real mouse interaction.
// Spec: [06 §12] "Hover and drag results" (observed: only the two results; band sizes unknown).

/// Non-row regions the views report their frames for.
enum SidebarDropRegion: Hashable {
    /// The visible viewport of the scrolling list.
    case list
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
            /// A tab or folder row. `allowsInto` is true for folders (middle band = drop inside).
            case row(UUID, allowsInto: Bool)
            case divider
            case newTabRow
        }
        var kind: Kind
        var frame: CGRect
    }

    struct DockItem: Equatable {
        var spaceID: UUID
        var frame: CGRect
    }

    /// Visible viewport of the list. Points outside it (and outside favorites and the dock) hit nothing.
    var list: CGRect
    var entries: [Entry]
    var favorites: CGRect
    var favoriteCount: Int
    var dockItems: [DockItem]
    /// Vertical gap between two entries. Each entry's hit band is widened by half of it, so there
    /// are no dead strips between rows.
    var rowSpacing: CGFloat

    /// Assembles the geometry from the snapshot and the reported frames. Entries whose frame has
    /// not been reported yet are skipped.
    static func make(
        snapshot: SidebarSnapshot,
        dockSpaceIDs: [UUID],
        rowFrames: [UUID: CGRect],
        regions: [SidebarDropRegion: CGRect],
        rowSpacing: CGFloat
    ) -> SidebarDropGeometry {
        var entries: [Entry] = []
        func append(_ item: SidebarItemModel) {
            guard let frame = rowFrames[item.id] else { return }
            // A split-group row is keyed by its layout id and, like a tab row, has no "into" band:
            // a drop on it lands before or after the whole group. [06 §5] observed (one group).
            if case .folder = item.kind {
                entries.append(Entry(kind: .row(item.id, allowsInto: true), frame: frame))
            } else {
                entries.append(Entry(kind: .row(item.id, allowsInto: false), frame: frame))
            }
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
            rowSpacing: rowSpacing
        )
    }
}

enum SidebarDropHitTester {

    /// The drop target under `point`, or nil when the point is over no drop region.
    ///
    /// - Dock icon: move to that Space ([06 §12] lists it as untested; inferred).
    /// - Favorites block: insertion gap by x; the block accepts drops even when empty (inferred).
    /// - Row: above / into / below by the y band (`SidebarDropZone.zone`). A point in the gap above
    ///   the first row counts as "above the first row", which is how a Today tab gets pinned
    ///   ([06 §12] observed).
    /// - Divider: upper half = end of the pinned area, lower half = top of Today (inferred).
    /// - "+ New Tab" row (at the top of Today): top of Today (inferred).
    /// - Everything below the last entry: end of Today (inferred).
    static func target(at point: CGPoint, in geometry: SidebarDropGeometry) -> SidebarDropTarget? {
        if let item = geometry.dockItems.first(where: { $0.frame.contains(point) }) {
            return .dockSpace(item.spaceID)
        }
        if geometry.favorites.contains(point) {
            return .favoriteGap(SidebarLayout.favoriteGapIndex(
                forX: point.x - geometry.favorites.minX,
                count: geometry.favoriteCount,
                blockWidth: geometry.favorites.width
            ))
        }
        guard geometry.list.contains(point), let first = geometry.entries.first, let last = geometry.entries.last else {
            // Inside the list viewport but nothing is listed: append to Today.
            return geometry.list.contains(point) ? .todayAreaEnd : nil
        }

        let slack = geometry.rowSpacing / 2
        if point.y < first.frame.minY - slack { return aboveFirst(first) }
        if point.y >= last.frame.maxY + slack { return .todayAreaEnd }

        guard let index = geometry.entries.firstIndex(where: { point.y >= $0.frame.minY - slack && point.y < $0.frame.maxY + slack }) else {
            return .todayAreaEnd
        }
        let entry = geometry.entries[index]
        switch entry.kind {
        case .row(let id, let allowsInto):
            let zone = SidebarDropZone.zone(forY: point.y - entry.frame.minY, rowHeight: entry.frame.height, allowsInto: allowsInto)
            return .row(id, zone)
        case .divider:
            if point.y < entry.frame.midY { return .pinnedAreaEnd }
            return topOfToday(after: index, in: geometry)
        case .newTabRow:
            return topOfToday(after: index, in: geometry)
        }
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
