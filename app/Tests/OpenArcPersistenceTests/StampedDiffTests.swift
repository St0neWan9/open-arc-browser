import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// B102: `submit(changesFrom:to:)` finds the changed records from their sync stamps
/// (`WorkspaceDiff.stampedChanges`) instead of comparing whole workspaces on the caller's thread.
/// These tests hold the stamp diff to the full compare for every record kind, tombstones and
/// purges included, and check that the store still saves exactly those records (A19).
final class StampedDiffTests: XCTestCase {
    private var dir: TempDirectory!

    override func setUp() {
        dir = TempDirectory()
    }

    override func tearDown() {
        dir.cleanUp()
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(directory: dir.url, scheduler: ManualAutosaveScheduler(), now: { Fx.t(1_000) })
    }

    private let i = Sample.ids
    private let easel = Fx.uuid(40)
    private let easelRow = Fx.uuid(41)
    private let element = Fx.uuid(42)
    private let otherElement = Fx.uuid(43)

    /// The sample workspace plus an Easel with two elements: every record kind is present.
    private func base() throws -> WorkspaceState {
        var s = try Sample.workspace()
        s = try TreeOps.createEasel(s, id: easel, tabID: easelRow, spaceID: i.space, now: Fx.t(20))
        let style = EaselStyle(strokeColor: RGBAColor(hex: 0x000000), strokeWidth: 2, fontSize: 14)
        s = try TreeOps.addEaselElement(s, id: element, easelID: easel, frame: EaselRect(x: 0, y: 0, width: 10, height: 10),
                                        content: .rectangle, style: style, now: Fx.t(21))
        s = try TreeOps.addEaselElement(s, id: otherElement, easelID: easel, frame: EaselRect(x: 5, y: 5, width: 10, height: 10),
                                        content: .circle, style: style, now: Fx.t(22))
        return s
    }

