import Foundation
import OpenArcModel

/// Reads Arc's sidebar file into a `ForeignSidebar` (plan D15).
///
/// This is an interoperability reader for a file on the user's own disk
/// (`~/Library/Application Support/Arc/StorableSidebar.json`). Arc's JSON keys appear only as
/// string literals below; every Swift name is ours. The file is opened read-only and nothing else
/// in Arc's folder is read here (never its sign-in or key files). The layout, as seen in the file
/// (inferred, D15):
///
/// - the sidebar section holds a list of containers; one of them has the item table and the Space
///   table. Both tables are flat lists that alternate an id string and its record (records also
///   carry their own id, so bare records are accepted too);
/// - a Space record has a title, an icon, an optional window theme, a profile marker and the ids
///   of its pinned and unpinned (Today) root items;
/// - an item record has an id, a parent id, ordered child ids, an optional user title and one
///   payload: a tab (saved URL and page title, optional emoji), a list (a folder), a split view
///   (child tabs, orientation), a root container (a Space's pinned / unpinned root, or the
///   favorites root), or another kind we skip;
/// - favorites are the children of the favorites root container (one per profile; the default
///   profile's is used).
public enum ArcSidebarReader {
    /// Where Arc keeps the file, relative to the home folder.
    public static let relativeFilePath = "Library/Application Support/Arc/StorableSidebar.json"
    /// Arc's Chromium profile folder (history and passwords, plan D15 / D3b), relative to home.
    public static let relativeProfilePath = "Library/Application Support/Arc/User Data/Default"

    /// Nesting deeper than this is treated as damaged and skipped (guards against cycles).
    static let maximumDepth = 64

