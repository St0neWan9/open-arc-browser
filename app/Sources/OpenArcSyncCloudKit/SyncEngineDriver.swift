import CloudKit
import os

// The thin seam between the store logic and CKSyncEngine. Everything above this seam is unit
// tested with a fake driver (no network, no iCloud account, no signing). `CKSyncEngineDriver` below
// is the only code that touches CKSyncEngine / CKContainer, and it only translates types.

/// A pending record change, mirroring `CKSyncEngine.PendingRecordZoneChange`.
enum DriverRecordChange: Hashable, Sendable {
    case save(CKRecord.ID)
    case delete(CKRecord.ID)

    var recordID: CKRecord.ID {
        switch self {
        case .save(let id), .delete(let id): return id
        }
    }
}

/// What to upload next.
struct DriverBatch: Sendable {
    var recordsToSave: [CKRecord]
    var recordIDsToDelete: [CKRecord.ID]
}

/// Account change reported by the engine.
enum DriverAccountChange: Hashable, Sendable {
    case signIn
    case signOut
    case switchAccounts
}

/// Why a zone disappeared from the server.
enum DriverZoneDeletionReason: Hashable, Sendable {
    /// Deleted by this app on another device.
    case deleted
    /// The user deleted the app's iCloud data in Settings.
    case purged
    /// The user reset end-to-end encrypted data (lost keychain); encrypted values are gone.
    case encryptedDataReset
}

struct DriverFailedSave: Sendable {
    var record: CKRecord
    var error: CKError
}

struct DriverFailedDelete: Sendable {
    var recordID: CKRecord.ID
    var error: CKError
}

struct DriverSentRecordChanges: Sendable {
    var savedRecords: [CKRecord] = []
    var failedSaves: [DriverFailedSave] = []
    var deletedRecordIDs: [CKRecord.ID] = []
    var failedDeletes: [DriverFailedDelete] = []
}

struct DriverFetchedDeletion: Hashable, Sendable {
    var recordID: CKRecord.ID
    var recordType: String
}

/// Why the engine ran a fetch or send, mirroring `CKSyncEngine.SyncReason`.
enum DriverSyncReason: Hashable, Sendable {
    /// The engine's own automatic sync. CKSyncEngine reports no error for these: a failure of its
    /// internal operations (database subscription, zone fetch) only shows as a cycle that ends
    /// without results, so the store must not read the end of the cycle as success (B63).
    case scheduled
    /// A `fetchChanges()` / `sendChanges()` call; errors are thrown to the caller.
    case manual
}

/// Result of `SyncEngineDriver.fetchZoneChanges`: every change in one zone after a token,
/// collapsed to the latest state per record.
struct DriverZoneChanges: Sendable {
    var modified: [CKRecord] = []
    var deleted: [DriverFetchedDeletion] = []
    /// Archived `CKServerChangeToken` to pass next time. nil when the zone does not exist (yet).
    var token: Data?
    /// Records the server listed but could not return (per-record errors); skipped.
    var failedRecordCount = 0
}

/// Engine events, translated from `CKSyncEngine.Event`.
enum SyncDriverEvent: Sendable {
    /// New engine state (server change tokens, engine-side pending list). Persist it.
    case stateUpdate(Data)
    case accountChange(DriverAccountChange)
    case zonesDeleted([CKRecordZone.ID: DriverZoneDeletionReason])
    case fetchedRecordChanges(modified: [CKRecord], deleted: [DriverFetchedDeletion])
    case sentZoneChanges(saved: [CKRecordZone.ID], failed: [CKRecordZone.ID: CKError])
    case sentRecordChanges(DriverSentRecordChanges)
    case willFetchChanges
    /// nil when the engine does not say (the fetch context needs macOS 14.2).
    case didFetchChanges(DriverSyncReason?)
    case willSendChanges
    case didSendChanges(DriverSyncReason?)
}

/// What a manual fetch covers.
enum DriverFetchScope: Hashable, Sendable {
    /// Database level (`CKSyncEngine.FetchChangesOptions.Scope.all`): the engine reads the
    /// private database's change feed from its saved token, then fetches every zone the feed
    /// reports changed. This is what finds other devices' edits; the store always uses it (B86).
    case allZones
    /// Only these zones. Not used by the store: a zone-restricted fetch only fetches zones the
    /// engine already knows to be changed (D4 log: "no zone IDs needing to be fetched").
    case zones([CKRecordZone.ID])
}

