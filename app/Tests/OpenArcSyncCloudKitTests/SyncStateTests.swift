import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// Persisted sync state, its file storage, the pending queue and the sync scope.
final class SyncStateTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        // Lives under app/.build so test files never land outside the package build area.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        tempDir = packageRoot
            .appendingPathComponent(".build/synctests-tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func sampleState() -> PersistedSyncState {
        var state = PersistedSyncState()
        state.engineState = Data("engine".utf8)
        state.pending.add(SyncRecordID(type: .tab, uuid: Fx.uuid(1)), .save)
        state.pending.add(SyncRecordID(type: .folder, uuid: Fx.uuid(2)), .delete)
        state.systemFields["Tab/\(Fx.uuid(1).uuidString)"] = Data([1, 2, 3])
        state.systemFields["Folder/\(Fx.uuid(2).uuidString)"] = Data()
        state.zoneSaved = true
        state.lastSyncedAt = Fx.t(5)
        state.awaitingAccountReset = true
        state.deferredUpserts = [.tab(Fx.tab()), .archiveItem(Fx.archiveItem())]
        state.deferredDeletions = [SyncRecordID(type: .space, uuid: Fx.uuid(3))]
        return state
    }

    // MARK: Serialization

    func testPersistedStateRoundTrip() throws {
        let state = sampleState()
        let data = try XCTUnwrap(state.encoded())
        XCTAssertEqual(PersistedSyncState.decode(data), state)
    }

    func testDecodeFallsBackToFreshStateOnBadInput() throws {
        XCTAssertEqual(PersistedSyncState.decode(nil), PersistedSyncState())
        XCTAssertEqual(PersistedSyncState.decode(Data("not json".utf8)), PersistedSyncState())

        // A different format version is not trusted.
        var future = sampleState()
        future.formatVersion = PersistedSyncState.currentFormatVersion + 1
        XCTAssertEqual(PersistedSyncState.decode(future.encoded()), PersistedSyncState())
    }

    // MARK: File storage

    func testFileStorageSaveLoadAndRemove() async throws {
        let file = tempDir.appendingPathComponent("nested/dir/sync-state.json")
        let storage = FileSyncStateStorage(fileURL: file)

        let missing = try await storage.loadState()
        XCTAssertNil(missing, "no file yet")

        let data = try XCTUnwrap(sampleState().encoded())
        try await storage.saveState(data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "creates intermediate directories")
        let loaded = try await storage.loadState()
        XCTAssertEqual(loaded, data)
        XCTAssertEqual(PersistedSyncState.decode(loaded), sampleState())

        // Overwrite.
        try await storage.saveState(Data("second".utf8))
        let second = try await storage.loadState()
        XCTAssertEqual(second, Data("second".utf8))

        // nil removes the file; removing twice is fine.
        try await storage.saveState(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try await storage.saveState(nil)
        let removed = try await storage.loadState()
        XCTAssertNil(removed)
    }

    func testLocalDatabaseStorageUsesDatabaseHooks() async throws {
        let database = FakeDatabase()
        let storage = LocalDatabaseSyncStateStorage(database: database)
        try await storage.saveState(Data("x".utf8))
        let stored = await database.loadSyncState()
        XCTAssertEqual(stored, Data("x".utf8))
        let loaded = try await storage.loadState()
        XCTAssertEqual(loaded, Data("x".utf8))
    }

    // MARK: Pending queue

    func testPendingQueueCoalescesAndTracksGenerations() {
        var queue = PendingQueue()
        let a = SyncRecordID(type: .tab, uuid: Fx.uuid(1))
        let b = SyncRecordID(type: .tab, uuid: Fx.uuid(2))
        let first = queue.add(a, .save)
        queue.add(b, .save)
        let second = queue.add(a, .delete)

        XCTAssertEqual(queue.count, 2, "one entry per record")
        XCTAssertEqual(queue.entries.map(\.id), [a, b], "keeps enqueue order")
        XCTAssertEqual(queue.entry(for: a)?.operation, .delete)
        XCTAssertGreaterThan(second.generation, first.generation)

        // A confirmation for the older send must not drop the newer change.
        XCTAssertFalse(queue.remove(a, ifGeneration: first.generation))
        XCTAssertNotNil(queue.entry(for: a))
        XCTAssertTrue(queue.remove(a, ifGeneration: second.generation))
        XCTAssertNil(queue.entry(for: a))

        XCTAssertTrue(queue.remove(b))
        XCTAssertFalse(queue.remove(b))
        XCTAssertTrue(queue.isEmpty)
    }

    func testPendingQueueGenerationsSurviveSerialization() throws {
        var state = PersistedSyncState()
        let id = SyncRecordID(type: .tab, uuid: Fx.uuid(1))
        state.pending.add(id, .save)
        state.pending.add(id, .save)
        var restored = PersistedSyncState.decode(state.encoded())
        let next = restored.pending.add(SyncRecordID(type: .tab, uuid: Fx.uuid(2)), .save)
        XCTAssertEqual(next.generation, 3, "generation counter persists, so old confirmations never match new edits")
    }

    // MARK: Scope

    /// Archive items sync by default (SyncScope.swift: pending product decision; see
    /// OpenArcSyncAPI/SyncStore.swift open question).
    func testDefaultScopeIncludesEveryTypeIncludingArchiveItems() {
        let scope = SyncScope.default
        for type in SyncRecordType.allCases {
            XCTAssertTrue(scope.includes(type), "\(type)")
        }
        XCTAssertTrue(scope.includes(.archiveItem))
        XCTAssertTrue(scope.includes(SyncRecord.archiveItem(Fx.archiveItem())))
    }

    func testCustomScopeExcludesRemovedTypes() {
        var types = Set(SyncRecordType.allCases)
        types.remove(.archiveItem)
        let scope = SyncScope(syncedTypes: types)
        XCTAssertFalse(scope.includes(.archiveItem))
        XCTAssertFalse(scope.includes(SyncRecord.archiveItem(Fx.archiveItem())))
        XCTAssertTrue(scope.includes(SyncRecord.tab(Fx.tab())))
    }
}
