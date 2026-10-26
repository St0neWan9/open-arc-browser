import Foundation
import OpenArcSyncAPI

/// Runs the sync store for the app (plan D5): starts it at launch when "Sync Sidebar" is on,
/// stops and restarts it when the toggle changes, forwards local changes, and keeps the status
/// the account card shows. [03 §账号卡] observed: the "Sync Sidebar" toggle and the
/// "Last synced: <time>" line.
///
/// Every call into the store runs on one serial chain, so a start always comes before the
/// enqueues that follow it and a quick off/on cannot reorder `stop` and `start`.
///
/// Changes made while sync is off (or before a start that failed) are not queued anywhere: a
/// stopped store keeps no queue the app could add to. So turning sync off marks the workspace
/// for a full upload (persisted in `AppPreferences`), and the next successful start announces
/// every record once. The backend merges each record under `ConflictPolicy`, so records the
/// server already has cost an upload but change nothing.
@MainActor
public final class SidebarSyncController: ObservableObject {
    /// Latest status from `SyncStore.statusUpdates()`.
    @Published public private(set) var status: SyncStatus
    /// Why the last "Sync Now" (or resume) failed, when the store threw instead of reporting a
    /// status. Cleared by the next attempt.
    @Published public private(set) var actionError: String?

    public let store: any SyncStore
    private let database: (any SyncLocalDatabase)?
    private let preferences: AppPreferences
    /// Every record id of the current workspace, for a full upload.
    private let allRecordIDs: @MainActor () -> [SyncRecordID]
    let now: () -> Date

    /// True between a successful `start` and the next `stop`.
    public private(set) var isRunning = false
    /// Tail of the serial chain of store calls.
    private var tail: Task<Void, Never>?

    /// - Parameters:
    ///   - database: the on-disk workspace store. nil (tests, previews, a read-only store) never
    ///     starts the sync store.
    ///   - allRecordIDs: every record id of the workspace (`WorkspaceState.allRecordIDs`).
    ///   - now: clock for the relative "Last synced" time.
    public init(
        store: any SyncStore,
        database: (any SyncLocalDatabase)?,
        preferences: AppPreferences,
        allRecordIDs: @escaping @MainActor () -> [SyncRecordID],
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.database = database
        self.preferences = preferences
        self.allRecordIDs = allRecordIDs
        self.now = now
        status = .disabled
    }

    /// False with `DisabledSyncStore`: this build has no sync backend.
    public var isBackendAvailable: Bool { !(store is DisabledSyncStore) }

    /// The "Sync Sidebar" toggle as shown: off when there is no backend.
    public var isEnabled: Bool { isBackendAvailable && preferences.isSidebarSyncEnabled }

    /// The account card for the current status, with "Last synced" relative to `now()`.
    public var card: SyncCardState {
        let reference = now()
        return SyncCardState.make(
            status: status,
            backendAvailable: isBackendAvailable,
            isSyncOn: preferences.isSidebarSyncEnabled,
            actionError: actionError,
            formatDate: { SyncTimeFormat.relative($0, now: reference) }
        )
    }

    // MARK: Lifecycle

    /// At launch: starts the store when the backend exists, there is a database and "Sync
    /// Sidebar" is on. With the toggle off nothing is started. inferred (D5).
    public func launch() {
        guard isEnabled, database != nil else { return }
        perform { await self.startStore() }
    }

    /// The "Sync Sidebar" toggle. Stores the choice, then starts or stops the store.
    public func setEnabled(_ isOn: Bool) {
        guard isBackendAvailable else { return }
        objectWillChange.send()
        preferences.isSidebarSyncEnabled = isOn
        actionError = nil
        if isOn {
            guard database != nil else { return }
            perform { await self.startStore() }
        } else {
            // Edits from now on are not queued; the next start uploads everything once.
            preferences.needsFullSyncUpload = true
            // `stop` is safe on a store that is not running.
            perform {
                self.isRunning = false
                await self.store.stop()
            }
        }
    }

    /// Hands local changes to the store while it runs. Dropped otherwise: the full upload after
    /// the next start covers them (see the type comment).
    public func forward(_ changes: [PendingChange]) {
        guard !changes.isEmpty else { return }
        perform {
            // When not running, `needsFullSyncUpload` is already set: it starts true and is set
            // again whenever sync is turned off; only a successful start clears it.
            guard self.isRunning else { return }
            await self.store.enqueue(changes)
        }
    }

    /// "Sync Now" on the account card (shown when the last sync failed).
    public func syncNow() {
        perform {
            self.actionError = nil
            do {
                try await self.store.syncNow()
            } catch {
                self.actionError = Self.describe(error)
            }
        }
    }

    /// After the iCloud account changed the store pauses until the app decides. The user chose to
    /// sync this Mac's sidebar with the new account: drop the old account's sync state and upload
    /// every record. inferred (D5; the decision itself is ours, not observed).
    public func resumeAfterAccountChange() {
        perform {
            self.actionError = nil
            await self.store.resetLocalSyncState()
            await self.store.enqueue(self.allRecordIDs().map(PendingChange.save))
        }
    }

    /// Follows the store's status until the stream ends or the calling task is cancelled. The
    /// Settings window runs this in `.task`.
    public func observeStatus() async {
        for await next in store.statusUpdates() {
            status = next
        }
    }

    /// Waits until every store call queued so far has finished (tests).
    func settle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    // MARK: Internals

    private func startStore() async {
        guard let database, preferences.isSidebarSyncEnabled else { return }
        do {
            try await store.start(database: database)
        } catch {
            isRunning = false
            actionError = Self.describe(error)
            // Changes made until the next start are not queued anywhere.
            preferences.needsFullSyncUpload = true
            return
        }
        isRunning = true
        if preferences.needsFullSyncUpload {
            await store.enqueue(allRecordIDs().map(PendingChange.save))
            preferences.needsFullSyncUpload = false
        }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// "Last synced: <time>" as a relative time. [03 §账号卡] observed the line; the time format was
/// not recorded, so the relative wording is ours (inferred).
public enum SyncTimeFormat {
    /// "just now", "5 minutes ago", "1 hour ago", "3 days ago"; a week or more shows the date.
    /// A time in the future (clock skew between devices) reads "just now".
    public static func relative(
        _ date: Date,
        now: Date,
        absolute: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        let minute: TimeInterval = 60, hour = 60 * minute, day = 24 * hour
        switch seconds {
        case ..<minute: return "just now"
        case ..<hour: return count(Int(seconds / minute), "minute")
        case ..<day: return count(Int(seconds / hour), "hour")
        case ..<(7 * day): return count(Int(seconds / day), "day")
        default: return absolute(date)
        }
    }

    private static func count(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit) ago" : "\(n) \(unit)s ago"
    }
}
