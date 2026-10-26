import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// The web toolbar, View ▸ Show Toolbar (plan B43). Every test names `docs/arc-spec/06-flows.md`
/// §17 (E16, observed unless noted) and `04 §网页工具栏`.
@MainActor
final class WebToolbarTests: XCTestCase {
    private let reference = CGSize(width: 1920, height: 985)
    private let t0 = Date(timeIntervalSince1970: 0)

    private func makeModel(preferences: AppPreferences = .inMemory()) -> ShellModel {
        ShellModel(dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: preferences),
                   workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
    }

    // MARK: Tokens

    /// 06 §17.2 / 04 §网页工具栏: the measured numbers.
    func testTokensMatchTheCapture() {
        let t = Metrics.WebToolbar.self
        XCTAssertEqual(t.height, 32)
        XCTAssertEqual(t.horizontalPadding, 5)
        XCTAssertEqual(t.navButtonSize, Size2D(width: 32, height: 24))
        XCTAssertEqual(t.navButtonTopInset, 4)
        XCTAssertEqual(t.navButtonPitch, 37)
        XCTAssertEqual(t.siteControlsButtonSize, Size2D(width: 32, height: 28))
        XCTAssertEqual(t.trailingButtonPitch, 36)
        XCTAssertEqual(t.centerButtonSize, 24)
        XCTAssertEqual(t.sidebarContentShift, 46)
        // 06 §17.1: the fresh-install default is unknown; off keeps the earlier layout.
        XCTAssertFalse(t.defaultIsShown)
        XCTAssertFalse(t.defaultShowsFullURL, "03 §Advanced: off")
    }

