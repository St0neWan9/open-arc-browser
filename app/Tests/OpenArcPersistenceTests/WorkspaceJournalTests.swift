import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// B153: `workspace.json` is a compact snapshot without backend system fields, and local edits
/// append to `workspace.journal` instead of rewriting it.
final class WorkspaceJournalTests: XCTestCase {
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

    private var journalFile: URL { dir.url.appendingPathComponent(PersistenceDefaults.workspaceJournalFileName) }

    private func size(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    // MARK: Fixture

    struct Large {
        var state: WorkspaceState
        var spaces: [UUID]
        var todayTabs: [UUID]
        var pinnedTabs: [UUID]
        var nextID: Int
    }

    /// About 3,800 records, like the data dir that prompted B153 (~3,500): 6 Spaces, 198 folders,
    /// 3,000 tabs (most pinned in folders), 300 archived tabs, and archived CloudKit-like system
    /// fields (~1.6 KB, mostly shared bytes) on every synced record.
    static func large() throws -> Large {
        let profile = Fx.uuid(1)
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "Personal", now: Fx.t(0))
        var n = 100
        func id() -> UUID { n += 1; return Fx.uuid(n) }
        var spaces: [UUID] = []
        for k in 0..<6 {
            let space = id()
            spaces.append(space)
            s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "Space \(k)", now: Fx.t(1))
        }
        var folders: [UUID] = []
        for k in 0..<198 {
            let folder = id()
            folders.append(folder)
            s = try TreeOps.createFolder(s, id: folder, spaceID: spaces[k % 6], title: "Folder \(k)", now: Fx.t(2))
        }
        var today: [UUID] = []
        var pinned: [UUID] = []
        for k in 0..<3_000 {
            let tab = id()
            let space = k % 6
            s = try TreeOps.openTab(s, id: tab, spaceID: spaces[space],
                                    url: URL(string: "https://site\(k % 300).example.com/path/to/page/\(k)?q=\(k)"),
                                    title: "Bookmark \(k) with a reasonably long page title", now: Fx.t(3))
            if k % 10 == 0 {
                today.append(tab)
            } else {
                // Folders of Space `space` are those with index ≡ space (mod 6).
                let folder = folders[(k / 6 % 33) * 6 + space]
                s = try TreeOps.moveTab(s, id: tab, to: .pinned(spaceID: spaces[space], folderID: folder), position: .last, now: Fx.t(4))
                pinned.append(tab)
            }
        }
        for k in 0..<300 {
            let tab = id()
            s = try TreeOps.openTab(s, id: tab, spaceID: spaces[0], url: URL(string: "https://archived\(k).example.com/a"), title: "Archived \(k)", now: Fx.t(5))
            s = try TreeOps.archiveTab(s, id: tab, now: Fx.t(6))
        }
        let shared = Data((0..<1_500).map { UInt8($0 % 61) })
        for recordID in s.allSyncedRecordIDs {
            guard let record = s.record(for: recordID) else { continue }
            let unique = Data(recordID.recordName.utf8) + Data((0..<40).map { UInt8(($0 * 37 + recordID.recordName.hashValue) & 0xFF) })
            s.setRecord(record.withBackendSystemFields(shared + unique))
        }
        return Large(state: s, spaces: spaces, todayTabs: today, pinnedTabs: pinned, nextID: n + 1)
    }

    /// `workspace.json` as the build before B153 wrote it: pretty-printed, system fields inline,
    /// no generation.
    private func writeLegacyFile(_ state: WorkspaceState) throws {
        struct LegacyEnvelope: Encodable {
            var schemaVersion: Int
            var savedAt: Date
            var workspace: LegacyWorkspace
        }
        struct LegacyWorkspace: Encodable {
            var profiles: [Profile], themes: [Theme], spaces: [Space], folders: [Folder], tabs: [TabNode]
            var archive: [ArchiveItem], splits: [SplitLayout], easels: [Easel], easelElements: [EaselElement]
        }
        func sorted<T: Identifiable>(_ values: Dictionary<UUID, T>.Values) -> [T] where T.ID == UUID {
            values.sorted { $0.id.uuidString < $1.id.uuidString }
        }
        let legacy = LegacyEnvelope(schemaVersion: 1, savedAt: Fx.t(10), workspace: LegacyWorkspace(
            profiles: sorted(state.profiles.values), themes: sorted(state.themes.values), spaces: sorted(state.spaces.values),
            folders: sorted(state.folders.values), tabs: sorted(state.tabs.values), archive: sorted(state.archive.values),
            splits: sorted(state.splits.values), easels: sorted(state.easels.values), easelElements: sorted(state.easelElements.values)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try encoder.encode(legacy).write(to: dir.workspaceFile)
    }

    // MARK: Size and bytes per edit

    /// Plan B153 acceptance: on a ~3,800-record workspace, a typical local edit (rename, move,
    /// open, close a tab) writes < 1 MB, and the snapshot no longer carries system fields.
    func testTypicalEditsWriteFarLessThanOneMegabyte() async throws {
        let large = try Self.large()
        XCTAssertGreaterThan(large.state.allRecordIDs.count, 3_500)
        try writeLegacyFile(large.state)
        let legacyBytes = size(dir.workspaceFile)

        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        XCTAssertEqual(store.loadResult.outcome, .loaded)
        var state = await store.workspace
        // The first save after loading a legacy file is the migration: one snapshot.
        state = try TreeOps.renameTab(state, id: large.pinnedTabs[0], customTitle: "Migrated", now: Fx.t(2_000))
        await store.update(state)
        await scheduler.fireAll()
        var snapshots = await store.snapshotWriteCount
        XCTAssertEqual(snapshots, 1)
        let snapshotBytes = size(dir.workspaceFile)

        let edits: [(String, (WorkspaceState) throws -> WorkspaceState)] = [
            ("rename", { try TreeOps.renameTab($0, id: large.pinnedTabs[10], customTitle: "Renamed", now: Fx.t(2_001)) }),
            ("move", { try TreeOps.moveTab($0, id: large.pinnedTabs[20], to: .today(spaceID: large.spaces[2]), position: .first, now: Fx.t(2_002)) }),
            ("open", { try TreeOps.openTab($0, id: Fx.uuid(large.nextID), spaceID: large.spaces[0], url: URL(string: "https://new.example"), title: "New", now: Fx.t(2_003)) }),
            ("close", { try TreeOps.archiveTab($0, id: large.todayTabs[5], now: Fx.t(2_004)) }),
        ]
        var perEdit: [String: Int] = [:]
        for (name, edit) in edits {
            state = try edit(state)
            await store.update(state)
            await scheduler.fireAll()
            let bytes = await store.lastWriteBytes
            perEdit[name] = bytes
            XCTAssertLessThan(bytes, 1_000_000, name)
            XCTAssertLessThan(bytes, 16 * 1024, "\(name) writes only the records it changed")
        }
        snapshots = await store.snapshotWriteCount
        XCTAssertEqual(snapshots, 1, "edits append to the journal")
        print("[B153] legacy workspace.json \(legacyBytes) B, snapshot \(snapshotBytes) B, per edit \(perEdit.sorted { $0.key < $1.key })")
        XCTAssertLessThan(snapshotBytes, legacyBytes / 3, "no system fields, no indentation")

        // Load equality: a relaunch sees exactly the edited workspace (system fields as markers).
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.loadResult.workspace, state.diskForm)
    }

    // MARK: Migration

    /// A data dir written by the build before B153 (pretty JSON, system fields inline, no
    /// generation) loads unchanged apart from system fields, which become markers; the first
    /// write migrates it to a snapshot of the new format, and nothing is lost.
    func testLegacyFileLoadsAndMigratesSilently() async throws {
        let original = try Sample.workspace()
        try writeLegacyFile(original)
        let store = makeStore()
        XCTAssertEqual(store.loadResult.outcome, .loaded)
        let loaded = store.loadResult.workspace
        XCTAssertEqual(loaded.tabs[Sample.ids.todayTab]?.meta.backendSystemFields, Data([0xDE, 0xAD, 0xBE, 0xEF]),
                       "the legacy file's system fields are read as they are")
        XCTAssertEqual(loaded.diskForm, original.diskForm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFile.path))

        // The first save is a snapshot (no journal continues a legacy file).
        let edited = try TreeOps.renameTab(loaded, id: Sample.ids.pinnedTab, customTitle: "After migration", now: Fx.t(500))
        await store.update(edited)
        try await store.flush()
        let snapshots = await store.snapshotWriteCount
        XCTAssertEqual(snapshots, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.workspaceFile)) as? [String: Any])
        XCTAssertNotNil(json["generation"])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1, "the change is additive: no schema bump")
        XCTAssertEqual(makeStore().loadResult.workspace, edited.diskForm)
        XCTAssertEqual(makeStore().loadResult.workspace.tabs[Sample.ids.todayTab]?.meta.backendSystemFields, SystemFieldsOnDisk.marker,
                       "a record that had system fields still shows it came from the server")
    }

    /// Rollback note: what a build before B153 reads. After a clean quit (`flush`) the snapshot
    /// holds everything, and it decodes with the old shape (the old decoder ignores `generation`).
    /// Edits still in the journal when such a build starts are not seen by it; it then writes a
    /// snapshot without a generation, which makes the stale journal inapplicable here.
    func testSnapshotDecodesWithThePreviousFormatAndAJournalIsNotAppliedToAnOldSnapshot() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        var state = try Sample.workspace()
        await store.update(state)
        await scheduler.fireAll()
        state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "In journal", now: Fx.t(600))
        await store.update(state)
        await scheduler.fireAll()
        XCTAssertGreaterThan(size(journalFile), 0)

        // The previous build's decoder: the envelope without `generation`.
        struct PreviousEnvelope: Decodable {
            var schemaVersion: Int
            var savedAt: Date
            var workspace: PersistedWorkspace
        }
        let before = try JSONDecoder().decode(PreviousEnvelope.self, from: Data(contentsOf: dir.workspaceFile))
        XCTAssertNotEqual(before.workspace.state.tabs[Sample.ids.pinnedTab]?.customTitle, "In journal",
                          "an unflushed edit is in the journal only")
        try await store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: journalFile.path), "flush compacts")
        let after = try JSONDecoder().decode(PreviousEnvelope.self, from: Data(contentsOf: dir.workspaceFile))
        XCTAssertEqual(after.workspace.state, state.diskForm, "after a clean quit the old shape sees everything")

        // An older build rewrote the snapshot (no generation); a journal left over must not apply.
        let leftover = try WorkspaceJournal.encode(WorkspaceJournalEntry(
            generation: UUID(), savedAt: Fx.t(700),
            records: PersistedWorkspace(WorkspaceState(tabs: [Sample.ids.pinnedTab: try XCTUnwrap(
                TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "Stale", now: Fx.t(700)).tabs[Sample.ids.pinnedTab])])),
            removed: []))
        try leftover.write(to: journalFile)
        try writeLegacyFile(state)
        XCTAssertEqual(makeStore().loadResult.workspace.tabs[Sample.ids.pinnedTab]?.customTitle, "In journal")
    }

    // MARK: Crash safety

    /// A crash after a journal append but before compaction: the next launch replays the entry.
    /// A crash after the new snapshot was renamed in but before the journal was removed: the
    /// entries name the old generation and are skipped (applying them again would change nothing
    /// anyway: they hold whole records).
    func testCrashBetweenAppendAndCompaction() async throws {
        let scheduler = ManualAutosaveScheduler()
        var state = try Sample.workspace()
        do {
            let store = makeStore(scheduler)
            await store.update(state)
            await scheduler.fireAll()
            state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "One", now: Fx.t(600))
            await store.update(state)
            await scheduler.fireAll()
            state = try TreeOps.renameFolder(state, id: Sample.ids.folder, title: "Two", now: Fx.t(601))
            await store.update(state)
            await scheduler.fireAll()
            // "Crash": the store is dropped without flush.
        }
        let journalBefore = try Data(contentsOf: journalFile)
        let snapshotBefore = try Data(contentsOf: dir.workspaceFile)
        let relaunched = makeStore(scheduler)
        XCTAssertEqual(relaunched.loadResult.workspace, state.diskForm, "the journal is replayed")

        // Compaction interrupted after the rename: new snapshot, old journal still there.
        try await relaunched.flush()
        let compacted = try Data(contentsOf: dir.workspaceFile)
        XCTAssertNotEqual(compacted, snapshotBefore)
        try journalBefore.write(to: journalFile)
        XCTAssertEqual(makeStore().loadResult.workspace, state.diskForm, "stale entries are skipped")

        // Replaying the same entries twice (idempotence) gives the same state.
        guard case .workspace(let snapshotState, let decodedGeneration) = WorkspaceFileCodec.decode(snapshotBefore) else {
            return XCTFail("snapshot does not decode")
        }
        let generation = try XCTUnwrap(decodedGeneration)
        let once = WorkspaceJournal.replay(journalBefore, onto: snapshotState, generation: generation)
        let twice = WorkspaceJournal.replay(journalBefore + journalBefore, onto: snapshotState, generation: generation)
        XCTAssertEqual(once.appliedEntries, 2)
        XCTAssertEqual(twice.state, once.state)
    }

    /// A torn last entry (the process died mid-write) is ignored on load, and the next append
    /// overwrites it, so later entries are not lost behind it.
    func testTornJournalEntryIsIgnoredAndOverwritten() async throws {
        let scheduler = ManualAutosaveScheduler()
        var state = try Sample.workspace()
        do {
            let store = makeStore(scheduler)
            await store.update(state)
            await scheduler.fireAll()
            state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "Kept", now: Fx.t(600))
            await store.update(state)
            await scheduler.fireAll()
        }
        let complete = try Data(contentsOf: journalFile)
        let torn = Data(#"{"generation":"00000000-0000-0000-0000-000000000000","records":{"tab"#.utf8)
        try (complete + torn).write(to: journalFile)

        let store = makeStore(scheduler)
        XCTAssertEqual(store.loadResult.workspace, state.diskForm)
        state = try TreeOps.renameFolder(store.loadResult.workspace, id: Sample.ids.folder, title: "After tear", now: Fx.t(700))
        await store.update(state)
        await scheduler.fireAll()
        let snapshots = await store.snapshotWriteCount
        XCTAssertEqual(snapshots, 0, "the edit was appended")
        XCTAssertFalse(try Data(contentsOf: journalFile).contains(torn), "the torn bytes were cut off")
        XCTAssertEqual(makeStore().loadResult.workspace, state.diskForm)
    }

    /// A journal past its limit is compacted into a snapshot by the next save.
    func testJournalIsCompactedPastItsLimit() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        var state = try Sample.workspace()
        await store.update(state)
        await scheduler.fireAll()
        let limit = WorkspaceJournal.compactionLimit(snapshotBytes: size(dir.workspaceFile))
        var n = 0
        while UInt64(size(journalFile)) + 4_096 < limit {
            n += 1
            state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "Title \(n) " + String(repeating: "x", count: 2_000), now: Fx.t(600 + Double(n)))
            await store.update(state)
            await scheduler.fireAll()
        }
        let before = await store.snapshotWriteCount
        for _ in 0..<3 {
            n += 1
            state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "Title \(n) " + String(repeating: "x", count: 2_000), now: Fx.t(600 + Double(n)))
            await store.update(state)
            await scheduler.fireAll()
        }
        let after = await store.snapshotWriteCount
        XCTAssertEqual(after, before + 1, "one compaction")
        XCTAssertLessThan(UInt64(size(journalFile)), limit)
        XCTAssertEqual(makeStore().loadResult.workspace, state.diskForm)
    }

    /// A journal removed behind the store's back (it had entries) makes the next save a snapshot,
    /// so the edits it held are written again rather than lost.
    func testMissingJournalMakesTheNextSaveASnapshot() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        var state = try Sample.workspace()
        await store.update(state)
        await scheduler.fireAll()
        state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "One", now: Fx.t(600))
        await store.update(state)
        await scheduler.fireAll()
        try FileManager.default.removeItem(at: journalFile)
        state = try TreeOps.renameFolder(state, id: Sample.ids.folder, title: "Two", now: Fx.t(601))
        await store.update(state)
        await scheduler.fireAll()
        let snapshots = await store.snapshotWriteCount
        XCTAssertEqual(snapshots, 2)
        XCTAssertEqual(makeStore().loadResult.workspace, state.diskForm)
    }

    /// The daily backup taken from a journal save is a complete file holding the saved state.
    func testBackupFromAJournalSaveIsComplete() async throws {
        let clock = TestClock(Fx.t(0))
        let scheduler = ManualAutosaveScheduler()
        let store = WorkspaceStore(directory: dir.url, scheduler: scheduler, now: { clock.now })
        var state = try Sample.workspace()
        await store.update(state)
        await scheduler.fireAll()
        clock.set(Fx.t(2 * 24 * 3600))
        state = try TreeOps.renameTab(state, id: Sample.ids.pinnedTab, customTitle: "Day two", now: clock.now)
        await store.update(state)
        await scheduler.fireAll()
        await store.waitForBackups()
        let snapshots = await store.snapshotWriteCount
        XCTAssertEqual(snapshots, 1, "the edit went to the journal")
        let newest = try XCTUnwrap(store.backups().first)
        XCTAssertEqual(try WorkspaceBackups.load(newest), state.diskForm)
    }
}
