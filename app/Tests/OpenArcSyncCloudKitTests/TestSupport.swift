import XCTest
import CloudKit
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

// Shared fixtures and fakes for the CloudKit sync tests. Nothing here touches the network,
// an iCloud account or a real CKContainer.

// MARK: - Fixtures

enum Fx {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    /// Same zone the store derives from the default configuration.
    static let zoneID = CKRecordZone.ID(zoneName: "OpenArc", ownerName: CKCurrentUserDefaultName)
    static let mapper = RecordMapper(zoneID: zoneID)

    /// Deterministic UUIDs so failures are readable.
    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    static func key(_ raw: String) -> SortKey { SortKey(rawValue: raw)! }

    // MARK: Entities with every optional field filled. `variant` changes every value.

    static func profile(_ id: UUID = uuid(1), variant: Int = 0) -> Profile {
        Profile(
            id: id, name: variant == 0 ? "Personal" : "Work",
            settings: variant == 0
                ? ProfileSettings(searchEngine: .duckDuckGo, todayLifetime: 24 * 3600)
                : ProfileSettings(searchEngine: .ecosia, todayLifetime: 7 * 24 * 3600, includesSearchSuggestions: false),
            now: t0
        )
    }

    static func theme(_ id: UUID = uuid(2), variant: Int = 0) -> Theme {
        variant == 0
            ? Theme(id: id, appearance: .dark, colors: [RGBAColor(hex: 0x112233), RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)], grain: 0.25, brightness: 0.3, now: t0)
            : Theme(id: id, appearance: .light, colors: [RGBAColor(hex: 0xABCDEF)], grain: 0.75, brightness: 0.8, now: t0)
    }

    static func space(_ id: UUID = uuid(3), variant: Int = 0) -> Space {
        variant == 0
            ? Space(id: id, profileID: uuid(1), name: "Home", icon: "🏠", themeID: uuid(2), dockSortKey: key("i"), now: t0)
            : Space(id: id, profileID: uuid(101), name: "Office", icon: "💼", themeID: uuid(102), dockSortKey: key("r"), now: t0)
    }

    static func folder(_ id: UUID = uuid(4), variant: Int = 0) -> Folder {
        variant == 0
            ? Folder(id: id, spaceID: uuid(3), parentFolderID: uuid(40), title: "Reading", isExpanded: true, sortKey: key("i"), now: t0)
            : Folder(id: id, spaceID: uuid(103), parentFolderID: uuid(140), title: "Docs", isExpanded: false, sortKey: key("x"), now: t0)
    }

    static func tab(_ id: UUID = uuid(5), variant: Int = 0) -> TabNode {
        var tab: TabNode
        if variant == 0 {
            tab = TabNode(
                id: id, location: .pinned(spaceID: uuid(3), folderID: uuid(4)), sortKey: key("i"),
                url: URL(string: "https://a.example/page?q=1"), title: "A page", customTitle: "Mine",
                pinnedURL: URL(string: "https://a.example/"), faviconURL: URL(string: "https://a.example/favicon.ico"), now: t0
            )
            tab.lastActiveAt = t(1)
        } else {
            tab = TabNode(
                id: id, location: .favorite(profileID: uuid(101)), sortKey: key("q"),
                url: URL(string: "https://b.example/"), title: "B page", customTitle: "Theirs",
                pinnedURL: URL(string: "https://b.example/start"), faviconURL: URL(string: "https://b.example/icon.png"), now: t0
            )
            tab.lastActiveAt = t(2)
        }
        return tab
    }

    static func archiveItem(_ id: UUID = uuid(6), variant: Int = 0) -> ArchiveItem {
        variant == 0
            ? ArchiveItem(id: id, url: URL(string: "https://c.example/"), title: "Closed", faviconURL: URL(string: "https://c.example/f.ico"), spaceID: uuid(3), folderPath: ["Reading", "Later"], reason: .closed, archivedAt: t0)
            : ArchiveItem(id: id, url: URL(string: "https://d.example/"), title: "Auto", faviconURL: URL(string: "https://d.example/f.ico"), spaceID: uuid(103), folderPath: ["Docs"], reason: .autoArchived, archivedAt: t0)
    }

    static func splitLayout(_ id: UUID = uuid(7), variant: Int = 0) -> SplitLayout {
        let root: SplitNode = variant == 0
            ? .split(axis: .horizontal, children: [
                SplitChild(node: .pane(tabID: uuid(50)), fraction: 0.4),
                SplitChild(node: .split(axis: .vertical, children: [
                    SplitChild(node: .pane(tabID: uuid(51)), fraction: 0.5),
                    SplitChild(node: .pane(tabID: uuid(52)), fraction: 0.5),
                ]), fraction: 0.6),
            ])
            : .split(axis: .vertical, children: [
                SplitChild(node: .pane(tabID: uuid(53)), fraction: 0.3),
                SplitChild(node: .pane(tabID: uuid(54)), fraction: 0.7),
            ])
        return SplitLayout(id: id, spaceID: variant == 0 ? uuid(3) : uuid(103), root: root, now: t0)
    }

    static func easel(_ id: UUID = uuid(8), variant: Int = 0) -> Easel {
        Easel(id: id, title: variant == 0 ? "Moodboard" : "Plan", now: t0)
    }

    static func easelElement(_ id: UUID = uuid(9), variant: Int = 0) -> EaselElement {
        variant == 0
            ? EaselElement(
                id: id, easelID: uuid(8), zKey: key("i"), frame: EaselRect(x: 10, y: 20, width: 30, height: 40),
                content: .text(string: "Hello"),
                style: EaselStyle(strokeColor: RGBAColor(hex: 0x111111), fillColor: RGBAColor(hex: 0xEEEEEE), strokeWidth: 2, fontSize: 16),
                now: t0
            )
            : EaselElement(
                id: id, easelID: uuid(108), zKey: key("r"), frame: EaselRect(x: 1, y: 2, width: 3, height: 4),
                content: .pen(points: [EaselPoint(x: 0, y: 0), EaselPoint(x: 0.5, y: 1)]),
                style: EaselStyle(strokeColor: RGBAColor(hex: 0x2255FF), strokeWidth: 4, fontSize: 20),
                now: t0
            )
    }

    /// One record of every type, every optional field filled.
    static func fullRecords(variant: Int = 0) -> [SyncRecord] {
        [
            .profile(profile(variant: variant)),
            .theme(theme(variant: variant)),
            .space(space(variant: variant)),
            .folder(folder(variant: variant)),
            .tab(tab(variant: variant)),
            .archiveItem(archiveItem(variant: variant)),
            .splitLayout(splitLayout(variant: variant)),
            .easel(easel(variant: variant)),
            .easelElement(easelElement(variant: variant)),
        ]
    }

    /// Records whose optional fields are all nil / empty, plus the tab locations not covered above.
    static func sparseRecords() -> [SyncRecord] {
        var todayTab = TabNode(id: uuid(60), location: .today(spaceID: uuid(3)), sortKey: key("i"), url: nil, title: "", now: t0)
        todayTab.lastActiveAt = t(9)
        let topPinned = TabNode(id: uuid(61), location: .pinned(spaceID: uuid(3), folderID: nil), sortKey: key("k"), url: URL(string: "https://e.example"), title: "E", now: t0)
        return [
            .space(Space(id: uuid(62), profileID: uuid(1), name: "Bare", dockSortKey: key("i"), now: t0)),
            .folder(Folder(id: uuid(63), spaceID: uuid(3), title: "Top", sortKey: key("i"), now: t0)),
            .tab(todayTab),
            .tab(topPinned),
            .archiveItem(ArchiveItem(id: uuid(64), url: nil, title: "", faviconURL: nil, spaceID: nil, folderPath: [], reason: .spaceDeleted, archivedAt: t0)),
            .splitLayout(SplitLayout(id: uuid(65), spaceID: uuid(3), root: .pane(tabID: uuid(66)), now: t0)),
        ]
    }

    /// Archived system fields for `id` carrying a server change tag, as if CloudKit had saved it.
    static func systemFields(for id: SyncRecordID, tag: String, zoneID: CKRecordZone.ID = zoneID) -> Data {
        let record = CKRecord(recordType: id.type.rawValue, recordID: CKRecord.ID(recordName: id.recordName, zoneID: zoneID))
        let archiver = ChangeTagArchiver(requiringSecureCoding: true)
        archiver.changeTag = tag
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    /// A "server copy" of a record: all fields plus a server change tag.
    static func serverCK(_ record: SyncRecord, tag: String) -> CKRecord {
        mapper.makeCKRecord(record, systemFields: systemFields(for: record.id, tag: tag))
    }
}

