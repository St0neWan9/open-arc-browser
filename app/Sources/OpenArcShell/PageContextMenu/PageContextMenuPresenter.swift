import Foundation
import AppKit
import OpenArcModel
import OpenArcEngine

// Shows the web page's right-click menu (plan B124) and runs its items. The order comes from
// `PageContextMenuLayout` ([05 §右键菜单] E29 observed); this file makes the NSMenu and acts on
// the shell's own items:
// - Open Link in Split View: the link opens as a new Today tab beside the page, in a split
//   (inferred; [06 §22.3] observed the same result from Peek's ▯▯ button).
// - Open Link in Little Arc: a Little Arc window on the link (as a link from another app, B24).
// - Open Link in Incognito Window: a new incognito window showing the link.
// - Capture Image…: the capture tool's region selection on the page (File ▸ Capture…, [06 §24.1]);
//   the engine reports no image box to preset it with (inferred).
// - Search <engine> for Image: a new Today tab with the engine's image results (B139, inferred).
// - Save As… / Print… / Translate / Search / Import Passwords: the shell's own commands
//   (File ▸ Save Page As, File ▸ Print, the translation bubble's Translate, a new tab with the
//   profile's search engine, Import from Another Browser…).

/// Builds and shows the NSMenu. One instance per shown menu: it is the items' target.
@MainActor
final class PageContextMenuPresenter: NSObject {
    private let menu: PageContextMenu
    private let entries: [PageMenuEntry]
    private let runShellAction: (PageMenuShellAction) -> Void
    /// Engine items by id, for the items Chromium changes while the menu is open.
    private var engineItems: [Int: NSMenuItem] = [:]
    private var pendingShellAction: PageMenuShellAction?

    init(menu: PageContextMenu, layout: PageContextMenuLayout, runShellAction: @escaping (PageMenuShellAction) -> Void) {
        self.menu = menu
        self.entries = layout.entries(for: menu)
        self.runShellAction = runShellAction
    }

    /// Shows the menu at the click and returns once it closed; a chosen shell item runs then.
    func present() {
        let nsMenu = NSMenu()
        nsMenu.autoenablesItems = false
        for entry in entries { nsMenu.addItem(makeItem(entry)) }
        menu.session.onItemUpdate { [weak self] item in self?.update(item) }
        let session = menu.session
        if !session.present(nsMenu) {
            session.close()
        } else {
            // The menu is gone; an engine item chosen in it already ran. Ending the session on the
            // next turn lets an action AppKit sends as the menu closes still reach the engine.
            Task { @MainActor in session.close() }
        }
        // Shell items run after the menu is gone (a window or a sheet may open).
        if let action = pendingShellAction {
            pendingShellAction = nil
            runShellAction(action)
        }
    }

    private func makeItem(_ entry: PageMenuEntry) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .shell(let action, let title, let isEnabled):
            let item = NSMenuItem(title: title, action: #selector(chooseShellItem(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = isEnabled
            item.representedObject = ShellActionBox(action)
            return item
        case .engine(let engineItem):
            return makeEngineItem(engineItem)
        }
    }

    private func makeEngineItem(_ engineItem: PageContextMenuItem) -> NSMenuItem {
        let item = NSMenuItem(title: engineItem.title, action: nil, keyEquivalent: "")
        item.isEnabled = engineItem.isEnabled
        item.isHidden = !engineItem.isVisible
        item.state = engineItem.isChecked ? .on : .off
        if engineItem.kind == .submenu {
            let submenu = NSMenu(title: engineItem.title)
            submenu.autoenablesItems = false
            for child in engineItem.children {
                submenu.addItem(child.kind == .separator ? .separator() : makeEngineItem(child))
            }
            item.submenu = submenu
            item.isEnabled = !engineItem.children.isEmpty
        } else {
            item.action = #selector(chooseEngineItem(_:))
            item.target = self
            item.tag = engineItem.id
            engineItems[engineItem.id] = item
        }
        return item
    }

    private func update(_ engineItem: PageContextMenuItem) {
        guard let item = engineItems[engineItem.id] else { return }
        item.title = engineItem.title
        item.isEnabled = engineItem.isEnabled
        item.isHidden = !engineItem.isVisible
    }

    @objc private func chooseEngineItem(_ sender: NSMenuItem) {
        menu.session.perform(sender.tag)
    }

    @objc private func chooseShellItem(_ sender: NSMenuItem) {
        pendingShellAction = (sender.representedObject as? ShellActionBox)?.action
    }
}

/// Lets a shell action ride in `NSMenuItem.representedObject`.
private final class ShellActionBox: NSObject {
    let action: PageMenuShellAction
    init(_ action: PageMenuShellAction) { self.action = action }
}

// MARK: - Actions

extension PageContextMenu {
    /// Shows the menu with the engine's items only (pages without a model tab: Little Arc, Peek;
    /// their own toolbars carry the shell's actions). inferred.
    @MainActor
    func presentEngineItemsOnly(searchEngineName: String) {
        let layout = PageContextMenuLayout(searchEngineName: searchEngineName, availableActions: [])
        PageContextMenuPresenter(menu: self, layout: layout, runShellAction: { _ in }).present()
    }
}

