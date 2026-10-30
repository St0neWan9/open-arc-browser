import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
@testable import OpenArcShell

/// B111 (update-ready pill above the dock) and B112 (Create Space button colors).
/// Spec: docs/arc-spec/07-design-system.md §8.6 (E27, observed): the pill at x 8–268, ≈ 22 pt tall,
/// fully rounded, the sidebar color lightened (#6C9174 → #7D9C84), white ≈ 12 pt medium text, right
/// above the dock; the Create Space button ≈ 39 pt tall, x 8–268, radius ≈ 8, #A6A8F5 disabled /
/// #2848FB enabled with no picked color, disabled ≈ #D88E64 with the orange preset p1-5.
@MainActor
final class SidebarAccessoryTests: XCTestCase {
    /// Largest per-channel difference, in 0–255 levels.
    private func distance(_ a: RGBAColor, _ b: RGBAColor) -> Double {
        max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue)) * 255
    }

    // MARK: B111 pill geometry and color

    /// [07 §8.6] observed: x 8–268, 22 pt tall, directly above the dock; hidden without an update.
    func testUpdatePillFrameSitsAboveTheDock() throws {
        XCTAssertNil(SidebarLayout().updatePillFrame, "hidden while no update is ready")
        let layout = SidebarLayout(showsUpdatePill: true)
        let pill = try XCTUnwrap(layout.updatePillFrame)
        XCTAssertEqual(pill.minX, 8)
        XCTAssertEqual(pill.maxX, 268)
        XCTAssertEqual(pill.height, 22)
        XCTAssertEqual(layout.dockFrame.minY - pill.maxY, CGFloat(UpdatePillTokens.bottomGap))
        XCTAssertLessThan(pill.maxY, layout.dockFrame.minY)
        // The list ends above the pill, so its last rows are not covered.
        XCTAssertLessThanOrEqual(layout.listBottom, pill.minY)
        XCTAssertEqual(SidebarLayout().listBottom, SidebarLayout().dockFrame.minY)
    }

    /// [07 §8.6] observed sample: sage sidebar #6C9174 → pill #7D9C84 (rule inferred: + 11 % white).
    func testUpdatePillColorLightensTheSidebar() {
        let pill = UpdatePillTokens.fill(over: RGBAColor(hex: 0x6C9174))
        XCTAssertLessThanOrEqual(distance(pill, RGBAColor(hex: 0x7D9C84)), 1.5)
        XCTAssertEqual(UpdatePillTokens.titleStyle.size, 12)
        XCTAssertEqual(UpdatePillTokens.titleStyle.weight, .medium)
        XCTAssertEqual(UpdatePillTokens.titleColor, RGBAColor(hex: 0xFFFFFF))
        XCTAssertEqual(SidebarUpdatePill.title, "New Open Arc Version Available")
    }

    // MARK: B111 update-ready state

    /// The pill follows the observable ready state; a click installs through the updater's
    /// immediate-install hook, else opens the updater's own prompt. [07 §8.6] behavior inferred.
    func testUpdateReadyStateDrivesTheInstall() {
        let checker = RecordingUpdateChecker()
        let model = UpdatesModel(checker: checker, preferences: .inMemory())
        XCTAssertFalse(model.isUpdateReady)
        model.installReadyUpdate()
        XCTAssertEqual(checker.checkCount, 0, "nothing to install")

        var installs = 0
        model.noteUpdateReady(installNow: { installs += 1 })
        XCTAssertTrue(model.isUpdateReady)
        model.installReadyUpdate()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(checker.checkCount, 0)

        model.noteUpdateReady()
        model.installReadyUpdate()
        XCTAssertEqual(installs, 1)
        XCTAssertEqual(checker.checkCount, 1, "without a hook the updater shows its install prompt")

        model.clearReadyUpdate()
        XCTAssertFalse(model.isUpdateReady)
        model.installReadyUpdate()
        XCTAssertEqual(checker.checkCount, 1)
    }

    // MARK: B112 Create Space button

    /// [07 §8.6] observed: ≈ 39 pt tall, sidebar content width (x 8–268), radius ≈ 8 (a token,
    /// not the former literal 10).
    func testCreateButtonGeometry() {
        XCTAssertEqual(CreateSpaceButtonTokens.height, 39)
        XCTAssertEqual(CreateSpaceButtonTokens.cornerRadius, 8)
        XCTAssertEqual(CreateSpaceButtonTokens.horizontalInset, 8)
        XCTAssertEqual(CreateSpaceButtonTokens.width, 260)
    }

    /// [07 §8.6] observed, no picked color: disabled #A6A8F5 (empty name), enabled #2848FB.
    func testCreateButtonColorsWithoutAPickedColor() {
        let model = makeModel()
        model.spaceFlow.beginCreate()
        XCTAssertFalse(model.spaceFlow.canCreate)
        XCTAssertLessThanOrEqual(distance(model.spaceFlow.createButtonFill, RGBAColor(hex: 0xA6A8F5)), 3)
        model.spaceFlow.draftName = "Work 2"
        XCTAssertTrue(model.spaceFlow.canCreate)
        XCTAssertLessThanOrEqual(distance(model.spaceFlow.createButtonFill, RGBAColor(hex: 0x2848FB)), 3)
        model.stop()
    }

    /// [07 §8.6]: with the orange preset p1-5 (#FF8558) the disabled fill follows the theme
    /// (observed ≈ #D88E64; our rule is inferred, ≤ 6/255). The enabled fill with a picked color is
    /// unknown: ours stays the derived `primaryButtonFill`.
    func testCreateButtonColorsWithAPickedColor() {
        let model = makeModel()
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftTheme.colors = [RGBAColor(hex: 0xFF8558)]
        XCTAssertLessThanOrEqual(distance(model.spaceFlow.createButtonFill, RGBAColor(hex: 0xD88E64)), 6)
        model.spaceFlow.draftName = "Orange"
        let palette = ThemeDerivation.palette(forStyle: model.spaceFlow.draftTheme.style, systemAppearance: .light)
        XCTAssertEqual(model.spaceFlow.createButtonFill, palette.primaryButtonFill)
        model.stop()
    }

    /// The disabled rule reproduces both observed samples from their window colors. inferred.
    func testDisabledRuleFitsBothSamples() {
        let none = ThemeDerivation.palette(for: nil, appearance: .light).windowBackground
        XCTAssertLessThanOrEqual(distance(CreateSpaceButtonTokens.disabledFill(window: none), RGBAColor(hex: 0xA6A8F5)), 6)
        let orange = ThemeDerivation.lightWindow(RGBAColor(hex: 0xFF8558))
        XCTAssertLessThanOrEqual(distance(CreateSpaceButtonTokens.disabledFill(window: orange), RGBAColor(hex: 0xD88E64)), 6)
    }

    private func makeModel() -> ShellModel {
        let f = SidebarFixture()
        var counter = 1000
        return ShellModel(dependencies: .fake(), workspace: f.ws, now: { f.now }, makeID: {
            counter += 1
            return SidebarFixture.id(counter)
        })
    }
}

/// An update checker that records checks and never touches the network.
@MainActor
private final class RecordingUpdateChecker: UpdateChecker {
    var unavailableReason: String? { nil }
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var automaticallyDownloadsUpdates = false
    var canCheckForUpdatesDidChange: (@MainActor (Bool) -> Void)?
    private(set) var checkCount = 0

    func start() {}
    func checkForUpdates() { checkCount += 1 }
}