    /// 06 §17.4: the background follows only the Space's light / dark mode: white, #3D3E3D, and
    /// #474747 for a dark split pane; icons and text turn light in dark.
    func testBackgroundFollowsOnlyTheSpaceMode() {
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .light), RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .dark), RGBAColor(hex: 0x3D3E3D))
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .dark, isSplitPane: true), RGBAColor(hex: 0x474747))
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .light, isSplitPane: true), RGBAColor(hex: 0xFFFFFF))
        let light = ThemeDerivation.webToolbarColors(appearance: .light)
        XCTAssertEqual(light.icon, RGBAColor(hex: 0x7D7D7D))
        XCTAssertEqual(light.iconDisabled, RGBAColor(hex: 0xC6C6C6))
        let dark = ThemeDerivation.webToolbarColors(appearance: .dark)
        XCTAssertGreaterThan(ThemeDerivation.luminance(dark.icon), ThemeDerivation.luminance(dark.background))
        XCTAssertGreaterThan(ThemeDerivation.luminance(dark.domainText), ThemeDerivation.luminance(dark.background))
        // 06 §17.5: the hover block is ≈ 4 % darker than the bar in light.
        XCTAssertLessThan(light.buttonHoverFill.red, light.background.red)
    }

    /// 06 §17.4: the theme's hue does not reach the toolbar (red and purple themes give the same
    /// colors in the same mode).
    func testToolbarIgnoresThemeHue() {
        let model = makeModel()
        let red = Theme(id: UUID(), colors: [RGBAColor(hex: 0xE03030)], now: t0)
        let palette = ThemeDerivation.palette(for: red, appearance: .light)
        XCTAssertNotEqual(palette.windowBackground, model.windowPalette.windowBackground)
        XCTAssertEqual(ThemeDerivation.webToolbarColors(appearance: palette.appearance),
                       model.webToolbarColors(isSplitPane: false))
        model.stop()
    }

    // MARK: Window layout

    /// 06 §17.2: the strip is the top 32 pt of the panel (276, 10, 1634 × 32), the page starts at
    /// y 42 and is 933 tall; hidden sidebar: x 10, 1900 wide.
    func testStripSitsInsideThePanelTop() {
        let on = MainWindowLayout(windowSize: reference, isSidebarVisible: true, isWebToolbarShown: true)
        XCTAssertEqual(on.webPanelFrame, CGRect(x: 276, y: 10, width: 1634, height: 965), "the panel itself does not move")
        XCTAssertEqual(on.webToolbarFrame, CGRect(x: 276, y: 10, width: 1634, height: 32))
        XCTAssertEqual(on.pageFrame, CGRect(x: 276, y: 42, width: 1634, height: 933))
        let hidden = MainWindowLayout(windowSize: reference, isSidebarVisible: false, isWebToolbarShown: true)
        XCTAssertEqual(hidden.webToolbarFrame, CGRect(x: 10, y: 10, width: 1900, height: 32))
    }

    /// 06 §17.7 / §17.1: toolbar off is today's layout: no strip, the page fills the panel, the
    /// sidebar keeps its URL box and the favorites stay at y 90.
    func testToolbarOffKeepsTodaysLayout() {
        let off = MainWindowLayout(windowSize: reference)
        XCTAssertEqual(off.webToolbarFrame, .zero)
        XCTAssertEqual(off.pageFrame, off.webPanelFrame)
        XCTAssertEqual(off.favoritesFrame.minY, 90)
        let sidebar = SidebarLayout(windowSize: reference)
        XCTAssertTrue(sidebar.showsAddressControls)
        XCTAssertEqual(sidebar.listTop, 181)
    }

    /// 06 §17.1: with the toolbar on, the sidebar loses the URL box and back / forward / reload,
    /// and the favorites (and all below) move up 46 pt.
    func testSidebarContentMovesUp46() {
        let on = SidebarLayout(windowSize: reference, isWebToolbarShown: true)
        let off = SidebarLayout(windowSize: reference)
        XCTAssertFalse(on.showsAddressControls)
        XCTAssertEqual(on.favoritesFrame.minY, off.favoritesFrame.minY - 46)
        XCTAssertEqual(on.spaceNameRowFrame.minY, off.spaceNameRowFrame.minY - 46)
        XCTAssertEqual(on.listTop, off.listTop - 46)
        XCTAssertEqual(on.listItemFrames([.row]).first?.minY, off.listItemFrames([.row]).first.map { $0.minY - 46 })
        // The traffic lights and the hide-sidebar button stay. [06 §17.1]
        XCTAssertEqual(on.hideSidebarButtonFrame, off.hideSidebarButtonFrame)
    }

    // MARK: Bar layout

    /// 06 §17.2: sidebar shown: back · forward · reload at x 281 / 318 / 355; site controls 1837
    /// (32 × 28, 2 from the top) and split menu 1873; all 32 wide.
    func testPageBarButtonsAtTheMeasuredPositions() {
        let bar = CGRect(x: 276, y: 10, width: 1634, height: 32)
        let items = WebToolbarItems.make(role: .page, isToolbarShown: true, showsSidebarButton: false)
        XCTAssertEqual(items.leading, [.back, .forward, .reload])
        XCTAssertEqual(items.trailing, [.siteControls, .splitMenu])
        let layout = WebToolbarLayout(barFrame: bar, items: items, domainTextWidth: 80, showsInsecureLock: false)
        XCTAssertEqual(layout.frame(of: .back), CGRect(x: 281, y: 14, width: 32, height: 24))
        XCTAssertEqual(layout.frame(of: .forward)?.minX, 318)
        XCTAssertEqual(layout.frame(of: .reload)?.minX, 355)
        XCTAssertEqual(layout.frame(of: .siteControls), CGRect(x: 1837, y: 12, width: 32, height: 28))
        XCTAssertEqual(layout.frame(of: .splitMenu), CGRect(x: 1873, y: 14, width: 32, height: 24))
    }

    /// 06 §17.2: sidebar hidden: show sidebar · back · forward · reload at x 15 / 52 / 89 / 126.
    func testHiddenSidebarLeadsWithShowSidebar() {
        let bar = CGRect(x: 10, y: 10, width: 1900, height: 32)
        let items = WebToolbarItems.make(role: .page, isToolbarShown: true, showsSidebarButton: true)
        XCTAssertEqual(items.leading, [.showSidebar, .back, .forward, .reload])
        let layout = WebToolbarLayout(barFrame: bar, items: items, domainTextWidth: 80, showsInsecureLock: false)
        XCTAssertEqual([WebToolbarItem.showSidebar, .back, .forward, .reload].compactMap { layout.frame(of: $0)?.minX }, [15, 52, 89, 126])
    }

    /// 06 §17.2: the center group (copy link, http lock, domain, two hidden spacers) is centered
    /// on the panel, not the window: panel center 1093, group 1014–1172 (158 = 4 × 24 + 62).
    func testCenterGroupIsCenteredOnThePanel() {
        let bar = CGRect(x: 276, y: 10, width: 1634, height: 32)
        let items = WebToolbarItems.make(role: .page, isToolbarShown: true, showsSidebarButton: false)
        let insecure = WebToolbarLayout(barFrame: bar, items: items, domainTextWidth: 62, showsInsecureLock: true)
        XCTAssertEqual(insecure.centerGroupFrame.midX, 1093)
        XCTAssertEqual(insecure.centerGroupFrame.minX, 1014)
        XCTAssertEqual(insecure.centerGroupFrame.maxX, 1172)
        XCTAssertEqual(insecure.copyLinkFrame.minX, 1014)
        XCTAssertEqual(insecure.lockFrame?.minX, 1038)
        XCTAssertEqual(insecure.domainFrame.minX, 1062)
        XCTAssertEqual(insecure.domainFrame.height, 16)
        let secure = WebToolbarLayout(barFrame: bar, items: items, domainTextWidth: 62, showsInsecureLock: false)
        XCTAssertNil(secure.lockFrame, "https shows no lock")
        XCTAssertEqual(secure.centerGroupFrame.midX, 1093)
        // 06 §17.5: hover pill = text + 12 wide, 23 tall, around the text only.
        XCTAssertEqual(secure.domainHoverFrame.width, 62 + 12)
        XCTAssertEqual(secure.domainHoverFrame.height, 23)
        XCTAssertEqual(secure.domainHoverFrame.minX, secure.domainFrame.minX - 6)
    }

    /// 06 §17.2: a long full URL is truncated so the group never reaches the side buttons.
    func testLongTextStaysClearOfTheButtons() {
        let bar = CGRect(x: 0, y: 0, width: 500, height: 32)
        let items = WebToolbarItems.make(role: .page, isToolbarShown: true, showsSidebarButton: false)
        let layout = WebToolbarLayout(barFrame: bar, items: items, domainTextWidth: 2000, showsInsecureLock: true)
        XCTAssertGreaterThan(layout.centerGroupFrame.minX, layout.frame(of: .reload)!.maxX)
        XCTAssertLessThan(layout.centerGroupFrame.maxX, layout.frame(of: .siteControls)!.minX)
        XCTAssertEqual(layout.centerGroupFrame.midX, 250, accuracy: 0.001)
    }

    /// 06 §17.6: the active split pane adds reload, site controls, the split menu and the close ✕
    /// at the far right (split menu 32 left of ✕, site controls 36 left of that); an inactive pane
    /// has back, forward, the domain group and ✕ only.
    func testSplitPaneItems() {
        let active = WebToolbarItems.make(role: .pane(isActive: true), isToolbarShown: true, showsSidebarButton: false)
        XCTAssertEqual(active.leading, [.back, .forward, .reload])
        XCTAssertEqual(active.trailing, [.siteControls, .splitMenu, .closePane])
        let inactive = WebToolbarItems.make(role: .pane(isActive: false), isToolbarShown: true, showsSidebarButton: false)
        XCTAssertEqual(inactive.leading, [.back, .forward])
        XCTAssertEqual(inactive.trailing, [.closePane])
        // Right pane of a 1634 panel: 812 wide from x 1098 (10 pt gap). ✕ at 1873, menu 1841, site 1805.
        let layout = WebToolbarLayout(barFrame: CGRect(x: 1098, y: 10, width: 812, height: 32), items: active,
                                      domainTextWidth: 60, showsInsecureLock: false)
        XCTAssertEqual(layout.frame(of: .closePane)?.minX, 1873)
        XCTAssertEqual(layout.frame(of: .splitMenu)?.minX, 1841)
        XCTAssertEqual(layout.frame(of: .siteControls)?.minX, 1805)
    }

    /// 06 §17.1, §5: toolbar off, the single page has no bar and split panes keep the §5 top bar.
    func testToolbarOffItems() {
        XCTAssertEqual(WebToolbarItems.make(role: .page, isToolbarShown: false, showsSidebarButton: true),
                       WebToolbarItems(leading: [], trailing: []))
        XCTAssertEqual(WebToolbarItems.make(role: .pane(isActive: true), isToolbarShown: false, showsSidebarButton: true),
                       WebToolbarItems(leading: [.back, .forward], trailing: [.closePane]))
    }

    // MARK: Text

    /// 06 §17.2: the host by default; with "Show full URL when Toolbar is enabled" the address
    /// without its scheme. http shows the lock, https none.
    func testDomainAndFullURLText() {
        let http = WebToolbarState(tabID: UUID(), url: URL(string: "http://10.20.0.59:8716/black.html"))
        XCTAssertEqual(http.displayText(showsFullURL: false), "10.20.0.59")
        XCTAssertEqual(http.displayText(showsFullURL: true), "10.20.0.59:8716/black.html")
        XCTAssertTrue(http.showsInsecureLock)
        let https = WebToolbarState(tabID: UUID(), url: URL(string: "https://example.com/a?b=1"))
        XCTAssertEqual(https.displayText(showsFullURL: false), "example.com")
        XCTAssertEqual(https.displayText(showsFullURL: true), "example.com/a?b=1")
        XCTAssertFalse(https.showsInsecureLock)
        XCTAssertEqual(WebToolbarState(tabID: nil, url: nil).displayText(showsFullURL: true), SidebarURLBoxContent.placeholderText)
    }

    // MARK: Setting

    /// 06 §17.1: Show Toolbar / Hide Toolbar, global for every window, stored per device.
    func testToggleIsGlobalAndPersisted() {
        let suite = "openarc.tests.webToolbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let first = makeModel(preferences: preferences)
        let second = ShellModel(controller: first.controller, window: WindowUIState(selectedSpaceID: first.selectedSpaceID))
        XCTAssertFalse(first.isWebToolbarShown)
        XCTAssertEqual(first.webToolbar.menuTitle, "Show Toolbar")
        first.toggleWebToolbar()
        XCTAssertTrue(second.isWebToolbarShown, "every window follows")
        XCTAssertEqual(second.webToolbar.menuTitle, "Hide Toolbar")
        XCTAssertTrue(second.windowLayout(size: reference).isWebToolbarShown)
        XCTAssertTrue(preferences.showsWebToolbar)
        XCTAssertTrue(WebToolbarSettings(preferences: AppPreferences(defaults: defaults)).isShown, "survives a relaunch")
        // An incognito window shares the setting. inferred.
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: first.controller)
        XCTAssertTrue(incognito.isWebToolbarShown)
        incognito.stop(); second.stop(); first.stop()
    }

    /// 03 §Advanced, 06 §17.2: "Show full URL when Toolbar is enabled" is live and persisted.
    func testFullURLSettingIsLive() {
        let preferences = AppPreferences.inMemory()
        let model = makeModel(preferences: preferences)
        XCTAssertTrue(SettingsCatalog.control("advanced.showFullURL").isEnabled)
        model.webToolbar.showsFullURL = true
        XCTAssertTrue(preferences.showsFullURLInWebToolbar)
        model.stop()
    }

    /// The Library keeps its own layout while the toolbar is on. inferred.
    func testLibraryHasNoToolbar() {
        let model = makeModel()
        model.toggleWebToolbar()
        XCTAssertTrue(model.windowLayout(size: reference).isWebToolbarShown)
        model.openLibrary()
        XCTAssertFalse(model.windowLayout(size: reference).isWebToolbarShown)
        model.stop()
    }

    // MARK: Actions

    private func selectExample(_ model: ShellModel) async throws -> UUID {
        let id = try XCTUnwrap(model.workspace.tabs.values.first { $0.url?.host == "example.com" }?.id)
        try await model.activate(tabID: id)
        return id
    }

    /// 06 §17.3: clicking the domain opens the centered command bar with the full URL selected,
    /// the same as ⌘L.
    func testDomainOpensCenteredCommandBar() async throws {
        let model = makeModel()
        model.toggleWebToolbar()
        let id = try await selectExample(model)
        model.webToolbarOpenAddress(id)
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertNil(model.commandBarPaneTabID, "centered on the window, not in a pane")
        XCTAssertEqual(model.commandBar.mode, .currentTab)
        XCTAssertEqual(model.commandBar.queryText, "https://example.com")
        XCTAssertGreaterThan(model.commandBar.selectAllRequestID, 0, "the URL is selected")
        model.stop()
    }

    /// 06 §17.3: copy link copies the full URL, with its scheme.
    func testCopyLinkCopiesFullURL() async throws {
        let model = makeModel()
        let pasteboard = RecordingPasteboardWriter()
        model.siteControls.pasteboard = pasteboard
        let id = try await selectExample(model)
        XCTAssertTrue(model.webToolbarCopyLink(id))
        XCTAssertEqual(pasteboard.written, [URL(string: "https://example.com")!])
        XCTAssertFalse(model.webToolbarCopyLink(nil))
        model.stop()
    }

    /// 06 §17.3: the lock and the site controls button open the Site Control Center.
    func testSiteControlsButtonOpensTheBubble() async throws {
        let model = makeModel()
        let id = try await selectExample(model)
        model.webToolbarShowSiteControls(id)
        XCTAssertTrue(model.siteControls.isPresented)
        XCTAssertEqual(model.siteControls.tabID, id)
        model.webToolbarShowSiteControls(id)
        XCTAssertFalse(model.siteControls.isPresented, "a second click closes it")
        model.stop()
    }

    /// 06 §17.3: the split menu adds the new pane on the chosen side (Right / Left side by side,
    /// Top / Bottom stacked) and opens the command bar in it, like ⌃⇧=.
    func testSplitMenuAddsPaneOnEachSide() async throws {
        for placement in WebToolbarSplitPlacement.allCases {
            let model = makeModel()
            let base = try await selectExample(model)
            model.addSplit(placement, beside: base)
            await model.sidebar.settleEngineWork()
            let layout = try XCTUnwrap(model.activeSplitLayout, placement.rawValue)
            let newTab = try XCTUnwrap(model.selectedTabID)
            XCTAssertNotEqual(newTab, base)
            guard case .split(let axis, let children) = layout.root else { return XCTFail("no split") }
            XCTAssertEqual(axis, placement == .right || placement == .left ? .horizontal : .vertical, placement.rawValue)
            let order = children.compactMap { if case .pane(let id) = $0.node { return id } else { return nil } }
            XCTAssertEqual(order, placement == .right || placement == .bottom ? [base, newTab] : [newTab, base], placement.rawValue)
            XCTAssertEqual(model.commandBarPaneTabID, newTab, "the command bar opens in the new pane")
            model.stop()
        }
        XCTAssertEqual(WebToolbarSplitPlacement.allCases.map(\.title),
                       ["Add Right Split", "Add Left Split", "Add Top Split", "Add Bottom Split"])
    }

    /// 06 §17.2: the show-sidebar button brings the sidebar back pinned.
    func testShowSidebarButton() {
        let model = makeModel()
        model.toggleWebToolbar()
        model.toggleSidebar()
        XCTAssertEqual(model.webToolbarItems(role: .page).leading.first, .showSidebar)
        model.webToolbarShowSidebar()
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertEqual(model.webToolbarItems(role: .page).leading.first, .back)
        model.stop()
    }

    /// 06 §17.6: in a split, a pane's bar acts on its own tab (back, ✕) and its domain opens the
    /// pane command bar.
    func testPaneBarActsOnItsTab() async throws {
        let model = makeModel()
        model.toggleWebToolbar()
        let base = try await selectExample(model)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        model.dismissCommandBar()
        let right = try XCTUnwrap(model.selectedTabID)
        XCTAssertTrue(model.webToolbarState(for: right).isActive)
        XCTAssertFalse(model.webToolbarState(for: base).isActive)
        model.webToolbarOpenAddress(base)
        XCTAssertEqual(model.commandBarPaneTabID, base)
        model.dismissCommandBar()
        model.webToolbarClosePane(base)
        await model.sidebar.settleEngineWork()
        XCTAssertFalse(model.hasActiveSplit)
        XCTAssertEqual(model.selectedTabID, right)
        model.stop()
    }
}
