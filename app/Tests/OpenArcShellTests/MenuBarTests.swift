import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// The menu bar's items, order and groups (plan B62). Acceptance: `docs/arc-spec/01-menus.md`, all
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

    /// 01 §菜单项图标与缩进 File: New Tab… … Restore Last Closed Tab ‖ Open Command Bar ‖ (New
    /// Profile ·) New Easel ‖ Close Window ‖ (Share… ·) Capture… … Print.
    func testFileMenuGroups() throws {
        let model = makeModel()
        let built = try items(FileMenuItems(model: model, hasWindow: true, openWindow: EnvironmentValues().openWindow))
            + [NSMenuItem.separator()]
            + items(FilePageMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(groups(built), MenuBarCatalog.fileGroups)
        assertNoOwnIcons(built)
        XCTAssertEqual(built.first { $0.title == "Close Window" }?.keyEquivalent, "w", "⇧⌘W [02]")
    }

    /// 01 §Edit: Copy URL (⇧⌘C) and Copy URL as Markdown (⌥⇧⌘C) [02 §复制链接].
    func testEditCopyURLItems() throws {
        let model = makeModel()
        let built = try items(EditCopyURLMenuItems(model: model, hasWindow: true))
        XCTAssertEqual(built.map(\.title), ["Copy URL", "Copy URL as Markdown"])
        XCTAssertEqual(built.map(\.keyEquivalentModifierMask), [[.shift, .command], [.option, .shift, .command]])
        assertNoOwnIcons(built)
    }

    /// 01 §Edit: Find ▸ items. Find and Replace / Jump to Selection are not built.
    func testFindMenu() throws {
        let model = makeModel()
        let built = try items(FindMenu(model: model, findBar: model.findBar, hasWindow: true))
        XCTAssertEqual(built.map(\.title), [MenuBarCatalog.findMenuTitle])
        XCTAssertEqual(built.first?.submenu?.items.map(\.title), ["Find…", "Find Next", "Find Previous", "Use Selection to Find"])
    }

    /// 01 §Spaces / §菜单项图标与缩进: New Space… · Edit Theme… · Rename Space ‖ Next · Previous ‖
    /// the Space list (current one checked) ‖ Manage Spaces….
    func testSpacesMenuGroups() throws {
        let model = makeModel()
        let built = try items(SpacesMenuItems(model: model, hasWindow: true))
        let spaceNames = model.sidebar.dockSpaces.prefix(9).map(\.name)
        var expected = MenuBarCatalog.spacesGroups
        expected.insert(spaceNames, at: 2)
        XCTAssertEqual(groups(built), expected)
        let current = built.first { $0.title == model.selectedSpace?.name }
        XCTAssertEqual(current?.state, .on, "the current Space is checked")
        assertNoOwnIcons(built)
    }

    /// 01 §Tabs, E20 tabs-crop.png: New Tab… · Pin Tab · New Folder… ‖ Next · Previous ‖ Clear Today.
    /// Archive Tab and Go to Sidebar Item are in no [01] menu.
    func testTabsMenuGroups() throws {
        let model = makeModel()
        let built = try items(TabsMenuItems(model: model, hasWindow: true))
        var expected = MenuBarCatalog.tabsGroups
        expected[0][1] = "Pin Tab"
        XCTAssertEqual(groups(built), expected)
        assertNoOwnIcons(built)
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
            + ["Go to Last Sidebar Item", "Open Extensions"])
        XCTAssertEqual(Set(built.map(\.title)), Set(MenuBarCatalog.keyOnlyItems))
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
        XCTAssertEqual(app.items.map(\.title), ["Hide Other Windows", "Minimize Window"], "01 §Arc, 01 §Window, 02 observed")
    }

    /// 01 §Edit observed order: Copy · Copy URL · Copy URL as Markdown · Paste.
    func testCopyURLItemsFollowCopy() {
        let bar = NSMenu(title: "Main")
        let edit = NSMenu(title: "Edit")
        for (title, action) in [("Cut", #selector(NSText.cut(_:))), ("Copy", #selector(NSText.copy(_:))), ("Paste", #selector(NSText.paste(_:))),
                                ("Select All", #selector(NSText.selectAll(_:))), ("Copy URL", nil), ("Copy URL as Markdown", nil)] as [(String, Selector?)] {
            edit.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        let top = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        top.submenu = edit
        bar.addItem(top)
        let adjuster = MenuBarAdjuster()
        adjuster.adjust(bar)
        adjuster.adjust(bar)
        XCTAssertEqual(edit.items.map(\.title), ["Cut", "Copy", "Copy URL", "Copy URL as Markdown", "Paste", "Select All"])
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
}
