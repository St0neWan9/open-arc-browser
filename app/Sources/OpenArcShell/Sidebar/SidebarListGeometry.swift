import Foundation
import CoreGraphics
import Combine
import OpenArcDesign
import OpenArcModel

// The scrolling list's exact vertical layout. Every list entry has a fixed height (a 41 pt row,
// the 17 pt divider, the 41 pt "+ New Tab" row; [07 §1, §4] observed), so the frame of any entry
// follows from the snapshot and the scroll offset alone. The list draws only the entries near the
// visible area, and drag and drop, the jump button and the quick list compute frames from this
// instead of every row reporting its frame (a Space with thousands of pinned items made each
// scroll step and each change re-lay out and re-report every row).

/// One entry of the scrolling list.
struct SidebarListEntry: Identifiable, Equatable {
    enum Content: Equatable {
        case row(SidebarItemModel)
        case divider
        case newTabRow
    }

    enum ID: Hashable {
        case row(UUID)
        case divider
        case newTabRow
    }

    var content: Content
    /// Top edge in content coordinates (0 = top of the scrolled content, above the 3 pt spacer).
    var top: CGFloat
    var height: CGFloat

    var id: ID {
        switch content {
        case .row(let item): return .row(item.id)
        case .divider: return .divider
        case .newTabRow: return .newTabRow
        }
    }

    var bottom: CGFloat { top + height }
}

/// Entries of the list in display order with their content-space positions.
struct SidebarListGeometry: Equatable {
    var entries: [SidebarListEntry]
    /// Height of the whole scrolled content, the trailing drop space included.
    var contentHeight: CGFloat
    /// Index in `entries` of each row id (tab, folder or split-group row).
    var rowIndex: [UUID: Int]
    /// The split-group row id of each tab shown inside a split-group row.
    var groupRowOfTab: [UUID: UUID] = [:]

    static let empty = SidebarListGeometry(entries: [], contentHeight: 0, rowIndex: [:])

    /// The row that shows tab `tabID`: its own row, or the split-group row that holds it. Nil for
    /// a tab with no row (favorite, inside a collapsed folder, another Space).
    func rowID(showingTab tabID: UUID) -> UUID? {
        if let group = groupRowOfTab[tabID] { return group }
        return rowIndex[tabID] != nil ? tabID : nil
    }

    /// Same order and heights as the list draws: pinned rows, the divider (when shown), "+ New
    /// Tab", Today rows; a `listTopSpacer` before them and `listTrailingSpace` after. [07 §1, §4]
    /// observed; the trailing space is B33's.
    init(snapshot: SidebarSnapshot, layout: SidebarLayout = SidebarLayout()) {
        var entries: [SidebarListEntry] = []
        var rowIndex: [UUID: Int] = [:]
        var groupRowOfTab: [UUID: UUID] = [:]
        entries.reserveCapacity(snapshot.pinned.count + snapshot.today.count + 2)
        rowIndex.reserveCapacity(snapshot.pinned.count + snapshot.today.count)
        var y = CGFloat(Metrics.Sidebar.listTopSpacer)
        func add(_ content: SidebarListEntry.Content, height: CGFloat) {
            if case .row(let item) = content {
                rowIndex[item.id] = entries.count
                if case .splitGroup(let group) = item.kind {
                    // A tab in two groups is damaged data: the first row wins, as in a list scan.
                    for tabID in group.sidebarOrder where groupRowOfTab[tabID] == nil { groupRowOfTab[tabID] = group.layoutID }
                }
            }
            entries.append(SidebarListEntry(content: content, top: y, height: height))
            y += height + layout.rowSpacing
        }
        for item in snapshot.pinned { add(.row(item), height: layout.rowHeight) }
        if snapshot.showsDivider { add(.divider, height: CGFloat(Metrics.Sidebar.dividerRowHeight)) }
        add(.newTabRow, height: layout.rowHeight)
        for item in snapshot.today { add(.row(item), height: layout.rowHeight) }
        self.init(entries: entries, contentHeight: y + SidebarLocalTokens.listTrailingSpace, rowIndex: rowIndex)
        self.groupRowOfTab = groupRowOfTab
    }

