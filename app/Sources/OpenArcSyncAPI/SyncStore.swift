import Foundation
import OpenArcModel

// Sync interface only. The CloudKit implementation (CKSyncEngine, private database, encrypted
// fields) will live in a separate target that depends on this one. This module must not
// import CloudKit, so a second backend (e.g. a self-hosted one) can implement the same protocols.
//
// Data flow (it mirrors how CKSyncEngine works, but is backend-neutral):
//   app edits model ──enqueue(.save(id))──▶ SyncStore ──(later)── asks SyncLocalDatabase.record(for:)
//   server changes ──▶ SyncStore merges using ConflictPolicy ──▶ SyncLocalDatabase.apply(batch)
//
// Which records sync: every `SyncRecordType` except the local-only ones (`isLocalOnly`: Profile,
// plan Q13). Neither the app nor a backend may enqueue, upload or apply a local-only record.
// Beyond that the app chooses what to enqueue. Two consequences hold whatever it chooses:
// - If ArchiveItems do not sync, archiving a synced (pinned/favorite) tab on one device deletes it
//   on the others with no archive entry there. Syncing ArchiveItems avoids that.
// - A record that leaves the synced scope (e.g. a pinned tab moved to Today, if Today is local)
//   must be enqueued as `.delete`; simply no longer enqueuing it would leave a stale server copy.

/// A local change to announce to the sync store. Only ids travel here; the store pulls the
/// current record contents when it is ready to send (so rapid edits coalesce).
public enum PendingChange: Hashable, Sendable {
    /// The record was created or changed (including becoming a tombstone).
    case save(SyncRecordID)
    /// The record should be deleted on the server. Use this once a tombstone can be purged.
    case delete(SyncRecordID)
}

/// Changes coming from the server, already merged with local data under `ConflictPolicy`.
public struct RemoteChangeBatch: Hashable, Sendable {
    /// Records to insert or overwrite locally (may be tombstones).
    public var upserts: [SyncRecord]
    /// Records deleted on the server; remove them locally.
    public var deletions: [SyncRecordID]

    public init(upserts: [SyncRecord] = [], deletions: [SyncRecordID] = []) {
        self.upserts = upserts
        self.deletions = deletions
    }
}

/// Why sync cannot run.
public enum SyncUnavailableReason: Hashable, Sendable {
    /// Not signed in to the platform account (iCloud).
    case noAccount
    /// Account restricted (parental controls, MDM).
    case restricted
    /// Account changed since the last run; local sync state was reset.
    case accountChanged
    /// Temporary; retry later.
    case temporarilyUnavailable
    /// This build cannot reach the backend at all (e.g. the app is not entitled to the iCloud
    /// container). Nothing to retry until a differently signed build runs.
    case notConfigured
}

/// Sync status shown in settings (docs/arc-spec/03-settings.md: "Sync Sidebar" toggle and
/// "Last synced: <time>", observed).
public struct SyncStatus: Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// The user turned sync off.
        case disabled
        case unavailable(SyncUnavailableReason)
        case idle
        case syncing
        /// Last attempt failed; the store retries on its own schedule.
        case failed(message: String)
    }

    public var phase: Phase
    public var lastSyncedAt: Date?
    /// Local changes not yet confirmed by the server.
    public var pendingChangeCount: Int

    public init(phase: Phase, lastSyncedAt: Date? = nil, pendingChangeCount: Int = 0) {
        self.phase = phase
        self.lastSyncedAt = lastSyncedAt
        self.pendingChangeCount = pendingChangeCount
    }

    public static let disabled = SyncStatus(phase: .disabled)
}

/// Implemented by the app's persistence layer; the sync store calls into it.
/// Every method must be safe to call again with the same input (the store may retry).
public protocol SyncLocalDatabase: AnyObject, Sendable {
    /// Current local copy of a record, or nil if it does not exist locally.
    func record(for id: SyncRecordID) async -> SyncRecord?
    /// Applies merged server changes. Must be idempotent.
    func apply(_ batch: RemoteChangeBatch) async throws
    /// Opaque backend state (change tokens etc.) persisted by the app between launches.
    func loadSyncState() async -> Data?
    func saveSyncState(_ data: Data?) async
}

/// A sync backend.
public protocol SyncStore: AnyObject, Sendable {
    /// Starts syncing against `database`. Throws if the backend cannot start at all; account
    /// problems are reported through `status` instead.
    func start(database: any SyncLocalDatabase) async throws
    /// Stops syncing. Pending changes stay queued in the persisted sync state.
    func stop() async
    /// Announces local changes. Cheap; never blocks on the network.
    func enqueue(_ changes: [PendingChange]) async
    /// Fetches and sends now (e.g. on app activation or a manual refresh).
    func syncNow() async throws
    /// Drops all local sync state (account switch, "turn sync off and remove data").
    func resetLocalSyncState() async
    /// Current status.
    func currentStatus() async -> SyncStatus
    /// Status changes. Every call returns a new independent stream that starts with the current status.
    func statusUpdates() -> AsyncStream<SyncStatus>
}

/// The store used when sync is turned off, and in previews and tests. Accepts every call and
/// does nothing; its status is always `.disabled`.
public final class DisabledSyncStore: SyncStore {
    public init() {}

    public func start(database: any SyncLocalDatabase) async throws {}
    public func stop() async {}
    public func enqueue(_ changes: [PendingChange]) async {}
    public func syncNow() async throws {}
    public func resetLocalSyncState() async {}
    public func currentStatus() async -> SyncStatus { .disabled }

    public func statusUpdates() -> AsyncStream<SyncStatus> {
        AsyncStream { continuation in
            continuation.yield(.disabled)
            continuation.finish()
        }
    }
}
