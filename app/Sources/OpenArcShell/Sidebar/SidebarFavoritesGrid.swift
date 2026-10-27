import CoreGraphics
import OpenArcDesign

/// Pure geometry of the favorites grid (plan B55). [06 §21.3] observed for n = 1, 2, 4–9:
/// rows = ⌈n / 4⌉, columns = ⌈n / rows⌉ (the rule is inferred from those counts); tiles are 47
/// tall with 8 pt gaps both ways, share the 260 pt between the 8 pt insets, and a short last row is
/// left-aligned. The area around the tiles adds 8 above and below (63 / 118 / 173 for 1 / 2 / 3
/// rows). With no favorites the area holds the empty-state card ([06 §21.2] observed, 105 tall).
///
/// Coordinates are relative to the top-left of the tiles (x 8, y 90 in the window).
enum SidebarFavoritesGrid {
    typealias G = Metrics.FavoritesGrid

    /// Width shared by the tiles of one row (x 8–268). [06 §21.3] observed.
    static var tilesWidth: CGFloat { CGFloat(Metrics.Sidebar.width - 2 * G.inset) }

    /// Rows and columns for `count` tiles. Zero tiles: no grid.
    static func shape(count: Int) -> (rows: Int, columns: Int) {
        guard count > 0 else { return (0, 0) }
        let rows = (count + G.maxColumns - 1) / G.maxColumns
        let columns = (count + rows - 1) / rows
        return (rows, columns)
    }

    /// Tile width for `columns` columns: (260 − 8 × (columns − 1)) ÷ columns. [06 §21.3] observed.
    static func tileWidth(columns: Int, width: CGFloat = tilesWidth) -> CGFloat {
        guard columns > 0 else { return width }
        return (width - CGFloat(G.spacing) * CGFloat(columns - 1)) / CGFloat(columns)
    }

    /// Height of the tiles block: rows × 47 + (rows − 1) × 8; the empty-state card (≈ 89) when
    /// there are no favorites and the card shows; one tile row when it was dismissed (inferred:
    /// the block stays as an empty drop target).
    static func tilesHeight(count: Int, showsEmptyCard: Bool) -> CGFloat {
        let rows = shape(count: count).rows
        guard rows > 0 else { return CGFloat(showsEmptyCard ? G.emptyStateCardHeight : G.tileHeight) }
        return CGFloat(rows) * CGFloat(G.tileHeight) + CGFloat(rows - 1) * CGFloat(G.spacing)
    }

    /// Height of the whole favorites area: the tiles plus 8 above and below. [06 §21.3] observed
    /// (63 / 118 / 173), [06 §21.2] observed (105 with the empty-state card).
    static func areaHeight(count: Int, showsEmptyCard: Bool) -> CGFloat {
        tilesHeight(count: count, showsEmptyCard: showsEmptyCard) + 2 * CGFloat(G.inset)
    }

    /// How much lower than with one row the Space header and the list sit.
    static func extraHeight(count: Int, showsEmptyCard: Bool) -> CGFloat {
        areaHeight(count: count, showsEmptyCard: showsEmptyCard) - CGFloat(G.oneRowAreaHeight)
    }

    /// Tile frames in display order, row by row, offset by `origin`. The last row is left-aligned.
    static func slotFrames(count: Int, origin: CGPoint = .zero, width: CGFloat = tilesWidth) -> [CGRect] {
        let (_, columns) = shape(count: count)
        guard columns > 0 else { return [] }
        let tile = tileWidth(columns: columns, width: width)
        let gap = CGFloat(G.spacing), height = CGFloat(G.tileHeight)
        return (0..<count).map { index in
            let row = index / columns, column = index % columns
            return CGRect(x: origin.x + CGFloat(column) * (tile + gap),
                          y: origin.y + CGFloat(row) * (height + gap),
                          width: tile, height: height)
        }
    }

    /// The slot (0..<count) a point over the grid of `count` tiles falls on: the row by y, then the
    /// column by x inside that row (points past a short last row take its last slot). `point` is
    /// relative to the tiles' top-left. Gaps belong to the slot on their left / above.
    static func slotIndex(at point: CGPoint, count: Int, width: CGFloat = tilesWidth) -> Int {
        let (rows, columns) = shape(count: count)
        guard rows > 0 else { return 0 }
        let pitchY = CGFloat(G.tileHeight + G.spacing)
        let row = min(max(Int((point.y / pitchY).rounded(.down)), 0), rows - 1)
        let inRow = min(columns, count - row * columns)
        let pitchX = tileWidth(columns: columns, width: width) + CGFloat(G.spacing)
        let column = min(max(Int((point.x / pitchX).rounded(.down)), 0), inRow - 1)
        return row * columns + column
    }

    /// The drop gap (0...favorites count, see `SidebarDropTarget.favoriteGap`) for a pointer over
    /// the grid. While a favorite is reordered the grid keeps its `favoriteCount` tiles and the slot
    /// under the pointer is the dragged tile's new place; any other item opens one more tile at the
    /// slot under the pointer. [06 §21.4] observed: the other tiles give way while dragging.
    static func dropGap(at point: CGPoint, favoriteCount: Int, draggedIndex: Int?, width: CGFloat = tilesWidth) -> Int {
        if let draggedIndex {
            let target = slotIndex(at: point, count: favoriteCount, width: width)
            return target >= draggedIndex ? target + 1 : target
        }
        return slotIndex(at: point, count: favoriteCount + 1, width: width)
    }

    /// The dragged item's place (0-based, in the order after the drop) for a gap from `dropGap`.
    static func targetIndex(gap: Int, draggedIndex: Int?) -> Int {
        guard let draggedIndex else { return gap }
        return gap > draggedIndex ? gap - 1 : gap
    }
}