/// CKRecord has no public setter for the change tag; this archiver injects one while encoding
/// system fields so tests can mimic a record the server already saved.
final class ChangeTagArchiver: NSKeyedArchiver {
    var changeTag = "tag"

    override func encode(_ object: Any?, forKey key: String) {
        if key == "ETag" {
            super.encode(changeTag as NSString, forKey: key)
        } else {
            super.encode(object, forKey: key)
        }
    }
}

extension SyncRecord {
    /// Returns a copy with `meta` transformed.
    func mapMeta(_ transform: (inout SyncMetadata) -> Void) -> SyncRecord {
        switch self {
        case .profile(var v): transform(&v.meta); return .profile(v)
        case .theme(var v): transform(&v.meta); return .theme(v)
        case .space(var v): transform(&v.meta); return .space(v)
        case .folder(var v): transform(&v.meta); return .folder(v)
        case .tab(var v): transform(&v.meta); return .tab(v)
        case .archiveItem(var v): transform(&v.meta); return .archiveItem(v)
        case .splitLayout(var v): transform(&v.meta); return .splitLayout(v)
        case .easel(var v): transform(&v.meta); return .easel(v)
        case .easelElement(var v): transform(&v.meta); return .easelElement(v)
        }
    }

    /// Copy without backend system fields, for value comparisons.
    var withoutSystemFields: SyncRecord { mapMeta { $0.backendSystemFields = nil } }

