import Foundation

// Easel: a free-form canvas the user draws on (plan B56).
//
// Spec: docs/arc-spec/06-flows.md §9 (canvas, title, toolbar, Share button), §4 (an Easel is a
// pinned row with an Easel icon), §8 (Library ▸ Easels), §11 (an Easel outlives the Space it was
// made in); 02-shortcuts.md (New Easel ⌃⇧E); 01-menus.md (File ▸ New Easel, Window ▸ View Easels…).
//
// Shape of the data (our own design; the spec shows only the surface):
// - `Easel` holds the title. It belongs to no Space: Library ▸ Easels lists it even after its Space
//   is deleted ([06 §11] observed), so its sidebar row is an ordinary `TabNode` whose URL is the
//   Easel's link (`EaselLink`). Pinning, moving, renaming, archiving and dragging the row reuse the
//   tab operations unchanged.
// - Every shape, text, image and pen stroke is its own `EaselElement` record. Separate records keep
//   each record small (CloudKit's 1 MB record limit) and let two devices edit different elements of
//   one Easel without conflicts.
//
// Image data (decision, B56): stored inline in the element's `content` group as an encoded PNG or
// JPEG of at most `EaselImage.maxEncodedBytes`. The shell downsizes larger images before inserting
// them. Inline keeps the record self-contained: it syncs like every other field (encrypted, since
// it is user content) and needs no blob store or CKAsset path, which do not exist yet. The cost is
// a larger workspace file; move images to a blob store plus CKAsset when that exists.

// MARK: - Geometry

/// A point in canvas coordinates (points, origin top-left), or normalized 0...1 inside an
/// element's frame where a type says so.
public struct EaselPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in canvas coordinates (points, origin top-left).
public struct EaselRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The rectangle spanned by two corners, in any order.
    public init(corner a: EaselPoint, _ b: EaselPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: EaselPoint { EaselPoint(x: x + width / 2, y: y + height / 2) }

    public func contains(_ p: EaselPoint) -> Bool {
        p.x >= x && p.x <= maxX && p.y >= y && p.y <= maxY
    }

    public func offsetBy(dx: Double, dy: Double) -> EaselRect {
        EaselRect(x: x + dx, y: y + dy, width: width, height: height)
    }

    /// The smallest rectangle containing both.
    public func union(_ other: EaselRect) -> EaselRect {
        let minX = Swift.min(x, other.x), minY = Swift.min(y, other.y)
        return EaselRect(x: minX, y: minY, width: Swift.max(maxX, other.maxX) - minX, height: Swift.max(maxY, other.maxY) - minY)
    }
}

// MARK: - Element content and style

/// Encoding of an inline image.
public enum EaselImageFormat: String, Codable, Hashable, Sendable {
    case png
    case jpeg
}

/// An image placed on an Easel: the encoded bytes and their pixel size.
public struct EaselImage: Codable, Hashable, Sendable {
    /// Largest encoded image kept inline (bytes). Our own limit (B56): with JSON's base64 and the
    /// other fields an element record stays well under CloudKit's 1 MB per record.
    public static let maxEncodedBytes = 300_000

    public var data: Data
    public var format: EaselImageFormat
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(data: Data, format: EaselImageFormat, pixelWidth: Int, pixelHeight: Int) {
        self.data = data
        self.format = format
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    /// Whether the bytes fit the inline limit.
    public var fitsInlineLimit: Bool { data.count <= Self.maxEncodedBytes }
}

/// The element kinds, in the order of the Easel toolbar's drawing tools: image, text, circle,
/// rectangle, arrow, pen. [06 §9] observed (toolbar order).
public enum EaselElementKind: String, Codable, Hashable, Sendable, CaseIterable {
    case image, text, circle, rectangle, arrow, pen
}

/// What an element draws. Case names and labels are persisted (workspace file and sync); never
/// rename them.
public enum EaselElementContent: Codable, Hashable, Sendable {
    /// A text box. The frame's width wraps the text.
    case text(string: String)
    case image(EaselImage)
    /// An ellipse filling the frame.
    case circle
    /// A rectangle filling the frame.
    case rectangle
    /// A straight arrow; `start` and `end` are normalized 0...1 inside the frame, so a resize
    /// scales it.
    case arrow(start: EaselPoint, end: EaselPoint)
    /// A pen stroke; points are normalized 0...1 inside the frame.
    case pen(points: [EaselPoint])

    public var kind: EaselElementKind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .circle: return .circle
        case .rectangle: return .rectangle
        case .arrow: return .arrow
        case .pen: return .pen
        }
    }
}

/// How an element is drawn. Defaults live in OpenArcDesign (`EaselTokens`, inferred values).
public struct EaselStyle: Codable, Hashable, Sendable {
    /// Outline, arrow, pen and text color.
    public var strokeColor: RGBAColor
    /// Fill of circles and rectangles; nil draws only the outline.
    public var fillColor: RGBAColor?
    /// Outline, arrow and pen width (points).
    public var strokeWidth: Double
    /// Text size (points).
    public var fontSize: Double