extension WorkspaceController {
    /// A page asked for its right-click menu (`TabEvent.contextMenuRequested`). The window that
    /// shows the tab presents it; with none, the menu closes unshown.
    func pageContextMenuRequested(_ menu: PageContextMenu, from id: UUID) {
        guard let window = browserWindows.first(where: { $0.sidebar.countsAsVisibleWindow && $0.sidebar.onScreenTabIDs.contains(id) }) else {
            menu.session.close()
            return
        }
        window.presentPageContextMenu(menu, tabID: id)
    }

    /// Opens `url` in a new Little Arc window (the page menu's "Open Link in Little Arc", B124).
    /// False when no window opener is installed or the URL is not a web link.
    @discardableResult
    func openURLInLittleArc(_ url: URL) -> Bool {
        guard ExternalOpen.isWebLink(url), let open = openLittleArcWindow else { return false }
        let id = issueLittleArcWindowID()
        littleArcLaunchURLs[id] = url
        open(id)
        return true
    }
}

extension ShellModel {
    /// The shell actions a browser window offers in the page menu: all of them, without the ones
    /// an incognito window cannot do (Little Arc is never off the record; Import Passwords is not
    /// for an incognito window; inferred).
    var pageMenuActions: Set<PageMenuShellAction.Kind> {
        var actions = Set(PageMenuShellAction.Kind.allCases)
        if isIncognito { actions.subtract([.openLinkInLittleArc, .importPasswords]) }
        return actions
    }

    var pageMenuLayout: PageContextMenuLayout {
        let engine = currentProfileSettings.searchEngine
        return PageContextMenuLayout(searchEngineName: engine.displayName, imageSearchURLTemplate: engine.imageSearchURLTemplate,
                                     availableActions: pageMenuActions)
    }

    /// Shows a page's right-click menu for model tab `tabID` (B124).
    func presentPageContextMenu(_ menu: PageContextMenu, tabID: UUID) {
        let presenter = PageContextMenuPresenter(menu: menu, layout: pageMenuLayout) { [weak self] action in
            self?.runPageMenuAction(action, tabID: tabID)
        }
        presenter.present()
    }

    /// Runs one of the shell's page menu items for model tab `tabID`.
    func runPageMenuAction(_ action: PageMenuShellAction, tabID: UUID) {
        switch action {
        case .openLinkInSplitView(let url):
            openLinkInSplitView(url, beside: tabID)
        case .openLinkInLittleArc(let url):
            if !controller.openURLInLittleArc(url) { sidebar.newTab(url: url, title: url.host ?? url.absoluteString) }
        case .openLinkInIncognito(let url):
            guard let open = controller.openBrowserWindow else { return }
            open(BrowserWindowRequest(kind: .incognito, url: url))
        case .captureImage:
            focusPaneIfNeeded(tabID)
            beginRegionCapture()
        case .savePage:
            focusPaneIfNeeded(tabID)
            savePageAs()
        case .print:
            focusPaneIfNeeded(tabID)
            printPage()
        case .translate:
            translation.translate(tabID, to: nil)
        case .search(let text):
            guard let url = searchURL(for: text) else { return }
            sidebar.newTab(url: url, title: text)
        case .searchImage(let url):
            sidebar.newTab(url: url, title: url.host ?? url.absoluteString)
        case .importPasswords:
            BookmarkImportPresenter.present(controller: controller)
        }
    }

    /// Open Link in Split View: a new Today tab with `url` beside `tabID` in a split (or added to
    /// the split it is in), focused. inferred: [06 §22.3] observed the same layout from Peek.
    @discardableResult
    func openLinkInSplitView(_ url: URL, beside tabID: UUID) -> UUID? {
        guard let source = workspace.tabs[tabID], !source.meta.isTombstone,
              let spaceID = source.location.spaceID ?? sidebar.selectedSpaceID else { return nil }
        let id = controller.makeID(), layoutID = controller.makeID()
        let stamp = controller.now()
        do {
            try controller.mutate(origin: nil) { state in
                var s = try TreeOps.openTab(state, id: id, spaceID: spaceID, url: url, title: url.host ?? url.absoluteString, now: stamp)
                if case .today = source.location {
                    s = try TreeOps.moveTab(s, id: id, to: .today(spaceID: spaceID), position: .after(tabID), now: stamp)
                }
                return try TreeOps.addSplitPane(s, layoutID: layoutID, existingTabID: tabID, newTabID: id, now: stamp)
            }
        } catch {
            return nil
        }
        sidebar.selectTab(id)
        return id
    }

    /// Page commands act on the selected tab; a right-click in another split pane selects it first.
    private func focusPaneIfNeeded(_ tabID: UUID) {
        if selectedTabID != tabID { focusPane(tabID) }
    }
}
