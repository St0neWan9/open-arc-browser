import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// The menu bar's items, order and groups (plans B62, B72). Acceptance: `docs/arc-spec/01-menus.md`, all
/// sections, and 01 §菜单项图标与缩进 (E20, observed): macOS indents a whole separator-delimited group
/// once one of its items has an icon, so each menu must split its groups exactly where Arc does, and
/// our items carry no icons of their own.
@MainActor
final class MenuBarTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private var models: [ShellModel] = []

    override func tearDown() async throws {
        for model in models { model.stop() }
        models = []
    }

    private func makeModel() -> ShellModel {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
        models.append(model)
        return model
    }

    /// The AppKit items SwiftUI makes for `content`.
    private func items<Content: View>(_ content: Content) throws -> [NSMenuItem] {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu.items
    }

    /// Visible titles split into groups at separators.
    private func groups(_ items: [NSMenuItem]) -> [[String]] {
        var result: [[String]] = [[]]
        for item in items where !item.isHidden {
            if item.isSeparatorItem { result.append([]) } else { result[result.count - 1].append(item.title) }
        }
        return result.filter { !$0.isEmpty }
    }

    private func assertNoOwnIcons(_ items: [NSMenuItem], file: StaticString = #filePath, line: UInt = #line) {
        for item in items where !item.isSeparatorItem {
            XCTAssertNil(item.image, "\(item.title) must carry no icon of ours (01 §菜单项图标与缩进)", file: file, line: line)
            if let submenu = item.submenu { assertNoOwnIcons(submenu.items, file: file, line: line) }
        }
    }

    // MARK: Groups per menu (01 §菜单项图标与缩进, observed)

    /// 01 §菜单项图标与缩进 View: Appearance, Hide Sidebar and Show Toolbar are not in a group with
    /// Enter Full Screen or the zoom items, so they are never indented; the zoom items are a group
    /// of their own; our list ends with a separator so the system Enter Full Screen stands alone.
    func testViewMenuGroups() throws {
        let model = makeModel()
        let built = try items(ViewMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(groups(built), MenuBarCatalog.viewGroups)
        XCTAssertTrue(built.last?.isSeparatorItem == true, "Enter Full Screen follows in its own group")
        assertNoOwnIcons(built)
        let appearance = built.first { $0.title == "Appearance" }
        XCTAssertEqual(appearance?.submenu?.items.map(\.title), ["Websites, Easels, and Notes will use:", "Automatic", "Light", "Dark"],
                       "01 §View observed")
    }

    /// 01 §菜单项图标与缩进 File: New Tab… … Restore Last Closed Tab ‖ Open Command Bar ‖ New
    /// Profile · New Easel ‖ Close Window ‖ Share… · Capture… … Print.
    func testFileMenuGroups() throws {
        let model = makeModel()
        let built = try items(FileMenuItems(model: model, hasWindow: true, openWindow: EnvironmentValues().openWindow))
            + [NSMenuItem.separator()]
            + items(FilePageMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(groups(built), MenuBarCatalog.fileGroups)
        assertNoOwnIcons(built)
        XCTAssertEqual(built.first { $0.title == "Close Window" }?.keyEquivalent, "w", "⇧⌘W [02]")
    }

    /// 01 §Edit: Copy URL (⇧⌘C), Copy URL as Markdown (⌥⇧⌘C), Copy URL as Quote (⌃⇧⌘C)
    /// [02 §复制链接]; Paste and Match Style (⌥⇧⌘V, the macOS key).
    func testEditCopyURLItems() throws {
        let model = makeModel()
        let built = try items(EditCopyURLMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(built.map(\.title), ["Copy URL", "Copy URL as Markdown", "Copy URL as Quote", "Paste and Match Style"])
        XCTAssertEqual(built.map(\.keyEquivalent), ["c", "c", "c", "v"])
        XCTAssertEqual(built.map(\.keyEquivalentModifierMask),
                       [[.shift, .command], [.option, .shift, .command], [.control, .shift, .command], [.option, .shift, .command]])
        assertNoOwnIcons(built)
    }

    /// 01 §Edit: Find ▸ Find… / Find Next / Find Previous / Use Selection to Find / Jump to
    /// Selection; keys 02 §页面与导航: ⌘F / ⌘G / ⇧⌘G / — / ⌘J. Find and Replace is not shown
    /// (B122: no replace step, decision pending); its ⌥⌘F stays in the key-only menu and opens
    /// the find bar.
    func testFindMenu() throws {
        let model = makeModel()
        let built = try items(FindMenu(model: model, findBar: model.findBar, hasWindow: true))
        XCTAssertEqual(built.map(\.title), [MenuBarCatalog.findMenuTitle])
        let find = try XCTUnwrap(built.first?.submenu?.items)
        XCTAssertEqual(find.map(\.title), MenuBarCatalog.findItems)
        XCTAssertFalse(find.contains { $0.title == "Find and Replace" })
        XCTAssertEqual(find.map(\.keyEquivalent), ["f", "g", "g", "", "j"])
        let keyOnly = try items(KeyOnlyMenuItems(model: model, hasWindow: true))
        let replace = try XCTUnwrap(keyOnly.first { $0.title == "Find and Replace" })
        XCTAssertEqual(replace.keyEquivalent, "f")
        XCTAssertEqual(replace.keyEquivalentModifierMask, [.option, .command])
        XCTAssertNotNil(MenuBarCatalog.omittedItems["Find and Replace"])
    }

    /// 01 §Spaces / §菜单项图标与缩进: New Space… · Edit Theme… · Rename Space · Change Profile ‖
    /// Next · Previous ‖ the Space list (current one checked) ‖ Manage Spaces…. A Space without an
    /// icon shows none.
    func testSpacesMenuGroups() throws {
        let model = makeModel()
        let built = try items(SpacesMenuItems(model: model, hasWindow: true))
        let spaceNames = model.sidebar.dockSpaces.map(\.name)
        var expected = MenuBarCatalog.spacesGroups
        expected.insert(spaceNames, at: 2)
        XCTAssertEqual(groups(built), expected)
        let current = built.first { $0.title == model.selectedSpace?.name }
        XCTAssertEqual(current?.state, .on, "the current Space is checked")
        assertNoOwnIcons(built)
    }

    /// 01 §菜单项图标与缩进 Spaces: each Space row shows the Space's own icon (emoji or symbol),
    /// none without one; ⌃1…⌃9 [02 §Space] for the first nine, none after.
    func testSpaceRowsShowTheSpaceIcon() throws {
        let model = makeModel()
        let home = try XCTUnwrap(model.selectedSpaceID)
        let profile = try XCTUnwrap(model.selectedSpace?.profileID)
        var ws = try TreeOps.setSpaceIcon(model.workspace, id: home, icon: "🚀", now: t0)
        var previous = home
        for n in 1...9 {
            let id = UUID()
            ws = try TreeOps.createSpace(ws, id: id, profileID: profile, name: "S\(n)", icon: n == 1 ? "briefcase" : nil, afterSpaceID: previous, now: t0)
            previous = id
        }
        model.sidebar.replaceWorkspace(ws)
        let built = try items(SpacesMenuItems(model: model, hasWindow: true))
        // The Space list: between Previous Space's group and Manage Spaces….
        let visibleItems = built.filter { !$0.isHidden }
        let start = try XCTUnwrap(visibleItems.firstIndex { $0.title == "Previous Space" }) + 2
        let end = try XCTUnwrap(visibleItems.firstIndex { $0.title == "Manage Spaces…" }) - 1
        let rows = Array(visibleItems[start..<end])
        XCTAssertEqual(rows.map(\.title), ["Home"] + (1...9).map { "S\($0)" })
        XCTAssertNotNil(rows[0].image, "emoji icon")
        XCTAssertNotNil(rows[1].image, "symbol icon")
        XCTAssertNil(rows[2].image, "a Space without an icon shows none")
        XCTAssertEqual(rows[8].keyEquivalent, "9")
        XCTAssertEqual(rows[9].keyEquivalent, "", "the tenth Space has no key")
        XCTAssertNil(SpaceMenuIcon.image(for: nil))
        XCTAssertNil(SpaceMenuIcon.image(for: ""))
    }

    /// 01 §Tabs, E20 tabs-crop.png: New Tab… · Pin Tab · New Folder… ‖ Next · Previous · Reveal Tab
    /// in Sidebar · (untitled disabled submenu, 01 E27) ‖ Clear Today · Reset all tabs in this
    /// Space. Archive Tab and Go to Sidebar Item are in no [01] menu.
    func testTabsMenuGroups() throws {
        let model = makeModel()
        let built = try items(TabsMenuItems(model: model, hasWindow: true))
        var expected = MenuBarCatalog.tabsGroups
        expected[0][1] = "Pin Tab"
        XCTAssertEqual(groups(built), expected)
        assertNoOwnIcons(built)
        let reveal = try XCTUnwrap(built.first { $0.title == "Reveal Tab in Sidebar" })
        XCTAssertEqual(reveal.keyEquivalent, " ", "⌃Space [02 §标签与侧边栏]")
        XCTAssertEqual(reveal.keyEquivalentModifierMask, .control)
    }

    /// 01 §Tabs, E27 observed: between Reveal Tab in Sidebar and Clear Today an untitled submenu,
    /// itself disabled, with three disabled items "Item 1", "Item 2", "Item 3" (plan Q19: shown
    /// disabled).
    func testTabsPlaceholderSubmenu() throws {
        let model = makeModel()
        let built = try items(TabsMenuItems(model: model, hasWindow: true)).filter { !$0.isHidden }
        let reveal = try XCTUnwrap(built.firstIndex { $0.title == "Reveal Tab in Sidebar" })
        let placeholder = built[reveal + 1]
        XCTAssertEqual(placeholder.title, "")
        XCTAssertFalse(placeholder.isSeparatorItem)
        // The item itself is `.disabled(true)`; NSHostingMenu reports a submenu item as enabled
        // whatever SwiftUI says, so only its items' state is checked here.
        let submenu = try XCTUnwrap(placeholder.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Item 1", "Item 2", "Item 3"])
        XCTAssertTrue(submenu.items.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(built[reveal + 2].isSeparatorItem)
        XCTAssertEqual(built[reveal + 3].title, "Clear Today")
    }

    /// 06 §16.2 observed: the pin item reads "Unpin Tab" for a pinned tab.
    func testPinTitleFollowsTheTab() async throws {
        let model = makeModel()
        XCTAssertEqual(model.pinMenuTitle, "Pin Tab")
        let space = try XCTUnwrap(model.selectedSpaceID)
        let id = try XCTUnwrap(model.workspace.today(spaceID: space).first?.id)
        try await model.activate(tabID: id)
        model.sidebar.togglePin(id)
        XCTAssertEqual(model.pinMenuTitle, "Unpin Tab")
    }

    /// 01 §Archive (B69), E20 archive-crop.png: Go Back · Go Forward ‖ View History · View Archive… ·
    /// Clear Archive, no icons; ⌘[ / ⌘] [02 §页面与导航]. Clear Archive is disabled with an empty archive.
    func testArchiveMenuGroups() throws {
        let model = makeModel()
        let built = try items(ArchiveMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(groups(built), MenuBarCatalog.archiveGroups)
        assertNoOwnIcons(built)
        XCTAssertEqual(built.first { $0.title == "Go Back" }?.keyEquivalent, "[")
        XCTAssertEqual(built.first { $0.title == "Go Forward" }?.keyEquivalent, "]")
        let clear = try XCTUnwrap(built.first { $0.title == "Clear Archive" })
        XCTAssertEqual(clear.isEnabled, model.sidebar.canClearArchive)
    }

    /// [02] keys in no [01] menu: they live in the hidden key-only menu.
    func testKeyOnlyItems() throws {
        let model = makeModel()
        let built = try items(KeyOnlyMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(built.map(\.title), ["Archive Tab"] + (1...8).map { "Go to Sidebar Item \($0)" }
            + ["Go to Last Sidebar Item", "Open Extensions", "Find and Replace", "Next Tab", "Previous Tab", "Go Back", "Go Forward", "Developer Tools"])
        XCTAssertEqual(built.map(\.title), MenuBarCatalog.keyOnlyItems)
        XCTAssertEqual(built.first?.keyEquivalent, "w", "⌘W archives [02]")
    }

    /// 01 §Archive / §Extensions / §Window / §菜单项图标与缩进.
    func testArchiveExtensionsAndWindowGroups() {
        XCTAssertEqual(MenuBarCatalog.archiveGroups, [["Go Back", "Go Forward"], ["View History", "View Archive…", "Clear Archive"]])
        XCTAssertEqual(MenuBarCatalog.extensionsGroups, [["Add Extension…", "Manage Extensions…"]])
        XCTAssertEqual(MenuBarCatalog.windowGroups, [["Open Library…", "View Downloads…", "View Easels…", "View Media…", "View Boosts…"]])
    }

    // MARK: The AppKit pass (01 §菜单项图标与缩进)

    private func menuBar(_ menus: [(String, [String?])]) -> NSMenu {
        let bar = NSMenu(title: "Main")
        for (title, entries) in menus {
            let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for entry in entries {
                menu.addItem(entry.map { NSMenuItem(title: $0, action: nil, keyEquivalent: "") } ?? .separator())
            }
            top.submenu = menu
            bar.addItem(top)
        }
        return bar
    }

    private func visible(_ menu: NSMenu?) -> [String] {
        (menu?.items ?? []).filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// Runs of separators collapse and edge separators hide, so the visible groups are exactly the
    /// built ones; an emptied group's separator comes back when the group fills again.
    func testSeparatorsCollapse() {
        let bar = menuBar([("File", [nil, "New Window", nil, nil, nil, "Close Window", nil, "Print", nil])])
        let adjuster = MenuBarAdjuster()
        adjuster.adjust(bar)
        let file = bar.items[0].submenu
        XCTAssertEqual(visible(file), ["New Window", "—", "Close Window", "—", "Print"])

        file?.items.first { $0.title == "Close Window" }?.isHidden = true
        adjuster.adjust(bar)
        XCTAssertEqual(visible(file), ["New Window", "—", "Print"])
        file?.items.first { $0.title == "Close Window" }?.isHidden = false
        adjuster.adjust(bar)
        XCTAssertEqual(visible(file), ["New Window", "—", "Close Window", "—", "Print"])
    }

    /// The key-only menu is hidden but keeps its keys; a second Find submenu is hidden; the system
    /// Hide Others / Minimize get the [01]/[02] titles.
    func testKeyOnlyMenuFindAndSystemTitles() {
        let bar = menuBar([
            ("Edit", ["Copy", nil, "Find", "Find"]),
            (MenuBarCatalog.keyOnlyMenuTitle, ["Archive Tab"]),
        ])
        let edit = bar.items[0].submenu!
        let finds = edit.items.filter { $0.title == "Find" }
        let systemFind = NSMenu(title: "Find")
        systemFind.addItem(NSMenuItem(title: "Find…", action: NSSelectorFromString("performFindPanelAction:"), keyEquivalent: "f"))
        finds[0].submenu = systemFind
        finds[1].submenu = NSMenu(title: "Find")
        let app = NSMenu(title: "App")
        app.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let appItem = NSMenuItem(title: "App", action: nil, keyEquivalent: "")
        appItem.submenu = app
        bar.insertItem(appItem, at: 0)

        MenuBarAdjuster().adjust(bar)
        let keyOnly = bar.items.first { $0.title == MenuBarCatalog.keyOnlyMenuTitle }
        XCTAssertEqual(keyOnly?.isHidden, true)
        XCTAssertEqual(keyOnly?.allowsKeyEquivalentWhenHidden, true)
        XCTAssertEqual(visible(edit), ["Copy", "—", "Find"])
        XCTAssertEqual(finds[0].isHidden, true, "the system Find is hidden, ours stays")
        XCTAssertEqual(systemFind.items.map(\.keyEquivalent), [""], "a hidden item's keys would still fire")
        XCTAssertEqual(app.items.map(\.title), ["Hide Other Windows", "Minimize Window"], "01 §Arc, 01 §Window, 02 observed")
    }

    /// 01 §Edit observed order: Copy · Copy URL · Copy URL as Markdown · Copy URL as Quote · Paste ·
    /// Paste and Match Style.
    func testCopyURLItemsFollowCopy() {
        let bar = NSMenu(title: "Main")
        let edit = NSMenu(title: "Edit")
        for (title, action) in [("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))), ("Paste", #selector(NSText.paste(_:))),
                                ("Select All", #selector(NSText.selectAll(_:))), ("Copy URL", nil), ("Copy URL as Markdown", nil),
                                ("Copy URL as Quote", nil), ("Paste and Match Style", nil)] as [(String, Selector?)] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = edit
        bar.addItem(top)
        let adjuster = MenuBarAdjuster()
        adjuster.adjust(bar)
        adjuster.adjust(bar)
        XCTAssertEqual(edit.items.map(\.title), ["Cut", "Copy", "Copy URL", "Copy URL as Markdown", "Copy URL as Quote", "Paste",
                                                 "Paste and Match Style", "Select All"])
        XCTAssertNotNil(edit.items.first { $0.title == "Paste and Match Style" }?.image, "the system clipboard icon, as in Arc")
    }

    /// Plan Q15, 01 §Edit observed: Find ▸ · Spelling and Grammar ▸ · Substitutions ▸ ·
    /// Transformations ▸ · Speech ▸ · Format ▸. Ours takes the system Find's place; the top-level
    /// Format menu (from `TextFormattingCommands`) shows inside Edit after Speech as a copy of its
    /// commands without keys; a second pass changes nothing.
    func testSystemEditSubmenusAroundOurFind() {
        let systemFindAction = NSSelectorFromString("performFindPanelAction:")
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            return item
        }
        let bar = NSMenu(title: "Main")
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(submenu("Find", [NSMenuItem(title: "Find…", action: nil, keyEquivalent: "f")]))
        edit.addItem(.separator())
        edit.addItem(submenu("Find", [NSMenuItem(title: "Find…", action: systemFindAction, keyEquivalent: "f"),
                                      NSMenuItem(title: "Use Selection for Find", action: systemFindAction, keyEquivalent: "e")]))
        for title in ["Spelling and Grammar", "Substitutions", "Transformations", "Speech"] { edit.addItem(submenu(title, [])) }
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Emoji & Symbols", action: nil, keyEquivalent: ""))
        let editTop = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editTop.submenu = edit
        bar.addItem(editTop)
        let larger = NSMenuItem(title: "Larger", action: NSSelectorFromString("modifyFont:"), keyEquivalent: "+")
        larger.tag = 3
        let format = submenu("Format", [submenu("Font", [larger])])
        bar.addItem(format)
        bar.addItem(NSMenuItem(title: "View", action: nil, keyEquivalent: ""))

        let adjuster = MenuBarAdjuster()
        adjuster.adjust(bar)
        let expected = ["Copy", "—", "Find"] + MenuBarCatalog.systemEditSubmenus + ["—", "Emoji & Symbols"]
        XCTAssertEqual(visible(edit), expected)
        // A copy of the Format items (SwiftUI owns the original): same commands, no keys, so the
        // hidden original cannot take View's ⌘+ (Zoom In, [02]).
        let copied = edit.items.first { $0.title == "Format" }?.submenu?.items.first?.submenu?.items.first
        XCTAssertEqual(copied?.action, larger.action)
        XCTAssertEqual(copied?.tag, 3)
        XCTAssertEqual(copied?.keyEquivalent, "")
        XCTAssertEqual(larger.keyEquivalent, "", "the hidden original's keys are cleared")
        XCTAssertEqual(format.isHidden, true, "no top-level Format menu (01: Format is in Edit)")
        let ourFind = edit.items.first { $0.title == "Find" && !$0.isHidden }
        XCTAssertEqual(ourFind?.submenu?.items.first?.action, nil, "the visible Find is ours")
        adjuster.adjust(bar)
        XCTAssertEqual(visible(edit), expected)
        XCTAssertEqual(edit.items.filter { $0.title == "Format" }.count, 1)
    }

    /// 01 §Help / §Arc / §Window / §View: the items B72 adds and the documented omissions.
    func testCatalogCoversEvery01Item() {
        XCTAssertEqual(MenuBarCatalog.appGroups[0], ["Settings…", "Share Open Arc", "Set as Default Browser"])
        XCTAssertEqual(MenuBarCatalog.appServicesGroupItems, ["Privacy Policy"])
        XCTAssertEqual(MenuBarCatalog.windowSystemGroupItems, ["Stay On Top"])
        XCTAssertEqual(MenuBarCatalog.helpGroups.flatMap { $0 }, ["Getting Started", "Essential Keyboard Shortcuts", "Contact the Team",
                                                                 "Visit Help Center", "Restore Data", "Troubleshooting"])
        XCTAssertEqual(MenuBarCatalog.troubleshootingItems, ["Reveal Open Arc Data", "Copy Open Arc Info"])
        XCTAssertEqual(Set(MenuBarCatalog.omittedItems.keys),
                       ["Sign Out", "Export Arc Notes", "Record Trace", "Open Task Manager", "Find and Replace"])
    }

    /// 01 §Help: Getting Started … Troubleshooting ▸ (Reveal Open Arc Data · Copy Open Arc Info);
    /// no icons ([01 §菜单项图标与缩进] observed).
    func testHelpMenuItems() throws {
        let model = makeModel()
        let built = try items(HelpMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(groups(built), MenuBarCatalog.helpGroups)
        // B122: Arc's Help has no Show Welcome Again ([01 §Help] observed).
        XCTAssertFalse(MenuBarCatalog.helpGroups.joined().contains("Show Welcome Again"))
        XCTAssertEqual(built.first { $0.title == "Troubleshooting" }?.submenu?.items.map(\.title), MenuBarCatalog.troubleshootingItems)
        assertNoOwnIcons(built)
    }

    /// 01 §Window: Stay On Top, checked while on; it floats the window.
    func testStayOnTop() throws {
        let model = makeModel()
        var levels: [Bool] = []
        model.applyWindowLevel = { levels.append($0) }
        XCTAssertEqual(try items(WindowMenuItems(model: model, hasWindow: true)).map(\.title), MenuBarCatalog.windowSystemGroupItems)
        model.toggleStayOnTop()
        XCTAssertTrue(model.staysOnTop)
        XCTAssertEqual(try items(WindowMenuItems(model: model, hasWindow: true)).first?.state, .on)
        model.toggleStayOnTop()
        XCTAssertEqual(levels, [true, false])
    }


    /// 01 §菜单项图标与缩进: Zoom In / Zoom Out and Save Page As get the icons macOS uses for
    /// zoomIn: / zoomOut: / saveDocument:, so their groups are indented as in Arc; nothing else does.
    func testStandardIcons() {
        let bar = menuBar([
            ("View", ["Hide Sidebar", nil, "Zoom to Actual Size", "Zoom In", "Zoom Out"]),
            ("File", ["Close Window", nil, "Capture…", "Save Page As", "Print"]),
            ("Tabs", ["Zoom In"]),
        ])
        MenuBarAdjuster().adjust(bar)
        func image(_ menu: Int, _ title: String) -> NSImage? { bar.items[menu].submenu?.items.first { $0.title == title }?.image }
        XCTAssertNotNil(image(0, "Zoom In"))
        XCTAssertNotNil(image(0, "Zoom Out"))
        XCTAssertNotNil(image(1, "Save Page As"))
        XCTAssertEqual(image(0, "Zoom In")?.size, MenuBarAdjuster.standardImage(for: "zoomIn:")?.size, "the system's own image")
        for (menu, title) in [(0, "Hide Sidebar"), (0, "Zoom to Actual Size"), (1, "Capture…"), (1, "Print"), (2, "Zoom In")] {
            XCTAssertNil(image(menu, title), "\(title) has no icon")
        }
    }

    // MARK: Actions

    /// 01 §Edit / 02 §复制链接: Copy URL writes the address, Copy URL as Markdown `[title](url)`.
    func testCopyURLActions() async throws {
        let model = makeModel()
        let pasteboard = RecordingPasteboardWriter()
        model.siteControls.pasteboard = pasteboard
        let space = try XCTUnwrap(model.selectedSpaceID)
        let id = try XCTUnwrap(model.workspace.today(spaceID: space).first?.id)
        try await model.activate(tabID: id)
        let url = try XCTUnwrap(model.sidebar.selectedURL)
        model.copySelectedURL()
        XCTAssertEqual(pasteboard.written, [url])
        model.copySelectedURLAsMarkdown()
        XCTAssertEqual(pasteboard.writtenText.count, 1)
        XCTAssertTrue(pasteboard.writtenText[0].hasSuffix("](\(url.absoluteString))"))
    }

    // MARK: Actions (B72)

    private func selectFirstTodayTab(_ model: ShellModel) async throws -> UUID {
        let space = try XCTUnwrap(model.selectedSpaceID)
        let id = try XCTUnwrap(model.workspace.today(spaceID: space).first?.id)
        try await model.activate(tabID: id)
        return id
    }

    private func desktop(_ model: ShellModel) throws -> RecordingDesktopServices {
        try XCTUnwrap(model.dependencies.desktop as? RecordingDesktopServices)
    }

    /// 01 §Arc Share Arc → Share Open Arc (the project homepage), 01 §File Share… (the page).
    func testShareItems() async throws {
        let model = makeModel()
        ShareOpenArcMenuItem(desktop: model.dependencies.desktop).desktop.share([OpenArcLinks.homepage])
        let id = try await selectFirstTodayTab(model)
        model.shareCurrentPage()
        let url = try XCTUnwrap(model.sidebar.linkURL(for: id))
        XCTAssertEqual(try desktop(model).shared, [[OpenArcLinks.homepage], [url]])
    }

    /// 01 §Arc Privacy Policy and 01 §Help Visit Help Center open a tab at the top of Today;
    /// Contact the Team opens a mail; Getting Started / Essential Keyboard Shortcuts open our local
    /// pages ([06 §27.5] observed placement, [02 §其他]).
    func testHelpAndPolicyLinks() async throws {
        let model = makeModel()
        let space = try XCTUnwrap(model.selectedSpaceID)
        model.openPrivacyPolicy()
        XCTAssertEqual(model.workspace.today(spaceID: space).first?.url, OpenArcLinks.privacyPolicy)
        model.openHelpCenter()
        XCTAssertEqual(model.workspace.today(spaceID: space).first?.url, OpenArcLinks.helpCenter)
        model.contactTheTeam()
        XCTAssertEqual(try desktop(model).opened, [OpenArcLinks.contactTheTeam])

        model.openGettingStarted()
        let welcome = try XCTUnwrap(model.workspace.today(spaceID: space).first)
        XCTAssertEqual(welcome.title, "Getting Started")
        let welcomeURL = try XCTUnwrap(welcome.url)
        XCTAssertTrue(welcomeURL.isFileURL)
        XCTAssertEqual(model.selectedTabID, welcome.id)
        model.openKeyboardShortcutsPage()
        let shortcutsURL = try XCTUnwrap(model.workspace.today(spaceID: space).first?.url)
        let page = try String(contentsOf: shortcutsURL, encoding: .utf8)
        XCTAssertTrue(page.contains("Archive Tab") && page.contains("⌘W"), "lists the shortcuts of [02]")
        try? FileManager.default.removeItem(at: model.helpPagesDirectory)
    }

    /// 01 §Help ▸ Troubleshooting: Reveal Open Arc Data shows the data folder; Copy Open Arc Info
    /// copies the version, engine and macOS lines.
    func testTroubleshootingItems() throws {
        let model = makeModel()
        model.revealAppData()
        XCTAssertEqual(try desktop(model).revealed.count, 1)
        model.copyAppInfo()
        let info = try XCTUnwrap(try desktop(model).copiedText.first)
        XCTAssertTrue(info.hasPrefix(AppIdentity.displayName))
        XCTAssertTrue(info.contains("Engine: \(model.dependencies.engine.engineVersion)"))
        XCTAssertTrue(info.contains("macOS: "))
    }

    /// 01 §Edit / 02 §复制链接 Copy URL as Quote (⌃⇧⌘C): the selection as a quote with a link
    /// to the text (format inferred).
    func testCopyURLAsQuote() async throws {
        let model = makeModel()
        let pasteboard = RecordingPasteboardWriter()
        model.siteControls.pasteboard = pasteboard
        let id = try await selectFirstTodayTab(model)
        let live = try XCTUnwrap(model.selectedLiveTab as? FakeTab)
        live.simulateSelection("Hello world")
        model.copySelectedURLAsQuote()
        await model.sidebar.settleEngineWork()
        for _ in 0..<200 where pasteboard.writtenText.isEmpty { await Task.yield() }
        let url = try XCTUnwrap(model.sidebar.linkURL(for: id))
        let text = try XCTUnwrap(pasteboard.writtenText.first)
        XCTAssertTrue(text.hasPrefix("> Hello world\n>\n> — ["), text)
        XCTAssertTrue(text.hasSuffix("(\(url.absoluteString)#:~:text=Hello%20world)"), text)
    }

    func testQuoteFormat() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a#top"))
        XCTAssertEqual(QuoteLink.text(selection: " ", title: "Ex [1]", url: url), "> [Ex \\[1\\]](https://example.com/a#top)")
        let long = "one two three four five six seven eight nine ten"
        XCTAssertEqual(QuoteLink.fragmentURL(url, quoting: long)?.absoluteString,
                       "https://example.com/a#top:~:text=one%20two%20three%20four,seven%20eight%20nine%20ten")
        XCTAssertEqual(QuoteLink.fragmentURL(url, quoting: "a-b, c")?.absoluteString, "https://example.com/a#top:~:text=a%2Db%2C%20c")
        XCTAssertEqual(QuoteLink.text(selection: "line 1\n\nline 2", title: "T", url: url).components(separatedBy: "\n").prefix(3),
                       ["> line 1", ">", "> line 2"])
    }

    /// 01 §Edit Paste and Match Style and Find ▸ Jump to Selection reach the page.
    func testPasteAndMatchStyleAndJumpToSelection() async throws {
        let model = makeModel()
        _ = try await selectFirstTodayTab(model)
        let live = try XCTUnwrap(model.selectedLiveTab as? FakeTab)
        model.pasteAndMatchStyle()
        model.jumpToSelection()
        await model.sidebar.settleEngineWork()
        for _ in 0..<200 where live.commands.count < 2 { await Task.yield() }
        XCTAssertTrue(live.commands.contains(.edit(.pasteAndMatchStyle)))
        XCTAssertTrue(live.commands.contains(.evaluateJavaScript(ShellModel.jumpToSelectionScript)))
    }

    /// 01 §View Collapse Pinned Tabs: the pinned rows hide in this window and come back with the
    /// item (now "Expand Pinned Tabs") or with Reveal Tab in Sidebar on a pinned tab.
    func testCollapsePinnedTabsAndReveal() throws {
        let model = makeModel()
        let sidebar = model.sidebar
        XCTAssertFalse(sidebar.snapshot.pinned.isEmpty)
        XCTAssertTrue(sidebar.canCollapsePinned)
        XCTAssertEqual(model.collapsePinnedMenuTitle, "Collapse Pinned Tabs")
        sidebar.toggleCollapsePinned()
        XCTAssertTrue(sidebar.snapshot.pinned.isEmpty)
        XCTAssertTrue(sidebar.snapshot.hasPinnedContent, "the content stays")
        XCTAssertEqual(model.collapsePinnedMenuTitle, "Expand Pinned Tabs")
        XCTAssertEqual(try items(ViewMenuItems(model: model, hasWindow: true)).first { $0.title == "Expand Pinned Tabs" }?.isEnabled, true)

        // The demo pins example.com inside the "Reading" folder: reveal opens the area and the folder.
        let space = try XCTUnwrap(model.selectedSpaceID)
        let folder = try XCTUnwrap(model.workspace.folders.values.first { $0.spaceID == space })
        let pinned = try XCTUnwrap(model.workspace.allTabs(inSpace: space).first { $0.location == .pinned(spaceID: space, folderID: folder.id) })
        sidebar.replaceWorkspace(try TreeOps.setFolderExpanded(model.workspace, id: folder.id, isExpanded: false, now: t0))
        sidebar.selectTab(pinned.id)
        model.toggleSidebar()
        model.revealSelectedTabInSidebar()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertFalse(sidebar.isPinnedAreaCollapsed)
        XCTAssertEqual(model.workspace.folders[folder.id]?.isExpanded, true)
        XCTAssertNotNil(sidebar.snapshot.listIndex(ofTab: pinned.id))
    }

    /// Reveal Tab in Sidebar scrolls the row into view (centered, within the scroll range).
    func testRevealScrollsTheRow() async throws {
        let model = makeModel()
        let id = try await selectFirstTodayTab(model)
        let scroller = RevealScroller(SidebarScrollMetrics(offset: 0, contentHeight: 2000, viewportHeight: 200))
        model.sidebar.listScroller = scroller
        model.revealSelectedTabInSidebar()
        let index = try XCTUnwrap(model.sidebar.snapshot.listIndex(ofTab: id))
        XCTAssertEqual(scroller.scrolls.count, 1)
        let rowTop = CGFloat(Metrics.Sidebar.listTopSpacer) + CGFloat(index) * SidebarLayout().rowHeight
            + (model.sidebar.snapshot.showsDivider && index > model.sidebar.snapshot.pinned.count
               ? CGFloat(Metrics.Sidebar.dividerRowHeight) - SidebarLayout().rowHeight : 0)
        XCTAssertEqual(scroller.scrolls.first ?? -1, max(0, rowTop - (200 - SidebarLayout().rowHeight) / 2), accuracy: 0.5)
    }

    /// 01 §Tabs Reset all tabs in this Space: every pinned tab goes back to its pinned page and
    /// unloads ([06 §16.1] for one row); Today tabs stay.
    func testResetAllTabsInSpace() async throws {
        let model = makeModel()
        let space = try XCTUnwrap(model.selectedSpaceID)
        let pinned = try XCTUnwrap(model.workspace.allTabs(inSpace: space).first { if case .pinned = $0.location { return true }; return false })
        let today = try XCTUnwrap(model.workspace.today(spaceID: space).first?.id)
        try await model.activate(tabID: pinned.id)
        model.sidebar.navigateSelectedTab(to: URL(string: "https://elsewhere.example")!)
        await model.sidebar.settleEngineWork()
        try await model.activate(tabID: today)
        XCTAssertTrue(model.sidebar.canResetPinnedTabs)
        model.sidebar.resetAllPinnedTabsInSpace()
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.workspace.tabs[pinned.id]?.url, pinned.pinnedURL)
        XCTAssertNil(model.sidebar.liveTab(for: pinned.id), "unloaded")
        XCTAssertNotNil(model.sidebar.liveTab(for: today), "Today tabs stay")
        XCTAssertEqual(model.selectedTabID, today)
    }

    /// 01 §View Cast: shown, disabled (no casting in the engine bridge).
    func testCastIsDisabled() throws {
        let model = makeModel()
        let cast = try XCTUnwrap(try items(ViewMenuItems(model: model, hasWindow: true)).first { $0.title == "Cast" })
        XCTAssertFalse(cast.isEnabled)
    }
}

@MainActor
private final class RevealScroller: SidebarListScrolling {
    var metrics: SidebarScrollMetrics?
    var scrolls: [CGFloat] = []
    init(_ metrics: SidebarScrollMetrics) { self.metrics = metrics }
    func scroll(toOffset offset: CGFloat) {
        scrolls.append(offset)
        metrics?.offset = offset
    }
}