    /// One local change per record kind, each made by `TreeOps`, plus tombstones and purges.
    private func edits() -> [(String, (WorkspaceState) throws -> WorkspaceState)] {
        let t = Fx.t(500)
        let i = self.i, easel = self.easel, element = self.element
        return [
            ("profile rename", { try TreeOps.renameProfile($0, id: i.profile, name: "Work", now: t) }),
            ("profile create", { TreeOps.createProfile($0, id: Fx.uuid(60), name: "New", now: t) }),
            ("theme edit", { try TreeOps.editTheme($0, id: i.theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x112233)]), now: t) }),
            ("theme create", { TreeOps.createTheme($0, id: Fx.uuid(63), style: ThemeStyle(colors: [RGBAColor(hex: 0x445566)]), now: t) }),
            ("theme tombstone", { state in
                let created = TreeOps.createTheme(state, id: Fx.uuid(63), style: ThemeStyle(colors: [RGBAColor(hex: 0x445566)]), now: Fx.t(400))
                return try TreeOps.deleteTheme(created, id: Fx.uuid(63), now: t)
            }),
            ("space rename", { try TreeOps.renameSpace($0, id: i.space, name: "Renamed", now: t) }),
            ("space tombstone", { try TreeOps.deleteSpace($0, id: i.space, now: t) }),
            ("folder rename", { try TreeOps.renameFolder($0, id: i.folder, title: "Renamed", now: t) }),
            ("folder collapse", { try TreeOps.setFolderExpanded($0, id: i.folder, isExpanded: false, now: t) }),
            ("tab activity", { try TreeOps.markTabActive($0, id: i.todayTab, now: t) }),
            ("tab archive (tombstone + archive item)", { try TreeOps.archiveTab($0, id: i.pinnedTab, now: t) }),
            ("tab open (with sibling placement)", { try TreeOps.openTab($0, id: Fx.uuid(61), spaceID: i.space, url: nil, title: "New", now: t) }),
            ("archive item restore (tombstone)", { try TreeOps.restoreFromArchive($0, itemID: i.archivedTab, newTabID: Fx.uuid(62), spaceID: i.space, now: t) }),
            ("split pane removed", { TreeOps.removeSplitPane($0, tabID: i.splitTab, now: t) }),
            ("easel rename", { try TreeOps.renameEasel($0, id: easel, title: "Board", now: t) }),
            ("easel tombstone (elements and row too)", { try TreeOps.deleteEasel($0, id: easel, now: t) }),
            ("easel element move", { try TreeOps.setEaselElementFrame($0, id: element, frame: EaselRect(x: 9, y: 9, width: 10, height: 10), now: t) }),
            ("purge of every kind", { state in
                var s = state
                s.profiles[i.profile] = nil
                s.themes[i.theme] = nil
                s.spaces[i.deletedSpace] = nil
                s.folders[i.deletedSpaceFolder] = nil
                s.tabs[i.archivedTab] = nil
                s.archive[i.archivedTab] = nil
                s.splits[i.split] = nil
                s.easels[easel] = nil
                s.easelElements[element] = nil
                return s
            }),
        ]
    }

    /// For every `TreeOps` change the stamp diff names exactly the records a full compare names.
    func testStampedChangesMatchFullCompareForEveryRecordKind() throws {
        let old = try base()
        XCTAssertFalse(old.profiles.isEmpty || old.themes.isEmpty || old.spaces.isEmpty || old.folders.isEmpty
                       || old.tabs.isEmpty || old.archive.isEmpty || old.splits.isEmpty || old.easels.isEmpty
                       || old.easelElements.isEmpty, "every record kind is present")
        var kinds: Set<SyncRecordType> = []
        var sawTombstone = false
        for (name, edit) in edits() {
            let new = try edit(old)
            let full = WorkspaceDiff.changes(from: old, to: new)
            XCTAssertFalse(full.isEmpty, "\(name) changes something")
            XCTAssertEqual(WorkspaceDiff.stampedChanges(from: old, to: new), full, name)
            kinds.formUnion((full.saved + full.removed).map(\.type))
            sawTombstone = sawTombstone || full.saved.contains { new.record(for: $0)?.meta.isTombstone == true && old.record(for: $0)?.meta.isTombstone == false }
        }
        XCTAssertEqual(kinds, Set(SyncRecordType.allCases), "the edits cover every record kind")
        XCTAssertTrue(sawTombstone, "the edits cover tombstoning")
        XCTAssertTrue(WorkspaceDiff.stampedChanges(from: old, to: old).isEmpty)
    }

    /// Creating records into an empty workspace and purging all of them.
    func testStampedChangesFromAndToEmpty() throws {
        let full = try base()
        XCTAssertEqual(WorkspaceDiff.stampedChanges(from: WorkspaceState(), to: full), WorkspaceDiff.changes(from: WorkspaceState(), to: full))
        XCTAssertEqual(WorkspaceDiff.stampedChanges(from: full, to: WorkspaceState()), WorkspaceDiff.changes(from: full, to: WorkspaceState()))
        XCTAssertEqual(WorkspaceDiff.stampedChanges(from: full, to: WorkspaceState()).removed.count, full.allRecordIDs.count)
    }

    /// A tombstone set without a version bump (never done by `TreeOps`, but cheap to cover) is
    /// still found.
    func testStampedChangesSeeTombstoneFlag() throws {
        let old = try base()
        var new = old
        new.tabs[i.todayTab]?.meta.isTombstone = true
        XCTAssertEqual(WorkspaceDiff.stampedChanges(from: old, to: new).saved, [SyncRecordID(type: .tab, uuid: i.todayTab)])
    }

    /// Each `TreeOps` change submitted through the store saves the same records and announces the
    /// same pending changes as a whole-value update would.
    func testSubmitChangesSavesEveryRecordKind() async throws {
        let old = try base()
        for (name, edit) in edits() {
            dir.cleanUp()
            let store = makeStore()
            await store.update(old)
            let (_, events) = await store.subscribe()
            let new = try edit(old)
            store.submit(changesFrom: old, to: new)
            try await store.flush()
            let current = await store.workspace
            XCTAssertEqual(current, new, name)
            XCTAssertEqual(makeStore().loadResult.workspace, new, "\(name) is on disk")
            var iterator = events.makeAsyncIterator()
            let event = await iterator.next()
            XCTAssertEqual(event?.origin, .local, name)
            XCTAssertEqual(event?.changes, WorkspaceDiff.changes(from: old, to: new), name)
            XCTAssertEqual(event?.pendingChanges, WorkspaceDiff.pendingChanges(from: old, to: new), name)
        }
    }

    /// A19 on the stamp path: a remote batch applied after the caller read `old` changes a record
    /// the caller also stamps (the caller's copy wins that record, as before), and adds and purges
    /// records the caller never touched (they stay as the store has them).
    func testSubmitChangesKeepsRemoteRecordsTheCallerDidNotTouch() async throws {
        let store = makeStore()
        let old = try base()
        await store.update(old)
        let remoteFolder = Folder(id: Fx.uuid(90), spaceID: i.space, title: "From another Mac", sortKey: SortKey.sequence(count: 1)[0], now: Fx.t(10))
        var remoteElement = try XCTUnwrap(old.easelElements[otherElement])
        remoteElement.frame = EaselRect(x: 50, y: 50, width: 1, height: 1)
        remoteElement.meta.stamp([EaselElement.FieldGroup.geometry], at: Fx.t(400))
        try await store.apply(RemoteChangeBatch(
            upserts: [.folder(remoteFolder), .easelElement(remoteElement)],
            deletions: [SyncRecordID(type: .splitLayout, uuid: i.split)]
        ))
        // The caller, still on `old`, makes two changes in a row.
        let first = try TreeOps.markTabActive(old, id: i.todayTab, now: Fx.t(600))
        let second = try TreeOps.renameEasel(first, id: easel, title: "Board", now: Fx.t(601))
        store.submit(changesFrom: old, to: first)
        store.submit(changesFrom: first, to: second)
        try await store.flush()
        let saved = makeStore().loadResult.workspace
        XCTAssertEqual(saved.folders[remoteFolder.id], remoteFolder, "a remote insert survives")
        XCTAssertEqual(saved.easelElements[otherElement], remoteElement, "a remote edit survives")
        XCTAssertNil(saved.splits[i.split], "a remote purge is not undone")
        XCTAssertEqual(saved.tabs[i.todayTab], second.tabs[i.todayTab], "the first local change is saved")
        XCTAssertEqual(saved.easels[easel], second.easels[easel], "the second local change is saved")
        XCTAssertEqual(saved.tabs[easelRow], second.tabs[easelRow], "the renamed Easel's row is saved")
    }

    /// A submission whose stamped records already equal the store's copy changes nothing and
    /// announces nothing (e.g. the same change submitted twice).
    func testSubmitChangesThatAreAlreadyStoredEmitNothing() async throws {
        let store = makeStore()
        let old = try base()
        let new = try TreeOps.markTabActive(old, id: i.todayTab, now: Fx.t(600))
        await store.update(new)
        let (_, events) = await store.subscribe()
        store.submit(changesFrom: old, to: new)
        _ = await store.currentWorkspace()
        // A change that does reach the store comes next on the stream: nothing came before it.
        let renamed = try TreeOps.renameSpace(new, id: i.space, name: "After", now: Fx.t(700))
        store.submit(changesFrom: new, to: renamed)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.changes, WorkspaceDiff.Changes(saved: [SyncRecordID(type: .space, uuid: i.space)]))
    }

    /// Many submissions from a synchronous burst (a user selecting through tabs) land in order,
    /// and the newest value of each record wins.
    func testBurstOfSubmissionsLandsInOrder() async throws {
        let store = makeStore()
        var current = try base()
        await store.update(current)
        let tabs = [i.todayTab, i.pinnedTab, i.splitTab, i.todayTab, i.favoriteTab, i.pinnedTab]
        for (n, tab) in tabs.enumerated() {
            let next = try TreeOps.markTabActive(current, id: tab, now: Fx.t(800 + Double(n)))
            store.submit(changesFrom: current, to: next)
            current = next
        }
        let stored = await store.currentWorkspace()
        XCTAssertEqual(stored, current)
    }
}
