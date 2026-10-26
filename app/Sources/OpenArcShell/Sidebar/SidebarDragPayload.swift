import Foundation
import AppKit
import UniformTypeIdentifiers

// What a sidebar drag puts on the pasteboard.
//
// [06 §15.7] observed: during a drag the pasteboard holds only an app-private item type, with no
// URL and no text, inside and outside the window, so a tab dropped on the desktop or another app
// produces nothing. Ours does the same: the item travels as our own private type only (the
// identifier is ours). Links dragged INTO the sidebar from other apps are still accepted.

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

    /// The item provider for a drag: the private type only, readable by this process only.
    static func makeProvider(item: SidebarDragItem) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = encode(item)
        provider.registerDataRepresentation(for: itemType, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    /// The pasteboard item of an AppKit drag session (`SidebarDragSourceView`): the private type only.
    static func makePasteboardItem(_ item: SidebarDragItem) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setData(encode(item), forType: NSPasteboard.PasteboardType(itemType.identifier))
        return pasteboardItem
    }
}

/// What a press in the sidebar can pick up, and where (sidebar root space).
struct SidebarDragSourceItem: Equatable {
    var item: SidebarDragItem
    var frame: CGRect
    /// Area where a press also selects the item ([06 §15.1] observed: mouse-down selects the tab).
    /// Excludes the row's trailing ✕ / — button, which acts on mouse-up. Nil = never selects.
    var selectRect: CGRect?

    /// Pickable items: favorite slots, then the list rows inside the visible list area.
    static func make(
        snapshot: SidebarSnapshot,
        rowFrames: [UUID: CGRect],
        listViewport: CGRect,
        favoriteSlots: [CGRect],
        accessoryWidth: CGFloat
    ) -> [SidebarDragSourceItem] {
        var result: [SidebarDragSourceItem] = zip(snapshot.favorites, favoriteSlots).map { tab, slot in
            SidebarDragSourceItem(item: .tab(tab.id), frame: slot, selectRect: slot)
        }
        for row in snapshot.pinned + snapshot.today {
            guard let frame = rowFrames[row.id] else { continue }
            let visible = listViewport.isNull ? frame : frame.intersection(listViewport)
            guard !visible.isNull, visible.height > 0 else { continue }
            let item: SidebarDragItem
            switch row.kind {
            case .tab(let tab): item = .tab(tab.id)
            case .folder(let folder): item = .folder(folder.id)
            case .splitGroup(let group): item = .splitGroup(group.layoutID)
            }
            var select = visible
            select.size.width = max(0, visible.width - accessoryWidth)
            let selectRect: CGRect? = if case .folder = row.kind { nil } else { select }
            result.append(SidebarDragSourceItem(item: item, frame: visible, selectRect: selectRect))
        }
        return result
    }

    /// The topmost item under `point`.
    static func item(at point: CGPoint, in items: [SidebarDragSourceItem]) -> SidebarDragSourceItem? {
        items.first { $0.frame.contains(point) }
    }
}

/// Drag start threshold, per axis. [06 §15.1] observed: ≥ 4 pt vertically or ≥ 5 pt horizontally
/// starts a drag; 1–3 pt vertically, 1–4 pt horizontally and (3, 3) diagonally do not.
enum SidebarDragThreshold {
    static func isExceeded(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dy) >= SidebarLocalTokens.dragStartThresholdY || abs(dx) >= SidebarLocalTokens.dragStartThresholdX
    }
}