    public init(strokeColor: RGBAColor, fillColor: RGBAColor? = nil, strokeWidth: Double, fontSize: Double) {
        self.strokeColor = strokeColor
        self.fillColor = fillColor
        self.strokeWidth = strokeWidth
        self.fontSize = fontSize
    }
}

// MARK: - Records

/// An Easel: a full-page canvas with a title. Its elements are `EaselElement` records; its sidebar
/// rows are `TabNode`s whose URL is `EaselLink.url(for:)`. [06 §9] observed.
public struct Easel: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        /// The title.
        case naming
    }
    /// Persisted record type name. Never rename.
    public static let recordTypeName = "Easel"

    /// Title of a new Easel. [06 §9] observed: "Untitled Easel".
    public static let defaultTitle = "Untitled Easel"

    public let id: UUID
    public var title: String
    public var meta: SyncMetadata

    public init(id: UUID, title: String = Easel.defaultTitle, now: Date) {
        self.id = id
        self.title = title
        self.meta = .new(at: now, groups: FieldGroup.self)
    }

    /// The title to show: an empty title shows the default.
    public var displayTitle: String { title.isEmpty ? Self.defaultTitle : title }
}

/// One shape, text box, image or pen stroke on an Easel.
public struct EaselElement: SyncableEntity, Hashable {
    public enum FieldGroup: String, SyncFieldGroup {
        /// Owning Easel and stacking order (`zKey`): where the element sits in the Easel's stack.
        case placement
        /// Position and size on the canvas.
        case geometry
        /// What it draws (kind and payload: text, image bytes, arrow ends, stroke points).
        case content
        /// Colors, line width and text size.
        case style
    }
    /// Persisted record type name. Never rename.
    public static let recordTypeName = "EaselElement"

    public let id: UUID
    public var easelID: UUID
    /// Stacking order: later keys draw on top.
    public var zKey: SortKey
    public var frame: EaselRect
    public var content: EaselElementContent
    public var style: EaselStyle
    public var meta: SyncMetadata

    public init(id: UUID, easelID: UUID, zKey: SortKey, frame: EaselRect, content: EaselElementContent, style: EaselStyle, now: Date) {
        self.id = id
        self.easelID = easelID
        self.zKey = zKey
        self.frame = frame
        self.content = content
        self.style = style
        self.meta = .new(at: now, groups: FieldGroup.self)
    }
}

// MARK: - Link

/// The URL of an Easel's sidebar row: `openarc://easel/<UUID>`. Persisted in tab records (and
/// archive items); never change the format. The shell shows the canvas for such a tab and never
/// gives it an engine page.
public enum EaselLink {
    public static let scheme = "openarc"
    public static let host = "easel"

    public static func url(for easelID: UUID) -> URL {
        // A fixed scheme, host and UUID always form a valid URL.
        URL(string: "\(scheme)://\(host)/\(easelID.uuidString)")!
    }

    /// The Easel a URL opens, or nil when it is not an Easel link.
    public static func easelID(from url: URL?) -> UUID? {
        guard let url, url.scheme?.lowercased() == scheme, url.host?.lowercased() == host else { return nil }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return UUID(uuidString: path)
    }
}

// MARK: - Queries

extension WorkspaceState {
    /// Live Easels, newest first (Library ▸ Easels order; inferred, the spec shows one card).
    public var liveEaselsNewestFirst: [Easel] {
        easels.values
            .filter { !$0.meta.isTombstone }
            .sorted { ($0.meta.createdAt, $0.id.uuidString) > ($1.meta.createdAt, $1.id.uuidString) }
    }

    /// The Easel with this id if it is live.
    public func liveEasel(_ id: UUID) -> Easel? {
        guard let easel = easels[id], !easel.meta.isTombstone else { return nil }
        return easel
    }

    /// Live elements of a live Easel, bottom to top.
    public func elements(inEasel easelID: UUID) -> [EaselElement] {
        guard liveEasel(easelID) != nil else { return [] }
        return easelElements.values
            .filter { !$0.meta.isTombstone && $0.easelID == easelID }
            .sorted { SortKey.order(($0.zKey, $0.id), ($1.zKey, $1.id)) }
    }

    /// The Easel a tab shows (its URL, else its pinned URL, is an Easel link), live or not.
    public func easelID(ofTab tabID: UUID) -> UUID? {
        guard let tab = tabs[tabID] else { return nil }
        return EaselLink.easelID(from: tab.url) ?? EaselLink.easelID(from: tab.pinnedURL)
    }

    /// Live tabs that show an Easel.
    public func tabs(showingEasel easelID: UUID) -> [TabNode] {
        tabs.values
            .filter { !$0.meta.isTombstone && easelID == (EaselLink.easelID(from: $0.url) ?? EaselLink.easelID(from: $0.pinnedURL)) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
