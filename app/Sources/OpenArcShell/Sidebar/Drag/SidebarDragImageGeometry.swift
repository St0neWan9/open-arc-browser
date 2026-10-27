import CoreGraphics
import OpenArcDesign

// Pure geometry of the sidebar drag image: which shape it takes for a pointer position and where
// it sits relative to the pointer. Everything is arithmetic in the sidebar's root coordinate space
// (top-left origin, the same space as `SidebarLayout`), so it is covered by unit tests.
// Spec: [06 §15.1] (lifted row, grab offset), [06 §15.4] (compact pill over the Space-name row,
// the address field and the window top), [06 §15.5] (favorite tile over Favorites);
// [04 §拖动图像(E17)]; design-tokens.json `Metrics.SidebarDrag`.

/// The shape of the drag image.
enum SidebarDragImageShape: Hashable, CaseIterable {
    /// The lifted row: the row's size, selected-row fill, icon + title + accessory. [06 §15.1] observed.
    case row
    /// Small pill (≈ 186 × 26), icon + smaller title + accessory. [06 §15.4] observed.
    case pill
    /// Favorite-tile shape (≈ 126 × 47), near white, only the centered icon. [06 §15.5] observed.
    case favoriteTile

    /// Image size of the shape (without shadow room).
    var size: CGSize {
        let d = Metrics.SidebarDrag.self
        switch self {
        case .row: return CGSize(width: d.rowImageSize.width, height: d.rowImageSize.height)
        case .pill: return CGSize(width: d.pillSize.width, height: d.pillSize.height)
        case .favoriteTile: return CGSize(width: d.favoriteTileSize.width, height: d.favoriteTileSize.height)
        }
    }
}

enum SidebarDragImageGeometry {

    /// The shape for a pointer at `point` (sidebar root space). The image changes shape the moment
    /// the pointer enters a zone and restores as soon as it leaves ([06 §15.4, §15.5] observed: the
    /// final shape was already there at the first sample; the transition curve is unknown, so we
    /// switch at once).
    ///
    /// - Favorites (the collection band between the address field and the Space header, window
    ///   y ≈ 82–145; Arc's switch was seen at y ≈ 85–135): favorite tile.
    /// - Above it (address field, toolbar row, window top) and the Space-name row: pill.
    /// - Everywhere else (the list, pinned rows, the dock, the web panel, outside the window):
    ///   the full-size row. [06 §15.4] observed: over pinned rows the image keeps its size. Over
    ///   the web panel and outside the window: unknown, the row is kept.
    ///
    /// The zones span the sidebar width only (the "window top" outside the sidebar is unknown).
    static func shape(at point: CGPoint, layout: SidebarLayout) -> SidebarDragImageShape {
        guard point.x >= 0, point.x < layout.width else { return .row }
        let favorites = favoritesBand(layout)
        if point.y >= favorites.minY, point.y < favorites.maxY { return .favoriteTile }
        if point.y < favorites.minY { return .pill }
        let header = spaceNameBand(layout)
        if point.y >= header.minY, point.y < header.maxY { return .pill }
        return .row
    }

    /// The favorites collection band: from the bottom of the address field (or the top bar when
    /// the web toolbar hides the address field) to the top of the Space header. [07 §4] observed
    /// (collection y 82–145).
    static func favoritesBand(_ layout: SidebarLayout) -> CGRect {
        let s = Metrics.Sidebar.self
        // The collection top does not move with more favorite rows (B55); the header below does.
        let top = CGFloat(s.favoritesCollectionTop) - layout.contentShift - layout.favoritesExtraHeight
        let bottom = CGFloat(s.spaceHeaderTop) - layout.contentShift
        return CGRect(x: 0, y: top, width: layout.width, height: bottom - top)
    }

    /// The Space-name row: full sidebar width, y 145–181. [06 §15.4] observed.
    static func spaceNameBand(_ layout: SidebarLayout) -> CGRect {
        let s = Metrics.Sidebar.self
        return CGRect(x: 0, y: CGFloat(s.spaceHeaderTop) - layout.contentShift,
                      width: layout.width, height: CGFloat(s.spaceHeaderHeight))
    }

    /// The full-size image frame at the start of a drag from a row: 1.5 pt left of the row fill,
    /// vertically centered on it. [06 §15.1] observed (press at (90, 18) in the row → image at
    /// pointer − (91.5, 18)).
    static func initialFrame(sourceFill: CGRect) -> CGRect {
        let size = SidebarDragImageShape.row.size
        return CGRect(x: sourceFill.minX - CGFloat(Metrics.SidebarDrag.rowImageLeadingOutset),
                      y: sourceFill.midY - size.height / 2, width: size.width, height: size.height)
    }

    /// Where the press sits inside the image, as fractions of its width and height (0...1).
    /// [06 §15.1] observed: the image keeps its position relative to the pointer from the press
    /// (pressed at (90, 18) in the row → image at pointer − (91.5, 18)).
    static func grabFraction(press: CGPoint, imageFrame: CGRect) -> CGPoint {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((press.x - imageFrame.minX) / imageFrame.width, 0), 1),
                       y: min(max((press.y - imageFrame.minY) / imageFrame.height, 0), 1))
    }

    /// The image frame for a pointer: the shape's size placed so the grab point keeps its fraction
    /// of the image. [06 §15.1] observed at full size; proportional when the image changes shape,
    /// inferred (Arc's small shapes held the pointer at ≈ 35 % of the width, 40–50 % of the height).
    static func frame(pointer: CGPoint, grab: CGPoint, shape: SidebarDragImageShape) -> CGRect {
        let size = shape.size
        return CGRect(x: pointer.x - grab.x * size.width, y: pointer.y - grab.y * size.height,
                      width: size.width, height: size.height)
    }
}