    init(entries: [SidebarListEntry], contentHeight: CGFloat, rowIndex: [UUID: Int]) {
        self.entries = entries
        self.contentHeight = contentHeight
        self.rowIndex = rowIndex
    }

    /// Indices of the entries that overlap content-space `minY..<maxY`. Entries are sorted by
    /// `top`, so this is a binary search.
    func range(overlapping minY: CGFloat, _ maxY: CGFloat) -> Range<Int> {
        guard !entries.isEmpty, maxY > minY else { return 0..<0 }
        // First entry whose bottom is below minY.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].bottom <= minY { low = mid + 1 } else { high = mid }
        }
        let start = low
        var end = start
        while end < entries.count, entries[end].top < maxY { end += 1 }
        return start..<end
    }

    /// The entry frame in the sidebar's root space for a list whose content top is at
    /// `contentMinY` in the list viewport (minus the scroll offset).
    func rootFrame(of entry: SidebarListEntry, contentMinY: CGFloat, layout: SidebarLayout) -> CGRect {
        CGRect(x: 0, y: layout.listTop + contentMinY + entry.top, width: layout.width, height: entry.height)
    }

    /// Root-space frame of row `id`, scrolled into view or not.
    func rootFrame(ofRow id: UUID, contentMinY: CGFloat, layout: SidebarLayout) -> CGRect? {
        rowIndex[id].map { rootFrame(of: entries[$0], contentMinY: contentMinY, layout: layout) }
    }

    /// What the drop hit-test and the drag source need: root-space frames of the rows in the
    /// visible list (`viewport`, root space) plus one entry on each side, so a slot at the edge
    /// still knows its neighbor; and the divider and "+ New Tab" frames as drop regions.
    func visibleFrames(contentMinY: CGFloat, viewport: CGRect, layout: SidebarLayout) -> (rows: [UUID: CGRect], regions: [SidebarDropRegion: CGRect]) {
        let origin = layout.listTop + contentMinY
        let visible: Range<Int>
        if viewport.isNull {
            // No viewport reported yet: the reference window's list height from the top.
            visible = range(overlapping: -contentMinY, -contentMinY + layout.windowSize.height)
        } else {
            visible = range(overlapping: viewport.minY - origin, viewport.maxY - origin)
        }
        let lower = max(0, visible.lowerBound - 1), upper = min(entries.count, visible.upperBound + 1)
        var rows: [UUID: CGRect] = [:]
        var regions: [SidebarDropRegion: CGRect] = [:]
        for entry in entries[lower..<upper] {
            let frame = rootFrame(of: entry, contentMinY: contentMinY, layout: layout)
            switch entry.content {
            case .row(let item): rows[item.id] = frame
            case .divider: regions[.divider] = frame
            case .newTabRow: regions[.newTabRow] = frame
            }
        }
        return (rows, regions)
    }
}

/// A snapshot and its list geometry, immutable and shared by reference (see
/// `SidebarViewModel.listContent`).
final class SidebarListContent: Sendable {
    let snapshot: SidebarSnapshot
    let geometry: SidebarListGeometry

    init(snapshot: SidebarSnapshot) {
        self.snapshot = snapshot
        self.geometry = SidebarListGeometry(snapshot: snapshot)
    }

    private init(snapshot: SidebarSnapshot, geometry: SidebarListGeometry) {
        self.snapshot = snapshot
        self.geometry = geometry
    }

