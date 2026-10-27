import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// The store as a `SyncLocalDatabase`, and the diff that turns local edits into `PendingChange`s.
final class SyncDatabaseTests: XCTestCase {
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

    private func tabID(_ uuid: UUID) -> SyncRecordID { SyncRecordID(type: .tab, uuid: uuid) }

    // MARK: Diff → PendingChange

    func testDiffCoversCreateUpdateTombstoneAndPurge() throws {
        let i = Sample.ids
        let old = try Sample.workspace()
        var new = try TreeOps.openTab(old, id: Fx.uuid(30), spaceID: i.space, url: nil, title: "Created", now: Fx.t(100))
        new = try TreeOps.renameFolder(new, id: i.folder, title: "Updated", now: Fx.t(101))
        new = try TreeOps.archiveTab(new, id: i.pinnedTab, now: Fx.t(102))
        new.splits[i.split] = nil // purged after the sync layer uploaded its deletion

        let changes = WorkspaceDiff.changes(from: old, to: new)
        XCTAssertEqual(Set(changes.saved), [
            tabID(Fx.uuid(30)),                                      // create
            SyncRecordID(type: .folder, uuid: i.folder),             // update
            tabID(i.pinnedTab),                                      // tombstone
            SyncRecordID(type: .archiveItem, uuid: i.pinnedTab),     // archive entry created
        ])
        XCTAssertEqual(changes.removed, [SyncRecordID(type: .splitLayout, uuid: i.split)])

        let pending = WorkspaceDiff.pendingChanges(from: old, to: new)
        XCTAssertEqual(pending.count, 5)
        XCTAssertTrue(pending.contains(.save(tabID(Fx.uuid(30)))))
        XCTAssertTrue(pending.contains(.save(tabID(i.pinnedTab))))
        XCTAssertTrue(pending.contains(.delete(SyncRecordID(type: .splitLayout, uuid: i.split))))
        let names = pending.map { change -> String in
            switch change {
            case .save(let id), .delete(let id): return id.recordName
            }
        }
        XCTAssertEqual(names, names.sorted(), "sorted by record name")
        XCTAssertTrue(WorkspaceDiff.changes(from: new, to: new).isEmpty)
    }

    func testDiffOrderIsDeterministic() throws {
        let old = WorkspaceState()
        let new = try Sample.workspace()
        XCTAssertEqual(WorkspaceDiff.pendingChanges(from: old, to: new), WorkspaceDiff.pendingChanges(from: old, to: new))
        XCTAssertEqual(WorkspaceDiff.changes(from: old, to: new).saved.count, new.allRecordIDs.count)
    }

