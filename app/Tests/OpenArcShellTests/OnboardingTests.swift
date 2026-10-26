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

/// D9: first-run onboarding. OWN DESIGN: the spec has no capture of Arc's onboarding (plan E6,
/// `docs/arc-spec` has no entry), so these tests pin our own behavior: shown once on first
/// launch, skippable from every step, per-device completion flag in `ui-state.json`, and
/// Help ▸ Show Welcome Again (inferred).
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

    // MARK: Card size (B26)

    /// B26: the card is a compact card sized to its content, not a full-height panel. Measured
    /// with the window's size as the offer, at 1920×985 (the reference size) and 1280×800.
    func testCardIsCompactAndBoundedAtWindowSizes() {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        for windowSize in [CGSize(width: 1920, height: 985), CGSize(width: 1280, height: 800)] {
            onboarding.showAgain(in: controller.browserWindows[0])
            for step in OnboardingModel.Step.allCases {
                while onboarding.step != step { onboarding.next() }
                let host = NSHostingController(rootView: OnboardingCard(onboarding: onboarding))
                let size = host.sizeThatFits(in: windowSize)
                XCTAssertEqual(size.width, OnboardingTokens.cardWidth, accuracy: 1, "\(step) @ \(windowSize)")
                XCTAssertLessThanOrEqual(size.height, OnboardingTokens.cardMaxHeight, "\(step) @ \(windowSize)")
                XCTAssertLessThan(size.height, windowSize.height * 0.75, "\(step) @ \(windowSize): no full-height card")
                if step == .welcome || step == .done {
                    XCTAssertLessThan(size.height, 360, "\(step): a text-only card stays short")
                }
                // The fitting size agrees: the height does not depend on the space offered.
                XCTAssertEqual(host.view.fittingSize.height, size.height, accuracy: 1, "\(step)")
            }
        }
    }

    /// B26: a window shorter than the content caps the card; the content scrolls inside it.
    func testCardFitsShortWindow() {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        onboarding.next()  // the Space step is the tallest (field + theme editor)
        let host = NSHostingController(rootView: OnboardingCard(onboarding: onboarding))
        let size = host.sizeThatFits(in: CGSize(width: 1280, height: 420))
        XCTAssertLessThanOrEqual(size.height, 421)
    }

    /// B26: in the window the card is centered and keeps its compact height.
    func testOverlayCentersCompactCard() throws {
        let controller = makeController()
        _ = openWindow(controller)
        let onboarding = controller.onboarding
        let windowSize = CGSize(width: 1920, height: 985)
        let expected = NSHostingController(rootView: OnboardingCard(onboarding: onboarding)).sizeThatFits(in: windowSize)
        let probe = CardFrameProbe()
        let root = OnboardingOverlay(onboarding: onboarding, palette: ThemeDerivation.palette(for: nil))
            .onPreferenceChange(OnboardingCardFrameKey.self) { frame in MainActor.assumeIsolated { probe.frame = frame } }
            .frame(width: windowSize.width, height: windowSize.height)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: windowSize)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let frame = try XCTUnwrap(probe.frame)
        XCTAssertEqual(frame.height, expected.height, accuracy: 1)
        XCTAssertEqual(frame.midX, windowSize.width / 2, accuracy: 1)
        XCTAssertEqual(frame.midY, windowSize.height / 2, accuracy: 1)
    }
}

@MainActor
private final class CardFrameProbe {
    var frame: CGRect?
}
