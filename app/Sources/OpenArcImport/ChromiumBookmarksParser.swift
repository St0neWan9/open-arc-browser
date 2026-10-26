import Foundation

/// Reads the `Bookmarks` file of a Chromium-family profile (Chrome, Brave, Edge, Chromium,
/// Vivaldi). The file is JSON:
///
/// ```json
/// { "roots": { "bookmark_bar": { "type": "folder", "name": "…", "children": [ … ] },
///              "other":        { … },
///              "synced":       { … } },
///   "version": 1 }
/// ```
///
/// Each child is `{"type": "url", "name": …, "url": …}` or `{"type": "folder", "name": …,
/// "children": […]}`. Unknown node types are ignored.
///
/// Mapping (inferred, D3): `bookmark_bar` → `BookmarkTree.bar`; the children of `other` go straight
/// into `BookmarkTree.other`; `synced` (mobile bookmarks) and any other non-empty root become one
/// folder each inside `other`, named after the root.
public enum ChromiumBookmarksParser {
    public static func parse(_ data: Data) throws -> BookmarkTree {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BookmarkImportError.unrecognizedFormat
        }
        guard let top = object as? [String: Any], let roots = top["roots"] as? [String: Any] else {
            throw BookmarkImportError.malformed("no \"roots\" object")
        }
        var tree = BookmarkTree()
        if let bar = roots["bookmark_bar"] as? [String: Any] {
            tree.bar = children(of: bar)
        }
        if let other = roots["other"] as? [String: Any] {
            tree.other = children(of: other)
        }
        // Remaining roots in a stable order: `synced` first, then the rest by key.
        let known: Set<String> = ["bookmark_bar", "other"]
        let rest = roots.keys.filter { !known.contains($0) }.sorted { lhs, rhs in
            if lhs == "synced" { return rhs != "synced" }
            if rhs == "synced" { return false }
            return lhs < rhs
        }
        for key in rest {
            guard let root = roots[key] as? [String: Any] else { continue }
            let nodes = children(of: root)
            guard !nodes.isEmpty else { continue }
            let fallback = key == "synced" ? "Mobile Bookmarks" : key
            let name = (root["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            tree.other.append(.folder(BookmarkFolder(title: name, children: nodes)))
        }
        return tree
    }

    private static func children(of folder: [String: Any]) -> [BookmarkNode] {
        guard let list = folder["children"] as? [Any] else { return [] }
        return list.compactMap { item in
            guard let node = item as? [String: Any] else { return nil }
            return self.node(node)
        }
    }

    private static func node(_ node: [String: Any]) -> BookmarkNode? {
        let name = node["name"] as? String ?? ""
        switch node["type"] as? String {
        case "url":
            guard let url = node["url"] as? String else { return nil }
            return .bookmark(Bookmark(title: name, url: url))
        case "folder":
            return .folder(BookmarkFolder(title: name, children: children(of: node)))
        default:
            return nil
        }
    }
}
