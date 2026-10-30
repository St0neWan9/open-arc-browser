import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// Loading, saving, recovery and autosave of `workspace.json`.
final class WorkspaceStoreTests: XCTestCase {
    private var dir: TempDirectory!

    override func setUp() {
        dir = TempDirectory()
    }

    override func tearDown() {
        dir.cleanUp()
    }

    private func makeStore(_ scheduler: ManualAutosaveScheduler = ManualAutosaveScheduler(), delay: TimeInterval = 1) -> WorkspaceStore {
        WorkspaceStore(directory: dir.url, autosaveDelay: delay, scheduler: scheduler, now: { Fx.t(1_000) })
    }

    // MARK: Round trip

    func testFirstLaunchHasNoFileAndAnEmptyWorkspace() async {
        let store = makeStore()
        XCTAssertEqual(store.loadResult.outcome, .noFile)
        XCTAssertEqual(store.loadResult.workspace, WorkspaceState())
        XCTAssertFalse(store.isReadOnly)
        XCTAssertEqual(dir.contents(), [], "loading never creates files")
    }

    /// Every record type, tombstones, nested folders, splits and backend blobs survive exactly.
    func testRoundTripOfEveryEntityTypeIncludingTombstones() async throws {
        let original = try Sample.workspace()
        let i = Sample.ids
        // The sample really covers what it claims to.
        XCTAssertEqual(original.tabs[i.archivedTab]?.meta.isTombstone, true)
        XCTAssertEqual(original.spaces[i.deletedSpace]?.meta.isTombstone, true)
        XCTAssertEqual(original.folders[i.deletedSpaceFolder]?.meta.isTombstone, true)
        XCTAssertNotNil(original.archive[i.archivedTab])
        XCTAssertNotNil(original.archive[i.deletedSpaceTab])
        XCTAssertNotNil(original.splits[i.split])
        XCTAssertFalse(original.profiles.isEmpty || original.themes.isEmpty)

        let store = makeStore()
        await store.update(original)
        try await store.flush()

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.loadResult.outcome, .loaded)
        XCTAssertEqual(reloaded.loadResult.workspace, original)
        let current = await reloaded.workspace
        XCTAssertEqual(current, original)
    }

    func testFileIsAnEnvelopeWithSchemaVersion() async throws {
        let store = makeStore()
        await store.update(try Sample.workspace())
        try await store.flush()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.workspaceFile)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(json["savedAt"])
        let workspace = try XCTUnwrap(json["workspace"] as? [String: Any])
        // `easels` / `easelElements` were added by B56 without a schema bump (older files lack them
        // and load with none; see `testFileWithoutEaselsLoadsWithNone`).
        XCTAssertEqual(Set(workspace.keys), ["profiles", "themes", "spaces", "folders", "tabs", "archive", "splits", "easels", "easelElements"])
    }

    /// [06 §9] B56: a file written before Easels existed still loads, with no Easels. The format
    /// change is additive, so the schema version stays 1.
    func testFileWithoutEaselsLoadsWithNone() async throws {
        let original = try Sample.workspace()
        let store = makeStore()
        await store.update(original)
        try await store.flush()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.workspaceFile)) as? [String: Any])
        var workspace = try XCTUnwrap(json["workspace"] as? [String: Any])
        workspace["easels"] = nil
        workspace["easelElements"] = nil
        json["workspace"] = workspace
        try JSONSerialization.data(withJSONObject: json).write(to: dir.workspaceFile)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.loadResult.outcome, .loaded)
        XCTAssertEqual(reloaded.loadResult.workspace, original)
        XCTAssertTrue(reloaded.loadResult.workspace.easels.isEmpty)
    }

    /// A file written before `Theme.brightness` existed still loads; its themes get the neutral
    /// default (the [06 §2] ring knob, inferred). No schema bump is needed for an added field.
    func testFileWithoutThemeBrightnessLoadsWithTheDefault() async throws {
        let original = try Sample.workspace()
        let store = makeStore()
        await store.update(original)
        try await store.flush()

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.workspaceFile)) as? [String: Any])
        var workspace = try XCTUnwrap(json["workspace"] as? [String: Any])
        // `[UUID: Theme]` encodes as a flat array: key, value, key, value, ...
        let themes = try XCTUnwrap(workspace["themes"] as? [Any])
        var stripped = 0
        workspace["themes"] = themes.map { element -> Any in
            guard var theme = element as? [String: Any] else { return element }
            if theme.removeValue(forKey: "brightness") != nil { stripped += 1 }
            return theme
        }
        XCTAssertEqual(stripped, original.themes.count)
        json["workspace"] = workspace
        try JSONSerialization.data(withJSONObject: json).write(to: dir.workspaceFile)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.loadResult.outcome, .loaded)
        var expected = original
        for id in expected.themes.keys { expected.themes[id]?.brightness = Theme.defaultBrightness }
        XCTAssertEqual(reloaded.loadResult.workspace, expected)
    }

    /// A file written before `Profile.settings` existed still loads with the defaults
    /// ([03 §Profiles] observed: Google, 12 hours); a saved file keeps the settings.
    func testFileWithoutProfileSettingsLoadsWithTheDefaults() async throws {
        let original = try Sample.workspace()
        XCTAssertNotEqual(original.profiles[Sample.ids.profile]?.settings, .default, "fixture must set settings")
        let store = makeStore()
        await store.update(original)
        try await store.flush()
        XCTAssertEqual(makeStore().loadResult.workspace, original, "settings survive a save")

        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.workspaceFile)) as? [String: Any])
        var workspace = try XCTUnwrap(json["workspace"] as? [String: Any])
        // `[UUID: Profile]` encodes as a flat array: key, value, key, value, ...
        let profiles = try XCTUnwrap(workspace["profiles"] as? [Any])
        var stripped = 0
        workspace["profiles"] = profiles.map { element -> Any in
            guard var profile = element as? [String: Any] else { return element }
            if profile.removeValue(forKey: "settings") != nil { stripped += 1 }
            return profile
        }
        XCTAssertEqual(stripped, original.profiles.count)
        json["workspace"] = workspace
        try JSONSerialization.data(withJSONObject: json).write(to: dir.workspaceFile)

        let reloaded = makeStore()
        XCTAssertEqual(reloaded.loadResult.outcome, .loaded)
        var expected = original
        for id in expected.profiles.keys { expected.profiles[id]?.settings = .default }
        XCTAssertEqual(reloaded.loadResult.workspace, expected)
    }

    // MARK: Atomic writes

    /// A save whose encoding fails leaves the previous file byte for byte and no temp files.
    func testFailedEncodingLeavesTheOldFile() async throws {
        let store = makeStore()
        var good = try Sample.workspace()
        await store.update(good)
        try await store.flush()
        let before = try Data(contentsOf: dir.workspaceFile)

        // JSONEncoder rejects non-finite numbers.
        good.themes[Sample.ids.theme]?.grain = .infinity
        await store.update(good)
        do {
            try await store.flush()
            XCTFail("expected an encoding failure")
        } catch PersistenceError.encodingFailed {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: dir.workspaceFile), before)
        XCTAssertEqual(dir.contents().filter { $0 != WorkspaceBackups.directoryName }, [PersistenceDefaults.workspaceFileName], "no temp file left behind")
        let unsaved = await store.hasUnsavedChanges
        XCTAssertTrue(unsaved, "the change stays pending for the next save")
    }

    func testSaveReplacesTheFileWithoutLeftovers() async throws {
        let store = makeStore()
        var state = try Sample.workspace()
        await store.update(state)
        try await store.flush()
        state = try TreeOps.renameTab(state, id: Sample.ids.todayTab, customTitle: "Renamed", now: Fx.t(50))
        await store.update(state)
        try await store.flush()
        XCTAssertEqual(dir.contents().filter { $0 != WorkspaceBackups.directoryName }, [PersistenceDefaults.workspaceFileName])
        XCTAssertEqual(makeStore().loadResult.workspace, state)
    }

    // MARK: Recovery

    /// A corrupt file is kept aside as workspace.corrupt-<timestamp>.json and the store starts empty.
    func testCorruptFileIsMovedAsideAndTheStoreStartsEmpty() async throws {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: dir.workspaceFile)

        let store = makeStore()
        guard case .recoveredFromCorruptFile(let movedTo) = store.loadResult.outcome else {
            return XCTFail("expected recovery, got \(store.loadResult.outcome)")
        }
        XCTAssertEqual(store.loadResult.workspace, WorkspaceState())
        XCTAssertFalse(store.isReadOnly)
        XCTAssertTrue(movedTo.lastPathComponent.hasPrefix("workspace.corrupt-"))
        XCTAssertEqual(movedTo.pathExtension, "json")
        XCTAssertEqual(try Data(contentsOf: movedTo), garbage, "the bad file is kept intact")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.workspaceFile.path))

        // The store keeps working and writes a fresh file.
        await store.update(try Sample.workspace())
        try await store.flush()
        XCTAssertEqual(makeStore().loadResult.outcome, .loaded)
    }

    /// A file with a valid header but an undecodable body is also corrupt.
    func testWrongShapeWithCurrentVersionIsCorrupt() throws {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion": 1, "workspace": {"tabs": 3}}"#.utf8).write(to: dir.workspaceFile)
        guard case .recoveredFromCorruptFile = makeStore().loadResult.outcome else {
            return XCTFail("expected recovery")
        }
    }

    func testSecondCorruptFileOnTheSameSecondGetsAUniqueName() throws {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.workspaceFile)
        _ = makeStore()
        try Data("y".utf8).write(to: dir.workspaceFile)
        _ = makeStore()
        XCTAssertEqual(dir.contents().filter { $0.hasPrefix("workspace.corrupt-") }.count, 2)
    }

    /// A file from a newer app version is never overwritten; the error is surfaced.
    func testNewerSchemaIsRefusedAndNeverOverwritten() async throws {
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let future = Data(#"{"schemaVersion": 99, "workspace": {"somethingNew": true}}"#.utf8)
        try future.write(to: dir.workspaceFile)

        let store = makeStore()
        XCTAssertEqual(store.loadResult.outcome, .refused(.unsupportedSchemaVersion(found: 99, supported: 1)))
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(store.loadResult.workspace, WorkspaceState())

        await store.update(try Sample.workspace())
        do {
            try await store.flush()
            XCTFail("a read-only store must not write")
        } catch PersistenceError.readOnly {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        do {
            try await store.apply(RemoteChangeBatch(upserts: [.profile(Profile(id: Fx.uuid(9), name: "x", now: Fx.t(0)))]))
            XCTFail("a read-only store must not apply remote changes")
        } catch PersistenceError.readOnly {
        } catch {
            XCTFail("unexpected error \(error)")
        }
        XCTAssertEqual(try Data(contentsOf: dir.workspaceFile), future)
        XCTAssertEqual(dir.contents(), [PersistenceDefaults.workspaceFileName])
    }

    // MARK: Autosave

    /// Many changes inside the window produce one scheduled save and one write.
    func testDebounceCoalescesManyChangesIntoOneWrite() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler, delay: 2.5)
        var state = try Sample.workspace()
        for n in 0..<50 {
            state = try TreeOps.renameTab(state, id: Sample.ids.todayTab, customTitle: "Title \(n)", now: Fx.t(100 + Double(n)))
            await store.update(state)
        }
        XCTAssertEqual(scheduler.scheduledCount, 1)
        XCTAssertEqual(scheduler.requestedDelays, [2.5])
        var writes = await store.writeCount
        XCTAssertEqual(writes, 0, "nothing is written before the delay elapses")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.workspaceFile.path))

        await scheduler.fireAll()
        writes = await store.writeCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(makeStore().loadResult.workspace, state, "the write holds the newest value")

        // The next change opens a new window.
        state = try TreeOps.renameTab(state, id: Sample.ids.todayTab, customTitle: "Later", now: Fx.t(500))
        await store.update(state)
        XCTAssertEqual(scheduler.scheduledCount, 2)
        await scheduler.fireAll()
        writes = await store.writeCount
        XCTAssertEqual(writes, 2)
    }

    func testUnchangedValueSchedulesNothing() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        await store.update(WorkspaceState())
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    /// flush() writes immediately and makes the pending autosave a no-op.
    func testFlushWritesImmediately() async throws {
        let scheduler = ManualAutosaveScheduler()
        let store = makeStore(scheduler)
        let state = try Sample.workspace()
        await store.update(state)
        try await store.flush()
        var writes = await store.writeCount
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(makeStore().loadResult.workspace, state)

        await scheduler.fireAll()
        writes = await store.writeCount
        XCTAssertEqual(writes, 1, "the stale autosave does not write again")

        try await store.flush()
        writes = await store.writeCount
        XCTAssertEqual(writes, 1, "flush with nothing unsaved does not write")
    }

    /// `submit` (fire-and-forget from synchronous callers) keeps the newest value.
    func testSubmitAppliesTheNewestValue() async throws {
        let store = makeStore()
        let first = try Sample.workspace()
        let second = try TreeOps.renameTab(first, id: Sample.ids.todayTab, customTitle: "Second", now: Fx.t(60))
        store.submit(first)
        store.submit(second)
        try await store.flush()
        XCTAssertEqual(makeStore().loadResult.workspace, second)
        await eventually { await store.workspace == second }
    }

    /// A19: `submit(changesFrom:to:)` writes only the records the caller changed, so a value the
    /// caller built before a remote batch reached it cannot revert or purge what `apply` stored.
    func testSubmitChangesKeepsRecordsAppliedMeanwhile() async throws {
        let store = makeStore()
        let base = try Sample.workspace()
        await store.update(base)
        // A remote batch adds a folder the caller has not seen yet.
        let remote = Folder(id: Fx.uuid(90), spaceID: Sample.ids.space, title: "From another Mac", sortKey: SortKey.sequence(count: 1)[0], now: Fx.t(10))
        try await store.apply(RemoteChangeBatch(upserts: [.folder(remote)]))
        // The caller renames a tab on its older copy and submits only that change.
        let renamed = try TreeOps.renameTab(base, id: Sample.ids.todayTab, customTitle: "Local", now: Fx.t(20))
        store.submit(changesFrom: base, to: renamed)
        try await store.flush()
        let saved = makeStore().loadResult.workspace
        XCTAssertEqual(saved.folders[remote.id], remote, "the remote record survives")
        XCTAssertEqual(saved.tabs[Sample.ids.todayTab], renamed.tabs[Sample.ids.todayTab], "the local edit is saved")
    }

    /// A19: a whole value followed by record changes applies both, in order; a purge in the
    /// changes removes the record.
    func testSubmitWholeValueThenChangesAppliesInOrder() async throws {
        let store = makeStore()
        let first = try Sample.workspace()
        store.submit(first)
        var purged = first
        purged.splits[Sample.ids.split] = nil
        store.submit(changesFrom: first, to: purged)
        try await store.flush()
        let current = await store.workspace
        XCTAssertEqual(current, purged)
    }

    // MARK: Sync state blob

    func testSyncStateIsStoredNextToTheWorkspace() async {
        let store = makeStore()
        let empty = await store.loadSyncState()
        XCTAssertNil(empty)
        let blob = Data((0..<64).map { UInt8($0) })
        await store.saveSyncState(blob)
        let loaded = await store.loadSyncState()
        XCTAssertEqual(loaded, blob)
        XCTAssertEqual(dir.contents(), [PersistenceDefaults.syncStateFileName])
        let reloaded = await makeStore().loadSyncState()
        XCTAssertEqual(reloaded, blob)
        await store.saveSyncState(nil)
        let cleared = await store.loadSyncState()
        XCTAssertNil(cleared)
        XCTAssertEqual(dir.contents(), [])
    }

    func testDefaultDirectoryUsesTheBundleIdentifier() {
        let url = PersistenceDefaults.defaultDirectory
        XCTAssertEqual(url.lastPathComponent, "org.openarc.browser")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Application Support")
        let dev = PersistenceDefaults.defaultDirectory(bundleIdentifier: PersistenceDefaults.developmentBundleIdentifier)
        XCTAssertEqual(dev.lastPathComponent, "org.openarc.browser.dev")
        XCTAssertEqual(dev.deletingLastPathComponent(), url.deletingLastPathComponent())
    }

    /// The development build keeps its own data directory (plan B37): the id comes from the main
    /// bundle when it is ours, and falls back to the release id otherwise.
    func testBundleIdentifierFollowsTheMainBundle() {
        XCTAssertEqual(PersistenceDefaults.bundleIdentifier(mainBundleIdentifier: "org.openarc.browser"), "org.openarc.browser")
        XCTAssertEqual(PersistenceDefaults.bundleIdentifier(mainBundleIdentifier: "org.openarc.browser.dev"), "org.openarc.browser.dev")
        XCTAssertEqual(PersistenceDefaults.bundleIdentifier(mainBundleIdentifier: nil), "org.openarc.browser")
        XCTAssertEqual(PersistenceDefaults.bundleIdentifier(mainBundleIdentifier: "com.apple.dt.xctest.tool"), "org.openarc.browser")
        for foreign in ["org.openarc.browserx", "org.openarc.browser.", "org.openarc.browser.Dev", "org.openarc.browser.dev.x", "org.openarc.browser.OpenArcCore"] {
            XCTAssertFalse(PersistenceDefaults.isOwnBundleIdentifier(foreign), foreign)
        }
        XCTAssertTrue(PersistenceDefaults.isOwnBundleIdentifier("org.openarc.browser.dev-2"))
    }
}
