import Foundation
import UniformTypeIdentifiers

// What a sidebar drag puts on the pasteboard.
//
// In-app items travel as a private type that only this process can read, so a tab or folder id
// never reaches another app as raw text. A tab that has a URL is also offered as a plain URL, so it
// can be dragged out to other apps (inferred; the spec does not cover dragging out).

enum SidebarDragPayload {

    /// Private pasteboard type of a sidebar item. The identifier is ours, not Arc's. It is
    /// `<bundle id>.sidebar-item`, so each build exports its own type; app/Bundle/Info.plist
    /// declares it and scripts/make-app.sh rewrites the prefix for the development build.
    static let itemType = UTType(exportedAs: "\(AppIdentity.bundleIdentifier).sidebar-item", conformingTo: .data)

    /// Encodes an item as `tab:<uuid>` / `folder:<uuid>` / `split:<layout uuid>`.
    static func encode(_ item: SidebarDragItem) -> Data {
        let kind: String
        switch item {
        case .tab: kind = "tab"
        case .folder: kind = "folder"
        case .splitGroup: kind = "split"
        }
        return Data("\(kind):\(item.id.uuidString)".utf8)
    }

    static func decode(_ data: Data) -> SidebarDragItem? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        switch parts[0] {
        case "tab": return .tab(id)
        case "folder": return .folder(id)
        case "split": return .splitGroup(id)
        default: return nil
        }
    }

    /// The item provider for a drag. `url` is the page address of a tab (nil for folders and
    /// tabs without a page).
    static func makeProvider(item: SidebarDragItem, url: URL?) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = encode(item)
        provider.registerDataRepresentation(for: itemType, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        if let url {
            provider.registerObject(url as NSURL, visibility: .all)
        }
        return provider
    }
}
