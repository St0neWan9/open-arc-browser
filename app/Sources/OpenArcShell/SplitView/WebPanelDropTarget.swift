import SwiftUI
import OpenArcModel

// A sidebar tab dropped on the web panel forms a split with the page there, the dropped tab on the
// pointer's side. [06 §15.7] observed (left half of the content area → left pane; a pinned tab
// stays where it is and Today gets a new split row). Only in-app sidebar drags are accepted here:
// links from other apps keep going to the page itself.

struct WebPanelDropDelegate: DropDelegate {
    let sidebar: SidebarViewModel
    /// Panes in the drop view's coordinate space (one pane = the whole panel).
    let panes: [SidebarWebPanelDrop.Pane]

    func validateDrop(info: DropInfo) -> Bool {
        guard case .tab? = sidebar.draggingItem else { return false }
        return SidebarWebPanelDrop.target(at: info.location, panes: panes) != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // The sidebar's indicator does not apply over the page.
        sidebar.clearDropTarget()
        guard let target = SidebarWebPanelDrop.target(at: info.location, panes: panes),
              sidebar.webPanelDropPartner(forPane: target.tabID) != nil else { return DropProposal(operation: .forbidden) }
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let target = SidebarWebPanelDrop.target(at: info.location, panes: panes),
              let partner = sidebar.webPanelDropPartner(forPane: target.tabID) else {
            sidebar.endDrag()
            return false
        }
        return sidebar.performWebPanelDrop(onTab: partner, side: target.side)
    }
}

extension View {
    /// Accepts sidebar tabs dropped on the web panel (see `WebPanelDropDelegate`).
    func webPanelDropTarget(sidebar: SidebarViewModel, panes: [SidebarWebPanelDrop.Pane]) -> some View {
        onDrop(of: [SidebarDragPayload.itemType], delegate: WebPanelDropDelegate(sidebar: sidebar, panes: panes))
    }
}