    /// These rows with tabs `ids` taken again from `workspace`, for a change that touched only
    /// those tabs' content (URL, title, favicon URL): no row moves, appears or goes away, so each
    /// one is replaced in place (B107). Returns `self` when none of them is drawn differently, and
    /// nil when a tab is no longer where the rows have it (the caller walks the Space again).
    func replacingTabs(_ ids: Set<UUID>, from workspace: WorkspaceState) -> SidebarListContent? {
        var snapshot = self.snapshot
        var geometry = self.geometry
        var changed = false
        // Where Today's rows start in `entries`: after the pinned rows, the divider and "+ New Tab".
        let todayStart = snapshot.pinned.count + (snapshot.showsDivider ? 1 : 0) + 1
        for id in ids {
            guard let tab = workspace.tabs[id] else { return nil }
            if let index = snapshot.favorites.firstIndex(where: { $0.id == id }), !snapshot.favorites[index].drawsSame(as: tab) {
                guard tab.location == snapshot.favorites[index].location else { return nil }
                snapshot.favorites[index] = tab
                changed = true
            }
            guard let rowID = geometry.rowID(showingTab: id), let index = geometry.rowIndex[rowID],
                  case .row(let item) = geometry.entries[index].content else { continue }
            guard let replaced = item.replacingTab(tab) else { return nil }
            guard !replaced.drawsSame(as: item) else { continue }
            geometry.entries[index].content = .row(replaced)
            if index < snapshot.pinned.count {
                snapshot.pinned[index] = replaced
            } else if index >= todayStart, index - todayStart < snapshot.today.count {
                snapshot.today[index - todayStart] = replaced
            } else {
                return nil
            }
            changed = true
        }
        return changed ? SidebarListContent(snapshot: snapshot, geometry: geometry) : self
    }
}

/// Scroll positions of a sidebar's lists, by Space (during the Space switch the outgoing and the
/// incoming page both show a list). Reference type owned by `SidebarView`: only the small views
/// that depend on the offset observe it, so scrolling never re-evaluates the whole sidebar.
@MainActor
final class SidebarListScrollState: ObservableObject {
    /// Frame of each list's content in its viewport (minY = minus the scroll offset).
    @Published private(set) var contentFrames: [UUID: CGRect] = [:]
    /// Viewport size of each list.
    private(set) var viewportSizes: [UUID: CGSize] = [:]
    /// Speaker glyph frames on screen (root space), by tab id. Read on a press only, so they
    /// are not published.
    var audioGlyphFrames: [UUID: CGRect] = [:]
    /// Content-space band of each list whose rows exist as views (`SidebarListWindow`), for
    /// tests and diagnostics. Not published.
    private(set) var rowBands: [UUID: ClosedRange<CGFloat>] = [:]

    func noteRowBand(_ spaceID: UUID?, minY: CGFloat, maxY: CGFloat) {
        guard let spaceID, maxY >= minY else { return }
        rowBands[spaceID] = minY...maxY
    }

    func contentFrame(for spaceID: UUID?) -> CGRect {
        spaceID.flatMap { contentFrames[$0] } ?? .zero
    }

    func viewportSize(for spaceID: UUID?) -> CGSize {
        spaceID.flatMap { viewportSizes[$0] } ?? .zero
    }

    func update(_ spaceID: UUID?, contentFrame: CGRect, viewportSize: CGSize) {
        guard let spaceID else { return }
        viewportSizes[spaceID] = viewportSize
        if contentFrames[spaceID] != contentFrame { contentFrames[spaceID] = contentFrame }
    }

    /// A Space's page was dropped (`SidebarSpacePagerView`): its list starts at the top when the
    /// page is built again.
    func forget(_ spaceID: UUID?) {
        guard let spaceID else { return }
        viewportSizes[spaceID] = nil
        scrollHooks[spaceID] = nil
        if contentFrames[spaceID] != nil { contentFrames[spaceID] = nil }
    }

    /// The scroll hook of each kept Space page's list (weak: the list owns it). B101.
    private var scrollHooks: [UUID: WeakScrollHook] = [:]

    private struct WeakScrollHook {
        weak var hook: SidebarNSScrollHook?
    }

    func setScrollHook(_ hook: SidebarNSScrollHook, for spaceID: UUID?) {
        guard let spaceID, scrollHooks[spaceID]?.hook !== hook else { return }
        scrollHooks[spaceID] = WeakScrollHook(hook: hook)
    }

