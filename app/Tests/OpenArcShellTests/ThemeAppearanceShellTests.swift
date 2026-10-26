import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B21: per-Space light / dark / automatic, View ▸ Appearance, the pages' color scheme and
/// the grain overlay. Spec: docs/arc-spec/04-visual-metrics.md §暗色模式 (E7) observed: "dark" is a
/// per-Space theme setting; automatic follows the system; floating panels go dark; pages get
/// `prefers-color-scheme: dark`; View ▸ Appearance (Automatic / Light / Dark, line "Websites,
/// Easels, and Notes will use:", [01 §View] observed) governs web content. How the menu and the
/// Space setting combine is inferred.
@MainActor
final class ThemeAppearanceShellTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private var engine: FakeEngine!
    private var system: ManualSystemAppearance!
    private var preferences: AppPreferences!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        system = ManualSystemAppearance(.light)
        preferences = .inMemory()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: preferences, systemAppearance: system),
            workspace: .demo(now: t0),
            now: { Date(timeIntervalSince1970: 100) },
            notificationCenter: NotificationCenter()
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
        system = nil
        preferences = nil
    }

    private var spaceID: UUID { model.selectedSpaceID! }

    /// Sets the selected Space's theme appearance through the theme bubble path.
    private func setAppearance(_ appearance: ThemeAppearance, grain: Double? = nil) {
        var draft = model.spaceFlow.themeDraft(of: spaceID)
        draft.appearance = appearance
        if let grain { draft.grain = grain }
        model.spaceFlow.applyThemeDraft(draft, to: spaceID)
    }

    private func openPage() async throws -> FakeTab {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: "https://example.com")))
        let id = try XCTUnwrap(opened)
        await model.controller.settleEngineWork()
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    // MARK: Palette per appearance

    /// Automatic follows the injected system appearance, and the window updates when it changes.
    func testAutomaticSpaceFollowsTheSystemAppearance() {
        XCTAssertEqual(model.workspace.themes.values.first?.appearance, .automatic)
        XCTAssertEqual(model.windowPalette.appearance, .light)
        let lightBackground = model.windowPalette.windowBackground

        system.set(.dark)
        XCTAssertEqual(model.controller.systemAppearance, .dark)
        XCTAssertEqual(model.windowPalette.appearance, .dark)
        XCTAssertNotEqual(model.windowPalette.windowBackground, lightBackground)
        XCTAssertEqual(model.windowPalette.commandBarBackground, RGBAColor(hex: 0x181818), "[07 §5] observed")

        setAppearance(.light)
        XCTAssertEqual(model.windowPalette.appearance, .light, "an explicit Light ignores the system")
        XCTAssertEqual(model.windowPalette.windowBackground, lightBackground)
    }

    /// The Dark segment makes the Space dark on a light system; Create Space stays light ([06 §1]).
    func testDarkSegmentMakesTheSpaceDark() {
        setAppearance(.dark)
        XCTAssertTrue(model.windowPalette.isDark)
        XCTAssertEqual(model.sidebar.palette, ThemeDerivation.palette(for: model.sidebar.theme, appearance: .dark))
        model.spaceFlow.beginCreate()
        XCTAssertFalse(model.windowPalette.isDark, "the creation view uses the default light neutral theme")
        model.spaceFlow.cancelCreate()
    }

    /// Command bar row colors in a dark Space: near-white text, a theme mid tone selection, white
    /// selected text. [07 §3, §8] observed.
    func testCommandBarUsesTheDarkPalette() {
        setAppearance(.dark)
        let palette = model.windowPalette
        let colors = CommandBarRowColors(palette: palette)
        XCTAssertEqual(colors.text, palette.commandBarText.swiftUI)
        XCTAssertEqual(palette.commandBarText, RGBAColor(hex: 0xFFFFFF, alpha: 0.85), "[07 §3] white ≈ 85 %")
        XCTAssertEqual(colors.selectionFill, palette.commandBarSelection.swiftUI)
        XCTAssertEqual(colors.selectedText, RGBAColor(hex: 0xFFFFFF).swiftUI)
        XCTAssertNotEqual(palette.commandBarSelection, model.sidebar.theme?.colors.first, "muted, not the picked accent")
        // The panel lays out in both appearances.
        for appearance in [ThemeAppearance.light, .dark] {
            setAppearance(appearance)
            let host = NSHostingView(rootView: CommandBarView(viewModel: model.commandBar, palette: model.windowPalette))
            host.frame = CGRect(x: 0, y: 0, width: 800, height: 400)
            host.layoutSubtreeIfNeeded()
        }
    }

    /// Little Arc and the Library board follow the same palette rules.
    func testLittleArcAndLibraryUseTheResolvedPalette() {
        setAppearance(.dark)
        let littleArc = LittleArcModel(shell: model)
        XCTAssertTrue(littleArc.palette.isDark)
        littleArc.close()
        XCTAssertTrue(model.library.boardColumns.first { $0.space.id == spaceID }?.palette.isDark ?? false)
    }

    // MARK: Web content color scheme

    /// A page in a dark Space gets the dark scheme from its first load. [04 §dark mode] observed.
    func testNewTabInADarkSpaceStartsDark() async throws {
        setAppearance(.dark)
        let live = try await openPage()
        XCTAssertEqual(live.preferredColorScheme, .dark)
        XCTAssertEqual(live.colorSchemeChanges, [], "created dark, nothing to change")
    }

    /// Switching the Space's appearance, the system setting and View ▸ Appearance reach every live
    /// page, once per change, in order.
    func testColorSchemeChangesPropagateToLiveTabs() async throws {
        let live = try await openPage()
        XCTAssertEqual(live.preferredColorScheme, .light)

        setAppearance(.dark)
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.colorSchemeChanges, [.dark])

        model.webAppearance = .light   // View ▸ Appearance ▸ Light forces pages light
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.colorSchemeChanges, [.dark, .light])

        setAppearance(.automatic)
        model.webAppearance = .automatic
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.colorSchemeChanges, [.dark, .light], "automatic on a light system stays light")

        system.set(.dark)
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.colorSchemeChanges, [.dark, .light, .dark], "automatic follows the system")

        model.webAppearance = .dark
        await model.controller.settleEngineWork()
        XCTAssertEqual(live.colorSchemeChanges, [.dark, .light, .dark], "already dark: no extra call")
        XCTAssertEqual(live.preferredColorScheme, .dark)
    }

    /// View ▸ Appearance ▸ Dark makes pages of a light Space dark.
    func testWebAppearanceDarkOverridesALightSpace() async throws {
        setAppearance(.light)
        model.webAppearance = .dark
        let live = try await openPage()
        XCTAssertEqual(live.preferredColorScheme, .dark)
    }

    // MARK: View ▸ Appearance menu

    /// The choice is stored per device and survives a new preferences object; Automatic by default.
    func testWebAppearanceIsPersisted() throws {
        let suite = "openarc.tests.webAppearance.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let stored = AppPreferences(defaults: defaults)
        XCTAssertEqual(stored.webAppearance, .automatic)
        let shell = ShellModel(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: stored),
            workspace: .demo(now: t0),
            notificationCenter: NotificationCenter()
        )
        shell.webAppearance = .dark
        XCTAssertEqual(AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).webAppearance, .dark)
        shell.webAppearance = .light
        XCTAssertEqual(AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).webAppearance, .light)
        defaults.set("bogus", forKey: AppPreferences.webAppearanceKey)
        XCTAssertEqual(stored.webAppearance, .automatic, "an unknown value reads as the default")
        shell.stop()
    }

    /// Observed menu title, explanatory line and items. [01 §View]
    func testAppearanceMenuTexts() {
        XCTAssertEqual(WebAppearance.menuTitle, "Appearance")
        XCTAssertEqual(WebAppearance.menuExplanation, "Websites, Easels, and Notes will use:")
        XCTAssertEqual(WebAppearance.allCases.map(\.title), ["Automatic", "Light", "Dark"])
        let host = NSHostingView(rootView: AppearanceMenu(model: model))
        host.layoutSubtreeIfNeeded()
    }

    // MARK: Grain

    /// The overlay is drawn iff `Theme.grain` > 0.
    func testGrainOverlayPresentOnlyWithGrain() {
        XCTAssertFalse(WindowBackgroundView(palette: model.windowPalette).showsGrain)
        setAppearance(.automatic, grain: 0.5)
        XCTAssertEqual(model.windowPalette.grain, 0.5, accuracy: 1e-9)
        XCTAssertTrue(WindowBackgroundView(palette: model.windowPalette).showsGrain)
        XCTAssertNotNil(GrainTile.image)
        XCTAssertEqual(GrainTile.image?.width, GrainNoise.tileSize)
        let host = NSHostingView(rootView: WindowBackgroundView(palette: model.windowPalette).frame(width: 300, height: 200))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        host.layoutSubtreeIfNeeded()
        setAppearance(.automatic, grain: 0)
        XCTAssertFalse(WindowBackgroundView(palette: model.windowPalette).showsGrain)
    }
}