    public static func read(contentsOf url: URL) throws -> ForeignSidebar {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw BookmarkImportError.unreadable(url.lastPathComponent)
        }
        return try read(data)
    }

    public static func read(_ data: Data) throws -> ForeignSidebar {
        guard let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw BookmarkImportError.unrecognizedFormat
        }
        guard let section = top["sidebar"] as? [String: Any],
              let containers = section["containers"] as? [Any]
        else { throw BookmarkImportError.malformed("no sidebar") }
        guard let main = containers.lazy.compactMap({ $0 as? [String: Any] }).first(where: { $0["spaces"] != nil && $0["items"] != nil })
        else { throw BookmarkImportError.malformed("no Spaces") }

        var reader = Walker(items: records(in: main["items"]))
        var result = ForeignSidebar()
        for space in records(in: main["spaces"]).values.sorted(by: { $0.order < $1.order }) {
            result.spaces.append(reader.space(space.record))
        }
        result.favorites = reader.favorites()
        result.skipped = reader.skipped
        return result
    }

    // MARK: Tables

    struct Entry {
        var order: Int
        var record: [String: Any]
    }

    /// A flat table: alternating "id", {record} pairs, or bare records with an "id" field. Keyed by
    /// id, keeping the table order.
    static func records(in value: Any?) -> [String: Entry] {
        var table: [String: Entry] = [:]
        guard let list = value as? [Any] else { return table }
        var pendingID: String?
        for element in list {
            if let id = element as? String {
                pendingID = id
            } else if let record = element as? [String: Any] {
                let id = (record["id"] as? String) ?? pendingID
                pendingID = nil
                guard let id, table[id] == nil else { continue }
                table[id] = Entry(order: table.count, record: record)
            }
        }
        return table
    }

    // MARK: Walking the item tree

    struct Walker {
        let items: [String: Entry]
        var skipped = 0

        init(items: [String: Entry]) {
            self.items = items
        }

        mutating func space(_ record: [String: Any]) -> ForeignSpace {
            let name = (record["title"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let info = record["customInfo"] as? [String: Any]
            let roots = Self.rootIDs(record)
            var space = ForeignSpace(
                name: name,
                icon: ArcSidebarReader.icon(info?["iconType"]),
                theme: ArcSidebarReader.theme(info?["windowTheme"]),
                isFromOtherProfile: !ArcSidebarReader.isDefaultProfile(record["profile"])
            )
            if let id = roots.pinned { space.pinned = children(of: id, depth: 0) }
            if let id = roots.today { space.today = children(of: id, depth: 0) }
            return space
        }

        /// The favorites root of the default profile (else the first one found).
        mutating func favorites() -> [ForeignSidebarItem] {
            let roots = items.values.sorted { $0.order < $1.order }.compactMap { entry -> (id: String, isDefault: Bool)? in
                guard let data = entry.record["data"] as? [String: Any],
                      let container = data["itemContainer"] as? [String: Any],
                      let type = container["containerType"] as? [String: Any],
                      let favorites = type["topApps"] as? [String: Any],
                      let id = entry.record["id"] as? String
                else { return nil }
                return (id, ArcSidebarReader.isDefaultProfile(favorites["_0"]))
            }
            guard let root = roots.first(where: \.isDefault) ?? roots.first else { return [] }
            return children(of: root.id, depth: 0)
        }

        /// A Space's pinned and unpinned root ids, from either of the two lists the file keeps
        /// ("pinned", id, "unpinned", id or {"pinned": {}}, id, {"unpinned": …}, id).
        static func rootIDs(_ record: [String: Any]) -> (pinned: String?, today: String?) {
            var pinned: String?
            var today: String?
            for key in ["containerIDs", "newContainerIDs"] {
                guard let list = record[key] as? [Any] else { continue }
                var index = 0
                while index + 1 < list.count {
                    let marker = list[index]
                    let label = (marker as? String) ?? (marker as? [String: Any])?.keys.first
                    if let id = list[index + 1] as? String {
                        if label == "pinned", pinned == nil { pinned = id }
                        if label == "unpinned", today == nil { today = id }
                    }
                    index += 2
                }
            }
            return (pinned, today)
        }

        mutating func children(of id: String, depth: Int) -> [ForeignSidebarItem] {
            guard let record = items[id]?.record else { return [] }
            return (record["childrenIds"] as? [Any] ?? []).compactMap { child in
                guard let childID = child as? String else { skipped += 1; return nil }
                return item(childID, depth: depth + 1)
            }
        }

        mutating func item(_ id: String, depth: Int) -> ForeignSidebarItem? {
            guard depth <= ArcSidebarReader.maximumDepth, let record = items[id]?.record else {
                skipped += 1
                return nil
            }
            let data = record["data"] as? [String: Any] ?? [:]
            if let tab = data["tab"] as? [String: Any] {
                guard let page = Self.page(record, tab: tab) else { skipped += 1; return nil }
                return .page(page)
            }
            if data["list"] != nil {
                let title = (record["title"] as? String).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
                return .folder(ForeignFolder(title: title, children: children(of: id, depth: depth)))
            }
            if let split = data["splitView"] as? [String: Any] {
                var pages: [ForeignPage] = []
                for case let childID as String in record["childrenIds"] as? [Any] ?? [] {
                    switch item(childID, depth: depth + 1) {
                    case .page(let page)?: pages.append(page)
                    case .some(let other): skipped += Self.size(other)
                    case nil: break
                    }
                }
                guard !pages.isEmpty else { return nil }
                if pages.count == 1 { return .page(pages[0]) }
                let axis: SplitAxis = (split["layoutOrientation"] as? String) == "vertical" ? .vertical : .horizontal
                return .split(ForeignSplit(axis: axis, pages: pages))
            }
            // Any other kind (onboarding pages, notes, canvases, …): skip it and what it holds.
            skipped += 1 + descendantCount(of: id, depth: depth)
            return nil
        }

        func descendantCount(of id: String, depth: Int) -> Int {
            guard depth <= ArcSidebarReader.maximumDepth, let record = items[id]?.record else { return 0 }
            return (record["childrenIds"] as? [Any] ?? []).reduce(0) { total, child in
                guard let childID = child as? String else { return total + 1 }
                return total + 1 + descendantCount(of: childID, depth: depth + 1)
            }
        }

        static func size(_ item: ForeignSidebarItem) -> Int {
            switch item {
            case .page: return 1
            case .split(let split): return split.pages.count
            case .folder(let folder): return 1 + folder.children.reduce(0) { $0 + size($1) }
            }
        }

        /// A tab row. The title is the row's own title when it has one (what the sidebar showed,
        /// a rename included), else the saved page title. The row title differs from the page
        /// title on most rows, so it cannot tell a rename from an older page title: no custom
        /// title is set and the page's title replaces it once the tab loads. inferred.
        static func page(_ record: [String: Any], tab: [String: Any]) -> ForeignPage? {
            guard let url = (tab["savedURL"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }
            let saved = (tab["savedTitle"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let shown = (record["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var page = ForeignPage(title: shown.isEmpty ? saved : shown, url: url)
            if case .emoji(let emoji)? = ArcSidebarReader.icon((tab["customInfo"] as? [String: Any])?["iconType"]) {
                page.emoji = emoji
            }
            return page
        }
    }

    // MARK: Space details

    /// "default": true marks the default profile; a missing marker counts as default.
    static func isDefaultProfile(_ value: Any?) -> Bool {
        guard let marker = value as? [String: Any] else { return true }
        if let isDefault = marker["default"] as? Bool { return isDefault }
        return marker.isEmpty
    }

    /// An emoji (as text, or as a code point) or a named glyph.
    static func icon(_ value: Any?) -> ForeignIcon? {
        guard let type = value as? [String: Any] else { return nil }
        if let emoji = type["emoji_v2"] as? String, !emoji.isEmpty { return .emoji(emoji) }
        if let code = type["emoji"] as? Int, code > 0x7F, let scalar = Unicode.Scalar(code) { return .emoji(String(Character(scalar))) }
        if let name = type["icon"] as? String, !name.isEmpty { return .symbol(name) }
        return nil
    }

    /// The Space's color: the single background color, else the palette's mid tone. Components in
    /// extended sRGB are clamped to 0…1. The appearance follows the theme's light / dark content
    /// marker; the noise strength becomes grain. Gradient backgrounds use their mid tone only.
    static func theme(_ value: Any?) -> ThemeStyle? {
        guard let theme = value as? [String: Any] else { return nil }
        let single = ((theme["background"] as? [String: Any])?["single"] as? [String: Any])?["_0"] as? [String: Any]
        let blended = ((((single?["style"] as? [String: Any])?["color"] as? [String: Any])?["_0"] as? [String: Any])?["blendedSingleColor"] as? [String: Any])?["_0"] as? [String: Any]
        let midTone = (theme["primaryColorPalette"] as? [String: Any])?["midTone"]
        guard let color = color(blended?["color"]) ?? color(midTone) else { return nil }
        var style = ThemeStyle(colors: [color])
        switch single?["contentOverBackgroundAppearance"] as? String {
        case "dark": style.appearance = .dark
        case "light": style.appearance = .light
        default: break
        }
        if let noise = ((blended?["modifiers"] as? [String: Any])?["noiseFactor"] as? NSNumber)?.doubleValue, noise.isFinite {
            style.grain = min(max(noise, 0), 1)
        }
        return style
    }

    static func color(_ value: Any?) -> RGBAColor? {
        guard let components = value as? [String: Any] else { return nil }
        func component(_ key: String) -> Double? {
            guard let number = (components[key] as? NSNumber)?.doubleValue, number.isFinite else { return nil }
            return min(max(number, 0), 1)
        }
        guard let red = component("red"), let green = component("green"), let blue = component("blue") else { return nil }
        return RGBAColor(red: red, green: green, blue: blue, alpha: component("alpha") ?? 1)
    }
}
