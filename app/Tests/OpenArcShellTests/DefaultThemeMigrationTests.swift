import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcPersistence
import OpenArcSyncAPI
@testable import OpenArcShell

/// B98: a Space with no picked color looks like Arc's default ([07 §8.5] observed), and themes
/// that still hold the old blue placeholder move to that default at launch.
@MainActor
final class DefaultThemeMigrationTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("b98-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func preferences() -> AppPreferences { .inMemory() }

    private func launch(with stored: WorkspaceState, preferences: AppPreferences) async throws -> WorkspaceController {
        let seed = WorkspaceStore(directory: directory)
        seed.submit(stored)
        try await seed.flush()
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(),
                                   persistence: WorkspaceStore(directory: directory), preferences: preferences)
        let controller = WorkspaceController(
            dependencies: deps, workspace: WorkspaceState(), now: { self.t0.addingTimeInterval(60) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    /// [07 §8.5] observed: the first-launch Space has no color dots and the light appearance.
    func testFirstLaunchSpaceUsesArcDefault() throws {
        let state = WorkspaceState.firstLaunch(now: t0)
        let space = try XCTUnwrap(state.allLiveSpaces.first)
        let theme = try XCTUnwrap(space.themeID.flatMap { state.themes[$0] })
        XCTAssertEqual(theme.colors, [])
        XCTAssertEqual(theme.appearance, .light)
        let palette = ThemeDerivation.palette(for: theme)
        XCTAssertEqual(palette.backgroundGradientColors, ThemeDerivation.defaultWindowStops)
    }

    /// Only the untouched placeholder theme moves; a picked color, and grain / brightness, stay.
    func testPlaceholderThemesMoveToArcDefault() async throws {
        let profile = UUID(), placeholder = UUID(), picked = UUID(), a = UUID(), b = UUID()
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "Default", now: t0)
        s = TreeOps.createTheme(s, id: placeholder, style: ThemeStyle(appearance: .automatic,
                                colors: [SpaceFlowLocalTokens.legacyPlaceholderColor], grain: 0.3), now: t0)
        s = TreeOps.createTheme(s, id: picked, style: ThemeStyle(colors: [RGBAColor(hex: 0xF25E6C)]), now: t0)
        s = try TreeOps.createSpace(s, id: a, profileID: profile, name: "A", themeID: placeholder, now: t0)
        s = try TreeOps.createSpace(s, id: b, profileID: profile, name: "B", themeID: picked, afterSpaceID: a, now: t0)

        let controller = try await launch(with: s, preferences: preferences())
        let moved = try XCTUnwrap(controller.workspace.themes[placeholder])
        XCTAssertEqual(moved.colors, [])
        XCTAssertEqual(moved.appearance, .light)
        XCTAssertEqual(moved.grain, 0.3)
        XCTAssertEqual(moved.meta.version, 2, "stamped through TreeOps so the change syncs")
        XCTAssertEqual(controller.workspace.themes[picked]?.colors, [RGBAColor(hex: 0xF25E6C)])
    }

    /// The pending first-launch Space is left alone: an edit would count as the user touching it
    /// (`FirstLaunchSpaceAdoption.isUntouched`).
    func testPendingFirstLaunchThemeIsLeftAlone() async throws {
        let profile = UUID(), theme = UUID(), space = UUID()
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "Default", now: t0)
        s = TreeOps.createTheme(s, id: theme, style: ThemeStyle(colors: [SpaceFlowLocalTokens.legacyPlaceholderColor]), now: t0)
        s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "Home", themeID: theme, now: t0)
        let prefs = preferences()
        prefs.firstLaunchSpaceID = space

        let controller = try await launch(with: s, preferences: prefs)
        XCTAssertEqual(controller.workspace.themes[theme]?.colors, [SpaceFlowLocalTokens.legacyPlaceholderColor])
        XCTAssertEqual(controller.workspace.themes[theme]?.meta.version, 1)
    }
}
