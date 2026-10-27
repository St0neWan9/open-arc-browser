import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Order of quit steps, written from any context.
private actor StepLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
}

private struct HoldingScheduler: AutosaveScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {}
}

/// How the fake engine's `shutdown()` behaves.
private enum ShutdownBehavior: Sendable {
    /// Hops to the main actor to shut down (like an engine that tears down views, Q11).
    case needsMainActor
    /// Never returns and ignores cancellation (a stuck engine).
    case hangs
}

/// A FakeEngine with a scripted `shutdown()`. Everything else forwards.
private final class QuitProbeEngine: BrowserEngine {
    let base = FakeEngine()
    let behavior: ShutdownBehavior
    let beforeShutdown: @Sendable () async -> Void

    init(_ behavior: ShutdownBehavior, beforeShutdown: @escaping @Sendable () async -> Void = {}) {
        self.behavior = behavior
        self.beforeShutdown = beforeShutdown
    }

    func makeTab(_ configuration: TabConfiguration) async throws -> any BrowserTab { try await base.makeTab(configuration) }
    func tab(for id: EngineTabID) async -> (any BrowserTab)? { await base.tab(for: id) }
    func closeTab(_ id: EngineTabID) async { await base.closeTab(id) }
    func events() -> AsyncStream<EngineEvent> { base.events() }
    func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) async throws -> any BrowserTab {
        try await base.adoptTab(token, requestedID: requestedID)
    }
    func declineTab(_ token: PendingTabToken) async { await base.declineTab(token) }
    var engineVersion: String { base.engineVersion }
    func shutdown() async {
        await beforeShutdown()
        switch behavior {
        case .needsMainActor:
            await MainActor.run { _ = NSApplication.shared.windows.count }
            await base.shutdown()
        case .hangs:
            // A stream that never ends: cancellation does not stop it either.
            let (stream, _) = AsyncStream<Void>.makeStream()
            for await _ in stream {}
        }
    }
    func deleteProfileData(_ profileID: Profile.ID) async throws { try await base.deleteProfileData(profileID) }
    func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async {
        await base.clearBrowsingData(profileID, types: types, since: since)
    }
    var downloads: any EngineDownloads { base.downloads }
    var extensions: any EngineExtensions { base.extensions }
}