    var tab: TabNode? {
        if case .tab(let v) = self { return v }
        return nil
    }
}

// MARK: - Fake local database

enum FakeError: Error, Equatable {
    case applyFailed
    case accountStatusFailed
}

actor FakeDatabase: SyncLocalDatabase {
    private(set) var records: [SyncRecordID: SyncRecord] = [:]
    private(set) var appliedBatches: [RemoteChangeBatch] = []
    private var failingApplies = 0
    private var syncState: Data?

    init(_ records: [SyncRecord] = []) {
        for record in records { self.records[record.id] = record }
    }

    func put(_ record: SyncRecord) { records[record.id] = record }
    func remove(_ id: SyncRecordID) { records.removeValue(forKey: id) }
    func failNextApplies(_ count: Int) { failingApplies = count }

    func record(for id: SyncRecordID) async -> SyncRecord? { records[id] }

    func apply(_ batch: RemoteChangeBatch) async throws {
        if failingApplies > 0 {
            failingApplies -= 1
            throw FakeError.applyFailed
        }
        appliedBatches.append(batch)
        for record in batch.upserts { records[record.id] = record }
        for id in batch.deletions { records.removeValue(forKey: id) }
    }

    func loadSyncState() async -> Data? { syncState }
    func saveSyncState(_ data: Data?) async { syncState = data }
}

// MARK: - In-memory state storage

actor InMemoryStateStorage: SyncStateStorage {
    private(set) var data: Data?

    func loadState() async throws -> Data? { data }
    func saveState(_ data: Data?) async throws { self.data = data }

    var decoded: PersistedSyncState { PersistedSyncState.decode(data) }
}

// MARK: - Retry scheduler

/// Records scheduled retries; tests run them explicitly, so nothing ever sleeps.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class FakeRetryScheduler: RetryScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _delays: [TimeInterval] = []
    private var work: [@Sendable () async -> Void] = []

    var delays: [TimeInterval] { lock.withLock { _delays } }
    var queuedCount: Int { lock.withLock { work.count } }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        lock.withLock {
            _delays.append(delay)
            self.work.append(work)
        }
    }

    /// Runs the oldest queued retry. Returns false if none was queued.
    @discardableResult
    func runNext() async -> Bool {
        let next: (@Sendable () async -> Void)? = lock.withLock { work.isEmpty ? nil : work.removeFirst() }
        guard let next else { return false }
        await next()
        return true
    }
}

// MARK: - Fake sync engine driver

