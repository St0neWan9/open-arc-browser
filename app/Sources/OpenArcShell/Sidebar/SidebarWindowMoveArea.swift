import CoreGraphics

// Moving the window from the sidebar (B110). [06 §15.1] observed: pressing on the blank area of
// the list below the last row and dragging moves the whole window; it is not a drag and drop.
// Pure, so the hit areas are unit-tested; `SidebarDragSourceView` acts on the result.

/// The blank part of the visible list below its last entry, in the sidebar's root space, minus
/// the controls drawn over it (the ↓ / ↑ jump button).
struct SidebarWindowMoveArea: Equatable {
    /// The blank band, or `.null` when the rows reach the list's bottom edge.
    var blank: CGRect
    /// Parts of `blank` that belong to controls drawn over the list.
    var excluded: [CGRect]

    static let none = SidebarWindowMoveArea(blank: .null, excluded: [])

    /// `listViewport` is the visible list and `contentBottom` the bottom edge of the list's last
    /// entry (both root space, after scrolling). The trailing drop space under the last entry is
    /// blank, so it counts.
    static func make(listViewport: CGRect, contentBottom: CGFloat, excluded: [CGRect] = []) -> SidebarWindowMoveArea {
        guard !listViewport.isNull, listViewport.height > 0 else { return .none }
        let top = max(contentBottom, listViewport.minY)
        guard top < listViewport.maxY else { return .none }
        let blank = CGRect(x: listViewport.minX, y: top, width: listViewport.width, height: listViewport.maxY - top)
        return SidebarWindowMoveArea(blank: blank, excluded: excluded.filter { $0.intersects(blank) })
    }

    func contains(_ point: CGPoint) -> Bool {
        !blank.isNull && blank.contains(point) && !excluded.contains { $0.contains(point) }
    }
}

/// What a plain left press on the sidebar may start.
enum SidebarPressTarget: Equatable {
    /// A row or favorite: a press selects it and a drag past the threshold drags it ([06 §15.1]).
    case item(SidebarDragSourceItem)
    /// The blank list area: a drag moves the window ([06 §15.1] observed).
    case windowMove
    /// Anything else: the press is left to the views under it.
    case none

    /// Items win over the blank area (they never overlap it, but a row scrolled half into the
    /// band stays a row).
    static func at(_ point: CGPoint, items: [SidebarDragSourceItem], windowMoveArea: SidebarWindowMoveArea) -> SidebarPressTarget {
        if let hit = SidebarDragSourceItem.item(at: point, in: items) { return .item(hit) }
        return windowMoveArea.contains(point) ? .windowMove : .none
    }
}

extension SidebarListScrollState {
    /// The selected Space's blank list area right now (scroll offset of this moment).
    func windowMoveArea(viewModel: SidebarViewModel, layout: SidebarLayout) -> SidebarWindowMoveArea {
        let viewport = listViewport
        guard !viewport.isNull, let last = viewModel.listGeometry.entries.last else { return .none }
        let contentMinY = contentFrame(for: viewModel.selectedSpaceID).minY
        let bottom = layout.listTop + contentMinY + last.bottom
        var excluded: [CGRect] = []
        // The ↓ / ↑ button sits at the list's bottom (or top) middle while the selection is out of
        // view; its press is the button's.
        if viewModel.draggingItem == nil, let rowID = viewModel.selectedListRowID,
           let rowFrame = rowFrame(of: rowID, viewModel: viewModel, layout: layout),
           let direction = SidebarSelectionJump.direction(rowFrame: rowFrame, viewport: viewport, fill: layout.rowFillFrame) {
            let center = SidebarSelectionJump.buttonCenter(direction: direction, viewport: viewport)
            let size = SidebarSelectionJump.buttonSize
            excluded.append(CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        }
        return .make(listViewport: viewport, contentBottom: bottom, excluded: excluded)
    }
}
