import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// A sync store that plays an account: `deliver` applies the account's records to the local
/// database, as a fetch would, and then reports the clean sync (`.idle` with a "Last synced" time)
/// the way the CloudKit store does after `finishConfirmedCycle`. Every enqueued change is recorded.
private actor FakeAccountStore: SyncStore {
    private var database: (any SyncLocalDatabase)?
    private(set) var enqueued: [PendingChange] = []
    private var status = SyncStatus(phase: .disabled)
    private var continuations: [UUID: AsyncStream<SyncStatus>.Continuation] = [:]
    private let clock = Date(timeIntervalSince1970: 2_000_000)

    func start(database: any SyncLocalDatabase) async throws {
        self.database = database
        publish(SyncStatus(phase: .idle, lastSyncedAt: status.lastSyncedAt))
    }

    func stop() async {
        database = nil
        publish(SyncStatus(phase: .disabled, lastSyncedAt: status.lastSyncedAt))
    }

    func enqueue(_ changes: [PendingChange]) async { enqueued += changes }
    func syncNow() async throws {}
    func resetLocalSyncState() async {}
    func currentStatus() async -> SyncStatus { status }

    nonisolated func statusUpdates() -> AsyncStream<SyncStatus> {
        let (stream, continuation) = AsyncStream<SyncStatus>.makeStream()
        Task { await self.add(continuation) }
        return stream
    }

    private func add(_ continuation: AsyncStream<SyncStatus>.Continuation) {
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { _ in Task { await self.remove(id) } }
        continuation.yield(status)
    }

    private func remove(_ id: UUID) { continuations[id] = nil }

    /// Applies `records` (as fetched from the account) and reports `phase`; a clean `.idle` also
    /// sets "Last synced".
    func deliver(_ records: [SyncRecord], phase: SyncStatus.Phase = .idle) async throws {
        guard let database else { throw CancellationError() }
        if !records.isEmpty { try await database.apply(RemoteChangeBatch(upserts: records)) }
        publish(SyncStatus(phase: phase, lastSyncedAt: phase == .idle ? clock : status.lastSyncedAt))
    }

    private func publish(_ next: SyncStatus) {
        status = next
        for continuation in continuations.values { continuation.yield(next) }
    }

    /// Saves of `type` that were handed over.
    func savedIDs(_ type: SyncRecordType) -> Set<UUID> {
        Set(enqueued.compactMap { change -> UUID? in
            if case .save(let id) = change, id.type == type { return id.uuid }
            return nil
        })
    }

    func allIDs() -> Set<SyncRecordID> {
        Set(enqueued.map { change in
            switch change { case .save(let id), .delete(let id): return id }
        })
    }
}

/// A device joins the account's Spaces instead of uploading its first-launch "Home"
/// (`FirstLaunchSpaceAdoption`). A user decision (2026-10-28, two-Mac sync testing); the spec
/// records no first-sync behavior. Profiles are local-only (plan Q13 / B73).
@MainActor
final class FirstLaunchSpaceAdoptionTests: XCTestCase {
    /// A unique directory under app/.build/home-tmp, removed after each test.
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/home-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: Fixtures