/// Marks the task of a CKSyncEngine delegate callback (`handleEvent`,
/// `nextRecordZoneChangeBatch`). CKSyncEngine traps when such a task awaits a call into the
/// engine ("Cannot await a call into CKSyncEngine from within a delegate callback", D4). A plain
/// `Task {}` started inside a callback inherits the callback's task-local context, so work the
/// store starts from a callback runs detached (`TaskRetryScheduler`). The fake driver in the
/// tests sets this marker the same way and records any engine call made while it is set. (B86)
enum EngineCallbackContext {
    @TaskLocal static var isActive = false
}

/// Receives engine callbacks. Implemented by the store.
///
/// Both methods run inside an engine callback (`EngineCallbackContext.isActive`): they must not
/// await `fetchChanges`, `sendChanges` or `cancel` on the driver, neither directly nor in a task
/// that inherits the callback's context. Synchronous state calls (`addPending`, ...) are fine.
protocol SyncEngineDriverDelegate: AnyObject, Sendable {
    func driverHandle(_ event: SyncDriverEvent) async
    /// Builds the next upload batch out of `pending` (already filtered to the send scope).
    /// Returns nil when there is nothing to send.
    func driverNextBatch(pending: [DriverRecordChange]) async -> DriverBatch?
}

/// The operations the store needs from CKSyncEngine.
protocol SyncEngineDriver: AnyObject, Sendable {
    func accountStatus() async throws -> CKAccountStatus
    func addPending(_ changes: [DriverRecordChange])
    func removePending(_ changes: [DriverRecordChange])
    var pendingChanges: [DriverRecordChange] { get }
    func addPendingZoneSave(_ zone: CKRecordZone)
    func fetchChanges(_ scope: DriverFetchScope) async throws
    /// Reads the changes of one zone directly from the private database, from `token` (nil: the
    /// whole zone), bypassing the engine. CKSyncEngine's `fetchChanges` only asks the server
    /// about zones it already knows to be changed (a push, its own `needsToFetchDatabaseChanges`,
    /// or a last database fetch about a day old); otherwise it logs "no zone IDs needing to be
    /// fetched" and returns without a request. So without a push (dropped by APNs, or never
    /// sent to the device that made the change) neither a relaunch nor an activation fetch saw
    /// other instances' edits (D4 2026-10-27). The store polls its zone with this instead. (B86)
    /// Not an engine call: allowed anywhere, but the store only calls it from `syncNow`.
    func fetchZoneChanges(_ zoneID: CKRecordZone.ID, since token: Data?) async throws -> DriverZoneChanges
    func sendChanges() async throws
    /// Cancels in-flight work; the driver is not used afterwards.
    func cancel() async
}

/// Creates a driver. `engineState` is the last persisted state (nil for a fresh engine).
typealias SyncEngineDriverFactory = @Sendable (_ engineState: Data?, _ delegate: any SyncEngineDriverDelegate) throws -> any SyncEngineDriver

// MARK: - CKSyncEngine adapter

/// Production driver. Not covered by unit tests: it needs a signed app with the iCloud
/// entitlement and a real container (creating `CKContainer` without them traps).
final class CKSyncEngineDriver: SyncEngineDriver, CKSyncEngineDelegate, @unchecked Sendable {
    // @unchecked: `container` is immutable; `engine` is written once at the end of init, before
    // the instance escapes; the delegate is behind a lock.
    private let container: CKContainer
    private var engine: CKSyncEngine!
    private let delegateBox: OSAllocatedUnfairLock<WeakDelegate>

    private struct WeakDelegate: Sendable {
        weak var value: (any SyncEngineDriverDelegate)?
    }

    init(containerIdentifier: String, engineState: Data?, delegate: any SyncEngineDriverDelegate) throws {
        container = CKContainer(identifier: containerIdentifier)
        delegateBox = OSAllocatedUnfairLock(initialState: WeakDelegate(value: delegate))
        let serialization = try engineState.map { try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let configuration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: serialization,
            delegate: self
        )
        engine = CKSyncEngine(configuration)
    }

