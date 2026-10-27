import AppKit

// Menu-bar fix-ups that SwiftUI's `Commands` cannot express (plan B62, [01] all sections, E20
// capture). SwiftUI builds the menus; this pass runs after every change AppKit reports
// (`NSMenu.didAdd/didChange/didRemoveItemNotification`) and only touches what it owns:
//
// - Separators. macOS indents a whole separator-delimited group once one visible item in it has an
//   icon ([01 §菜单项图标与缩进] observed). SwiftUI leaves a separator for every empty system group
//   (File's save / import-export groups, the Arc menu's settings group), so a menu can show two
//   separators in a row or one at the end. Runs of separators collapse to one, and a separator at
//   the top or bottom of a menu is hidden, so each menu's groups are exactly the observed ones.
// - Key-only menu. Tabs ▸ Archive Tab (⌘W), Go to Sidebar Item 1–9 (⌘1…⌘9) and Open Extensions
//   (⌘E) are in [02] but in no [01] menu. They live in a hidden top-level menu
//   (`MenuBarCatalog.keyOnlyMenuTitle`) whose key equivalents still work.
// - System Find. The system Find submenu (from `TextEditingCommands`) duplicates ours and is
//   hidden.
// - "Hide Others" → "Hide Other Windows" and "Minimize" → "Minimize Window" ([01 §Arc], [01 §Window],
//   [02 §窗口与应用] observed titles). These are system items, so their titles are set here.
//
// - Copy URL / Copy URL as Markdown move right after Copy ([01 §Edit] observed order;
//   `MenuBarCatalog.afterCopyItems`). SwiftUI keeps updating a moved item in place.
// - Standard icons. Zoom In / Zoom Out / Save Page As stand for AppKit's zoomIn: / zoomOut: /
//   saveDocument: commands, which macOS shows with its standard icons; SwiftUI buttons carry no
//   action, so the pass gives them the image macOS uses for that action
//   (`MenuBarCatalog.standardIconActions`).
//
// The pass draws no icon of its own ([01 §菜单项图标与缩进]: keep the system's standard icons, add
// none of ours).

/// Runs the fix-ups on the main menu. One per app; installed by the app delegate, which lives as
/// long as the app, so its observers are never removed.
@MainActor
public final class MenuBarAdjuster {
    private var tokens: [NSObjectProtocol] = []
    private var isAdjusting = false
    /// Separators this pass hid, so it can show them again when their group fills.
    private let hiddenSeparators = NSHashTable<NSMenuItem>.weakObjects()

    public init() {}

    /// Starts listening. Call before the menu bar is built (`applicationWillFinishLaunching`).
    public func install(center: NotificationCenter = .default) {
        guard tokens.isEmpty else { return }
        let names = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification]
        for name in names {
            // AppKit posts menu notifications on the main thread.
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.adjustMainMenu() }
            })
        }
        adjustMainMenu()
    }

    /// One pass over the main menu. Re-entrant notifications from its own changes are ignored.
    public func adjustMainMenu() {
        guard !isAdjusting, let main = NSApp.mainMenu else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        adjust(main)
    }

    /// The pass on any menu bar (tests pass their own).
    func adjust(_ main: NSMenu) {
        for top in main.items {
            if top.title == MenuBarCatalog.keyOnlyMenuTitle {
                setHidden(top, true)
                if !top.allowsKeyEquivalentWhenHidden { top.allowsKeyEquivalentWhenHidden = true }
                continue
            }
            guard let menu = top.submenu else { continue }
            retitleSystemItems(in: menu)
            moveItemsAfterCopy(in: menu)
            applyStandardIcons(in: menu, titled: top.title)
            hideDuplicateFindMenus(in: menu)
            tidySeparators(in: menu)
        }
    }

    private func retitleSystemItems(in menu: NSMenu) {
        for item in menu.items {
            guard let action = item.action, let title = MenuBarCatalog.systemTitles[NSStringFromSelector(action)] else { continue }
            if item.title != title { item.title = title }
        }
    }

    private func moveItemsAfterCopy(in menu: NSMenu) {
        guard let copy = menu.items.firstIndex(where: { $0.action == #selector(NSText.copy(_:)) }) else { return }
        var target = copy + 1
        for title in MenuBarCatalog.afterCopyItems {
            guard let index = menu.items.firstIndex(where: { $0.title == title && !$0.isSeparatorItem }) else { continue }
            if index != target {
                let item = menu.items[index]
                menu.removeItem(at: index)
                menu.insertItem(item, at: index < target ? target - 1 : target)
            }
            target = (menu.items.firstIndex { $0.title == title } ?? target) + 1
        }
    }

    private func applyStandardIcons(in menu: NSMenu, titled title: String) {
        guard let actions = MenuBarCatalog.standardIconActions[title] else { return }
        for item in menu.items where item.image == nil {
            guard let action = actions[item.title], let image = Self.standardImage(for: action) else { continue }
            item.image = image
        }
    }

    /// The image macOS gives a menu item with this action (nil when it gives none).
    static func standardImage(for action: String) -> NSImage? {
        NSMenuItem(title: "", action: NSSelectorFromString(action), keyEquivalent: "").image
    }

    /// Hides the system Find submenu (its items use AppKit's find-panel actions); ours stays.
    private func hideDuplicateFindMenus(in menu: NSMenu) {
        let systemFind = NSSelectorFromString("performFindPanelAction:")
        for item in menu.items where item.title == MenuBarCatalog.findMenuTitle {
            guard let submenu = item.submenu, submenu.items.contains(where: { $0.action == systemFind }) else { continue }
            setHidden(item, true)
        }
    }

    /// One visible separator between groups, none at the top or bottom.
    private func tidySeparators(in menu: NSMenu) {
        var atGroupStart = true
        var pending: NSMenuItem?
        for item in menu.items {
            if item.isSeparatorItem {
                // A separator someone else hid stays hidden.
                if item.isHidden, !hiddenSeparators.contains(item) { continue }
                if atGroupStart {
                    hideSeparator(item)
                } else {
                    showSeparator(item)
                    pending = item
                    atGroupStart = true
                }
            } else if !item.isHidden {
                atGroupStart = false
                pending = nil
            }
        }
        if let pending { hideSeparator(pending) }
    }

    private func hideSeparator(_ item: NSMenuItem) {
        hiddenSeparators.add(item)
        setHidden(item, true)
    }

    private func showSeparator(_ item: NSMenuItem) {
        guard hiddenSeparators.contains(item) else { return }
        hiddenSeparators.remove(item)
        setHidden(item, false)
    }

    /// Sets `isHidden` only on a change, so the pass posts no notification when nothing changes.
    private func setHidden(_ item: NSMenuItem, _ hidden: Bool) {
        if item.isHidden != hidden { item.isHidden = hidden }
    }
}