/// Mimics the parts of CKSyncEngine the store relies on:
/// - pending record changes are a duplicate-free ordered list;
/// - `sendChanges` asks the delegate for batches, offering each pending change at most once per
///   call, removes the sent changes from the pending list, and reports the outcome built by
///   `sendHandler` (default: every save and delete succeeds, saved records get a change tag);
/// - `fetchChanges` emits the scripted fetch events between willFetch / didFetch;
/// - every delegate call runs inside `EngineCallbackContext`, as in `CKSyncEngineDriver`, and an
///   engine call made from inside a callback is recorded in `callsInsideCallback` (CKSyncEngine
///   traps on it).
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class FakeDriver: SyncEngineDriver, @unchecked Sendable {
    typealias SendHandler = @Sendable (DriverBatch) async -> DriverSentRecordChanges
    /// Builds the events of a `fetchChanges` call when no scripted fetch is queued.
    typealias FetchHandler = @Sendable () async -> [SyncDriverEvent]

    private let lock = NSLock()
    private weak var _delegate: (any SyncEngineDriverDelegate)?
    private var _pending: [DriverRecordChange] = []
    private var _zoneSavePending = false
    private var _zoneSaveRequests = 0
    private var _sentBatches: [DriverBatch] = []
    private var _fetchEvents: [[SyncDriverEvent]] = []
    private var _fetchErrors: [any Error] = []
    private var _sendErrors: [any Error] = []
    private var _sendHandler: SendHandler?
    private var _fetchHandler: FetchHandler?
    private var _accountStatus: Result<CKAccountStatus, FakeError> = .success(.available)
    private var _cancelled = false
    private var _tagCounter = 0
    private var _fetchScopes: [DriverFetchScope] = []
    private var _callsInsideCallback: [String] = []
    let engineState: Data?

    init(engineState: Data? = nil) {
        self.engineState = engineState
    }

    func attach(_ delegate: any SyncEngineDriverDelegate) {
        lock.withLock { _delegate = delegate }
    }

    private var delegate: (any SyncEngineDriverDelegate)? { lock.withLock { _delegate } }

    // MARK: Test controls

    var accountStatusResult: Result<CKAccountStatus, FakeError> {
        get { lock.withLock { _accountStatus } }
        set { lock.withLock { _accountStatus = newValue } }
    }

    var sendHandler: SendHandler? {
        get { lock.withLock { _sendHandler } }
        set { lock.withLock { _sendHandler = newValue } }
    }

    var fetchHandler: FetchHandler? {
        get { lock.withLock { _fetchHandler } }
        set { lock.withLock { _fetchHandler = newValue } }
    }

    var sentBatches: [DriverBatch] { lock.withLock { _sentBatches } }
    var zoneSavePending: Bool { lock.withLock { _zoneSavePending } }
    var zoneSaveRequests: Int { lock.withLock { _zoneSaveRequests } }
    var isCancelled: Bool { lock.withLock { _cancelled } }

    /// Events delivered by the next `fetchChanges` call (FIFO, one array per call).
    func queueFetch(_ events: [SyncDriverEvent]) { lock.withLock { _fetchEvents.append(events) } }
    func failNextFetch(_ error: any Error) { lock.withLock { _fetchErrors.append(error) } }
    func failNextSend(_ error: any Error) { lock.withLock { _sendErrors.append(error) } }

    /// Fetch scopes of every `fetchChanges` call, in order.
    var fetchScopes: [DriverFetchScope] { lock.withLock { _fetchScopes } }
    /// Engine calls (`fetchChanges`, `sendChanges`, `cancel`) made from inside a delegate
    /// callback, directly or from a task that inherited the callback context. CKSyncEngine traps
    /// on these (D4). (B86)
    var callsInsideCallback: [String] { lock.withLock { _callsInsideCallback } }

    private func noteEngineCall(_ name: String) {
        guard EngineCallbackContext.isActive else { return }
        lock.withLock { _callsInsideCallback.append(name) }
    }

    /// One delegate callback, inside the callback context as `CKSyncEngineDriver` sets it.
    private func callback(_ delegate: any SyncEngineDriverDelegate, _ event: SyncDriverEvent) async {
        await EngineCallbackContext.$isActive.withValue(true) {
            await delegate.driverHandle(event)
        }
    }

    private func nextBatchCallback(_ delegate: any SyncEngineDriverDelegate, _ pending: [DriverRecordChange]) async -> DriverBatch? {
        await EngineCallbackContext.$isActive.withValue(true) {
            await delegate.driverNextBatch(pending: pending)
        }
    }

    /// Delivers an event as the engine would, outside any fetch/send.
    func emit(_ event: SyncDriverEvent) async {
        guard let delegate else { return }
        await callback(delegate, event)
    }

    /// Replays one automatic engine sync (`SyncReason.scheduled`) the way CKSyncEngine reports
    /// it: nothing is thrown, even when an internal operation such as the database subscription
    /// save failed; only the events below reach the delegate. Pending changes are left alone.
    func emitAutomaticCycle(fetchEvents: [SyncDriverEvent] = [], sendEvents: [SyncDriverEvent] = []) async {
        guard let delegate else { return }
        await callback(delegate, .willFetchChanges)
        for event in fetchEvents { await callback(delegate, event) }
        await callback(delegate, .didFetchChanges(.scheduled))
        await callback(delegate, .willSendChanges)
        for event in sendEvents { await callback(delegate, event) }
        await callback(delegate, .didSendChanges(.scheduled))
    }

    // MARK: SyncEngineDriver

    func accountStatus() async throws -> CKAccountStatus {
        try accountStatusResult.get()
    }

    func addPending(_ changes: [DriverRecordChange]) {
        lock.withLock {
            for change in changes where !_pending.contains(change) { _pending.append(change) }
        }
    }

    func removePending(_ changes: [DriverRecordChange]) {
        lock.withLock { _pending.removeAll { changes.contains($0) } }
    }

    var pendingChanges: [DriverRecordChange] { lock.withLock { _pending } }

    func addPendingZoneSave(_ zone: CKRecordZone) {
        lock.withLock {
            _zoneSavePending = true
            _zoneSaveRequests += 1
        }
    }

    func fetchChanges(_ scope: DriverFetchScope) async throws {
        noteEngineCall("fetchChanges")
        lock.withLock { _fetchScopes.append(scope) }
        let error: (any Error)? = lock.withLock { _fetchErrors.isEmpty ? nil : _fetchErrors.removeFirst() }
        if let error { throw error }
        let scripted: [SyncDriverEvent]? = lock.withLock { _fetchEvents.isEmpty ? nil : _fetchEvents.removeFirst() }
        var events = scripted ?? []
        if scripted == nil, let fetchHandler { events = await fetchHandler() }
        guard let delegate else { return }
        await callback(delegate, .willFetchChanges)
        for event in events { await callback(delegate, event) }
        await callback(delegate, .didFetchChanges(.manual))
    }

    func sendChanges() async throws {
        noteEngineCall("sendChanges")
        let error: (any Error)? = lock.withLock { _sendErrors.isEmpty ? nil : _sendErrors.removeFirst() }
        if let error { throw error }
        guard let delegate else { return }
        await callback(delegate, .willSendChanges)
        let zoneSave: Bool = lock.withLock {
            defer { _zoneSavePending = false }
            return _zoneSavePending
        }
        if zoneSave {
            if case .success(.available) = accountStatusResult {
                await callback(delegate, .sentZoneChanges(saved: [Fx.zoneID], failed: [:]))
            } else {
                // Like CloudKit: without a usable account the zone save fails and stays pending.
                lock.withLock { _zoneSavePending = true }
                await callback(delegate, .sentZoneChanges(saved: [], failed: [Fx.zoneID: CKError(.notAuthenticated)]))
            }
        }
        var offered: [DriverRecordChange] = []
        while true {
            let candidates = pendingChanges.filter { !offered.contains($0) }
            guard !candidates.isEmpty,
                  let batch = await nextBatchCallback(delegate, candidates)
            else { break }
            offered += candidates
            let sent = batch.recordsToSave.map { DriverRecordChange.save($0.recordID) }
                + batch.recordIDsToDelete.map { DriverRecordChange.delete($0) }
            removePending(sent)
            lock.withLock { _sentBatches.append(batch) }
            let result = await (sendHandler ?? defaultResult)(batch)
            await callback(delegate, .sentRecordChanges(result))
        }
        await callback(delegate, .didSendChanges(.manual))
    }

    func cancel() async {
        noteEngineCall("cancel")
        lock.withLock { _cancelled = true }
    }

    // MARK: Default server behaviour

    /// Every change succeeds; each saved record comes back with a fresh change tag "srv-<n>".
    private var defaultResult: SendHandler {
        { [weak self] batch in
            guard let self else { return DriverSentRecordChanges() }
            return DriverSentRecordChanges(
                savedRecords: batch.recordsToSave.map { self.saved($0) },
                deletedRecordIDs: batch.recordIDsToDelete
            )
        }
    }

    /// What the server returns for a successful save of `record`.
    func saved(_ record: CKRecord) -> CKRecord {
        let tag: String = lock.withLock {
            _tagCounter += 1
            return "srv-\(_tagCounter)"
        }
        guard let decoded = try? Fx.mapper.decode(record) else { return record }
        return Fx.serverCK(decoded, tag: tag)
    }
}