/// B27: ⌘Q answers `.terminateLater`, flushes the store and shuts the engine down without
/// blocking the main thread, and replies within a bounded time, even with a stuck engine. The
/// quit sequence and its limits are our own (the spec records nothing about quitting); inferred.
@MainActor
final class QuitSequenceTests: XCTestCase {
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b27-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(engine: any BrowserEngine, persistence: WorkspaceStore?, center: NotificationCenter = NotificationCenter()) -> ShellModel {
        let model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), persistence: persistence),
            workspace: .firstLaunch(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) },
            notificationCenter: center
        )
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// Starts the quit sequence and waits (without blocking the main actor) for its reply.
    /// Returns the elapsed time.
    private func quit(_ termination: AppTermination, limit: TimeInterval) async throws -> TimeInterval {
        let start = Date()
        let replied = expectation(description: "replied to applicationShouldTerminate")
        let answer = termination.begin { replied.fulfill() }
        XCTAssertEqual(answer, .terminateLater)
        await fulfillment(of: [replied], timeout: limit)
        return Date().timeIntervalSince(start)
    }

    /// Normal quit: the store is on disk before the engine shuts down, the reply comes well
    /// within a second, and the main thread kept running meanwhile (the engine needs it).
    func testQuitFlushesThenShutsDownAndRepliesQuickly() async throws {
        let directory = self.directory
        let log = StepLog()
        let engine = QuitProbeEngine(.needsMainActor) {
            let saved = WorkspaceStore(directory: directory).loadResult.workspace
            await log.append(saved.folders.values.contains { $0.title == "Last edit" } ? "shutdown after flush" : "shutdown before flush")
        }
        let store = WorkspaceStore(directory: directory, scheduler: HoldingScheduler())
        let model = makeModel(engine: engine, persistence: store)
        _ = try XCTUnwrap(model.sidebar.createFolder(title: "Last edit"))
        var dragDataReleased = false
        let termination = AppTermination(releaseDragData: { dragDataReleased = true })
        termination.attach(model.controller)

        let elapsed = try await quit(termination, limit: 2)

        XCTAssertLessThan(elapsed, 1, "quit must finish within about a second")
        XCTAssertTrue(dragDataReleased, "promised drag data is dropped before quitting")
        let entries = await log.entries
        XCTAssertEqual(entries, ["shutdown after flush"])
        XCTAssertTrue(engine.base.shutdownCalled)
        XCTAssertEqual(WorkspaceStore(directory: directory).loadResult.workspace.folders.values.map(\.title), ["Last edit"])
        XCTAssertTrue(model.controller.isTerminationPrepared)
    }

    /// A stuck engine: the reply still comes, at the deadline, and the data is on disk.
    func testHangingEngineStillQuitsAtTheDeadline() async throws {
        let store = WorkspaceStore(directory: directory, scheduler: HoldingScheduler())
        let model = makeModel(engine: QuitProbeEngine(.hangs), persistence: store)
        _ = try XCTUnwrap(model.sidebar.createFolder(title: "Saved anyway"))
        let termination = AppTermination(deadline: 0.5, releaseDragData: {})
        termination.attach(model.controller)

        let elapsed = try await quit(termination, limit: 3)

        XCTAssertGreaterThanOrEqual(elapsed, 0.45)
        XCTAssertLessThan(elapsed, 2, "quit waited past its deadline")
        XCTAssertEqual(WorkspaceStore(directory: directory).loadResult.workspace.folders.values.map(\.title), ["Saved anyway"])
    }

    /// The per-step engine limit applies within the overall deadline too.
    func testEngineStepIsBoundedByItsOwnTimeout() async {
        let model = makeModel(engine: QuitProbeEngine(.hangs), persistence: nil)
        let start = Date()
        await model.controller.prepareForTermination(engineShutdownTimeout: 0.2)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15)
        XCTAssertLessThan(elapsed, 1.5)
    }

    /// After the async sequence ran, `willTerminate` does not flush or wait again.
    func testWillTerminateAfterPreparedQuitDoesNothingMore() async throws {
        let center = NotificationCenter()
        let store = WorkspaceStore(directory: directory, scheduler: HoldingScheduler())
        let model = makeModel(engine: QuitProbeEngine(.hangs), persistence: store, center: center)
        _ = try XCTUnwrap(model.sidebar.createFolder(title: "Once"))
        await model.controller.prepareForTermination(engineShutdownTimeout: 0.1)
        let writes = await store.writeCount
        XCTAssertEqual(writes, 1)

        let start = Date()
        center.post(name: NSApplication.willTerminateNotification, object: nil)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1, "willTerminate waited for the stuck engine again")
        let after = await store.writeCount
        XCTAssertEqual(after, 1)
    }

    /// A second ⌘Q while the first is still running starts nothing new.
    func testSecondQuitRequestWhileRunningIsAnsweredLater() async throws {
        let model = makeModel(engine: QuitProbeEngine(.hangs), persistence: nil)
        let termination = AppTermination(deadline: 0.3, releaseDragData: {})
        termination.attach(model.controller)
        var replies = 0
        let replied = expectation(description: "first reply")
        XCTAssertEqual(termination.begin { replies += 1; replied.fulfill() }, .terminateLater)
        XCTAssertEqual(termination.begin { replies += 1 }, .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, 1)
    }

    /// Without a controller (nothing to save) the app quits right away.
    func testQuitWithoutControllerTerminatesNow() {
        let termination = AppTermination(releaseDragData: {})
        XCTAssertEqual(termination.begin {}, .terminateNow)
    }

    // MARK: Warn before quitting (B68, 03 §General observed: on by default)

    private func confirmingTermination(
        _ answer: QuitConfirmation,
        asked: @escaping @MainActor () -> Void,
        isSystemQuit: Bool = false,
        center: NotificationCenter = NotificationCenter()
    ) -> AppTermination {
        AppTermination(
            deadline: 0.5, releaseDragData: {},
            confirmQuit: { asked(); return answer },
            isSystemQuit: { isSystemQuit },
            notificationCenter: center
        )
    }

    /// On (the default): the user is asked; Cancel keeps the app running and nothing is shut down.
    func testWarnBeforeQuittingCancelKeepsTheAppOpen() {
        let engine = QuitProbeEngine(.needsMainActor)
        let model = makeModel(engine: engine, persistence: nil)
        XCTAssertTrue(model.dependencies.preferences.warnsBeforeQuitting, "03 §General: on by default")
        var asked = 0
        let termination = confirmingTermination(.cancel) { asked += 1 }
        termination.attach(model.controller)
        XCTAssertEqual(termination.request {}, .terminateCancel)
        XCTAssertEqual(asked, 1)
        XCTAssertFalse(model.controller.isTerminationPrepared)
        XCTAssertFalse(engine.base.shutdownCalled)
    }

    /// On: Quit runs the normal quit sequence (store flush, engine shutdown).
    func testWarnBeforeQuittingQuitRunsTheQuitSequence() async throws {
        let engine = QuitProbeEngine(.needsMainActor)
        let model = makeModel(engine: engine, persistence: nil)
        var asked = 0
        let termination = confirmingTermination(.quit) { asked += 1 }
        termination.attach(model.controller)
        let replied = expectation(description: "replied")
        XCTAssertEqual(termination.request { replied.fulfill() }, .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(engine.base.shutdownCalled)
        XCTAssertTrue(model.dependencies.preferences.warnsBeforeQuitting)
    }

    /// "Don't ask again" quits and turns the setting off.
    func testDontAskAgainTurnsTheSettingOff() async throws {
        let model = makeModel(engine: QuitProbeEngine(.needsMainActor), persistence: nil)
        let termination = confirmingTermination(.quitAndStopWarning) {}
        termination.attach(model.controller)
        let replied = expectation(description: "replied")
        XCTAssertEqual(termination.request { replied.fulfill() }, .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertFalse(model.dependencies.preferences.warnsBeforeQuitting)
    }

    /// Off: no question, the app quits at once.
    func testWarnBeforeQuittingOffQuitsWithoutAsking() async throws {
        let engine = QuitProbeEngine(.needsMainActor)
        let model = makeModel(engine: engine, persistence: nil)
        model.dependencies.preferences.warnsBeforeQuitting = false
        var asked = 0
        let termination = confirmingTermination(.cancel) { asked += 1 }
        termination.attach(model.controller)
        let replied = expectation(description: "replied")
        XCTAssertEqual(termination.request { replied.fulfill() }, .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(asked, 0)
        XCTAssertTrue(engine.base.shutdownCalled)
    }

    /// Logout / restart / shut down and an update relaunch are never questioned (inferred).
    func testSystemQuitAndUpdateRelaunchAreNotQuestioned() async throws {
        let model = makeModel(engine: QuitProbeEngine(.needsMainActor), persistence: nil)
        var asked = 0
        let system = confirmingTermination(.cancel, asked: { asked += 1 }, isSystemQuit: true)
        system.attach(model.controller)
        let replied = expectation(description: "system quit replied")
        XCTAssertEqual(system.request { replied.fulfill() }, .terminateLater)
        await fulfillment(of: [replied], timeout: 2)

        let center = NotificationCenter()
        let update = confirmingTermination(.cancel, asked: { asked += 1 }, center: center)
        update.attach(model.controller)
        center.post(name: QuitConfirmationAlert.updateRelaunchNotification, object: nil)
        XCTAssertNotEqual(update.request {}, .terminateCancel)
        XCTAssertEqual(asked, 0)
    }

    /// The alert's wording names our app, and only its first button (Quit) quits. inferred.
    func testQuitAlertTextsAndAnswers() {
        XCTAssertEqual(QuitConfirmationAlert.title, "Quit Open Arc?")
        XCTAssertEqual(QuitConfirmationAlert.answer(for: .alertFirstButtonReturn, suppressed: false), .quit)
        XCTAssertEqual(QuitConfirmationAlert.answer(for: .alertFirstButtonReturn, suppressed: true), .quitAndStopWarning)
        XCTAssertEqual(QuitConfirmationAlert.answer(for: .alertSecondButtonReturn, suppressed: true), .cancel)
    }
}