    /// The account as another Mac uploaded it: its own (unknown here) profile, a theme, two
    /// Spaces and a pinned tab. Fetched records carry backend system fields.
    private func accountRecords() throws -> (records: [SyncRecord], spaces: [UUID]) {
        let otherProfile = UUID(), theme = UUID(), work = UUID(), personal = UUID(), tab = UUID()
        var s = TreeOps.createProfile(WorkspaceState(), id: otherProfile, name: "Default", now: t0)
        s = TreeOps.createTheme(s, id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x3366CC)]), now: t0)
        s = try TreeOps.createSpace(s, id: work, profileID: otherProfile, name: "Work", themeID: theme, now: t0)
        s = try TreeOps.createSpace(s, id: personal, profileID: otherProfile, name: "Personal", afterSpaceID: work, now: t0)
        s = try TreeOps.openTab(s, id: tab, spaceID: work, url: URL(string: "https://work.example"), title: "Work", now: t0)
        s = try TreeOps.pinTab(s, id: tab, now: t0)
        let records = s.allSyncedRecordIDs.compactMap { id -> SyncRecord? in
            guard var record = s.record(for: id) else { return nil }
            record.setSystemFields(Data([1, 2, 3]))
            return record
        }
        return (records, [work, personal])
    }

    private func makeController(
        store: FakeAccountStore,
        preferences: AppPreferences,
        clock: Date? = nil
    ) -> WorkspaceController {
        let fixed = clock ?? t0.addingTimeInterval(60)
        let deps = AppDependencies(engine: FakeEngine(), sync: store, persistence: WorkspaceStore(directory: directory), preferences: preferences)
        let controller = WorkspaceController(
            dependencies: deps, workspace: .firstLaunch(now: t0), now: { fixed },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func settle(_ controller: WorkspaceController, until done: () -> Bool = { false }) async {
        for _ in 0..<20 {
            await controller.sidebarSync.settle()
            for _ in 0..<200 { await Task.yield() }
            if done() { break }
        }
        await controller.sidebarSync.settle()
    }

    private func homeSpace(_ controller: WorkspaceController) throws -> Space {
        try XCTUnwrap(controller.workspace.spaces.values.first { $0.name == FirstLaunchDefaults.spaceName })
    }

    // MARK: (a) untouched default joins an account with Spaces

    /// Device B (untouched first-launch workspace) turns sync on against an account with Spaces:
    /// its "Home" is never uploaded, it is tombstoned locally once the account's Spaces are in,
    /// and the window shows one of the account's Spaces.
    func testUntouchedDefaultAdoptsAccountSpaces() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        let homeTheme = try XCTUnwrap(home.themeID)
        XCTAssertEqual(preferences.firstLaunchSpaceID, home.id, "marked at creation")
        let window = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: home.id))
        addTeardownBlock { @MainActor in window.stop() }
        XCTAssertEqual(window.selectedSpaceID, home.id)
        await settle(controller)

        let account = try accountRecords()
        try await store.deliver(account.records)
        await settle(controller) { controller.workspace.spaces[home.id]?.meta.isTombstone == true }

        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, true, "the default Home is dropped (tombstoned)")
        XCTAssertEqual(controller.workspace.themes[homeTheme]?.meta.isTombstone, true, "with its theme")
        XCTAssertEqual(Set(controller.workspace.allLiveSpaces.map(\.id)), Set(account.spaces), "B shows the account's Spaces")
        XCTAssertEqual(window.selectedSpaceID, account.spaces.first, "the window moved to the first account Space")
        let uploaded = await store.allIDs()
        XCTAssertFalse(uploaded.contains(SyncRecordID(type: .space, uuid: home.id)), "no extra Home on the server")
        XCTAssertFalse(uploaded.contains(SyncRecordID(type: .theme, uuid: homeTheme)))
        XCTAssertFalse(uploaded.contains { $0.type == .profile }, "profiles stay local")
        XCTAssertNil(preferences.firstLaunchSpaceID, "decided once")

        // The local Default profile is the only profile; the account's Spaces resolve to it.
        let profiles = controller.workspace.liveProfilesOldestFirst
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(Set(controller.workspace.spaces(inProfile: profiles[0].id).map(\.id)), Set(account.spaces))

        // Later edits still sync, but never the dropped Space's tombstones.
        let work = try XCTUnwrap(account.spaces.first)
        try controller.mutate(origin: nil) { try TreeOps.renameSpace($0, id: work, name: "Work 2", now: self.t0.addingTimeInterval(120)) }
        await settle(controller)
        let saves = await store.savedIDs(.space)
        XCTAssertTrue(saves.contains(work))
        XCTAssertFalse(saves.contains(home.id))

        // The tombstone is saved, so a relaunch keeps showing only the account's Spaces.
        try await controller.flushPersistence()
        let reloaded = WorkspaceStore(directory: directory).loadResult.workspace
        XCTAssertEqual(reloaded.spaces[home.id]?.meta.isTombstone, true)
    }

    /// The decision survives a relaunch: sync turned on only in the second session (the workspace
    /// file now exists) still drops the untouched Home.
    func testPendingDecisionSurvivesRelaunch() async throws {
        let preferences = AppPreferences.inMemory()
        let first = makeController(store: FakeAccountStore(), preferences: preferences)
        let home = try homeSpace(first)
        await settle(first)
        try await first.flushPersistence()
        first.stop()

        preferences.isSidebarSyncEnabled = true
        let store = FakeAccountStore()
        let second = makeController(store: store, preferences: preferences)
        XCTAssertEqual(preferences.firstLaunchSpaceID, home.id, "a loaded file does not reset the mark")
        await settle(second)
        try await store.deliver(try accountRecords().records)
        await settle(second) { second.workspace.spaces[home.id]?.meta.isTombstone == true }
        XCTAssertEqual(second.workspace.spaces[home.id]?.meta.isTombstone, true)
        let spaces = await store.savedIDs(.space)
        XCTAssertFalse(spaces.contains(home.id))
    }

    // MARK: (b) an edited Home is kept and uploaded

    /// Home edited before sync was turned on: the full upload includes it, and the account's
    /// Spaces join it instead of replacing it.
    func testEditedHomeIsKeptAndUploaded() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.inMemory()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        let tab = UUID()
        try controller.mutate(origin: nil) {
            try TreeOps.openTab($0, id: tab, spaceID: home.id, url: URL(string: "https://mine.example"), title: "Mine", now: self.t0.addingTimeInterval(5))
        }
        await settle(controller)
        XCTAssertNil(preferences.firstLaunchSpaceID, "the edit settles it: keep")

        controller.sidebarSync.setEnabled(true)
        await settle(controller)
        let saved = await store.savedIDs(.space)
        XCTAssertTrue(saved.contains(home.id), "Home goes up with the full upload")
        let themes = await store.savedIDs(.theme)
        XCTAssertTrue(themes.contains(try XCTUnwrap(home.themeID)))

        try await store.deliver(try accountRecords().records)
        await settle(controller)
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, false, "a Space with user content is never deleted")
        XCTAssertEqual(controller.workspace.allLiveSpaces.count, 3)
    }

    /// A rename while sync runs but before the first fetch finished releases Home at once.
    func testRenameBeforeFirstFetchReleasesHome() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        await settle(controller)
        let before = await store.savedIDs(.space)
        XCTAssertFalse(before.contains(home.id), "held while pending")

        try controller.mutate(origin: nil) { try TreeOps.renameSpace($0, id: home.id, name: "Studio", now: self.t0.addingTimeInterval(5)) }
        await settle(controller)
        let after = await store.savedIDs(.space)
        XCTAssertTrue(after.contains(home.id))
        XCTAssertNil(preferences.firstLaunchSpaceID)

        try await store.deliver(try accountRecords().records)
        await settle(controller)
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, false)
    }

    // MARK: (c) empty account: upload as today

    func testEmptyAccountUploadsDefault() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        await settle(controller)

        try await store.deliver([])
        await settle(controller) { preferences.firstLaunchSpaceID == nil }
        XCTAssertNil(preferences.firstLaunchSpaceID)
        let spaces = await store.savedIDs(.space)
        let themes = await store.savedIDs(.theme)
        XCTAssertTrue(spaces.contains(home.id), "the first device seeds the account with its Home")
        XCTAssertTrue(themes.contains(try XCTUnwrap(home.themeID)))
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, false)
    }

    // MARK: (d) races

    /// Remote Spaces that are already applied while the sync has not finished cleanly (a failed
    /// cycle) do not trigger the decision; the next clean sync does.
    func testDecisionWaitsForCleanSync() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        await settle(controller)

        let account = try accountRecords()
        try await store.deliver(Array(account.records.prefix(2)), phase: .failed(message: "offline"))
        await settle(controller)
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, false, "no decision on a failed cycle")
        XCTAssertEqual(preferences.firstLaunchSpaceID, home.id)

        try await store.deliver(account.records)
        await settle(controller) { controller.workspace.spaces[home.id]?.meta.isTombstone == true }
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, true)
    }

    /// The clean-sync status can come before the controller merged the applied batch: the
    /// decision reads the stored workspace itself.
    func testDecisionReadsStoredWorkspaceBeforeMerge() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        await settle(controller)
        let account = try accountRecords()
        // Apply and report without yielding in between.
        try await store.deliver(account.records)
        await settle(controller) { controller.workspace.spaces[home.id]?.meta.isTombstone == true }
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, true)
        XCTAssertEqual(Set(controller.workspace.allLiveSpaces.map(\.id)), Set(account.spaces))
    }

    /// Account Spaces that arrive after the decision (the account was empty at the first clean
    /// sync) join the uploaded Home; nothing is dropped any more.
    func testSpacesArrivingAfterDecisionKeepHome() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        await settle(controller)
        try await store.deliver([])
        await settle(controller) { preferences.firstLaunchSpaceID == nil }

        let account = try accountRecords()
        try await store.deliver(account.records)
        await settle(controller) { controller.workspace.allLiveSpaces.count == 3 }
        XCTAssertEqual(controller.workspace.spaces[home.id]?.meta.isTombstone, false)
        XCTAssertEqual(controller.workspace.allLiveSpaces.count, 3)
    }

    /// A Space the user deleted before the decision is gone for good: neither it nor its
    /// tombstone ever goes up.
    func testHomeDeletedBeforeDecisionNeverUploads() async throws {
        let store = FakeAccountStore()
        let preferences = AppPreferences.syncOn()
        let controller = makeController(store: store, preferences: preferences)
        let home = try homeSpace(controller)
        await settle(controller)
        let second = UUID()
        try controller.mutate(origin: nil) {
            let profile = try XCTUnwrap($0.defaultProfileID)
            var s = try TreeOps.createSpace($0, id: second, profileID: profile, name: "Mine", now: self.t0.addingTimeInterval(5))
            s = try TreeOps.deleteSpace(s, id: home.id, now: self.t0.addingTimeInterval(6))
            return s
        }
        await settle(controller)
        try await store.deliver([])
        await settle(controller)
        let spaces = await store.savedIDs(.space)
        XCTAssertTrue(spaces.contains(second))
        XCTAssertFalse(spaces.contains(home.id))
        XCTAssertNil(preferences.firstLaunchSpaceID)
    }

    // MARK: Pure rule

    /// "Untouched" precisely: the Space and its theme are as created (version 1), nothing lives
    /// or lived in it, and no other Space was made on this device. Favorites do not count.
    func testUntouchedRule() throws {
        let base = WorkspaceState.firstLaunch(now: t0)
        let home = try XCTUnwrap(base.allLiveSpaces.first)
        let profile = try XCTUnwrap(base.defaultProfileID)
        let later = t0.addingTimeInterval(10)
        typealias Rule = FirstLaunchSpaceAdoption
        XCTAssertTrue(Rule.isUntouchedWorkspace(base, spaceID: home.id))

        var fav = try TreeOps.openTab(base, id: SidebarFixture.id(9), spaceID: home.id, url: nil, title: "Fav", now: later)
        fav = try TreeOps.moveTab(fav, id: SidebarFixture.id(9), to: .favorite(profileID: profile), position: .last, now: later)
        XCTAssertTrue(Rule.isUntouched(fav, spaceID: home.id), "a favorite is not in the Space")

        let edits: [(String, WorkspaceState)] = [
            ("rename", try TreeOps.renameSpace(base, id: home.id, name: "Studio", now: later)),
            ("icon", try TreeOps.setSpaceIcon(base, id: home.id, icon: "🏠", now: later)),
            ("theme edit", try TreeOps.editTheme(base, id: try XCTUnwrap(home.themeID), style: ThemeStyle(colors: [RGBAColor(hex: 0xFF0000)]), now: later)),
            ("Today tab", try TreeOps.openTab(base, id: UUID(), spaceID: home.id, url: nil, title: "T", now: later)),
            ("folder", try TreeOps.createFolder(base, id: UUID(), spaceID: home.id, title: "F", now: later)),
            ("archived tab", try TreeOps.archiveTab(try TreeOps.openTab(base, id: SidebarFixture.id(8), spaceID: home.id, url: nil, title: "A", now: later), id: SidebarFixture.id(8), now: later)),
            ("another local Space", try TreeOps.createSpace(base, id: UUID(), profileID: profile, name: "Mine", now: later)),
        ]
        for (name, state) in edits {
            XCTAssertFalse(Rule.isUntouchedWorkspace(state, spaceID: home.id), name)
            XCTAssertEqual(Rule.decide(state, spaceID: home.id), .keep, name)
        }
        XCTAssertEqual(Rule.decide(base, spaceID: home.id), .keep, "no account Spaces: keep")
        XCTAssertEqual(Rule.decide(try TreeOps.deleteSpace(base, id: home.id, now: later), spaceID: home.id), .gone)
    }
}

private extension SyncRecord {
    mutating func setSystemFields(_ data: Data) {
        switch self {
        case .profile(var v): v.meta.backendSystemFields = data; self = .profile(v)
        case .theme(var v): v.meta.backendSystemFields = data; self = .theme(v)
        case .space(var v): v.meta.backendSystemFields = data; self = .space(v)
        case .folder(var v): v.meta.backendSystemFields = data; self = .folder(v)
        case .tab(var v): v.meta.backendSystemFields = data; self = .tab(v)
        case .archiveItem(var v): v.meta.backendSystemFields = data; self = .archiveItem(v)
        case .splitLayout(var v): v.meta.backendSystemFields = data; self = .splitLayout(v)
        case .easel(var v): v.meta.backendSystemFields = data; self = .easel(v)
        case .easelElement(var v): v.meta.backendSystemFields = data; self = .easelElement(v)
        }
    }
}
