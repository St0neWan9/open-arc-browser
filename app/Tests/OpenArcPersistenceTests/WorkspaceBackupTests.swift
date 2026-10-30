import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// A clock tests move by hand.
// @unchecked: `value` is read and written only under `lock`.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date) { value = start }

    var now: Date { lock.withLock { value } }

    func set(_ date: Date) { lock.withLock { value = date } }
}

/// Plan B117 (decision Q18, [01 §Help] "Restore Data" observed item): rolling local backups of the
/// workspace file, and restoring one as ordinary local edits.
final class WorkspaceBackupTests: XCTestCase {
    private var dir: TempDirectory!
    private let day: TimeInterval = 24 * 3600

    override func setUp() {
        dir = TempDirectory()
    }

    override func tearDown() {
        dir.cleanUp()
    }

    private func makeStore(_ clock: TestClock) -> WorkspaceStore {
        WorkspaceStore(directory: dir.url, autosaveDelay: 1, scheduler: ManualAutosaveScheduler(), now: { clock.now })
    }

    private func save(_ store: WorkspaceStore, _ state: WorkspaceState) async throws {
        await store.update(state)
        try await store.flush()
        await store.waitForBackups()
    }

    // MARK: Rotation

    /// One backup a day at most while the app runs; the newest seven are kept.
    func testOneBackupPerDayAndTheLastSevenAreKept() async throws {
        let clock = TestClock(Fx.t(0))
        let store = makeStore(clock)
        var state = try Sample.workspace()
        try await save(store, state)
        XCTAssertEqual(dir.backupNames(), [WorkspaceBackups.fileName(for: Fx.t(0))])

        // More saves the same day add none.
        for hour in 1...5 {
            clock.set(Fx.t(Double(hour) * 3600))
            state = try TreeOps.renameSpace(state, id: Sample.ids.space, name: "Home \(hour)", now: clock.now)
            try await save(store, state)
        }
        XCTAssertEqual(dir.backupNames().count, 1)

        // One a day for nine more days: ten taken, seven kept (the newest).
        var expected = [Fx.t(0)]
        for n in 1...9 {
            clock.set(Fx.t(Double(n) * day + 60))
            expected.append(clock.now)
            state = try TreeOps.renameSpace(state, id: Sample.ids.space, name: "Day \(n)", now: clock.now)
            try await save(store, state)
        }
        let kept = expected.suffix(WorkspaceBackups.keepCount).map(WorkspaceBackups.fileName(for:))
        XCTAssertEqual(dir.backupNames(), kept.sorted())
        XCTAssertEqual(store.backups().map(\.url.lastPathComponent), kept.reversed(), "newest first")
        XCTAssertEqual(store.backups().first?.createdAt.timeIntervalSince1970,
                       Fx.t(9 * day + 60).timeIntervalSince1970.rounded(.down), "second resolution")

        // The newest backup holds what the store wrote then.
        let newest = try WorkspaceBackups.load(XCTUnwrap(store.backups().first))
        XCTAssertEqual(newest.spaces[Sample.ids.space]?.name, "Day 9")
        XCTAssertNil(store.lastBackupError)
    }

    /// At launch: a backup of the file as loaded when the newest backup is a day old or more.
    func testLaunchBacksUpWhenTheNewestBackupIsADayOld() async throws {
        let clock = TestClock(Fx.t(0))
        let first = makeStore(clock)
        try await save(first, try Sample.workspace())
        XCTAssertEqual(dir.backupNames().count, 1)

        clock.set(Fx.t(day - 60))
        let sameDay = makeStore(clock)
        await sameDay.waitForBackups()
        XCTAssertEqual(dir.backupNames().count, 1, "the newest is less than a day old")

        clock.set(Fx.t(day + 60))
        let nextDay = makeStore(clock)
        await nextDay.waitForBackups()
        XCTAssertEqual(dir.backupNames(), [WorkspaceBackups.fileName(for: Fx.t(0)), WorkspaceBackups.fileName(for: Fx.t(day + 60))])
        let launchCopy = try Data(contentsOf: XCTUnwrap(nextDay.backups().first).url)
        XCTAssertEqual(launchCopy, try Data(contentsOf: dir.workspaceFile), "a byte copy of the file as loaded")
    }