/// Hands out a fresh `FakeDriver` on each factory call, so tests can follow driver restarts.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class FakeDriverFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _drivers: [FakeDriver] = []
    private let configure: @Sendable (FakeDriver) -> Void

    init(configure: @escaping @Sendable (FakeDriver) -> Void = { _ in }) {
        self.configure = configure
    }

    var drivers: [FakeDriver] { lock.withLock { _drivers } }
    var current: FakeDriver? { lock.withLock { _drivers.last } }

    var factory: SyncEngineDriverFactory {
        { [self] state, delegate in
            let driver = FakeDriver(engineState: state)
            configure(driver)
            driver.attach(delegate)
            lock.withLock { _drivers.append(driver) }
            return driver
        }
    }
}

// MARK: - Store harness

/// A store wired to fakes: fixed clock, in-memory state, fake scheduler and driver.
struct StoreHarness {
    let store: CloudKitSyncStore
    let database: FakeDatabase
    let storage: InMemoryStateStorage
    let scheduler: FakeRetryScheduler
    let drivers: FakeDriverFactory

    init(
        records: [SyncRecord] = [],
        scope: SyncScope = .default,
        storage: InMemoryStateStorage = InMemoryStateStorage(),
        isEntitled: Bool = true,
        configureDriver: @escaping @Sendable (FakeDriver) -> Void = { _ in }
    ) {
        database = FakeDatabase(records)
        self.storage = storage
        scheduler = FakeRetryScheduler()
        drivers = FakeDriverFactory(configure: configureDriver)
        store = CloudKitSyncStore(
            configuration: CloudKitSyncStore.Configuration(scope: scope),
            stateStorage: storage,
            driverFactory: drivers.factory,
            clock: { Fx.t(1000) },
            retryScheduler: scheduler,
            containerCheck: { _ in isEntitled }
        )
    }