    /// Local edits come out of the event stream with their pending changes.
    func testLocalUpdateEmitsPendingChanges() async throws {
        let store = makeStore()
        let base = try Sample.workspace()
        await store.update(base)
        let stream = await store.events()
        let renamed = try TreeOps.renameTab(base, id: Sample.ids.todayTab, customTitle: "X", now: Fx.t(200))
        await store.update(renamed)

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.origin, .local)
        XCTAssertEqual(event.workspace, renamed)
        XCTAssertEqual(event.pendingChanges, [.save(tabID(Sample.ids.todayTab))])
    }

    // MARK: record(for:)

    func testRecordForMapsEveryTypeAndTombstones() async throws {
        let store = makeStore()
        let state = try Sample.workspace()
        await store.update(state)
        for id in state.allRecordIDs {
            let record = await store.record(for: id)
            XCTAssertEqual(record?.id, id)
        }
        let i = Sample.ids
        let tombstone = await store.record(for: tabID(i.archivedTab))
        XCTAssertEqual(tombstone?.meta.isTombstone, true)
        // An archive item shares its tab's UUID; the type keeps them apart.
        let archive = await store.record(for: SyncRecordID(type: .archiveItem, uuid: i.archivedTab))
        guard case .archiveItem = archive else { return XCTFail("expected an archive item") }
        let missing = await store.record(for: tabID(Fx.uuid(999)))
        XCTAssertNil(missing)
    }

    // MARK: apply(_:) under the conflict policy

    private func base() throws -> (WorkspaceStore, WorkspaceState, TabNode) {
        let store = makeStore()
        let state = try Sample.workspace()
        return (store, state, try XCTUnwrap(state.tabs[Sample.ids.todayTab]))
    }

    /// Different field groups both survive; the local win is reported for re-upload.
    func testApplyMergesFieldGroupsAndReportsLocalWins() async throws {
        let (store, state, tab) = try base()
        let local = try TreeOps.renameTab(state, id: tab.id, customTitle: "Local name", now: Fx.t(300))
        await store.update(local)
        try await store.flush()

        var server = tab
        server.url = URL(string: "https://server.example")
        server.title = "Server title"
        server.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(250))
        server.meta.backendSystemFields = Data([9])

        let stream = await store.events()
        try await store.apply(RemoteChangeBatch(upserts: [.tab(server)]))

        let mergedTab = await store.workspace.tabs[tab.id]
        let merged = try XCTUnwrap(mergedTab)
        XCTAssertEqual(merged.customTitle, "Local name", "local naming group is newer")
        XCTAssertEqual(merged.url, URL(string: "https://server.example"), "server content group is newer")
        XCTAssertEqual(merged.title, "Server title")
        XCTAssertEqual(merged.meta.backendSystemFields, Data([9]), "system fields come from the server")

        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.origin, .remote)
        XCTAssertEqual(event.changes.saved, [tabID(tab.id)])
        XCTAssertEqual(event.pendingChanges, [.save(tabID(tab.id))], "local naming must be uploaded again")

        // apply persists before returning.
        let reloaded = WorkspaceStore(directory: dir.url, scheduler: ManualAutosaveScheduler())
        XCTAssertEqual(reloaded.loadResult.workspace.tabs[tab.id], merged)
    }

    /// Within one group the later write wins; ties go to the server.
    func testApplyLaterWriteWinsAndTiesGoToTheServer() async throws {
        let (store, state, tab) = try base()
        var local = state
        local.tabs[tab.id]?.customTitle = "Local"
        local.tabs[tab.id]?.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(400))
        await store.update(local)

        var newer = tab
        newer.customTitle = "Newer server"
        newer.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(500))
        try await store.apply(RemoteChangeBatch(upserts: [.tab(newer)]))
        var current = await store.workspace.tabs[tab.id]
        XCTAssertEqual(current?.customTitle, "Newer server")

        var tie = tab
        tie.customTitle = "Tie server"
        tie.meta.stamp([TabNode.FieldGroup.naming], at: Fx.t(500))
        try await store.apply(RemoteChangeBatch(upserts: [.tab(tie)]))
        current = await store.workspace.tabs[tab.id]
        XCTAssertEqual(current?.customTitle, "Tie server")
    }

    /// Delete wins over a newer edit on either side.
    func testApplyDeleteWins() async throws {
        let (store, state, tab) = try base()
        let local = try TreeOps.renameTab(state, id: tab.id, customTitle: "Edited", now: Fx.t(900))
        await store.update(local)

        var server = tab
        server.meta.markDeleted(at: Fx.t(10))
        try await store.apply(RemoteChangeBatch(upserts: [.tab(server)]))
        let merged = await store.workspace.tabs[tab.id]
        XCTAssertEqual(merged?.meta.isTombstone, true)

        // A local tombstone beats a newer live server copy and must be re-uploaded.
        let favorite = try XCTUnwrap(state.tabs[Sample.ids.favoriteTab])
        let currentState = await store.workspace
        let deletedLocally = try TreeOps.archiveTab(currentState, id: favorite.id, now: Fx.t(20))
        await store.update(deletedLocally)
        var liveServer = favorite
        liveServer.title = "Server edit"
        liveServer.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(999))
        let stream = await store.events()
        try await store.apply(RemoteChangeBatch(upserts: [.tab(liveServer)]))
        let result = await store.workspace.tabs[favorite.id]
        XCTAssertEqual(result?.meta.isTombstone, true)
        var iterator = stream.makeAsyncIterator()
        let next = await iterator.next()
        let event = try XCTUnwrap(next)
        XCTAssertEqual(event.pendingChanges, [.save(tabID(favorite.id))])
    }

    /// New records are inserted, deletions purge, and applying the same batch twice changes nothing.
    func testApplyInsertsPurgesAndIsIdempotent() async throws {
        let (store, state, tab) = try base()
        await store.update(state)
        try await store.flush()
        let writesBefore = await store.writeCount

        var server = tab
        server.title = "Server"
        server.meta.stamp([TabNode.FieldGroup.content], at: Fx.t(700))
        let newFolder = Folder(id: Fx.uuid(40), spaceID: Sample.ids.space, title: "Work", sortKey: SortKey.sequence(count: 1)[0], now: Fx.t(700))
        let batch = RemoteChangeBatch(
            upserts: [.tab(server), .folder(newFolder)],
            deletions: [SyncRecordID(type: .splitLayout, uuid: Sample.ids.split)]
        )
        try await store.apply(batch)
        let afterFirst = await store.workspace
        XCTAssertEqual(afterFirst.folders[newFolder.id], newFolder)
        XCTAssertNil(afterFirst.splits[Sample.ids.split])
        XCTAssertEqual(afterFirst.tabs[tab.id]?.title, "Server")
        var writes = await store.writeCount
        XCTAssertEqual(writes, writesBefore + 1)

        try await store.apply(batch)
        let afterSecond = await store.workspace
        XCTAssertEqual(afterSecond, afterFirst)
        writes = await store.writeCount
        XCTAssertEqual(writes, writesBefore + 1, "a repeated batch does not write")
    }

    // MARK: Local-only profiles (B73)

    /// Plan Q13, [06 §16.3] observed "Profiles are not synced between computers.": profile edits,
    /// creations and purges produce no pending change; the rest of the diff is unchanged; a full
    /// upload lists no profile.
    func testProfileChangesProduceNoPendingChanges() throws {
        let i = Sample.ids
        let old = try Sample.workspace()
        var new = TreeOps.createProfile(old, id: Fx.uuid(60), name: "Work", now: Fx.t(100))
        new = try TreeOps.updateProfileSettings(new, id: i.profile, settings: ProfileSettings(searchEngine: .duckDuckGo), now: Fx.t(101))
        new = try TreeOps.renameFolder(new, id: i.folder, title: "Updated", now: Fx.t(102))
        var purged = new
        purged.profiles[Fx.uuid(60)] = nil

        let changes = WorkspaceDiff.changes(from: old, to: new)
        XCTAssertTrue(changes.saved.contains(SyncRecordID(type: .profile, uuid: i.profile)), "the diff still sees the profile")
        XCTAssertEqual(changes.pendingChanges, [.save(SyncRecordID(type: .folder, uuid: i.folder))])
        XCTAssertEqual(WorkspaceDiff.pendingChanges(from: new, to: purged), [])
        XCTAssertFalse(new.allSyncedRecordIDs.contains { $0.type == .profile })
        XCTAssertEqual(new.allSyncedRecordIDs.count, new.allRecordIDs.count - new.profiles.count)
    }

    /// Profile records in a remote batch (an older build uploaded them) are ignored: an unknown
    /// one is not inserted, a known one is neither overwritten nor purged, and nothing is written.
    func testIncomingProfileRecordsAreIgnored() async throws {
        let store = makeStore()
        let state = try Sample.workspace()
        await store.update(state)
        try await store.flush()
        let writesBefore = await store.writeCount

        var remoteEdit = try XCTUnwrap(state.profiles[Sample.ids.profile])
        remoteEdit.name = "Renamed elsewhere"
        remoteEdit.meta.stamp([Profile.FieldGroup.naming], at: Fx.t(900))
        let foreign = Profile(id: Fx.uuid(61), name: "Other Mac", now: Fx.t(900))
        try await store.apply(RemoteChangeBatch(
            upserts: [.profile(remoteEdit), .profile(foreign)],
            deletions: [SyncRecordID(type: .profile, uuid: Sample.ids.profile)]
        ))

        let after = await store.workspace
        XCTAssertEqual(after, state)
        let writes = await store.writeCount
        XCTAssertEqual(writes, writesBefore, "an all-profile batch changes nothing")
    }

    /// The merge helper resolves the same way as the policy for every record type.
    func testRecordMergeHandlesEveryType() throws {
        let state = try Sample.workspace()
        for id in state.allRecordIDs {
            let record = try XCTUnwrap(state.record(for: id))
            let outcome = try XCTUnwrap(RecordMerge.merge(local: record, server: record))
            XCTAssertEqual(outcome.merged, record)
            XCTAssertFalse(outcome.needsUpload)
        }
        let a = try XCTUnwrap(state.record(for: tabID(Sample.ids.todayTab)))
        let b = try XCTUnwrap(state.record(for: SyncRecordID(type: .profile, uuid: Sample.ids.profile)))
        XCTAssertNil(RecordMerge.merge(local: a, server: b))
    }
}
