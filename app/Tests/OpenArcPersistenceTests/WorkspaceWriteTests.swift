import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// B151: `workspace.json` (10.5 MB for the user who hit the macOS disk-writes report) and the
/// sync state are rewritten only when what they hold changed.
final class WorkspaceWriteTests: XCTestCase {
    private var dir: TempDirectory!

    override func setUp() {
        dir = TempDirectory()
    }

    override func tearDown() {
        dir.cleanUp()
    }

    private func makeStore(_ scheduler: ManualAutosaveScheduler = ManualAutosaveScheduler()) -> WorkspaceStore {
        WorkspaceStore(directory: dir.url, scheduler: scheduler, now: { Fx.t(1_000) })
    }

    private var todayTab: SyncRecordID { SyncRecordID(type: .tab, uuid: Sample.ids.todayTab) }

    /// The server echoing this device's own upload changes only the record's system fields: the
    /// workspace keeps them in memory for the next send and writes nothing for them. An hour of
    /// such echoes (one a minute) costs no write.
    func testSystemFieldsOnlyBatchesAreNotWrittenOnTheirOwn() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        let state = try Sample.workspace()
        await store.update(state)
        try await store.flush()
        let writesBefore = await store.writeCount

        for minute in 0..<60 {
            let echo = try XCTUnwrap(state.record(for: todayTab))
                .withBackendSystemFields(Data("tag-\(minute)".utf8))
            try await store.apply(RemoteChangeBatch(upserts: [echo]))
            await scheduler.fireAll()
        }
        var writes = await store.writeCount
        XCTAssertEqual(writes, writesBefore, "echoes alone write nothing")
        let inMemory = await store.workspace.record(for: todayTab)?.meta.backendSystemFields
        XCTAssertEqual(inMemory, Data("tag-59".utf8), "kept in memory for the next send")

        // B153: the files keep only a marker for system fields (the sync state owns them), and
        // the record had one already, so even the quit writes nothing for the echoes.
        try await store.flush()
        writes = await store.writeCount
        XCTAssertEqual(writes, writesBefore, "the files already hold the marker")
        let reloaded = makeStore().loadResult.workspace.record(for: todayTab)?.meta.backendSystemFields
        XCTAssertEqual(reloaded, SystemFieldsOnDisk.marker)
    }

    /// A remote batch that changes what the user sees is still written before `apply` returns
    /// (the backend may persist its change token right after).
    func testVisibleRemoteChangeIsWrittenImmediately() async throws {
        let store = makeStore()
        let state = try Sample.workspace()
        await store.update(state)
        try await store.flush()
        let writesBefore = await store.writeCount

        guard case .tab(var server)? = state.record(for: todayTab) else { return XCTFail("no tab") }
        server.title = "Renamed elsewhere"
        server.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(900))
        try await store.apply(RemoteChangeBatch(upserts: [.tab(server)]))
        let writes = await store.writeCount
        XCTAssertEqual(writes, writesBefore + 1)
        XCTAssertEqual(makeStore().loadResult.workspace.tabs[server.id]?.title, "Renamed elsewhere")
    }

    /// Edits that cancel out within the autosave window, and a flush with the loaded value, leave
    /// the file alone.
    func testUnchangedWorkspaceIsNotRewritten() async throws {
        let scheduler = ManualAutosaveScheduler()
        let state = try Sample.workspace()
        do {
            let first = makeStore(scheduler)
            await first.update(state)
            try await first.flush()
        }
        let store = makeStore(scheduler)
        XCTAssertEqual(store.loadResult.outcome, .loaded)
        let edited = try TreeOps.renameTab(state, id: Sample.ids.todayTab, customTitle: "Draft", now: Fx.t(500))
        await store.update(edited)
        await store.update(state)
        await scheduler.fireAll()
        try await store.flush()
        let writes = await store.writeCount
        let bytes = await store.bytesWritten
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(bytes, 0)
    }

    /// The same sync state bytes twice are written once.
    func testIdenticalSyncStateIsWrittenOnce() async {
        let store = makeStore()
        let blob = Data((0..<64).map { UInt8($0) })
        for _ in 0..<10 { await store.saveSyncState(blob) }
        var count = await store.syncStateWriteCount
        XCTAssertEqual(count, 1)
        await store.saveSyncState(Data([1]))
        await store.saveSyncState(blob)
        count = await store.syncStateWriteCount
        XCTAssertEqual(count, 3)
        let bytes = await store.syncStateBytesWritten
        XCTAssertEqual(bytes, 64 + 1 + 64)
    }

    /// The UI state file is not rewritten with the same contents.
    func testIdenticalUIStateIsNotRewritten() throws {
        let state = UIState()
        try UIStateFile.save(state, to: dir.url)
        let file = UIStateFile.url(in: dir.url)
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        try UIStateFile.save(state, to: dir.url)
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        XCTAssertEqual(before, after, "an atomic rewrite would replace the file (new inode)")
    }
}
