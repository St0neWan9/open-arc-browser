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
    case didFetchChanges
    case willSendChanges
    case didSendChanges
}

/// Receives engine callbacks. Implemented by the store.
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
    func fetchChanges() async throws
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

    func fetchChanges() async throws {
        try await engine.fetchChanges()
    }

    func sendChanges() async throws {
        try await engine.sendChanges()
    }

    func cancel() async {
        await engine.cancelOperations()
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
        await delegate.driverHandle(translated)
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges
            .filter { context.options.scope.contains($0) }
            .map(Self.driverChange)
        guard !pending.isEmpty, let delegate,
              let batch = await delegate.driverNextBatch(pending: pending)
        else { return nil }
        return CKSyncEngine.RecordZoneChangeBatch(recordsToSave: batch.recordsToSave, recordIDsToDelete: batch.recordIDsToDelete)
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
        case .didFetchChanges: return .didFetchChanges
        case .willSendChanges: return .willSendChanges
        case .didSendChanges: return .didSendChanges
        case .willFetchRecordZoneChanges, .didFetchRecordZoneChanges: return nil
        @unknown default: return nil
        }
    }
}
