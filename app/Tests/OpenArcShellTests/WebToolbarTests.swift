import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// The web toolbar, View ▸ Show Toolbar (plan B43; colors plan B45). Every test names
/// `docs/arc-spec/06-flows.md` §17 (E16; §17.4 colors rewritten by E18; observed unless noted) and
/// `04 §网页工具栏`.
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

    // MARK: Colors (plan B45, 06 §17.4 as rewritten by E18)

    /// 06 §17.4: the bar copies the sampled page color exactly (no blend, no theme tint), the
    /// same in light and dark Spaces.
    func testBackgroundIsTheSampledPageColorExactly() {
        for color in [RGBAColor(hex: 0xFD0200), RGBAColor(hex: 0x00FE00), RGBAColor(hex: 0x0700FD),
                      RGBAColor(hex: 0x222222), RGBAColor(hex: 0xFFFFFF), RGBAColor(hex: 0x540000)] {
            for appearance in ResolvedAppearance.allCases {
                let colors = ThemeDerivation.webToolbarColors(appearance: appearance, source: .page(color),
                                                              panelBackground: RGBAColor(hex: 0x4D4253))
                XCTAssertEqual(colors.background, color, "\(appearance)")
            }
        }
    }

    /// 06 §17.4: on a classic scrollbar the bar uses the Space-mode neutral #F3F2F3 / #3E3E3E;
    /// with no page it is transparent over the panel fill.
    func testFallbackAndEmptyPane() {
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .light, source: .neutral), RGBAColor(hex: 0xF3F2F3))
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .dark, source: .neutral), RGBAColor(hex: 0x3E3E3E))
        XCTAssertEqual(ThemeDerivation.webToolbarBackground(appearance: .dark, source: .transparent).alpha, 0)
        // Ink on an empty pane follows the panel underneath: light ink on a dark panel.
        let empty = ThemeDerivation.webToolbarColors(appearance: .dark, source: .transparent, panelBackground: RGBAColor(hex: 0x4D4253))
        XCTAssertGreaterThan(ThemeDerivation.luminance(empty.icon), ThemeDerivation.luminance(RGBAColor(hex: 0x4D4253)))
    }

    /// 06 §17.4: the ink flips by the bar's luminance. White and green take translucent black,
    /// black, #222222, #540000 and pure red take translucent white; the threshold (unknown) lies
    /// between pure red (≈ 0.21) and pure green (≈ 0.72).
    func testInkFlipsByLuminance() {
        let threshold = ThemeDerivation.webToolbarInkLuminanceThreshold
        XCTAssertGreaterThan(threshold, ThemeDerivation.luminance(RGBAColor(hex: 0xFF0000)))
        XCTAssertLessThan(threshold, ThemeDerivation.luminance(RGBAColor(hex: 0x00FF00)))
        for light in [0xFFFFFF, 0x00FF00, 0xF3F2F3] {
            XCTAssertFalse(ThemeDerivation.webToolbarUsesLightInk(on: RGBAColor(hex: UInt32(light))), String(light, radix: 16))
        }
        for dark in [0x000000, 0x222222, 0x540000, 0xFD0200, 0x3E3E3E, 0x0700FD] {
            XCTAssertTrue(ThemeDerivation.webToolbarUsesLightInk(on: RGBAColor(hex: UInt32(dark))), String(dark, radix: 16))
        }
    }

    /// 06 §17.4, §17.5: the measured ink values (±3 levels): on white, domain ≈ #6B6B6B, icons
    /// ≈ #7D7D7D, disabled ≈ #C6C6C6; on green, icons ≈ #007300; on black, domain ≈ #CBCBCB; on
    /// #540000 ≈ #ECC6C4; on #FD0200 ≈ #FFCFC0.
    func testInkMatchesTheCapture() {
        func colors(_ hex: UInt32) -> WebToolbarColors {
            ThemeDerivation.webToolbarColors(appearance: .light, source: .page(RGBAColor(hex: hex)),
                                             panelBackground: RGBAColor(hex: 0xFFFFFF))
        }
        func assertNear(_ a: RGBAColor, _ hex: UInt32, _ tolerance: Double, _ label: String) {
            let b = RGBAColor(hex: hex)
            for (x, y) in [(a.red, b.red), (a.green, b.green), (a.blue, b.blue)] {
                XCTAssertEqual(x * 255, y * 255, accuracy: tolerance, label)
            }
        }
        let white = colors(0xFFFFFF)
        assertNear(white.domainText, 0x6B6B6B, 3, "domain on white")
        assertNear(white.icon, 0x7D7D7D, 3, "icon on white")
        assertNear(white.iconDisabled, 0xC6C6C6, 3, "disabled icon on white")
        assertNear(colors(0x00FF00).icon, 0x007300, 12, "icon on green")
        assertNear(colors(0x000000).domainText, 0xCBCBCB, 3, "domain on black")
        assertNear(colors(0x540000).domainText, 0xECC6C4, 16, "domain on #540000")
        assertNear(colors(0xFD0200).domainText, 0xFFCFC0, 16, "domain on #FD0200")
        // 06 §17.5: the hover block is ≈ 4 % darker than a white bar.
        assertNear(white.buttonHoverFill, 0xF5F5F5, 3, "hover on white")
    }

    /// 06 §17.4: the theme's hue does not reach the toolbar: a red and a purple theme give the
    /// same bar for the same page sample.
    func testToolbarIgnoresThemeHue() {
        let red = ThemeDerivation.palette(for: Theme(id: UUID(), colors: [RGBAColor(hex: 0xE03030)], now: t0), appearance: .light)
        let purple = ThemeDerivation.palette(for: Theme(id: UUID(), colors: [RGBAColor(hex: 0x8E7CC3)], now: t0), appearance: .light)
        XCTAssertNotEqual(red.windowBackground, purple.windowBackground)
        let sample = WebToolbarBackgroundSource.page(RGBAColor(hex: 0x00FE00))
        XCTAssertEqual(ThemeDerivation.webToolbarColors(appearance: .light, source: sample, panelBackground: red.webPanelBackground),
                       ThemeDerivation.webToolbarColors(appearance: .light, source: sample, panelBackground: purple.webPanelBackground))
    }

    /// 06 §17.4: the bar follows the engine's sample of each finished load; a scrollbar sample
    /// falls back to the neutral; no page is transparent. Split panes each use their own page.
    func testBarFollowsTheEngineSamplePerPane() async throws {
        let model = makeModel()
        model.toggleWebToolbar()
        let base = try await selectExample(model)
        let live = try XCTUnwrap(model.sidebar.liveTab(for: base) as? FakeTab)
        XCTAssertEqual(model.webToolbarBackgroundSource(for: base), .neutral, "not sampled yet (inferred)")
        live.simulatePageTopColor(.color(RGBAColor(hex: 0xFD0200)))
        try await waitUntil { model.webToolbarBackgroundSource(for: base) == .page(RGBAColor(hex: 0xFD0200)) }
        XCTAssertEqual(model.webToolbarColors(for: base).background, RGBAColor(hex: 0xFD0200))
        live.simulatePageTopColor(.scrollbar)
        try await waitUntil { model.webToolbarBackgroundSource(for: base) == .neutral }
        XCTAssertEqual(model.webToolbarColors(for: base).background, RGBAColor(hex: 0xF3F2F3))
        XCTAssertEqual(model.webToolbarBackgroundSource(for: nil), .transparent)

        live.simulatePageTopColor(.color(RGBAColor(hex: 0xFBFBFB)))
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        model.dismissCommandBar()
        let right = try XCTUnwrap(model.selectedTabID)
        XCTAssertEqual(model.webToolbarBackgroundSource(for: right), .transparent, "a new empty pane")
        try await waitUntil { model.webToolbarBackgroundSource(for: base) == .page(RGBAColor(hex: 0xFBFBFB)) }
        model.stop()
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
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

    /// 06 §17.7 (B59): with the toolbar off, the sidebar URL box shows the toolbar's red
    /// struck-through lock before the domain on http pages only, in the leading 24 pt cell at x 14
    /// with the domain from x 41; clicking it opens the Site Control Center (06 §17.3).
    func testSidebarURLBoxShowsInsecureLockOnHTTP() async throws {
        let model = makeModel()
        XCTAssertFalse(model.webToolbar.isShown)
        XCTAssertTrue(SidebarURLBoxContent.showsInsecureLock(url: URL(string: "http://info.cern.ch")))
        XCTAssertFalse(SidebarURLBoxContent.showsInsecureLock(url: URL(string: "https://example.com")))
        XCTAssertFalse(SidebarURLBoxContent.showsInsecureLock(url: nil))
        XCTAssertEqual(WebToolbarState(tabID: nil, url: URL(string: "http://info.cern.ch")).showsInsecureLock, true,
                       "the toolbar and the sidebar share one rule")

        _ = try await selectExample(model)
        XCTAssertFalse(model.sidebar.urlBoxShowsInsecureLock, "https shows no lock")

        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "http://info.cern.ch/hypertext/WWW/TheProject.html")))
        let id = try XCTUnwrap(opened)
        XCTAssertEqual(model.sidebar.selectedTabID, id)
        XCTAssertEqual(model.sidebar.urlBoxContent, .domain("info.cern.ch", isSecure: false))
        XCTAssertTrue(model.sidebar.urlBoxShowsInsecureLock)
        XCTAssertEqual(Metrics.Sidebar.addressFieldIconFrame, Rect2D(x: 14, y: 52, width: 24, height: 24))
        XCTAssertEqual(Metrics.Sidebar.addressFieldTextLeadingAfterIcon, 41)

        model.sidebar.requestFromMenu(.showSiteControls)
        XCTAssertTrue(model.siteControls.isPresented)
        XCTAssertEqual(model.siteControls.tabID, id)
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

    // MARK: Right-click menus (06 §28)

    private func menuItems<Content: View>(_ content: Content) throws -> [NSMenuItem] {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu.items
    }

    private func titles(_ items: [NSMenuItem]) -> [String] {
        items.filter { !$0.isHidden }.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    /// 06 §28 observed: Copy URL · Share ▸ · Capture… · Capture Full Page ‖ Manage Extensions… ‖
    /// Show Full URL · Hide Toolbar (Disable Shared Quotes is out of v1). No icons, no key hints.
    func testToolbarContextMenuItems() async throws {
        let model = makeModel()
        model.toggleWebToolbar()
        let id = try await selectExample(model)
        let items = try menuItems(WebToolbarContextMenu(model: model, tabID: id, settings: model.webToolbar))
        XCTAssertEqual(titles(items), ["Copy URL", "Share", "Capture…", "Capture Full Page", "—",
                                       "Manage Extensions…", "—", "Show Full URL", "Hide Toolbar"])
        // No item has an icon, Share ▸ included, so nothing indents a group (06 §28; B139).
        for item in items where !item.isSeparatorItem {
            XCTAssertNil(item.image, "\(item.title): no icon (06 §28)")
            XCTAssertEqual(item.keyEquivalent, "", "\(item.title): no key hint (06 §28)")
            XCTAssertEqual(item.indentationLevel, 0, "\(item.title): not indented (06 §28)")
        }
        let share = try XCTUnwrap(items.first { $0.title == "Share" })
        XCTAssertNotNil(share.submenu, "Share ▸ is a submenu (06 §28)")
        model.stop()
    }

    /// 06 §28 observed "Share ▸"; its services are the system share services for the URL
    /// (06 §21.5 observed "系统分享服务"); without a URL it offers none. B139 (F5-48).
    func testToolbarShareMenuListsSystemServices() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com"))
        let services = WebToolbarShareServices.services(for: url)
        XCTAssertTrue(services.allSatisfy { $0.canPerform(withItems: [url]) })
        let items = try menuItems(WebToolbarShareMenu(url: url))
        let share = try XCTUnwrap(items.first)
        XCTAssertEqual(share.title, "Share")
        XCTAssertNil(share.image, "Share ▸ carries no icon (06 §28)")
        XCTAssertEqual(share.submenu?.items.map(\.title), services.map(\.menuItemTitle))
        XCTAssertTrue(share.submenu?.items.allSatisfy { $0.isEnabled } ?? false)

        // Without a URL there is nothing to share. (`NSHostingMenu` does not carry SwiftUI's
        // `.disabled` onto a submenu item, so the empty submenu is what can be checked here.)
        let none = try XCTUnwrap(menuItems(WebToolbarShareMenu(url: nil)).first)
        XCTAssertEqual(none.title, "Share")
        XCTAssertEqual(none.submenu?.items.count ?? 0, 0)
    }

    /// 06 §28: the menu's actions — Copy URL copies the bar's URL, Show Full URL toggles the
    /// full-URL display (title "Hide Full URL" while on, inferred), Hide Toolbar turns it off,
    /// Manage Extensions… opens the extensions page.
    func testToolbarContextMenuActions() async throws {
        let model = makeModel()
        let pasteboard = RecordingPasteboardWriter()
        model.siteControls.pasteboard = pasteboard
        model.toggleWebToolbar()
        let id = try await selectExample(model)

        let copy = try XCTUnwrap(menuItems(WebToolbarContextMenu(model: model, tabID: id, settings: model.webToolbar)).first)
        XCTAssertEqual(copy.title, "Copy URL")
        model.webToolbarCopyLink(id)
        XCTAssertEqual(pasteboard.written, [URL(string: "https://example.com")!])

        XCTAssertFalse(model.webToolbar.showsFullURL)
        XCTAssertEqual(model.webToolbar.fullURLMenuTitle, "Show Full URL")
        model.webToolbar.showsFullURL.toggle()
        XCTAssertTrue(model.webToolbar.showsFullURL, "the toolbar now shows the full URL (06 §17.2)")
        XCTAssertEqual(model.webToolbar.fullURLMenuTitle, "Hide Full URL")
        let fullURLTitles = try titles(menuItems(WebToolbarContextMenu(model: model, tabID: id, settings: model.webToolbar)))
        XCTAssertTrue(fullURLTitles.contains("Hide Full URL"))

        let tabsBefore = model.workspace.today(spaceID: try XCTUnwrap(model.selectedSpaceID)).count
        model.openManageExtensions()
        XCTAssertEqual(model.workspace.today(spaceID: try XCTUnwrap(model.selectedSpaceID)).count, tabsBefore + 1)

        model.webToolbar.isShown = false
        XCTAssertFalse(model.isWebToolbarShown, "Hide Toolbar = View ▸ Show Toolbar off (06 §28)")
        model.stop()
    }

    /// 06 §4 observed (E34): the URL box and the toolbar drop only a leading "www."; other
    /// subdomains and multi-part suffixes stay. The full URL keeps it.
    func testDomainDropsOnlyLeadingWWW() throws {
        let cases = ["https://www.github.com/": "github.com", "https://www.apple.com/mac/": "apple.com",
                     "https://www.bbc.co.uk/news": "bbc.co.uk", "https://docs.github.com/en": "docs.github.com",
                     "https://news.ycombinator.com/": "news.ycombinator.com"]
        for (raw, shown) in cases {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(SidebarURLBoxContent.make(url: url), .domain(shown, isSecure: true), raw)
            XCTAssertEqual(WebToolbarText.display(url: url, showsFullURL: false), shown, raw)
        }
        let full = try XCTUnwrap(URL(string: "https://www.github.com/a"))
        XCTAssertEqual(WebToolbarText.display(url: full, showsFullURL: true), "www.github.com/a")
    }

    /// 06 §28 observed (E33): right-click on the sidebar URL box while a page is open shows the
    /// URL menu — Copy URL · Share ▸ · Capture… · Capture Full Page ‖ Show as Toolbar (Disable
    /// Shared Quotes is out of v1). No icons, no key hints. Show as Toolbar turns the toolbar on;
    /// Copy URL copies the page URL.
    func testSidebarURLBoxContextMenu() async throws {
        let model = makeModel()
        let pasteboard = RecordingPasteboardWriter()
        model.siteControls.pasteboard = pasteboard
        let id = try await selectExample(model)
        let items = try menuItems(SidebarURLBoxMenu(viewModel: model.sidebar, tabID: id))
        XCTAssertEqual(titles(items), ["Copy URL", "Share", "Capture…", "Capture Full Page", "—", "Show as Toolbar"])
        for item in items where !item.isSeparatorItem {
            XCTAssertNil(item.image, "\(item.title): no icon (06 §28)")
            XCTAssertEqual(item.keyEquivalent, "", "\(item.title): no key hint (06 §28)")
        }
        XCTAssertNotNil(items.first { $0.title == "Share" }?.submenu, "Share ▸ is a submenu (06 §28)")

        model.sidebar.requestFromMenu(.copyURL(tabID: id))
        XCTAssertEqual(pasteboard.written, [URL(string: "https://example.com")!])
        XCTAssertFalse(model.isWebToolbarShown)
        model.sidebar.requestFromMenu(.showToolbar)
        XCTAssertTrue(model.isWebToolbarShown, "Show as Toolbar = View ▸ Show Toolbar on (06 §28)")
        model.stop()
    }

    /// 06 §28 observed: right-click on the sidebar top (traffic-light row, and the URL box without
    /// a page) opens the current Space's menu, the same items as the Space name's "⋯".
    func testSidebarTopContextMenuIsTheSpaceMenu() throws {
        let model = makeModel()
        let items = try menuItems(SidebarSpaceMenu(viewModel: model.sidebar))
        XCTAssertEqual(titles(items), ["Change Space Icon…", "Rename Space…", "Edit Theme Color…", "Set Profile", "—",
                                       "New Folder", "Live Folders", "—", "Share Space…",
                                       "Export “\(try XCTUnwrap(model.selectedSpace?.name))” into Folder", "—",
                                       "Manage Spaces…", "—", "Delete Space"])
        XCTAssertTrue(items.allSatisfy { $0.isSeparatorItem || $0.image == nil }, "no icons (06 §28)")
        model.stop()
    }
}
