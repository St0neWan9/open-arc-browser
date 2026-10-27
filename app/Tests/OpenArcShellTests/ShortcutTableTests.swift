import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B85: one shortcut table shared by the menus, Settings ▸ Shortcuts and Help ▸ Essential
/// Keyboard Shortcuts. Acceptance: docs/arc-spec/02-shortcuts.md, all sections (observed keys):
/// every key a menu of ours binds is in the table and every menu key of the table is bound; the
/// [02] aliases ⌘} / ⌘{ (§标签与侧边栏), ⌘← / ⌘→ (§页面与导航) and F12 (§开发者) are hidden
/// key-only items that fire; "Start with the basics" opens Essential Keyboard Shortcuts (§其他).
@MainActor
final class ShortcutTableTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private var models: [ShellModel] = []

    override func tearDown() async throws {
        for model in models { model.stop() }
        models = []
    }

    private func makeModel(engine: FakeEngine = FakeEngine()) -> ShellModel {
        let model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) }
        )
        models.append(model)
        return model
    }

    private func menu<Content: View>(_ content: Content) throws -> NSMenu {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu
    }

    /// The keys of `items` and their submenus, as table keys.
    private func keys(_ items: [NSMenuItem]) -> [ShortcutKey] { boundItems(items).map(\.key) }

    /// Each item with a key, with its title.
    private func boundItems(_ items: [NSMenuItem]) -> [(title: String, key: ShortcutKey)] {
        items.flatMap { item -> [(title: String, key: ShortcutKey)] in
            var result = item.submenu.map { boundItems($0.items) } ?? []
            guard !item.isSeparatorItem, let first = item.keyEquivalent.first else { return result }
            var modifiers: EventModifiers = []
            let mask = item.keyEquivalentModifierMask
            if mask.contains(.control) { modifiers.insert(.control) }
            if mask.contains(.option) { modifiers.insert(.option) }
            if mask.contains(.shift) { modifiers.insert(.shift) }
            if mask.contains(.command) { modifiers.insert(.command) }
            var character = first
            // An upper-case letter is the letter with ⇧.
            if first.isLetter, first.isUppercase {
                character = Character(first.lowercased())
                modifiers.insert(.shift)
            }
            result.append((item.title, ShortcutKey(character, modifiers)))
            return result
        }
    }

    /// Ten Spaces, so the Spaces menu binds ⌃1…⌃9.
    private func addSpaces(_ model: ShellModel) throws {
        let profile = try XCTUnwrap(model.selectedSpace?.profileID)
        var ws = model.workspace
        var previous = try XCTUnwrap(model.selectedSpaceID)
        for n in 1...9 {
            let id = UUID()
            ws = try TreeOps.createSpace(ws, id: id, profileID: profile, name: "S\(n)", icon: nil, afterSpaceID: previous, now: t0)
            previous = id
        }
        model.sidebar.replaceWorkspace(ws)
    }

    /// Every key bound by a menu of ours (each `keyboardShortcut` in the menus), with its item.
    private func menuKeys(_ model: ShellModel) throws -> [(title: String, key: ShortcutKey)] {
        try addSpaces(model)
        var all: [NSMenuItem] = []
        all += try menu(FileMenuItems(model: model, hasWindow: true, openWindow: EnvironmentValues().openWindow)).items
        all += try menu(FilePageMenuItems(model: model, hasWindow: true)).items
        all += try menu(EditCopyURLMenuItems(model: model, hasWindow: true)).items
        all += try menu(FindMenu(model: model, findBar: model.findBar, hasWindow: true)).items
        all += try menu(ViewMenuItems(model: model, hasWindow: true)).items
        all += try menu(SpacesMenuItems(model: model, hasWindow: true)).items
        all += try menu(TabsMenuItems(model: model, hasWindow: true)).items
        all += try menu(ArchiveMenuItems(model: model, hasWindow: true)).items
        all += try menu(WindowLibraryMenuItems(model: model, hasWindow: true)).items
        all += try menu(WindowMenuItems(model: model, hasWindow: true)).items
        all += try menu(HelpMenuItems(model: model, hasWindow: true)).items
        all += try menu(KeyOnlyMenuItems(model: model, hasWindow: true)).items
        return boundItems(all)
    }

    // MARK: Menus ↔ table

    /// Every key a menu of ours binds appears in the table, and every key the table gives a menu is
    /// bound by one; no key is bound to two different items. (New Tab… is in File and Tabs with ⌘T,
    /// as [01 §File] and [01 §Tabs] observed.)
    func testMenusAndTableBindTheSameKeys() throws {
        let model = makeModel()
        let items = try menuKeys(model)
        let bound = items.map(\.key)
        let titlesByKey = Dictionary(grouping: items, by: \.key).mapValues { Set($0.map(\.title)) }
        let clashes = titlesByKey.filter { $0.value.count > 1 }.map { "\($0.key.symbols): \($0.value.sorted())" }
        XCTAssertEqual(clashes, [], "one key on two different items")
        XCTAssertEqual(titlesByKey[ShortcutKey("t", .command)], ["New Tab…"])
        let table = ShortcutCatalog.table.flatMap(\.definitions).filter { $0.binding == .menu }.flatMap(\.keys)
        XCTAssertEqual(table.count, Set(table).count, "a key listed twice")
        let missingFromTable = Set(bound).subtracting(table).map(\.symbols).sorted()
        let notBound = Set(table).subtracting(bound).map(\.symbols).sorted()
        XCTAssertEqual(missingFromTable, [], "bound by a menu but not in the Shortcuts pane")
        XCTAssertEqual(notBound, [], "in the Shortcuts pane but bound by no menu")
    }

    /// Each table action has one entry, and the pane and the help page list every one of them.
    func testPaneAndHelpPageAreGeneratedFromTheTable() {
        let definitions = ShortcutCatalog.table.flatMap(\.definitions)
        XCTAssertEqual(Set(definitions.map(\.id)), Set(AppShortcut.allCases))
        XCTAssertEqual(definitions.count, AppShortcut.allCases.count)
        XCTAssertEqual(ShortcutCatalog.groups.map(\.title), ShortcutCatalog.table.map(\.title))
        XCTAssertEqual(ShortcutCatalog.groups.flatMap(\.entries).map(\.keys), definitions.map(\.keyText))
        let page = HelpPages.shortcutsHTML(ShortcutCatalog.groups)
        for definition in definitions {
            XCTAssertTrue(page.contains(definition.keyText), "\(definition.title) on the help page")
        }
    }

    /// [02] groups in order, its aliases written as alternatives, numbered items as ranges.
    func testGroupsAndKeyText() {
        XCTAssertEqual(ShortcutCatalog.groups.map(\.title),
                       ["Tabs and Sidebar", "Spaces", "Split View", "Page and Navigation", "Copy Links", "Windows and App", "Developer"])
        let all = Dictionary(uniqueKeysWithValues: ShortcutCatalog.groups.flatMap(\.entries).map { ($0.action, $0.keys) })
        XCTAssertEqual(all["Next Tab"], "⌥⌘↓ or ⌘}")
        XCTAssertEqual(all["Previous Tab"], "⌥⌘↑ or ⌘{")
        XCTAssertEqual(all["Go Back"], "⌘[ or ⌘←")
        XCTAssertEqual(all["Go Forward"], "⌘] or ⌘→")
        XCTAssertEqual(all["Developer Tools"], "⌥⌘I or F12")
        XCTAssertEqual(all["Go to Sidebar Item 1–8"], "⌘1…⌘8")
        XCTAssertEqual(all["Go to Space 1–9"], "⌃1…⌃9")
        XCTAssertEqual(all["New Little Arc Window"], "⌥⌘N")
        XCTAssertEqual(all["Copy URL as Quote"], "⌃⇧⌘C")
        XCTAssertEqual(all["Reveal Current Tab"], "⌃Space")
        XCTAssertEqual(all["Exit"], "⎋")
    }

    /// The search field finds a name or any one key, also inside a range or behind an alias.
    func testSearchMatchesNamesAndEachKey() {
        func actions(_ query: String) -> [String] {
            ShortcutCatalog.filtered(ShortcutCatalog.groups, query: query).flatMap(\.entries).map(\.action)
        }
        XCTAssertEqual(actions("⌘}"), ["Next Tab"])
        XCTAssertEqual(actions("F12"), ["Developer Tools"])
        XCTAssertEqual(actions("⌘5"), ["Go to Sidebar Item 1–8"])
        XCTAssertEqual(actions("⇧⌘K"), ["Clear Unpinned Tabs"])
        XCTAssertEqual(actions("split").count, 2)
        XCTAssertTrue(actions("zzz").isEmpty)
    }

    // MARK: Aliases

    /// The hidden aliases carry the [02] keys and run the visible items' commands.
    func testKeyOnlyAliasesCarryTheirKeys() throws {
        let model = makeModel()
        let items = try menu(KeyOnlyMenuItems(model: model, hasWindow: true)).items
        XCTAssertEqual(items.map(\.title), MenuBarCatalog.keyOnlyItems)
        for alias in MenuBarCatalog.keyOnlyAliases {
            let item = try XCTUnwrap(items.first { $0.title == alias.title }, alias.title)
            XCTAssertEqual(keys([item]), [alias.shortcut.keys[1]], alias.title)
        }
    }

    /// Runs the item's command as a key equivalent would. Calls the item's own target and action:
    /// `performActionForItem` does nothing for a menu that is not in the menu bar.
    private func perform(_ title: String, in menu: NSMenu) throws {
        let item = try XCTUnwrap(menu.item(withTitle: title), title)
        XCTAssertTrue(item.isEnabled, title)
        let action = try XCTUnwrap(item.action, title)
        _ = (try XCTUnwrap(item.target, title) as AnyObject).perform(action, with: item)
    }

    /// ⌘} / ⌘{ step through the tabs like ⌥⌘↓ / ⌥⌘↑.
    func testTabAliasesFire() async throws {
        let model = makeModel()
        let order = model.sidebar.keyboardTabOrder
        XCTAssertGreaterThan(order.count, 1)
        try await model.activate(tabID: order[0])
        let keyOnly = try menu(KeyOnlyMenuItems(model: model, hasWindow: true))
        try perform("Next Tab", in: keyOnly)
        XCTAssertEqual(model.selectedTabID, order[1])
        try perform("Previous Tab", in: keyOnly)
        XCTAssertEqual(model.selectedTabID, order[0])
    }

    /// ⌘← / ⌘→ navigate the page when no text field of ours has the keyboard, F12 opens the
    /// developer tools.
    func testPageAliasesFire() async throws {
        let model = makeModel()
        let first = try await model.openNewTab(url: URL(string: "https://a.example"))
        let id = try XCTUnwrap(first)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        try await live.load(try XCTUnwrap(URL(string: "https://b.example")))
        try await waitUntil { model.sidebar.canGoBack }
        // No window is key in the test, so no text field of ours has the keyboard.
        let keyOnly = try menu(KeyOnlyMenuItems(model: model, hasWindow: true))
        try perform("Go Back", in: keyOnly)
        try await waitUntil { model.sidebar.liveState(for: id)?.url?.host == "a.example" }
        try perform("Go Forward", in: keyOnly)
        try await waitUntil { model.sidebar.liveState(for: id)?.url?.host == "b.example" }
        try perform("Developer Tools", in: keyOnly)
        try await waitUntil { live.commands.contains(.showDevTools(nil)) }
    }

    /// In a text field of ours ⌘← / ⌘→ move the caret and leave the page alone.
    func testPageAliasesLeaveTextFieldsTheKey() async throws {
        let model = makeModel()
        let first = try await model.openNewTab(url: URL(string: "https://a.example"))
        let id = try XCTUnwrap(first)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
        try await live.load(try XCTUnwrap(URL(string: "https://b.example")))
        try await waitUntil { model.sidebar.canGoBack }
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
        text.string = "hello"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        PageKeyAlias.perform(.back, model: model, responder: text, event: nil)
        XCTAssertEqual(text.selectedRange().location, 0, "the caret goes to the line's start")
        PageKeyAlias.perform(.forward, model: model, responder: text, event: nil)
        XCTAssertEqual(text.selectedRange().location, 5)
        await model.controller.settleEngineWork()
        XCTAssertEqual(model.sidebar.liveState(for: id)?.url?.host, "b.example", "the page did not navigate")
        // A read-only text view does not take the key.
        text.isEditable = false
        XCTAssertNil(PageKeyAlias.editableText(text))
    }

    // MARK: Start with the basics

    /// [02 §其他] observed: the button opens Help ▸ Essential Keyboard Shortcuts.
    func testStartWithTheBasicsOpensTheShortcutsPage() throws {
        let model = makeModel()
        XCTAssertTrue(SettingsCatalog.control("shortcuts.basics").isEnabled)
        let settings = SettingsModel(shell: model)
        let id = try XCTUnwrap(settings.startWithTheBasics())
        let tab = try XCTUnwrap(model.workspace.tabs[id])
        XCTAssertEqual(tab.title, "Essential Keyboard Shortcuts")
        let url = try XCTUnwrap(tab.url)
        XCTAssertEqual(url.lastPathComponent, HelpPages.Page.keyboardShortcuts.fileName)
        let page = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(page.contains("⌥⌘↓ or ⌘}"))
        try? FileManager.default.removeItem(at: model.helpPagesDirectory)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await models.first?.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }
}