    var driver: FakeDriver {
        get throws { try XCTUnwrap(drivers.current, "store has not created a driver") }
    }

    func start() async throws {
        try await store.start(database: database)
    }

    var persisted: PersistedSyncState {
        get async { await storage.decoded }
    }
}

// MARK: - Bounded AsyncStream reading

/// Reads `stream` until `predicate` matches or `timeout` passes (the timeout only guards against
/// a hang; matching statuses are normally already buffered). Returns everything seen.
func collectStatuses(
    _ stream: AsyncStream<SyncStatus>,
    timeout: TimeInterval = 2,
    until predicate: @escaping @Sendable (SyncStatus) -> Bool
) async -> [SyncStatus] {
    await withTaskGroup(of: [SyncStatus]?.self) { group in
        group.addTask {
            var seen: [SyncStatus] = []
            for await status in stream {
                seen.append(status)
                if predicate(status) { return seen }
            }
            return seen
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first ?? []
    }
}

/// Takes at most `count` statuses from `stream`, giving up after `timeout`.
func takeStatuses(_ stream: AsyncStream<SyncStatus>, count: Int, timeout: TimeInterval = 2) async -> [SyncStatus] {
    let box = StatusBox()
    _ = await collectStatuses(stream, timeout: timeout) { status in
        box.append(status) >= count
    }
    return box.values
}

/// Thread-safe accumulator for `takeStatuses`.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class StatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [SyncStatus] = []

    func append(_ status: SyncStatus) -> Int {
        lock.withLock {
            _values.append(status)
            return _values.count
        }
    }

    var values: [SyncStatus] { lock.withLock { _values } }
}
