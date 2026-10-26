import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Collects autosave work; tests fire it by hand instead of sleeping.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class ManualSaveScheduler: AutosaveScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () async -> Void] = []

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        lock.withLock { pending.append(work) }
    }

    func fireAll() async {
        let work = lock.withLock { () -> [@Sendable () async -> Void] in
            defer { pending = [] }
            return pending
        }
        for item in work { await item() }
    }
}

/// `ShellModel` loads through and saves to the optional persistence store.
@MainActor
final class ShellPersistenceTests: XCTestCase {
    /// A unique directory under app/.build/persistence-tmp, removed after each test.
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/persistence-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let clock = Date(timeIntervalSince1970: 1_700_000_000)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeStore(_ scheduler: ManualSaveScheduler) -> WorkspaceStore {
        WorkspaceStore(directory: directory, scheduler: scheduler, now: { [clock] in clock })
    }

    private func makeModel(_ store: WorkspaceStore) -> ShellModel {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), persistence: store)
        let now = clock
        return ShellModel(dependencies: deps, workspace: .demo(now: now), now: { now })
    }

    func testFakeDependenciesHaveNoPersistence() {
        XCTAssertNil(AppDependencies.fake().persistence)
    }

    func testBundleIdentifierMatchesThePersistenceDirectory() {
        XCTAssertEqual(PersistenceDefaults.bundleIdentifier, AppIdentity.bundleIdentifier)
        XCTAssertEqual(PersistenceDefaults.releaseBundleIdentifier, AppIdentity.releaseBundleIdentifier)
        XCTAssertEqual(PersistenceDefaults.developmentBundleIdentifier, AppIdentity.developmentBundleIdentifier)
    }

    /// A sidebar change reaches disk after the debounced autosave; a relaunch loads it back.
    func testShellSavesAfterASidebarChangeAndReloads() async throws {
        let scheduler = ManualSaveScheduler()
        let store = makeStore(scheduler)
        let model = makeModel(store)
        defer { model.stop() }

        // A folder is a pure workspace change (no engine events can race the comparison).
        let id = try XCTUnwrap(model.sidebar.createFolder(title: "Saved"))
        let expected = model.workspace
        let workspaceFile = store.workspaceFileURL
        await eventually { await store.workspace == expected }
        await scheduler.fireAll()
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceFile.path))

        let relaunchStore = makeStore(ManualSaveScheduler())
        XCTAssertEqual(relaunchStore.loadResult.outcome, .loaded)
        let relaunched = makeModel(relaunchStore)
        defer { relaunched.stop() }
        XCTAssertEqual(relaunched.workspace.folders[id]?.title, "Saved")
        XCTAssertEqual(relaunched.workspace, expected, "the loaded workspace replaces the default")
    }

    /// flushPersistence writes immediately (app termination).
    func testFlushPersistenceWritesWithoutWaitingForAutosave() async throws {
        let store = makeStore(ManualSaveScheduler())
        let model = makeModel(store)
        defer { model.stop() }
        let id = try XCTUnwrap(model.sidebar.createFolder(title: "Flushed"))
        try await model.flushPersistence()
        let reloaded = makeStore(ManualSaveScheduler())
        XCTAssertEqual(reloaded.loadResult.workspace.folders[id]?.title, "Flushed")
        XCTAssertEqual(reloaded.loadResult.workspace, model.workspace)
    }

    private func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met", file: file, line: line)
    }
}
