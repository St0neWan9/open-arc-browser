import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// The web page's right-click menu (plan B124) on the bridge's OACContextMenu.h: the bridge builds
// Chromium's items for the click and hands an `OACContextMenu` to `-tab:showContextMenu:`; this file
// turns it into `TabEvent.contextMenuRequested(PageContextMenu)`, whose session shows the shell's
// NSMenu through `-popUpMenu:` and runs Chromium's items through `-performItemWithIdentifier:`.
// Also the extension action items of `EngineExtensions` (`contexts: ["action"]`).

extension PageContextMenuItem {
    init(_ item: OACContextMenuItem) {
        self.init(
            id: item.identifier,
            kind: Kind(rawValue: item.kind.rawValue) ?? .command,
            role: PageContextMenuRole(rawValue: item.role.rawValue) ?? .other,
            title: item.title,
            isEnabled: item.isEnabled,
            isChecked: item.isChecked,
            isVisible: item.isVisible,
            extensionID: item.extensionIdentifier,
            children: item.submenuItems.map(PageContextMenuItem.init)
        )
    }
}

extension PageContextMenuTarget {
    @MainActor
    init(_ menu: OACContextMenu) {
        let media: Media = switch menu.mediaKind {
        case .image: .image
        case .video: .video
        case .audio: .audio
        case .canvas: .canvas
        case .plugin: .plugin
        case .file: .file
        default: .none
        }
        self.init(
            linkURL: menu.linkURL,
            linkText: menu.linkText,
            sourceURL: menu.sourceURL,
            media: media,
            hasImageContents: menu.hasImageContents,
            selectionText: menu.selectionText,
            isEditable: menu.isEditable,
            isPasswordField: menu.isPasswordField,
            editFlags: EditFlags(rawValue: Int(menu.editFlags.rawValue)),
            pageURL: menu.pageURL,
            x: Double(menu.location.x),
            y: Double(menu.location.y)
        )
    }
}

extension PageContextMenu {
    /// Wraps a bridge menu. The session keeps the bridge object alive until it closes.
    @MainActor
    static func bridged(_ menu: OACContextMenu) -> PageContextMenu {
        let handle = BridgeMenuHandle(menu: menu)
        let session = PageContextMenuSession(
            present: { object in handle.menu.popUp(object) },
            perform: { id in handle.menu.performItem(identifier: id) },
            close: { ChromiumTabCore.onMain { handle.menu.close() } }
        )
        menu.itemUpdateHandler = { [weak session] item in
            session?.itemDidUpdate(PageContextMenuItem(item))
        }
        return PageContextMenu(
            target: PageContextMenuTarget(menu),
            items: menu.items.map(PageContextMenuItem.init),
            session: session
        )
    }
}

/// Carries the bridge menu into the session's handlers.
// @unchecked: `menu` is a main-actor object; every handler that touches it runs on the main actor
// (`present` / `perform` are `@MainActor`, `close` hops with `ChromiumTabCore.onMain`).
private final class BridgeMenuHandle: @unchecked Sendable {
    let menu: OACContextMenu
    init(menu: OACContextMenu) { self.menu = menu }
}

// MARK: - Extension action menu

extension ChromiumExtensions {
    func actionMenuItems(extensionID: String, tabID: EngineTabID) async -> [PageContextMenuItem] {
        await actionMenuItemsOnMain(extensionID, tabID: tabID)
    }

    func performActionMenuItem(_ itemID: Int, extensionID: String, tabID: EngineTabID) async {
        await performActionMenuItemOnMain(itemID, extensionID: extensionID, tabID: tabID)
    }

    @MainActor
    private func actionMenuItemsOnMain(_ extensionID: String, tabID: EngineTabID) async -> [PageContextMenuItem] {
        guard let wrapper = engineCore.tabs[tabID], let profile = await engineCore.onDiskProfile(wrapper.profileID) else { return [] }
        return profile.actionMenuItems(extensionIdentifier: extensionID, tab: wrapper.core.tab)
            .map(PageContextMenuItem.init)
    }

    @MainActor
    private func performActionMenuItemOnMain(_ itemID: Int, extensionID: String, tabID: EngineTabID) async {
        guard let wrapper = engineCore.tabs[tabID], let profile = await engineCore.onDiskProfile(wrapper.profileID) else { return }
        profile.performActionMenuItem(identifier: itemID, extensionIdentifier: extensionID, tab: wrapper.core.tab)
    }
}

extension ChromiumTab {
    /// Asks the page for its keyboard context menu (the focused element or selection, else the
    /// page), placed at (`x`, `y`) in the page's points: `.contextMenuRequested` follows unless the
    /// page cancels it (plan B124; for the engine conformance test and a keyboard menu command).
    public func requestContextMenu(x: Double, y: Double) async {
        await core.perform { $0.requestContextMenu(at: CGPoint(x: x, y: y)) }
    }
}
