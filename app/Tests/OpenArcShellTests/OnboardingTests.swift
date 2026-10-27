import Foundation
import XCTest
import SwiftUI
import AppKit
import OpenArcDesign
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// A default-browser service that records every request (D2 protocol).
@MainActor
private final class RecordingDefaultBrowserService: DefaultBrowserService {
    private(set) var requests: [String] = []
    private var handlers: [String: URL] = [:]
    let applicationURL = URL(fileURLWithPath: "/Applications/Open Arc.app", isDirectory: true)

    nonisolated init() {}

    func defaultApplication(toOpen url: URL) -> URL? { url.scheme.flatMap { handlers[$0] } }

    func setDefaultApplication(at appURL: URL, toOpenURLsWithScheme scheme: String) async throws {
        requests.append(scheme)
        handlers[scheme] = appURL
    }
}

/// D9: first-run onboarding. The behavior is our own: shown once on first launch, skippable from
/// every step, per-device completion flag in `ui-state.json`, and Help ▸ Show Welcome Again
/// (inferred). B53: the look follows the E6 capture, `docs/arc-spec/06-flows.md §27`.
@MainActor
final class OnboardingTests: XCTestCase {
    private nonisolated let directory: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openarc-d9-\(UUID().uuidString)", isDirectory: true)
    private let clock = Date(timeIntervalSince1970: 5_000)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeController(
        persistence: Bool = true,
        preferences: AppPreferences = .inMemory(),
        defaultBrowser: (any DefaultBrowserService)? = nil
    ) -> WorkspaceController {
        var counter = 9_000
        let deps = AppDependencies(
            engine: FakeEngine(),
            sync: DisabledSyncStore(),
            persistence: persistence ? WorkspaceStore(directory: directory) : nil,
            preferences: preferences,
            defaultBrowser: defaultBrowser
        )
        let controller = WorkspaceController(
            dependencies: deps, workspace: .firstLaunch(now: clock), now: { [clock] in clock.addingTimeInterval(60) },
            makeID: { counter += 1; return SidebarFixture.id(counter) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func openWindow(_ controller: WorkspaceController) -> ShellModel {
        let model = ShellModel.window(for: BrowserWindowRequest(kind: .restore), on: controller)
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// Quits the current controller (writes files) and launches a new one on the same directory.
    private func relaunch(_ controller: WorkspaceController, _ windows: [ShellModel]) async throws -> WorkspaceController {
        try await controller.flushPersistence()
        windows.forEach { $0.stop() }
        controller.stop()
        return makeController()
    }

    // MARK: Shown only on first launch

    func testShownOnFirstLaunchInFirstWindowOnly() {
        let controller = makeController()
        let first = openWindow(controller)
        let second = openWindow(controller)
        XCTAssertTrue(controller.onboarding.isPresented)
        XCTAssertTrue(controller.onboarding.isShown(in: first))
        XCTAssertFalse(controller.onboarding.isShown(in: second), "one window hosts the flow")
        XCTAssertEqual(controller.onboarding.step, .welcome)
    }

    func testNotShownWhenWorkspaceFileExistsFromBeforeOnboarding() async throws {
        // A device that already had a workspace (and a ui-state.json without the new flag).
        do {
            let controller = makeController()
            controller.onboarding.skip()
            try await controller.flushPersistence()
            controller.stop()
        }
        try UIStateFile.save(UIState(), to: directory)
        let controller = makeController()
        _ = openWindow(controller)
        XCTAssertFalse(controller.onboarding.isPresented)
    }

    func testNotShownWithoutPersistenceOrInIncognito() {
        let controller = makeController(persistence: false)
        _ = openWindow(controller)
        XCTAssertFalse(controller.onboarding.isPresented, "tests and previews never show it")

        let firstLaunch = makeController()
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: firstLaunch)
        addTeardownBlock { @MainActor in incognito.stop() }
        XCTAssertFalse(firstLaunch.onboarding.isShown(in: incognito))
        XCTAssertFalse(incognito.controller.onboarding.isPresented)
    }

    // MARK: Skip

    func testSkipFromEveryStepMarksCompleted() async throws {
        for step in OnboardingModel.Step.allCases {
            try? FileManager.default.removeItem(at: directory)
            let controller = makeController()
            let window = openWindow(controller)
            let onboarding = controller.onboarding
            while onboarding.step != step { onboarding.next() }
            onboarding.skip()
            XCTAssertFalse(onboarding.isPresented, "skip at \(step)")
            XCTAssertFalse(onboarding.isShown(in: window))
            XCTAssertTrue(controller.onboardingCompleted)
            XCTAssertEqual(UIStateFile.load(from: directory)?.onboardingCompleted, true, "saved at \(step)")
            window.stop()
            controller.stop()
        }
    }

    func testContinueThroughAllStepsFinishes() {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        var seen: [OnboardingModel.Step] = []
        while onboarding.isPresented {
            seen.append(onboarding.step)
            onboarding.next()
        }
        XCTAssertEqual(seen, OnboardingModel.Step.allCases)
        XCTAssertTrue(controller.onboardingCompleted)
    }

    // MARK: Step 2: Space name and theme

    func testSpaceStepRenamesHomeAndSetsThemeThroughTreeOps() throws {
        let controller = makeController()
        let window = openWindow(controller)
        let onboarding = controller.onboarding
        let spaceID = try XCTUnwrap(onboarding.spaceID)
        XCTAssertEqual(onboarding.spaceName, FirstLaunchDefaults.spaceName)
        let themeID = try XCTUnwrap(controller.workspace.spaces[spaceID]?.themeID)
        let themeStampBefore = controller.workspace.themes[themeID]?.meta.fieldGroupModifiedAt["style"]

        onboarding.next()                      // welcome → space
        let picked = RGBAColor(hex: 0x3FAE6A)
        var draft = onboarding.themeDraft
        draft.colors = [picked]
        onboarding.themeDraft = draft          // live, like Edit Theme…
        onboarding.spaceName = "  Personal "
        onboarding.next()                      // applies the name

        let space = try XCTUnwrap(controller.workspace.spaces[spaceID])
        XCTAssertEqual(space.name, "Personal")
        XCTAssertEqual(space.meta.fieldGroupModifiedAt["naming"], clock.addingTimeInterval(60), "only naming is stamped")
        XCTAssertEqual(space.meta.fieldGroupModifiedAt["theme"], clock, "the theme reference is unchanged")
        XCTAssertEqual(controller.workspace.themes[themeID]?.colors, [picked])
        XCTAssertNotEqual(controller.workspace.themes[themeID]?.meta.fieldGroupModifiedAt["style"], themeStampBefore)
        // [07 §8]: the window color is derived from the theme color (mixed with gray).
        XCTAssertEqual(window.sidebar.palette, ThemeDerivation.palette(for: controller.workspace.themes[themeID], systemAppearance: controller.systemAppearance),
                       "the background follows the theme")
        XCTAssertEqual(window.sidebar.palette.backgroundGradientColors.count, 1)
        XCTAssertEqual(onboarding.step, .importBookmarks)
    }

    func testEmptySpaceNameKeepsOldName() throws {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        let spaceID = try XCTUnwrap(onboarding.spaceID)
        onboarding.next()
        onboarding.spaceName = "   "
        onboarding.next()
        XCTAssertEqual(controller.workspace.spaces[spaceID]?.name, FirstLaunchDefaults.spaceName)
    }

    // MARK: Step 3: import

    func testImportStepOpensImportFlow() {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        var opened: [WorkspaceController] = []
        onboarding.presentImport = { opened.append($0) }
        while onboarding.step != .importBookmarks { onboarding.next() }
        onboarding.openImport()
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === controller)
        XCTAssertTrue(onboarding.didOpenImport)
        XCTAssertEqual(onboarding.step, .importBookmarks, "the step stays until Continue")
    }

    // MARK: Step 4: default browser

    func testDefaultBrowserStepCallsService() async {
        let service = RecordingDefaultBrowserService()
        let controller = makeController(defaultBrowser: service)
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        while onboarding.step != .defaultBrowser { onboarding.next() }
        XCTAssertFalse(onboarding.isDefaultBrowser)
        await onboarding.makeDefaultBrowser()
        XCTAssertEqual(service.requests, DefaultBrowserModel.schemes)
        XCTAssertTrue(onboarding.isDefaultBrowser)
    }

    // MARK: Step 5: sync

    func testSyncStepWritesPreference() {
        let preferences = AppPreferences.inMemory()
        preferences.needsFullSyncUpload = false
        let controller = makeController(preferences: preferences)
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        while onboarding.step != .sync { onboarding.next() }
        XCTAssertTrue(onboarding.syncEnabled, "Sync Sidebar starts on")
        onboarding.setSyncEnabled(false)
        XCTAssertFalse(preferences.isSidebarSyncEnabled)
        XCTAssertTrue(preferences.needsFullSyncUpload, "turning it off marks a full upload, like the toggle")
        onboarding.setSyncEnabled(true)
        XCTAssertTrue(preferences.isSidebarSyncEnabled)
    }

    // MARK: Persistence of the flag

    func testCompletionSurvivesRelaunch() async throws {
        let controller = makeController()
        let window = openWindow(controller)
        controller.onboarding.next()
        controller.onboarding.skip()
        let relaunched = try await relaunch(controller, [window])
        _ = openWindow(relaunched)
        XCTAssertTrue(relaunched.onboardingCompleted)
        XCTAssertFalse(relaunched.onboarding.isPresented)
    }

    func testQuitBeforeFinishingShowsAgainAtNextLaunch() async throws {
        let controller = makeController()
        let window = openWindow(controller)
        controller.onboarding.next()
        let relaunched = try await relaunch(controller, [window])
        XCTAssertEqual(UIStateFile.load(from: directory)?.onboardingCompleted, false)
        let next = openWindow(relaunched)
        XCTAssertTrue(relaunched.onboarding.isShown(in: next))
        XCTAssertEqual(relaunched.onboarding.step, .welcome)
    }

    // MARK: Show Welcome Again

    func testShowWelcomeAgainReopensFlow() async throws {
        let controller = makeController()
        let window = openWindow(controller)
        while controller.onboarding.isPresented { controller.onboarding.next() }
        let relaunched = try await relaunch(controller, [window])
        let next = openWindow(relaunched)
        XCTAssertFalse(relaunched.onboarding.isPresented)

        relaunched.onboarding.showAgain(in: next)
        XCTAssertTrue(relaunched.onboarding.isShown(in: next))
        XCTAssertEqual(relaunched.onboarding.step, .welcome)
        XCTAssertEqual(relaunched.onboarding.spaceName, FirstLaunchDefaults.spaceName)
        relaunched.onboarding.skip()
        XCTAssertFalse(relaunched.onboarding.isPresented)
        XCTAssertTrue(relaunched.onboardingCompleted)
    }

    func testShowWelcomeAgainIgnoresIncognitoWindow() {
        let controller = makeController(persistence: false)
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        controller.onboarding.showAgain(in: incognito)
        XCTAssertFalse(controller.onboarding.isPresented)
    }

    // MARK: UI state file

    func testUIStateDecodesFilesWithoutFlag() throws {
        let legacy = Data(#"{"version":1,"isSidebarVisible":true}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(UIState.self, from: legacy).onboardingCompleted)
        let state = UIState(windows: [], onboardingCompleted: true)
        let decoded = try JSONDecoder().decode(UIState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.onboardingCompleted, true)
    }

    // MARK: Look (B53, [06 §27])

    /// [06 §27.1] the welcome is its own full-window screen; [06 §27.2, §27.4] every later D9
    /// step goes into the split layout's left column, one step per screen.
    func testStepToScreenMapping() {
        XCTAssertEqual(OnboardingModel.screen(for: .welcome), .welcome)
        for step in OnboardingModel.Step.allCases where step != .welcome {
            XCTAssertEqual(OnboardingModel.screen(for: step), .split, "\(step)")
        }
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        XCTAssertEqual(onboarding.screen, .welcome)
        onboarding.next()
        XCTAssertEqual(onboarding.screen, .split)
        onboarding.back()
        XCTAssertEqual(onboarding.screen, .welcome)
    }

    /// [06 §27.2] observed: the demo changes about every 3 s and wraps around. Driven by dates
    /// passed in, no real timer.
    func testCarouselAdvancesEveryIntervalAndWraps() {
        let start = Date(timeIntervalSince1970: 1_000)
        let interval = OnboardingCarousel.interval
        XCTAssertEqual(interval, 3, accuracy: 0.001)
        let count = OnboardingDemoSample.samples.count
        XCTAssertGreaterThanOrEqual(count, 4, "[06 §27.2]: several themed samples")
        func index(_ t: TimeInterval) -> Int { OnboardingCarousel.index(start: start, now: start.addingTimeInterval(t), count: count) }
        XCTAssertEqual(index(-5), 0, "before the start")
        XCTAssertEqual(index(0), 0)
        XCTAssertEqual(index(interval - 0.1), 0)
        XCTAssertEqual(index(interval), 1)
        XCTAssertEqual(index(interval * 2.5), 2)
        XCTAssertEqual(index(interval * Double(count)), 0, "wraps after the last sample")
        XCTAssertEqual(index(interval * Double(count + 1)), 1)
        XCTAssertEqual(OnboardingCarousel.index(start: start, now: start.addingTimeInterval(100), count: 0), 0)
        // Sample themes differ, so each change is visible.
        XCTAssertEqual(Set(OnboardingDemoSample.samples.map(\.colors)).count, count)
    }

    /// [06 §27.3] observed: the primary button has a disabled state. Ours: the Space step needs
    /// a name; other steps are always enabled.
    func testContinueDisabledOnlyForEmptySpaceName() {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        XCTAssertTrue(onboarding.isContinueEnabled)
        onboarding.next()
        XCTAssertEqual(onboarding.step, .space)
        XCTAssertTrue(onboarding.isContinueEnabled, "prefilled with the Space name")
        XCTAssertTrue(onboarding.showsLiveSpaceDemo)
        onboarding.spaceName = "  "
        XCTAssertFalse(onboarding.isContinueEnabled)
        onboarding.spaceName = "Work"
        XCTAssertTrue(onboarding.isContinueEnabled)
        onboarding.next()
        XCTAssertTrue(onboarding.isContinueEnabled)
        XCTAssertFalse(onboarding.showsLiveSpaceDemo)
    }

    /// [06 §27.2] observed at 1280 × 800: halves of 640; the demo card's top left at (736, 83),
    /// running out of the window on the right; scallops along the half line.
    func testSplitLayoutMatchesCapture() {
        let layout = OnboardingSplitLayout(windowSize: CGSize(width: 1280, height: 800))
        XCTAssertEqual(layout.leftColumnWidth, 640)
        XCTAssertEqual(layout.rightColumnFrame.maxX, 1280)
        XCTAssertLessThan(layout.rightColumnFrame.minX, 640, "room for the scallops")
        let card = layout.demoCardFrame
        XCTAssertEqual(card.minX, 736, accuracy: 1)
        XCTAssertEqual(card.minY, 83, accuracy: 1)
        XCTAssertGreaterThan(card.maxX, 1280, "cropped by the window's right edge")
        XCTAssertEqual(card.maxY, 800 - 83, accuracy: 1)

        // The wavy edge stays within the amplitude and repeats with the period.
        let period = OnboardingTokens.scallopPeriod, amplitude = OnboardingTokens.scallopAmplitude
        let xs = stride(from: CGFloat(0), through: 200, by: 0.5).map {
            ScallopedColumn.edge(at: $0, center: 640, period: period, amplitude: amplitude)
        }
        XCTAssertEqual(xs.max() ?? 0, 640 + amplitude, accuracy: 0.01)
        XCTAssertEqual(xs.min() ?? 0, 640 - amplitude, accuracy: 0.01)
        XCTAssertEqual(ScallopedColumn.edge(at: 3, center: 640, period: period, amplitude: amplitude),
                       ScallopedColumn.edge(at: 3 + period, center: 640, period: period, amplitude: amplitude), accuracy: 0.001)
    }

    /// [06 §27.1, §27.3] observed sizes and colors of the welcome button, field and primary button.
    func testControlTokensMatchCapture() {
        XCTAssertEqual(OnboardingTokens.arrowButtonSize, CGSize(width: 67, height: 40))
        XCTAssertEqual(OnboardingTokens.arrowButtonRadius, 8)
        XCTAssertEqual(OnboardingTokens.arrowButtonFill, RGBAColor(hex: 0xDDDEFB))
        XCTAssertEqual(OnboardingTokens.fieldSize, CGSize(width: 369, height: 63))
        XCTAssertEqual(OnboardingTokens.accent, RGBAColor(hex: 0x3950F0))
        XCTAssertEqual(OnboardingTokens.primarySize, CGSize(width: 232, height: 40))
        XCTAssertEqual(OnboardingTokens.bodyInk, RGBAColor(hex: 0x505050))
        XCTAssertEqual(OnboardingTokens.bodyWidth, 330)
        XCTAssertEqual(OnboardingTokens.grayButtonFill, RGBAColor(hex: 0xEFEFEF))
        // Our own wording: never the captured headline.
        XCTAssertNotEqual(OnboardingTokens.headline, "A browser for you.")
    }

    /// Every screen renders at the captured window size and at the minimum window size, and the
    /// left column's content fits the half width. [06 §27.2]
    func testScreensRenderAtWindowSizes() {
        let controller = makeController()
        let window = openWindow(controller)
        let onboarding = controller.onboarding
        for windowSize in [CGSize(width: 1280, height: 800), CGSize(width: 800, height: 500)] {
            onboarding.showAgain(in: window)
            for step in OnboardingModel.Step.allCases {
                while onboarding.step != step { onboarding.next() }
                let host = NSHostingView(rootView: OnboardingOverlay(onboarding: onboarding, palette: ThemeDerivation.palette(for: nil))
                    .frame(width: windowSize.width, height: windowSize.height))
                host.frame = CGRect(origin: .zero, size: windowSize)
                host.layoutSubtreeIfNeeded()
                XCTAssertEqual(host.fittingSize.width, windowSize.width, accuracy: 1, "\(step) @ \(windowSize)")
                let column = NSHostingController(rootView: OnboardingStepColumn(onboarding: onboarding))
                let size = column.sizeThatFits(in: CGSize(width: windowSize.width / 2, height: windowSize.height))
                XCTAssertLessThanOrEqual(size.width, windowSize.width / 2 + 1, "\(step) @ \(windowSize)")
                XCTAssertLessThanOrEqual(size.height, windowSize.height + 1, "\(step) @ \(windowSize)")
            }
        }
    }
}