    func scrollHook(for spaceID: UUID?) -> SidebarNSScrollHook? {
        spaceID.flatMap { scrollHooks[$0]?.hook }
    }

    // MARK: Regions

    /// Frames of the non-row regions (list viewport, Space name, favorites, dock icons) in the
    /// sidebar root space. The divider and "+ New Tab" come from the list geometry instead.
    @Published private(set) var regions: [SidebarDropRegion: CGRect] = [:]
    /// Regions reported by the sidebar itself (favorites, dock) and by the Space pages (list,
    /// Space name). The pages are hosted apart (`SidebarSpacePagerView`), so their preferences
    /// do not reach the sidebar's: each side reports here and `regions` is their union (B101).
    private var sidebarRegions: [SidebarDropRegion: CGRect] = [:]
    private var pageRegions: [SidebarDropRegion: CGRect] = [:]

    func setRegions(_ new: [SidebarDropRegion: CGRect]) {
        sidebarRegions = new
        publishRegions()
    }

    /// The regions a Space page reports. Every page has the same list and Space-name frames.
    func setPageRegions(_ new: [SidebarDropRegion: CGRect]) {
        pageRegions = new
        publishRegions()
    }

    private func publishRegions() {
        // The divider and "+ New Tab" scroll with the list: computed, never stored.
        let fixed = sidebarRegions.merging(pageRegions) { _, page in page }.filter { $0.key != .divider && $0.key != .newTabRow }
        if fixed != regions { regions = fixed }
    }

    /// The visible list area (sidebar root space), `.null` until reported.
    var listViewport: CGRect { regions[.list] ?? .null }

    // MARK: Derived frames

    /// Content top of the selected Space's list, in its viewport (minus the scroll offset).
    private func contentMinY(_ viewModel: SidebarViewModel) -> CGFloat {
        contentFrame(for: viewModel.selectedSpaceID).minY
    }

    /// Root-space frame of row `id` of the selected Space's list, on screen or not.
    func rowFrame(of id: UUID, viewModel: SidebarViewModel, layout: SidebarLayout) -> CGRect? {
        viewModel.listGeometry.rootFrame(ofRow: id, contentMinY: contentMinY(viewModel), layout: layout)
    }

    /// The drop hit-test's geometry for the current scroll offset: the rows around the visible
    /// list plus the reported regions.
    func dropGeometry(viewModel: SidebarViewModel, layout: SidebarLayout) -> SidebarDropGeometry {
        let visible = viewModel.listGeometry.visibleFrames(contentMinY: contentMinY(viewModel), viewport: listViewport, layout: layout)
        var geometry = SidebarDropGeometry.make(
            snapshot: viewModel.snapshot,
            dockSpaceIDs: viewModel.dockSpaces.map(\.id),
            rowFrames: visible.rows,
            regions: regions.merging(visible.regions) { _, new in new },
            width: layout.width
        )
        // Reordering a favorite keeps the grid's tile count. [06 §21.4] B55.
        geometry.favoriteDraggedIndex = viewModel.draggedFavoriteIndex
        return geometry
    }

    /// What a press can pick up right now (favorite slots and the rows in the visible list).
    func dragSourceItems(viewModel: SidebarViewModel, layout: SidebarLayout) -> [SidebarDragSourceItem] {
        let snapshot = viewModel.snapshot
        let favoriteSlots = viewModel.isIncognito ? [] : layout.favoriteSlotFrames(count: snapshot.favorites.count)
        let visible = viewModel.listGeometry.visibleFrames(contentMinY: contentMinY(viewModel), viewport: listViewport, layout: layout)
        return SidebarDragSourceItem.make(
            snapshot: snapshot,
            rowFrames: visible.rows,
            listViewport: listViewport,
            favoriteSlots: favoriteSlots,
            accessoryWidth: layout.width - layout.rowFillFrame.maxX + SidebarLocalTokens.rowAccessoryTrailingPadding + SidebarLocalTokens.rowAccessoryButtonSize,
            audioGlyphFrames: Array(audioGlyphFrames.values)
        )
    }
}
