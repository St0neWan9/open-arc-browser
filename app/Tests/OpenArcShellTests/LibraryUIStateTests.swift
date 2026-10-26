import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Never runs autosave work: these tests only look at `ui-state.json`.
private struct NeverSaveScheduler: AutosaveScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {}
}

/// B22: the Library's Media intro dismissal and last section survive a relaunch through
/// `ui-state.json`. [06 §8] observed: the intro card shows on the first visit and Open Library
/// shows a section; keeping both across launches is inferred.
@MainActor
final class LibraryUIStateTests: XCTestCase {
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b22-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let clock = Date(timeIntervalSince1970: 1_000)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A model on a fresh store over `directory`; a second call simulates a relaunch.
    private func launch() -> ShellModel {
        let store = WorkspaceStore(directory: directory, scheduler: NeverSaveScheduler(), now: { [clock] in clock })
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), persistence: store)
        let now = clock
        let model = ShellModel(dependencies: deps, workspace: .firstLaunch(now: now), now: { now }, notificationCenter: NotificationCenter())
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    func testFirstLaunchShowsIntroAndOpensMedia() {
        let model = launch()
        XCTAssertTrue(model.library.isMediaIntroVisible)
        model.openLibrary()
        XCTAssertEqual(model.library.section, .media)
    }

    func testDismissedIntroSurvivesRelaunch() {
        let first = launch()
        first.library.dismissMediaIntro()
        // Saved right away, without a flush or termination.
        XCTAssertEqual(UIStateFile.load(from: directory)?.mediaIntroDismissed, true)
        first.stop()

        let second = launch()
        XCTAssertFalse(second.library.isMediaIntroVisible)
    }

    func testLastSectionIsRestoredOnRelaunch() {
        let first = launch()
        first.openLibrary(.archivedTabs)
        first.exitLibrary()
        XCTAssertEqual(UIStateFile.load(from: directory)?.lastLibrarySection, "archivedTabs")
        first.stop()

        let second = launch()
        XCTAssertFalse(second.isLibraryActive, "relaunch does not reopen the Library by itself")
        XCTAssertTrue(second.library.isMediaIntroVisible)
        second.openLibrary()
        XCTAssertEqual(second.library.section, .archivedTabs)
    }

    func testUnknownSavedSectionFallsBackToMedia() throws {
        try UIStateFile.save(UIState(lastLibrarySection: "notASection"), to: directory)
        let model = launch()
        model.openLibrary()
        XCTAssertEqual(model.library.section, .media)
    }
}