    static func factory(containerIdentifier: String) -> SyncEngineDriverFactory {
        { state, delegate in
            try CKSyncEngineDriver(containerIdentifier: containerIdentifier, engineState: state, delegate: delegate)
        }
    }

    private var delegate: (any SyncEngineDriverDelegate)? {
        delegateBox.withLock { $0.value }
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await container.accountStatus()
    }

    func addPending(_ changes: [DriverRecordChange]) {
        engine.state.add(pendingRecordZoneChanges: changes.map(Self.engineChange))
    }

    func removePending(_ changes: [DriverRecordChange]) {
        engine.state.remove(pendingRecordZoneChanges: changes.map(Self.engineChange))
    }

    var pendingChanges: [DriverRecordChange] {
        engine.state.pendingRecordZoneChanges.map(Self.driverChange)
    }

    func addPendingZoneSave(_ zone: CKRecordZone) {
        engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
    }

    // The asserts name the mistake in debug builds; CKSyncEngine itself traps with a vaguer message.

    func fetchChanges(_ scope: DriverFetchScope) async throws {
        assert(!EngineCallbackContext.isActive, "fetchChanges awaited inside a CKSyncEngine delegate callback")
        try await engine.fetchChanges(Self.fetchOptions(for: scope))
    }

    func fetchZoneChanges(_ zoneID: CKRecordZone.ID, since token: Data?) async throws -> DriverZoneChanges {
        let database = container.privateCloudDatabase
        var changeToken = token.flatMap(Self.unarchiveToken)
        // Latest state per record across pages, in first-seen order; a later page wins.
        enum Latest { case saved(CKRecord), deleted(DriverFetchedDeletion) }
        var latest: [CKRecord.ID: Latest] = [:]
        var order: [CKRecord.ID] = []
        var failed = 0
        func note(_ id: CKRecord.ID, _ value: Latest) {
            if latest[id] == nil { order.append(id) }
            latest[id] = value
        }
        while true {
            let page: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>],
                       deletions: [CKDatabase.RecordZoneChange.Deletion],
                       changeToken: CKServerChangeToken,
                       moreComing: Bool)
            do {
                page = try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken)
            } catch let error as CKError where error.code == .changeTokenExpired && changeToken != nil {
                // The server forgot our token: read the whole zone again.
                changeToken = nil
                latest.removeAll()
                order.removeAll()
                failed = 0
                continue
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
                // Not created yet (no device has uploaded) or removed; the engine reports a
                // removal through its own database fetch.
                return DriverZoneChanges()
            }
            for (id, result) in page.modificationResultsByID {
                switch result {
                case .success(let modification): note(id, .saved(modification.record))
                case .failure: failed += 1
                }
            }
            for deletion in page.deletions {
                note(deletion.recordID, .deleted(DriverFetchedDeletion(recordID: deletion.recordID, recordType: deletion.recordType)))
            }
            changeToken = page.changeToken
            if !page.moreComing { break }
        }
        var changes = DriverZoneChanges(token: changeToken.flatMap(Self.archiveToken), failedRecordCount: failed)
        for id in order {
            switch latest[id] {
            case .saved(let record): changes.modified.append(record)
            case .deleted(let deletion): changes.deleted.append(deletion)
            case nil: break
            }
        }
        return changes
    }

    static func archiveToken(_ token: CKServerChangeToken) -> Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    static func unarchiveToken(_ data: Data) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    func sendChanges() async throws {
        assert(!EngineCallbackContext.isActive, "sendChanges awaited inside a CKSyncEngine delegate callback")
        try await engine.sendChanges()
    }

    func cancel() async {
        assert(!EngineCallbackContext.isActive, "cancel awaited inside a CKSyncEngine delegate callback")
        await engine.cancelOperations()
    }

    /// Engine options for a fetch. `.allZones` is the engine's default scope `.all`, a
    /// database-level fetch: zones changed elsewhere are found through the database change feed
    /// even when no push marked them changed.
    static func fetchOptions(for scope: DriverFetchScope) -> CKSyncEngine.FetchChangesOptions {
        switch scope {
        case .allZones: return CKSyncEngine.FetchChangesOptions(scope: .all)
        case .zones(let ids): return CKSyncEngine.FetchChangesOptions(scope: .zoneIDs(ids))
        }
    }

    private static func engineChange(_ change: DriverRecordChange) -> CKSyncEngine.PendingRecordZoneChange {
        switch change {
        case .save(let id): return .saveRecord(id)
        case .delete(let id): return .deleteRecord(id)
        }
    }

    private static func driverChange(_ change: CKSyncEngine.PendingRecordZoneChange) -> DriverRecordChange {
        switch change {
        case .saveRecord(let id): return .save(id)
        case .deleteRecord(let id): return .delete(id)
        @unknown default:
            // Future cases cannot be sent by us; report them as a save so they are dropped
            // by the store's record lookup.
            return .save(CKRecord.ID(recordName: "unknown"))
        }
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard let delegate, let translated = Self.translate(event) else { return }
        await EngineCallbackContext.$isActive.withValue(true) {
            await delegate.driverHandle(translated)
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
            .map(Self.driverChange)
        guard !pending.isEmpty, let delegate else { return nil }
        let batch = await EngineCallbackContext.$isActive.withValue(true) {
            await delegate.driverNextBatch(pending: pending)
        }
        guard let batch else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.recordsToSave, recordIDsToDelete: batch.recordIDsToDelete)
    }

    private static func reason(_ reason: CKSyncEngine.SyncReason) -> DriverSyncReason {
        reason == .manual ? .manual : .scheduled
    }

    private static func translate(_ event: CKSyncEngine.Event) -> SyncDriverEvent? {
        switch event {
        case .stateUpdate(let update):
            guard let data = try? JSONEncoder().encode(update.stateSerialization) else { return nil }
            return .stateUpdate(data)
        case .accountChange(let change):
            switch change.changeType {
            case .signIn: return .accountChange(.signIn)
            case .signOut: return .accountChange(.signOut)
            case .switchAccounts: return .accountChange(.switchAccounts)
            @unknown default: return nil
            }
        case .fetchedDatabaseChanges(let changes):
            var deleted: [CKRecordZone.ID: DriverZoneDeletionReason] = [:]
            for deletion in changes.deletions {
                switch deletion.reason {
                case .deleted: deleted[deletion.zoneID] = .deleted
                case .purged: deleted[deletion.zoneID] = .purged
                case .encryptedDataReset: deleted[deletion.zoneID] = .encryptedDataReset
                @unknown default: deleted[deletion.zoneID] = .deleted
                }
            }
            return deleted.isEmpty ? nil : .zonesDeleted(deleted)
        case .fetchedRecordZoneChanges(let changes):
            return .fetchedRecordChanges(
                modified: changes.modifications.map(\.record),
                deleted: changes.deletions.map { DriverFetchedDeletion(recordID: $0.recordID, recordType: $0.recordType) }
            )
        case .sentDatabaseChanges(let sent):
            var failed: [CKRecordZone.ID: CKError] = [:]
            for failure in sent.failedZoneSaves {
                failed[failure.zone.zoneID] = failure.error
            }
            return .sentZoneChanges(saved: sent.savedZones.map(\.zoneID), failed: failed)
        case .sentRecordZoneChanges(let sent):
            return .sentRecordChanges(DriverSentRecordChanges(
                savedRecords: sent.savedRecords,
                failedSaves: sent.failedRecordSaves.map { DriverFailedSave(record: $0.record, error: $0.error) },
                deletedRecordIDs: sent.deletedRecordIDs,
                failedDeletes: sent.failedRecordDeletes.map { DriverFailedDelete(recordID: $0.key, error: $0.value) }
            ))
        case .willFetchChanges: return .willFetchChanges
        case .didFetchChanges(let fetched):
            // The fetch context exists from macOS 14.2; before that the reason is unknown and the
            // store decides by whether one of its own `syncNow` calls is running.
            if #available(macOS 14.2, *) {
                return .didFetchChanges(Self.reason(fetched.context.reason))
            }
            return .didFetchChanges(nil)
        case .willSendChanges: return .willSendChanges
        case .didSendChanges(let sent): return .didSendChanges(Self.reason(sent.context.reason))
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges: return nil
        @unknown default: return nil
        }
    }
}
