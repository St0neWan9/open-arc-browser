import AppKit

// Menu-bar fix-ups that SwiftUI's `Commands` cannot express (plans B62, B72, [01] all sections,
// E20 capture). SwiftUI builds the menus; this pass runs after every change AppKit reports
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
// - Edit ▸ Find and the system text submenus (plan Q15). `TextEditingCommands` brings back Spelling
//   and Grammar / Substitutions / Transformations / Speech ([01 §Edit] observed) together with a
//   system Find submenu whose items use AppKit's find panel, which never reaches the page. That
//   Find is hidden and its keys are cleared (a hidden item keeps its key equivalent, and its ⌘E
//   "Use Selection for Find" would take Open Extensions' key); ours moves into its place, so it
//   sits right before Spelling and Grammar and gets the standard Find icon AppKit gives the item
//   in that slot.
// - Edit ▸ Format. `TextFormattingCommands` adds Format as a top-level menu; [01 §Edit] observed it
//   inside Edit after Speech, with no top-level Format menu. The top-level one is hidden (its keys
//   cleared) and a copy of its items is added to Edit after Speech (`moveFormatIntoEdit`).
// - Moving items and clearing keys never run inside a menu notification: AppKit can post one while
//   it holds its key-equivalent lock, and changing items there deadlocks (`install`).
// - "Hide Others" → "Hide Other Windows" and "Minimize" → "Minimize Window" ([01 §Arc], [01 §Window],
//   [02 §窗口与应用] observed titles). These are system items, so their titles are set here.
// - Edit items SwiftUI can only append after Select All move after the system item they follow in
//   Arc (`MenuBarCatalog.itemsAfter`): Copy URL / Copy URL as Markdown / Copy URL as Quote after
//   Copy, Paste and Match Style after Paste ([01 §Edit] observed order). SwiftUI keeps updating a
//   moved item in place.
// - Standard icons. Zoom In / Zoom Out / Save Page As / Paste and Match Style stand for AppKit
//   commands, which macOS shows with its standard icons; SwiftUI buttons carry no action, so the
//   pass gives them the image macOS uses for that action (`MenuBarCatalog.standardIconActions`).
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

    /// A structural pass is scheduled for the next run-loop turn.
    private var isStructuralPassScheduled = false

    /// Starts listening. Call before the menu bar is built (`applicationWillFinishLaunching`).
    ///
    /// AppKit posts some of these notifications while its key-equivalent bookkeeping holds a lock
    /// (SwiftUI rebuilding a menu as it opens). Adding, removing or re-keying items from inside
    /// such a callback deadlocks the app (B72: seen while the accessibility tree read the menus),
    /// so the callback only hides, retitles and sets images; moving items and clearing keys runs
    /// on the next run-loop turn, in the common modes, so it also runs while a menu is open.
    public func install(center: NotificationCenter = .default) {
        guard tokens.isEmpty else { return }
        let names = [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification, NSMenu.didRemoveItemNotification]
        for name in names {
            // AppKit posts menu notifications on the main thread.
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuDidChange() }
            })
        }
        adjustMainMenu()
    }

    /// One full pass over the main menu. Re-entrant notifications from its own changes are ignored.
    /// Never call it from inside a menu notification (see `install`).
    public func adjustMainMenu() {
        guard !isAdjusting, let main = NSApp.mainMenu else { return }
        isAdjusting = true
        defer { isAdjusting = false }
        adjust(main)
    }

    private func menuDidChange() {
        guard !isAdjusting, let main = NSApp.mainMenu else { return }
        isAdjusting = true
        adjustInPlace(main)
        isAdjusting = false
        scheduleStructuralPass()
    }

    private func scheduleStructuralPass() {
        guard !isStructuralPassScheduled else { return }
        isStructuralPassScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.isStructuralPassScheduled = false
                self?.adjustMainMenu()
            }
        }
    }

    /// The full pass on any menu bar (tests pass their own): moves, then the in-place fix-ups.
    func adjust(_ main: NSMenu) {
        moveFormatIntoEdit(main)
        for top in main.items {
            guard let menu = top.submenu, top.title != MenuBarCatalog.keyOnlyMenuTitle else { continue }
            moveItemsAfterSystemItems(in: menu)
            moveOurFindIntoPlace(in: menu)
        }
        adjustInPlace(main)
    }

    /// The fix-ups that neither add, remove nor re-key items: safe inside a menu notification.
    private func adjustInPlace(_ main: NSMenu) {
        for top in main.items {
            if top.title == MenuBarCatalog.keyOnlyMenuTitle {
                setHidden(top, true)
                if !top.allowsKeyEquivalentWhenHidden { top.allowsKeyEquivalentWhenHidden = true }
                continue
            }
            if top.title == "Format", top.identifier?.rawValue != MenuBarCatalog.formatMirrorIdentifier, top.submenu != nil {
                setHidden(top, true)
            }
            guard let menu = top.submenu else { continue }
            retitleSystemItems(in: menu)
            applyStandardIcons(in: menu, titled: top.title)
            hideSystemFindMenu(in: menu)
            tidySeparators(in: menu)
        }
    }

    private func retitleSystemItems(in menu: NSMenu) {
        for item in menu.items {
            guard let action = item.action, let title = MenuBarCatalog.systemTitles[NSStringFromSelector(action)] else { continue }
            if item.title != title { item.title = title }
        }
    }

    private func moveItemsAfterSystemItems(in menu: NSMenu) {
        for (action, titles) in MenuBarCatalog.itemsAfter {
            let selector = NSSelectorFromString(action)
            guard let anchor = menu.items.firstIndex(where: { $0.action == selector }) else { continue }
            var target = anchor + 1
            for title in titles {
                guard let index = menu.items.firstIndex(where: { $0.title == title && !$0.isSeparatorItem }) else { continue }
                if index != target {
                    let item = menu.items[index]
                    menu.removeItem(at: index)
                    menu.insertItem(item, at: index < target ? target - 1 : target)
                }
                target = (menu.items.firstIndex { $0.title == title } ?? target) + 1
            }
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

    /// The system Find submenu (its items use AppKit's find-panel actions) and ours.
    private func findMenus(in menu: NSMenu) -> (system: NSMenuItem, ours: NSMenuItem?)? {
        let systemFind = NSSelectorFromString("performFindPanelAction:")
        let finds = menu.items.filter { $0.title == MenuBarCatalog.findMenuTitle && $0.submenu != nil }
        guard let system = finds.first(where: { $0.submenu?.items.contains { $0.action == systemFind } == true }) else { return nil }
        return (system, finds.first { $0 !== system })
    }

    /// Hides the system Find submenu; ours stays.
    private func hideSystemFindMenu(in menu: NSMenu) {
        if let system = findMenus(in: menu)?.system { setHidden(system, true) }
    }

    /// Puts ours right before the system Find (where AppKit draws the standard Find icon), then
    /// clears the hidden system Find's keys. In that order: AppKit lets only one item own a key,
    /// and re-inserting ours hands the shared keys (⌘F, ⌘G, ⌘J) back to the system items until
    /// theirs are cleared; a hidden item's key would still fire.
    private func moveOurFindIntoPlace(in menu: NSMenu) {
        guard let (system, ours) = findMenus(in: menu) else { return }
        if let ours, menu.index(of: ours) != menu.index(of: system) - 1 {
            menu.removeItem(ours)
            menu.insertItem(ours, at: menu.index(of: system))
        }
        for item in system.submenu?.items ?? [] where !item.keyEquivalent.isEmpty { item.keyEquivalent = "" }
    }

    /// Shows the top-level Format menu as Edit ▸ Format, after Speech. SwiftUI owns the top-level
    /// item's submenu and rebuilds the Edit menu as it opens (dropping items it did not make), so
    /// Edit gets a copy of the Format items, made again whenever it is missing. The items are
    /// standard AppKit text commands (nil target, the action and tag say what they do), so a copy
    /// works the same; the hidden original keeps their keys working.
    private func moveFormatIntoEdit(_ main: NSMenu) {
        let formatTitle = "Format"
        let id = NSUserInterfaceItemIdentifier(MenuBarCatalog.formatMirrorIdentifier)
        guard let edit = main.items.first(where: { $0.title == "Edit" })?.submenu,
              let source = main.items.first(where: { $0.title == formatTitle && $0.identifier != id })?.submenu else { return }
        // The hidden original's keys still fire and come before View's: ⌘+ / ⌘- (Larger / Smaller)
        // would take Zoom In / Out and ⌥⌘C (Copy Style) Inspect Elements ([02] observed keys).
        // Format's items keep no keys; a page's own ⌘B / ⌘I / ⌘U still reach it.
        Self.clearKeys(source)
        if let mirror = edit.items.first(where: { $0.identifier == id }) {
            guard edit.index(of: mirror) != formatIndex(in: edit, excluding: mirror) else { return }
            edit.removeItem(mirror)
            edit.insertItem(mirror, at: formatIndex(in: edit))
            return
        }
        let item = NSMenuItem(title: formatTitle, action: nil, keyEquivalent: "")
        item.identifier = id
        item.submenu = Self.copyMenu(source)
        edit.insertItem(item, at: formatIndex(in: edit))
    }

    /// Removes every key equivalent in `menu` and its submenus (only where one is set).
    static func clearKeys(_ menu: NSMenu) {
        for item in menu.items {
            if !item.keyEquivalent.isEmpty { item.keyEquivalent = "" }
            if let submenu = item.submenu { clearKeys(submenu) }
        }
    }

    /// A copy of a menu of standard AppKit commands: titles, actions, tags, keys, states, images.
    static func copyMenu(_ source: NSMenu) -> NSMenu {
        let menu = NSMenu(title: source.title)
        for item in source.items {
            if item.isSeparatorItem {
                menu.addItem(.separator())
                continue
            }
            let copy = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.keyEquivalent)
            copy.keyEquivalentModifierMask = item.keyEquivalentModifierMask
            copy.tag = item.tag
            copy.target = item.target
            copy.image = item.image
            copy.state = item.state
            copy.isHidden = item.isHidden
            copy.isEnabled = item.isEnabled
            copy.representedObject = item.representedObject
            if let submenu = item.submenu { copy.submenu = copyMenu(submenu) }
            menu.addItem(copy)
        }
        return menu
    }

    /// Where Edit ▸ Format goes: right after the last of the system text submenus (Speech), else
    /// at the end. With `excluding` (the Format item itself) it is the index that item has when it
    /// already sits in place.
    private func formatIndex(in edit: NSMenu, excluding: NSMenuItem? = nil) -> Int {
        let names = Set(MenuBarCatalog.systemEditSubmenus.dropLast())
        let last = edit.items.lastIndex { $0 !== excluding && names.contains($0.title) && $0.submenu != nil }
        return last.map { $0 + 1 } ?? edit.numberOfItems
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