    func testFirstLaunchAndEmptyFolderHaveNoBackups() async {
        let store = makeStore(TestClock(Fx.t(0)))
        await store.waitForBackups()
        XCTAssertEqual(dir.contents(), [], "loading never creates files")
        XCTAssertFalse(store.canRestoreBackup)
        XCTAssertEqual(store.backups(), [])
    }

    /// A read-only store (a file from a newer version) writes no backup, at launch or later.
    func testReadOnlyStoreWritesNoBackups() async throws {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 99, "workspace": {}}"#.utf8).write(to: dir.workspaceFile)
        let store = makeStore(TestClock(Fx.t(0)))
        XCTAssertTrue(store.isReadOnly)
        await store.update(try Sample.workspace())
        try? await store.flush()
        await store.waitForBackups()
        XCTAssertEqual(dir.contents(), [PersistenceDefaults.workspaceFileName])
        XCTAssertFalse(store.canRestoreBackup)
    }

    /// Files in the folder that are not ours are ignored by the list and by pruning.
    func testForeignFilesAreIgnored() async throws {
        let folder = WorkspaceBackups.directory(in: dir.url)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: folder.appendingPathComponent("workspace-garbage.json"))
        let store = makeStore(TestClock(Fx.t(0)))
        try await save(store, try Sample.workspace())
        XCTAssertEqual(store.backups().count, 1)
        XCTAssertTrue(dir.backupNames().contains("notes.txt"))
        XCTAssertEqual(WorkspaceBackupSummary(try WorkspaceBackups.load(store.backups()[0])),
                       WorkspaceBackupSummary(try Sample.workspace()))
    }

    func testSummaryCountsLiveSpacesAndTabs() throws {
        let summary = WorkspaceBackupSummary(try Sample.workspace())
        // Sample: Home live, Old deleted; pinned, today, favorite and split tabs live.
        XCTAssertEqual(summary.spaceCount, 1)
        XCTAssertEqual(summary.tabCount, 4)
    }

    // MARK: Restore

    /// Live records, without sync metadata and last-active times: what the sidebar shows.
    private func liveContent(_ s: WorkspaceState) -> WorkspaceState {
        func live<T: SyncableEntity>(_ records: [UUID: T]) -> [UUID: T] {
            records.filter { !$0.value.meta.isTombstone }.mapValues { var v = $0; v.meta = SyncMetadata(createdAt: .distantPast); return v }
        }
        var result = WorkspaceState(
            profiles: live(s.profiles), themes: live(s.themes), spaces: live(s.spaces), folders: live(s.folders),
            tabs: live(s.tabs), archive: live(s.archive), splits: live(s.splits), easels: live(s.easels),
            easelElements: live(s.easelElements)
        )
        for id in result.tabs.keys { result.tabs[id]?.lastActiveAt = .distantPast }
        return result
    }

    /// Edits since the backup are undone in place (same ids, groups stamped now); records created
    /// since are tombstoned. Afterwards the live records equal the backup's.
    func testRestoreUndoesEditsAndTombstonesNewRecords() throws {
        let i = Sample.ids
        let backup = try Sample.workspace()
        var current = try TreeOps.renameSpace(backup, id: i.space, name: "Renamed", now: Fx.t(100))
        current = try TreeOps.renameTab(current, id: i.pinnedTab, customTitle: "Other", now: Fx.t(101))
        current = try TreeOps.moveTab(current, id: i.favoriteTab, to: .today(spaceID: i.space), position: .first, now: Fx.t(102))
        let newTab = Fx.uuid(500)
        current = try TreeOps.openTab(current, id: newTab, spaceID: i.space, url: URL(string: "https://new.example"), title: "New", now: Fx.t(103))

        let now = Fx.t(1_000)
        let restored = WorkspaceRestore.restored(current: current, backup: backup, now: now, makeID: { XCTFail("no new ids needed"); return UUID() })

        XCTAssertEqual(liveContent(restored), liveContent(backup))
        XCTAssertEqual(restored.tabs[newTab]?.meta.isTombstone, true, "made after the backup: deleted")
        XCTAssertEqual(restored.tabs[newTab]?.meta.deletedAt, now)
        // Only the groups that differed are stamped, with `now`.
        let space = try XCTUnwrap(restored.spaces[i.space])
        XCTAssertEqual(space.meta.modifiedAt(Space.FieldGroup.naming), now)
        XCTAssertEqual(space.meta.modifiedAt(Space.FieldGroup.theme), current.spaces[i.space]?.meta.modifiedAt(Space.FieldGroup.theme))
        XCTAssertGreaterThan(space.meta.version, current.spaces[i.space]!.meta.version)
        XCTAssertEqual(restored.tabs[i.favoriteTab]?.meta.modifiedAt(TabNode.FieldGroup.placement), now)
        XCTAssertEqual(restored.tabs[i.todayTab], current.tabs[i.todayTab], "unchanged records are untouched")
        // Every changed record is visible to the stamp-based diff the store and sync use.
        let changes = WorkspaceDiff.stampedChanges(from: current, to: restored)
        XCTAssertEqual(Set(changes.saved), Set(WorkspaceDiff.changes(from: current, to: restored).saved))
        XCTAssertEqual(Set(changes.saved), [
            SyncRecordID(type: .space, uuid: i.space), SyncRecordID(type: .tab, uuid: i.pinnedTab),
            SyncRecordID(type: .tab, uuid: i.favoriteTab), SyncRecordID(type: .tab, uuid: newTab),
        ])
    }

    /// A record deleted since the backup is never resurrected: its tombstone stays and the backup's
    /// copy comes back under a new id, with references rewritten. Nothing is purged.
    func testRecordsDeletedSinceTheBackupComeBackUnderNewIDs() throws {
        let i = Sample.ids
        let backup = try Sample.workspace()
        // Delete the folder (archives the pinned tab inside), and archive the Today tab.
        var current = try TreeOps.deleteFolder(backup, id: i.folder, now: Fx.t(100))
        current = try TreeOps.archiveTab(current, id: i.favoriteTab, now: Fx.t(101))
        var ids = (900..<920).map(Fx.uuid).makeIterator()
        let restored = WorkspaceRestore.restored(current: current, backup: backup, now: Fx.t(1_000), makeID: { ids.next()! })

        XCTAssertEqual(restored.folders[i.folder]?.meta.isTombstone, true, "a tombstone is never undone")
        XCTAssertEqual(restored.tabs[i.pinnedTab]?.meta.isTombstone, true)
        XCTAssertEqual(restored.tabs[i.favoriteTab]?.meta.isTombstone, true)
        for id in current.allRecordIDs { XCTAssertNotNil(restored.record(for: id), "\(id) not purged") }

        let folder = try XCTUnwrap(restored.folders.values.first { !$0.meta.isTombstone && $0.spaceID == i.space })
        XCTAssertNotEqual(folder.id, i.folder)
        XCTAssertEqual(folder.title, "Reading")
        XCTAssertEqual(folder.meta.createdAt, Fx.t(1_000), "a new record")
        let pinned = try XCTUnwrap(restored.tabs.values.first { !$0.meta.isTombstone && $0.url?.host == "pinned.example" })
        XCTAssertEqual(pinned.location, .pinned(spaceID: i.space, folderID: folder.id), "points at the new folder")
        XCTAssertEqual(pinned.customTitle, "My pinned")
        XCTAssertEqual(pinned.lastActiveAt, Fx.t(1_000), "a re-created tab is active now")
        // The favorite was archived and comes back as a favorite.
        XCTAssertEqual(restored.tabs.values.filter { !$0.meta.isTombstone && $0.location == .favorite(profileID: i.profile) }.map(\.title), ["Fav"])
        // Archive items made by the deletes are not in the backup: tombstoned.
        let newArchive = current.archive.keys.filter { backup.archive[$0] == nil }
        XCTAssertFalse(newArchive.isEmpty)
        for id in newArchive { XCTAssertEqual(restored.archive[id]?.meta.isTombstone, true) }
        // Same live counts as the backup.
        XCTAssertEqual(WorkspaceBackupSummary(restored), WorkspaceBackupSummary(backup))
    }

    /// Splits whose panes are re-created point at the new tab ids.
    func testSplitPanesFollowRecreatedTabs() throws {
        let i = Sample.ids
        let backup = try Sample.workspace()
        // Archiving a split tab ends the split (one pane left): both records are tombstoned.
        let current = try TreeOps.archiveTab(backup, id: i.splitTab, now: Fx.t(100))
        XCTAssertEqual(current.splits[i.split]?.meta.isTombstone, true)
        var ids = (900..<920).map(Fx.uuid).makeIterator()
        let restored = WorkspaceRestore.restored(current: current, backup: backup, now: Fx.t(1_000), makeID: { ids.next()! })
        let split = try XCTUnwrap(restored.splits.values.first { !$0.meta.isTombstone })
        XCTAssertNotEqual(split.id, i.split)
        XCTAssertTrue(split.root.tabIDs.contains(i.todayTab), "a live tab keeps its id")
        let newPane = try XCTUnwrap(split.root.tabIDs.first { $0 != i.todayTab })
        XCTAssertEqual(restored.tabs[newPane]?.meta.isTombstone, false)
        XCTAssertEqual(restored.tabs[newPane]?.title, "New Tab")
    }

    /// Profiles never sync, so a deleted one is made live again under its own id, and a profile
    /// made after the backup is kept.
    func testProfilesKeepTheirIDs() throws {
        let i = Sample.ids
        let backup = try Sample.workspace()
        var current = TreeOps.createProfile(backup, id: Fx.uuid(600), name: "Work", now: Fx.t(100))
        current.profiles[i.profile]?.meta.markDeleted(at: Fx.t(101))
        let restored = WorkspaceRestore.restored(current: current, backup: backup, now: Fx.t(1_000), makeID: { UUID() })
        XCTAssertEqual(restored.profiles[i.profile]?.meta.isTombstone, false)
        XCTAssertEqual(restored.profiles[i.profile]?.name, "Personal")
        XCTAssertEqual(restored.profiles[Fx.uuid(600)]?.meta.isTombstone, false)
    }

    /// The restore goes through the store as a local change: saved, and every changed record is
    /// announced for sync (`pendingChanges`), deletions as tombstone saves.
    func testRestoreThroughTheStoreReachesSync() async throws {
        let clock = TestClock(Fx.t(0))
        let store = makeStore(clock)
        let backup = try Sample.workspace()
        try await save(store, backup)
        let backupFile = try XCTUnwrap(store.backups().first)

        clock.set(Fx.t(100))
        var edited = try TreeOps.renameSpace(backup, id: Sample.ids.space, name: "Renamed", now: clock.now)
        edited = try TreeOps.openTab(edited, id: Fx.uuid(500), spaceID: Sample.ids.space, url: nil, title: "New", now: clock.now)
        try await save(store, edited)

        let current = await store.currentWorkspace()
        let (_, events) = await store.subscribe()
        let restored = WorkspaceRestore.restored(current: current, backup: try WorkspaceBackups.load(backupFile), now: Fx.t(200), makeID: { UUID() })
        store.submit(changesFrom: current, to: restored)
        var iterator = events.makeAsyncIterator()
        let next = await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.origin, .local)
        XCTAssertEqual(Set(event.pendingChanges), [
            .save(SyncRecordID(type: .space, uuid: Sample.ids.space)), .save(SyncRecordID(type: .tab, uuid: Fx.uuid(500))),
        ])
        try await store.flush()
        let reloaded = makeStore(clock).loadResult.workspace
        XCTAssertEqual(liveContent(reloaded), liveContent(backup))
        XCTAssertEqual(reloaded.tabs[Fx.uuid(500)]?.meta.isTombstone, true)
    }
}
