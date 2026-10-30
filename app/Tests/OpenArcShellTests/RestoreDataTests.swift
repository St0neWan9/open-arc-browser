import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// A sync store that records what it is asked to enqueue.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class RestoreRecordingSyncStore: SyncStore, @unchecked Sendable {
    private let lock = NSLock()
    private var batches: [[PendingChange]] = []

    var enqueued: [PendingChange] { lock.withLock { batches.flatMap { $0 } } }

    func start(database: any SyncLocalDatabase) async throws {}
    func stop() async {}
    func enqueue(_ changes: [PendingChange]) async { lock.withLock { batches.append(changes) } }
    func syncNow() async throws {}
    func resetLocalSyncState() async {}
    func currentStatus() async -> SyncStatus { .disabled }
    func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { $0.yield(.disabled); $0.finish() }
    }
}

/// Plan B117 (decision Q18): Help ▸ Restore Data. [01 §Help] observed item; the rest is ours.
@MainActor
final class RestoreDataTests: XCTestCase {
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b117-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let clock = Date(timeIntervalSince1970: 1_000)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeModel(_ store: WorkspaceStore?, sync: any SyncStore = DisabledSyncStore()) -> ShellModel {
        let preferences = AppPreferences.syncOn()
        preferences.needsFullSyncUpload = false
        let deps = AppDependencies(engine: FakeEngine(), sync: sync, persistence: store, preferences: preferences)
        let now = clock
        let model = ShellModel(dependencies: deps, workspace: .firstLaunch(now: now), now: { now }, notificationCenter: NotificationCenter())
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func items<Content: View>(_ content: Content) throws -> [NSMenuItem] {
        guard #available(macOS 15, *) else { throw XCTSkip("NSHostingMenu needs macOS 15") }
        let menu = NSHostingMenu(rootView: content)
        menu.update()
        return menu.items
    }

    private func restoreItem(_ model: ShellModel) throws -> NSMenuItem {
        try XCTUnwrap(try items(HelpMenuItems(model: model, hasWindow: true)).first { $0.title == "Restore Data" })
    }

    /// 01 §Help: Restore Data is shown, and enabled only while a backup exists.
    func testMenuItemIsEnabledOnlyWithBackups() async throws {
        let store = WorkspaceStore(directory: directory, now: { [clock] in clock })
        let model = makeModel(store)
        XCTAssertFalse(try restoreItem(model).isEnabled, "no backup yet")
        try await model.flushPersistence()
        await store.waitForBackups()
        XCTAssertEqual(store.backups().count, 1)
        XCTAssertTrue(try restoreItem(model).isEnabled)
        XCTAssertTrue(RestoreDataMenuItem.isEnabled(model.controller))
    }

    /// Without a store (tests, previews) and in an incognito window the item is disabled.
    func testMenuItemIsDisabledWithoutAStore() throws {
        let model = makeModel(nil)
        XCTAssertFalse(try restoreItem(model).isEnabled)
        XCTAssertFalse(RestoreDataMenuItem.isEnabled(model.controller.makeIncognito()))
    }

    /// The restore goes through the controller as a local change: the shown workspace has the
    /// backup's live records, the store saves it, and the sync store gets every changed record.
    func testRestoreFromTheSheetModelReachesStoreAndSync() async throws {
        let store = WorkspaceStore(directory: directory, now: { [clock] in clock })
        let recorder = RestoreRecordingSyncStore()
        let model = makeModel(store, sync: recorder)
        let kept = try XCTUnwrap(model.sidebar.createFolder(title: "Kept"))
        try await model.flushPersistence()
        await store.waitForBackups()

        // After the backup: a new folder, and the kept one renamed.
        let added = try XCTUnwrap(model.sidebar.createFolder(title: "Added later"))
        try model.controller.mutate(origin: nil) { try TreeOps.renameFolder($0, id: kept, title: "Renamed", now: self.clock) }

        let sheet = RestoreDataModel(controller: model.controller)
        XCTAssertEqual(sheet.rows.count, 1)
        await sheet.loadSummaries()
        XCTAssertEqual(try sheet.rows[0].summary?.get(), WorkspaceBackupSummary(try WorkspaceBackups.load(sheet.rows[0].backup)))
        var closed = false
        sheet.onClose = { closed = true }
        sheet.requestRestore()
        XCTAssertTrue(sheet.isConfirming, "a restore asks first")
        await sheet.confirmRestore()
        XCTAssertTrue(closed)
        XCTAssertNil(sheet.errorMessage)

        XCTAssertEqual(model.workspace.folders[kept]?.title, "Kept")
        XCTAssertEqual(model.workspace.folders[added]?.meta.isTombstone, true)
        let addedRecord = SyncRecordID(type: .folder, uuid: added)
        let keptRecord = SyncRecordID(type: .folder, uuid: kept)
        await eventually { await store.currentWorkspace() == model.workspace }
        // The rename and the restore each announce the kept folder; the tombstone is a save too.
        await eventually { recorder.enqueued.filter { $0 == .save(keptRecord) }.count >= 3 && recorder.enqueued.filter { $0 == .save(addedRecord) }.count >= 2 }
    }

    private func eventually(_ condition: @escaping () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met", file: file, line: line)
    }
}
