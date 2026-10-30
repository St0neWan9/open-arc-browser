import XCTest
import SwiftUI
import AppKit
import CoreGraphics
import OpenArcModel
import OpenArcDesign
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B48: the incognito window per docs/arc-spec/06-flows.md §20 (observed, E19, dark
/// appearance), 04-visual-metrics.md (E19 table) and design-tokens.json `Metrics.Incognito`.
/// Light-appearance colors are unknown ([06 §20.5]): only "neutral, untinted" is checked.
@MainActor
final class IncognitoWindowTests: XCTestCase {
    private var preferences: AppPreferences!
    private var system: ManualSystemAppearance!
    private var controller: WorkspaceController!
    private var incognito: ShellModel!

    override func setUp() async throws {
        let f = SidebarFixture()
        preferences = .inMemory()
        preferences.webAppearance = .dark
        system = ManualSystemAppearance(.light)
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: preferences, systemAppearance: system)
        controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now.addingTimeInterval(10) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
    }

    override func tearDown() async throws {
        incognito.stop()
        controller.stop()
        incognito = nil
        controller = nil
        system = nil
        preferences = nil
    }

    private var sidebar: SidebarViewModel { incognito.sidebar }

    // MARK: Colors

    /// 06 §20.1 / §20.3 observed: fixed near-black neutral colors, no theme tint; the command bar
    /// selection is a fixed blue-violet with white text.
    func testDarkColorsMatch06Section20() {
        let p = sidebar.palette
        XCTAssertEqual(p.appearance, .dark)
        XCTAssertEqual(p.windowBackground, RGBAColor(hex: 0x0C0F14), "[06 §20.1] sidebar / window")
        XCTAssertEqual(p.controlFill, RGBAColor(hex: 0x3D4243), "[06 §20.1] address field")
        XCTAssertEqual(p.selectedTabFill, RGBAColor(hex: 0x4F5257), "[06 §20.1] selected row")
        XCTAssertEqual(p.webPanelBackground, RGBAColor(hex: 0x2A2D31), "[06 §20.1] blank panel")
        XCTAssertEqual(p.commandBarBackground, RGBAColor(hex: 0x1A1A1D), "[06 §20.3] command bar")
        XCTAssertEqual(p.commandBarSelection, RGBAColor(hex: 0x444DDC), "[06 §20.3] selected row")
        XCTAssertEqual(p.commandBarSelectedText, RGBAColor(hex: 0xFFFFFF), "[06 §20.3] white text")
        XCTAssertEqual(p.backgroundGradientColors, [RGBAColor(hex: 0x0C0F14)])
        XCTAssertEqual(p.grain, 0)
        XCTAssertTrue(p.usesLightInk)
        // [06 §20.1] sidebar text ≈ #878789: the Space-name ink over the window lands within ±3 levels.
        let name = p.ink(\.spaceName)
        let blended = ThemeDerivation.mix(p.windowBackground, RGBAColor(red: name.red, green: name.green, blue: name.blue), amount: name.alpha)
        XCTAssertEqual(blended.red * 255, IncognitoTokens.sidebarText.red * 255, accuracy: 3)
        XCTAssertEqual(blended.blue * 255, IncognitoTokens.sidebarText.blue * 255, accuracy: 3)
    }

    /// 06 §20.1 observed: the colors do not follow any Space theme (a purple Space in the parent
    /// does not tint the incognito window), and no dot of the window color is tinted.
    func testNoThemeTint() {
        let w = sidebar.palette.windowBackground
        XCTAssertLessThan(max(w.red, w.green, w.blue) - min(w.red, w.green, w.blue), 0.04, "neutral")
        let regular = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: SidebarFixture().home))
        defer { regular.stop() }
        XCTAssertNotEqual(regular.sidebar.palette.windowBackground, w)
    }

    /// 06 §20.5: the light incognito colors are unknown. Our fallback is a neutral, untinted light
    /// window; the command bar selection keeps the fixed blue-violet (inferred).
    func testLightFallbackIsNeutral() {
        preferences.webAppearance = .light
        let p = sidebar.palette
        XCTAssertEqual(p.appearance, .light)
        let w = p.windowBackground
        XCTAssertGreaterThan(ThemeDerivation.luminance(w), 0.6)
        XCTAssertLessThan(max(w.red, w.green, w.blue) - min(w.red, w.green, w.blue), 0.02, "neutral")
        XCTAssertEqual(p.commandBarSelection, IncognitoTokens.commandBarSelection)
        // Automatic follows the system.
        preferences.webAppearance = .automatic
        XCTAssertEqual(sidebar.palette.appearance, .light)
        system.set(.dark)
        XCTAssertEqual(sidebar.palette.windowBackground, IncognitoTokens.windowBackground)
    }

    // MARK: Sidebar contents

    /// 06 §20.1 observed: no badge; the Space-name row reads "Incognito Tabs" without an icon.
    func testTitleRowIsIncognitoTabs() {
        XCTAssertEqual(sidebar.selectedSpace?.name, "Incognito Tabs")
        XCTAssertNil(sidebar.selectedSpace?.icon, "name at x 13: no icon")
    }

    /// 06 §20.2 observed: no favorites block, the rows move up: name row y 115–152 on screen with
    /// the window at y 30 (window 85–122), name text y 124 (window 94).
    func testNoFavoritesRowsMoveUp() {
        let layout = SidebarLayout(windowSize: CGSize(width: 1920, height: 985), hidesFavorites: true)
        XCTAssertEqual(layout.contentShift, 60)
        XCTAssertEqual(Metrics.Sidebar.spaceNameTop - layout.contentShift, 94, "[06 §20.1] name y 124 − 30")
        XCTAssertEqual(Metrics.Sidebar.spaceHeaderTop - layout.contentShift, 85, "[06 §20.2] row y 115 − 30")
        XCTAssertEqual(layout.listTop, 121)
        XCTAssertEqual(SidebarLayout(windowSize: CGSize(width: 1920, height: 985)).contentShift, 0)
        XCTAssertTrue(sidebar.snapshot.favorites.isEmpty)
    }

    /// 06 §20.2 observed: no pinned area and no divider; only "+ New Tab" and the tab rows.
    func testNoPinnedAreaOrDivider() async throws {
        let idOpened = try await incognito.openNewTab(url: URL(string: "https://example.com"))
        let id = try XCTUnwrap(idOpened)
        XCTAssertEqual(sidebar.snapshot.listKinds, [.newTabRow, .row], "no divider row")
        sidebar.pinTab(id)
        XCTAssertTrue(sidebar.snapshot.pinned.isEmpty, "⌘D does not pin")
        XCTAssertNil(sidebar.createFolder(title: "Folder"), "no folders (pinned area)")
        XCTAssertFalse(sidebar.incognitoAllowsDrop(on: .pinnedAreaTop))
        XCTAssertFalse(sidebar.incognitoAllowsDrop(on: .favoriteGap(0)))
        XCTAssertTrue(sidebar.incognitoAllowsDrop(on: .row(id, .above)))
    }

    /// 06 §20.2 observed: the dock has Home and "+" but no Space icons; "+" opens the command bar
    /// for a new tab, not New Space.
    func testDockHasNoSpacesAndPlusOpensCommandBar() {
        XCTAssertTrue(sidebar.dockSpaces.isEmpty)
        sidebar.dockPlusClicked()
        XCTAssertTrue(incognito.isCommandBarPresented)
        XCTAssertEqual(incognito.commandBar.mode, .newTab)
        XCTAssertFalse(incognito.spaceFlow.isCreating)
    }

    /// 06 §20.2 observed: Archive Other Tabs / Below / Above (disabled with a single tab).
    func testArchiveAroundTab() async throws {
        let aOpened = try await incognito.openNewTab(url: URL(string: "https://a.example"))
        let a = try XCTUnwrap(aOpened)
        XCTAssertTrue(sidebar.todayTabs(around: a).above.isEmpty && sidebar.todayTabs(around: a).below.isEmpty)
        let bOpened = try await incognito.openNewTab(url: URL(string: "https://b.example"))
        let b = try XCTUnwrap(bOpened)
        let cOpened = try await incognito.openNewTab(url: URL(string: "https://c.example"))
        let c = try XCTUnwrap(cOpened)
        // New tabs go to the top of Today: order c, b, a.
        XCTAssertEqual(sidebar.todayTabs(around: b).above, [c])
        XCTAssertEqual(sidebar.todayTabs(around: b).below, [a])
        sidebar.archiveTabs(sidebar.todayTabs(around: b).below)
        XCTAssertEqual(sidebar.snapshot.today.map(\.id), [c, b])
        sidebar.clearToday()
        XCTAssertTrue(sidebar.snapshot.today.isEmpty, "Clear archives every incognito tab (inferred)")
    }

    /// 06 §20.2 observed: the Spaces menu is disabled while an incognito window is in front; its
    /// commands do nothing there.
    func testSpacesCommandsDisabled() {
        XCTAssertTrue(incognito.isIncognito, "OpenArcScene disables the Spaces menu on this flag")
        incognito.perform(.runCommand(.manageSpaces))
        XCTAssertFalse(incognito.library.isActive)
        sidebar.stepSpace(by: 1)
        XCTAssertEqual(sidebar.selectedSpace?.name, "Incognito Tabs")
    }

    /// The AppKit items SwiftUI makes for `content`.
    private func menuItems<Content: View>(_ content: Content) throws -> [NSMenuItem] {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu.items
    }

    /// 06 §20.2 observed (F5-3, F5-4): with incognito in front the Spaces menu has no Change
    /// Profile, and lists every Space of the app, all greyed, none checked.
    func testSpacesMenuListsSpacesGreyedWithoutChangeProfile() throws {
        let items = try menuItems(SpacesMenuItems(model: incognito, hasWindow: true)).filter { !$0.isSeparatorItem && !$0.isHidden }
        let titles = items.map(\.title)
        XCTAssertFalse(titles.contains("Change Profile"))
        let spaceNames = controller.workspace.allLiveSpaces.map(\.name)
        XCTAssertFalse(spaceNames.isEmpty)
        XCTAssertEqual(titles, ["New Space…", "Edit Theme…", "Rename Space", "Next Space", "Previous Space"]
                       + spaceNames + ["Manage Spaces…"])
        XCTAssertTrue(items.allSatisfy { !$0.isEnabled }, "the whole menu is disabled")
        XCTAssertTrue(items.allSatisfy { $0.state == .off }, "no Space is current in an incognito window")
        // The dock stays empty ([06 §20.2] observed).
        XCTAssertTrue(sidebar.dockSpaces.isEmpty)
        // A regular window keeps Change Profile.
        let regular = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: SidebarFixture().home))
        defer { regular.stop() }
        XCTAssertTrue(try menuItems(SpacesMenuItems(model: regular, hasWindow: true)).contains { $0.title == "Change Profile" })
    }

    /// 06 §20.2 observed (F5-42): the incognito tab menu's Copy Link shows ⌘C.
    func testTabMenuCopyLinkShowsCommandC() throws {
        let id = try XCTUnwrap(sidebar.newTab(url: URL(string: "https://incognito.example"), title: "x"))
        let tab = try XCTUnwrap(incognito.workspace.tabs[id])
        let items = try menuItems(IncognitoTabMenu(viewModel: sidebar, tab: tab))
        let copy = try XCTUnwrap(items.first { $0.title == "Copy Link" })
        XCTAssertEqual(copy.keyEquivalent, "c")
        XCTAssertEqual(copy.keyEquivalentModifierMask, .command)
    }

    /// 06 §20.1 observed (F5-41): a new incognito window opens with the front window's size and
    /// position; before a window reported its frame, the placement is left to the system.
    func testNewIncognitoWindowTakesTheFrontWindowFrame() {
        let regular = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: SidebarFixture().home))
        defer { regular.stop() }
        XCTAssertNil(regular.windowRequest(.incognito).frame)
        regular.windowFrameDidChange(x: 0, y: 30, width: 1920, height: 985)
        let request = regular.windowRequest(.incognito)
        XCTAssertEqual(request.frame, CGRect(x: 0, y: 30, width: 1920, height: 985))
        XCTAssertNil(regular.windowRequest(.newWindow).frame, "only the incognito window copies the frame")
        let opened = ShellModel.window(for: request, on: controller)
        defer { opened.stop() }
        XCTAssertEqual(opened.takeOpeningFrame(), CGRect(x: 0, y: 30, width: 1920, height: 985))
        XCTAssertNil(opened.takeOpeningFrame(), "applied once")
        // The request still round-trips as the window's scene value.
        let decoded = try? JSONDecoder().decode(BrowserWindowRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded, request)
    }
}
