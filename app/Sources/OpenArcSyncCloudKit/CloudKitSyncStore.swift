import CloudKit
import OpenArcModel
import OpenArcSyncAPI

/// Errors thrown by `CloudKitSyncStore` itself (CloudKit errors are rethrown as they are).
public enum CloudKitSyncStoreError: Error, Hashable, Sendable {
    case notStarted
    case unavailable(SyncUnavailableReason)
}

/// Schedules a delayed retry. Injectable so tests never sleep.
protocol RetryScheduling: Sendable {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void)
}

struct TaskRetryScheduler: RetryScheduling {
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            await work()
        }
    }
}

/// `SyncStore` backed by CloudKit: CKSyncEngine on the private database, one custom zone.
///
/// Flow:
/// - `enqueue` records ids in a persisted pending queue and hands them to the engine.
/// - When the engine sends, `driverNextBatch` pulls the current records from the local database
///   and maps them to CKRecords (all keys, cached system fields for conflict detection).
/// - Fetched server records are merged with the local copy under `ConflictPolicy` (field-group
///   last-writer-wins, delete wins, ties to the server) and applied in one batch.
/// - A `serverRecordChanged` failure is merged the same way; the merged record is resent if the
///   local copy won any group or holds a delete the server has not seen.
public actor CloudKitSyncStore: SyncStore {

    public struct Configuration: Hashable, Sendable {
        /// iCloud container. Placeholder until the real bundle id / container is registered.
        public var containerIdentifier: String
        /// Name of the custom zone in the private database. Persisted; never rename.
        public var zoneName: String
        public var scope: SyncScope
        /// Upper bound per upload batch (CloudKit allows 400 operations per request).
        public var maxRecordsPerBatch: Int

        public init(
            containerIdentifier: String = "iCloud.org.openarc.browser",
            zoneName: String = "OpenArc",
            scope: SyncScope = .default,
            maxRecordsPerBatch: Int = 200
        ) {
            self.containerIdentifier = containerIdentifier
            self.zoneName = zoneName
            self.scope = scope
            self.maxRecordsPerBatch = maxRecordsPerBatch
        }
    }

    // MARK: Dependencies

    private let configuration: Configuration
    private let mapper: RecordMapper
    private let zone: CKRecordZone
    private let injectedStorage: (any SyncStateStorage)?
    private let driverFactory: SyncEngineDriverFactory
    private let clock: @Sendable () -> Date
    private let retryScheduler: any RetryScheduling
    /// Whether this process may use the container. Creating a `CKContainer` without the iCloud
    /// entitlement traps, so the driver is only built when this returns true.
    private let containerCheck: @Sendable (String) -> Bool
    private nonisolated let broadcaster = StatusBroadcaster(initial: .disabled)

    // MARK: State

    private var database: (any SyncLocalDatabase)?
    private var storage: (any SyncStateStorage)?
    private var driver: (any SyncEngineDriver)?
    private var state = PersistedSyncState()
    /// Generation of each queue entry included in the batch being sent.
    private var inFlight: [SyncRecordID: UInt64] = [:]
    private var phase: SyncStatus.Phase = .disabled
    /// First failure seen during the current fetch/send cycle.
    private var cycleFailure: String?
    private var retryAttempt = 0
    private var retryScheduled = false
    /// A confirming `syncNow` is queued after an automatic engine cycle (see `finishEngineCycle`).
    private var confirmationScheduled = false
    /// Number of `syncNow` calls running; their engine cycles are finished by `syncNow` itself.
    private var manualSyncDepth = 0
    /// Message of the last `.failed` phase, shown again while its retry is still waiting.
    private var lastFailureMessage: String?

    /// Production initializer. No CloudKit object is created until `start(database:)`.
    /// - Parameter stateStorage: where to persist sync state; nil uses the database's
    ///   `loadSyncState` / `saveSyncState`.
    public init(configuration: Configuration = Configuration(), stateStorage: (any SyncStateStorage)? = nil) {
        self.init(
            configuration: configuration,
            stateStorage: stateStorage,
            driverFactory: CKSyncEngineDriver.factory(containerIdentifier: configuration.containerIdentifier),
            clock: { Date() },
            retryScheduler: TaskRetryScheduler(),
            containerCheck: CloudKitEntitlements.allowsContainer
        )
    }

    init(
        configuration: Configuration,
        stateStorage: (any SyncStateStorage)?,
        driverFactory: @escaping SyncEngineDriverFactory,
        clock: @escaping @Sendable () -> Date,
        retryScheduler: any RetryScheduling,
        containerCheck: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        self.configuration = configuration
        let zoneID = CKRecordZone.ID(zoneName: configuration.zoneName, ownerName: CKCurrentUserDefaultName)
        self.zone = CKRecordZone(zoneID: zoneID)
        self.mapper = RecordMapper(zoneID: zoneID)
        self.injectedStorage = stateStorage
        self.driverFactory = driverFactory
        self.clock = clock
        self.retryScheduler = retryScheduler
        self.containerCheck = containerCheck
    }

    // MARK: - SyncStore

    public func start(database: any SyncLocalDatabase) async throws {
        if driver != nil { await stop() }
        self.database = database
        let storage = injectedStorage ?? LocalDatabaseSyncStateStorage(database: database)
        self.storage = storage
        state = PersistedSyncState.decode(try? await storage.loadState())
        // A queue persisted by an older build may still hold local-only records (B73): drop them.
        for entry in state.pending.entries where entry.id.type.isLocalOnly {
            state.pending.remove(entry.id)
        }
        if state.awaitingAccountReset {
            setPhase(.unavailable(.accountChanged))
            return
        }
        try await bringUpDriver()
    }

    public func stop() async {
        await persist()
        if let driver { await driver.cancel() }
        driver = nil
        database = nil
        storage = nil
        inFlight.removeAll()
        setPhase(.disabled)
    }

    public func enqueue(_ changes: [PendingChange]) async {
        var driverChanges: [DriverRecordChange] = []
        for change in changes {
            switch change {
            case .delete(let id) where id.type.isLocalOnly:
                // Local-only records never touch the server, not even to delete a copy an older
                // build uploaded (see `SyncScope`).
                continue
            case .save(let id):
                guard configuration.scope.includes(id.type) else { continue }
                state.pending.add(id, .save)
                driverChanges.append(.save(mapper.recordID(for: id)))
            case .delete(let id):
                // Deletes are sent even for out-of-scope types so a scope change cleans up the server.
                state.pending.add(id, .delete)
                driverChanges.append(.delete(mapper.recordID(for: id)))
            }
        }
        guard !driverChanges.isEmpty else { return }
        if let driver {
            if !state.zoneSaved { driver.addPendingZoneSave(zone) }
            driver.addPending(driverChanges)
        }
        await persist()
        publishStatus()
    }

    public func syncNow() async throws {
        guard let driver else {
            if state.awaitingAccountReset { throw CloudKitSyncStoreError.unavailable(.accountChanged) }
            if phase == .unavailable(.notConfigured) { throw CloudKitSyncStoreError.unavailable(.notConfigured) }
            throw CloudKitSyncStoreError.notStarted
        }
        manualSyncDepth += 1
        defer { manualSyncDepth -= 1 }
        await applyDeferredRemoteChanges()
        do {
            try await driver.fetchChanges()
            try await driver.sendChanges()
        } catch {
            handleOperationError(error)
            await persist()
            throw error
        }
        // Only here, with both halves returned without an error, is the cycle known to be good.
        finishConfirmedCycle()
        await persist()
    }

    public func resetLocalSyncState() async {
        if let driver { await driver.cancel() }
        driver = nil
        inFlight.removeAll()
        cycleFailure = nil
        state = PersistedSyncState()
        await persist()
        if database != nil {
            try? await bringUpDriver()
        } else {
            setPhase(.disabled)
        }
    }

    public func currentStatus() async -> SyncStatus {
        broadcaster.current
    }

    public nonisolated func statusUpdates() -> AsyncStream<SyncStatus> {
        broadcaster.stream()
    }

    // MARK: - Driver lifecycle

    private func bringUpDriver() async throws {
        // Without the entitlement (a SwiftPM or ad-hoc signed build) report it instead of trapping.
        guard containerCheck(configuration.containerIdentifier) else {
            setPhase(.unavailable(.notConfigured))
            return
        }
        let driver = try driverFactory(state.engineState, self)
        self.driver = driver

        let reason: SyncUnavailableReason?
        do {
            reason = CloudKitErrorPolicy.unavailableReason(for: try await driver.accountStatus())
        } catch {
            reason = .temporarilyUnavailable
        }
        // The engine keeps working in the background and reports a later sign-in as an event.
        setPhase(reason.map { .unavailable($0) } ?? .idle)

        if !state.zoneSaved { driver.addPendingZoneSave(zone) }
        let pending = state.pending.entries.map { entry -> DriverRecordChange in
            let id = mapper.recordID(for: entry.id)
            return entry.operation == .save ? .save(id) : .delete(id)
        }
        if !pending.isEmpty { driver.addPending(pending) }
        await applyDeferredRemoteChanges()
        await persist()
    }

    // MARK: - Status

    private func setPhase(_ phase: SyncStatus.Phase) {
        self.phase = phase
        if case .failed(let message) = phase { lastFailureMessage = message }
        publishStatus()
    }

    private func publishStatus() {
        broadcaster.publish(SyncStatus(phase: phase, lastSyncedAt: state.lastSyncedAt, pendingChangeCount: state.pending.count))
    }

    private var isAccountBlocked: Bool {
        if case .unavailable(let reason) = phase, reason != .temporarilyUnavailable { return true }
        return phase == .disabled
    }

    private func noteFailure(_ message: String) {
        if cycleFailure == nil { cycleFailure = message }
    }

    /// End of a `syncNow` whose fetch and send both returned without an error. The only place
    /// that advances `lastSyncedAt` and resets the retry backoff (B63).
    ///
    /// Remote changes that could not be applied locally (staged for retry) keep the status at
    /// `.failed` and do not advance `lastSyncedAt`: the local data is not in sync yet, even when
    /// the send half of the cycle succeeded. Decided by the user (plan Q3).
    private func finishConfirmedCycle() {
        // A per-record failure has already scheduled the next (longer) retry; keep its backoff.
        if cycleFailure == nil { retryAttempt = 0 }
        guard !isAccountBlocked else { return }
        let hasStagedRemoteChanges = !state.deferredUpserts.isEmpty || !state.deferredDeletions.isEmpty
        if let cycleFailure {
            setPhase(.failed(message: cycleFailure))
        } else if hasStagedRemoteChanges {
            setPhase(.failed(message: "Some changes from iCloud could not be saved yet; will retry."))
        } else {
            state.lastSyncedAt = clock()
            setPhase(.idle)
        }
    }

    /// End of an engine fetch or send (`didFetchChanges` / `didSendChanges`).
    ///
    /// CKSyncEngine throws errors only to explicit `fetchChanges()` / `sendChanges()` calls. In
    /// its automatic syncs a failed internal operation (database subscription save, zone fetch;
    /// seen in D4 as HTTP 500, CKError 15) is not reported at all: the cycle simply ends. So the
    /// end of an automatic cycle proves nothing. It never advances `lastSyncedAt`; instead a
    /// confirming `syncNow` runs at once, which surfaces any error and then retries with backoff.
    /// Failures the cycle did report show as `.failed` and schedule a backoff retry. (B63)
    private func finishEngineCycle(_ reason: DriverSyncReason?) {
        guard !isAccountBlocked else { return }
        if let cycleFailure { setPhase(.failed(message: cycleFailure)) }
        // A running `syncNow` finishes its own cycles. Without a reason (macOS < 14.2) a cycle
        // that ends while `syncNow` runs is taken to be that call's.
        let finishedByCaller = reason == .manual || (reason == nil && manualSyncDepth > 0)
        guard !finishedByCaller else { return }
        if cycleFailure != nil {
            scheduleRetry(suggested: nil)
        } else if retryScheduled {
            // The engine ran on its own while a retry waits: nothing is confirmed yet, so keep
            // showing the failure instead of "syncing" until the retry settles it.
            setPhase(.failed(message: lastFailureMessage ?? "Sync failed; will retry."))
        } else {
            scheduleConfirmation()
        }
    }

    private func scheduleConfirmation() {
        guard !retryScheduled, !confirmationScheduled else { return }
        confirmationScheduled = true
        retryScheduler.schedule(after: 0) { [weak self] in
            await self?.runConfirmation()
        }
    }

    private func runConfirmation() async {
        confirmationScheduled = false
        guard driver != nil, !retryScheduled else { return }
        try? await syncNow()
    }

    // MARK: - Persistence

    private func persist() async {
        guard let storage else { return }
        try? await storage.saveState(state.encoded())
    }

    // MARK: - Errors outside record results

    private func handleOperationError(_ error: any Error) {
        switch CloudKitErrorPolicy.classify(error) {
        case .retry(let after):
            setPhase(.failed(message: Self.describe(error)))
            scheduleRetry(suggested: after)
        case .accountUnavailable(let reason):
            setPhase(.unavailable(reason))
        case .quotaExceeded:
            setPhase(.failed(message: "iCloud storage is full"))
        case .recreateZone:
            state.zoneSaved = false
            driver?.addPendingZoneSave(zone)
            setPhase(.failed(message: Self.describe(error)))
            scheduleRetry(suggested: nil)
        case .resolveConflict, .resetSystemFieldsAndResend, .discard:
            // Outside a record result there is no change to drop: the whole operation failed
            // (e.g. serverRejectedRequest / HTTP 500 on the subscription save in D4). Keep
            // everything pending and retry with backoff. (B63)
            setPhase(.failed(message: Self.describe(error)))
            scheduleRetry(suggested: nil)
        }
    }

    private func scheduleRetry(suggested: TimeInterval?) {
        guard !retryScheduled else { return }
        retryScheduled = true
        let delay = CloudKitErrorPolicy.backoff(attempt: retryAttempt, suggested: suggested)
        retryAttempt += 1
        retryScheduler.schedule(after: delay) { [weak self] in
            await self?.runScheduledRetry()
        }
    }

    private func runScheduledRetry() async {
        retryScheduled = false
        guard driver != nil else { return }
        try? await syncNow()
    }

    private static func describe(_ error: any Error) -> String {
        if let ck = error as? CKError { return "CloudKit error \(ck.code.rawValue)" }
        return String(describing: error)
    }

    // MARK: - Remote changes

    /// Merges server copies with local copies and applies the result in one batch. On failure the
    /// server copies are kept and retried later (the engine has already advanced its change token).
    private func applyRemote(serverRecords: [SyncRecord], deletions: [SyncRecordID]) async {
        guard let database else {
            state.deferredUpserts += serverRecords
            state.deferredDeletions += deletions
            return
        }
        var upserts: [SyncRecord] = []
        var resend: [SyncRecordID] = []
        // Pending saves the server copy supersedes entirely, with the queue generation seen here.
        var superseded: [(SyncRecordID, UInt64)] = []
        for server in serverRecords {
            guard configuration.scope.includes(server) else { continue }
            let pendingEntry = state.pending.entry(for: server.id)
            if pendingEntry?.operation == .delete { continue }
            if let local = await database.record(for: server.id),
               let outcome = RecordMerge.merge(local: local, server: server) {
                upserts.append(outcome.merged)
                if outcome.needsUpload {
                    // Mixed or local-wins: the merged record goes up once.
                    resend.append(server.id)
                } else if let pendingEntry {
                    // Remote wins everything: the local copy becomes the server's, so a pending
                    // save would only upload the server's own content again.
                    superseded.append((server.id, pendingEntry.generation))
                }
            } else {
                upserts.append(server)
            }
        }
        // A server deletion of a local-only record (an older build purging its uploaded copy)
        // must not remove this device's own record.
        let deletions = deletions.filter { !$0.type.isLocalOnly }
        var driverRemovals: [DriverRecordChange] = []
        for id in deletions {
            // Delete wins: a pending local edit of a record deleted on the server is dropped.
            state.pending.remove(id)
            state.systemFields.removeValue(forKey: id.recordName)
            let ckID = mapper.recordID(for: id)
            driverRemovals += [.save(ckID), .delete(ckID)]
        }
        if !driverRemovals.isEmpty { driver?.removePending(driverRemovals) }

        let batch = RemoteChangeBatch(upserts: upserts, deletions: deletions)
        if !upserts.isEmpty || !deletions.isEmpty {
            do {
                try await database.apply(batch)
            } catch {
                state.deferredUpserts += serverRecords
                state.deferredDeletions += deletions
                noteFailure("Applying server changes failed: \(error)")
                return
            }
        }
        // Only after the apply succeeded, and only if no newer local change arrived meanwhile.
        for (id, generation) in superseded where state.pending.remove(id, ifGeneration: generation) {
            driver?.removePending([.save(mapper.recordID(for: id))])
        }
        if !resend.isEmpty {
            await enqueue(resend.map { .save($0) })
        }
    }

    private func applyDeferredRemoteChanges() async {
        guard database != nil,
              !state.deferredUpserts.isEmpty || !state.deferredDeletions.isEmpty
        else { return }
        let upserts = state.deferredUpserts
        let deletions = state.deferredDeletions
        state.deferredUpserts = []
        state.deferredDeletions = []
        await applyRemote(serverRecords: upserts, deletions: deletions)
    }

    private func handleFetched(modified: [CKRecord], deleted: [DriverFetchedDeletion]) async {
        await applyDeferredRemoteChanges()
        var serverRecords: [SyncRecord] = []
        for ck in modified {
            // Local-only records (Profile, B73) an older build uploaded are ignored.
            guard let record = try? mapper.decode(ck), !record.id.type.isLocalOnly else { continue }
            state.systemFields[record.id.recordName] = record.meta.backendSystemFields
            serverRecords.append(record)
        }
        let deletions = deleted.compactMap { mapper.syncRecordID(from: $0.recordID) }
        await applyRemote(serverRecords: serverRecords, deletions: deletions)
    }

    // MARK: - Sent changes

    /// Drops a confirmed change from the queue unless the record changed again after the send.
    private func confirmSent(_ id: SyncRecordID, as change: DriverRecordChange) {
        let generation = inFlight.removeValue(forKey: id)
        let removed = state.pending.remove(id, ifGeneration: generation)
        if !removed, let entry = state.pending.entry(for: id) {
            // A newer local change arrived while this one was in flight: keep it pending.
            let ckID = change.recordID
            driver?.addPending([entry.operation == .save ? .save(ckID) : .delete(ckID)])
        }
    }

    /// Gives up on a change that can never succeed.
    private func discard(_ id: SyncRecordID, _ change: DriverRecordChange, error: CKError) {
        inFlight.removeValue(forKey: id)
        state.pending.remove(id)
        driver?.removePending([change])
        noteFailure("Dropped change for \(id.recordName): CloudKit error \(error.code.rawValue)")
    }

    private func keepPending(_ change: DriverRecordChange) {
        driver?.addPending([change])
    }

    private func handleSent(_ sent: DriverSentRecordChanges) async {
        for ck in sent.savedRecords {
            guard let id = mapper.syncRecordID(from: ck.recordID) else { continue }
            state.systemFields[id.recordName] = RecordMapper.encodeSystemFields(of: ck)
            confirmSent(id, as: .save(ck.recordID))
        }
        for ckID in sent.deletedRecordIDs {
            guard let id = mapper.syncRecordID(from: ckID) else { continue }
            state.systemFields.removeValue(forKey: id.recordName)
            confirmSent(id, as: .delete(ckID))
        }

        var conflicts: [(SyncRecordID, CKRecord)] = []
        for failure in sent.failedSaves {
            let ckID = failure.record.recordID
            guard let id = mapper.syncRecordID(from: ckID) else { continue }
            let change = DriverRecordChange.save(ckID)
            switch CloudKitErrorPolicy.classify(failure.error) {
            case .resolveConflict:
                if let serverRecord = failure.error.serverRecord {
                    conflicts.append((id, serverRecord))
                } else {
                    keepPending(change)
                }
            case .recreateZone:
                state.zoneSaved = false
                state.systemFields[id.recordName] = Data()
                driver?.addPendingZoneSave(zone)
                keepPending(change)
            case .resetSystemFieldsAndResend:
                state.systemFields[id.recordName] = Data()
                keepPending(change)
            case .retry(let after):
                keepPending(change)
                noteFailure("CloudKit error \(failure.error.code.rawValue)")
                scheduleRetry(suggested: after)
            case .accountUnavailable(let reason):
                keepPending(change)
                setPhase(.unavailable(reason))
            case .quotaExceeded:
                keepPending(change)
                noteFailure("iCloud storage is full")
            case .discard:
                discard(id, change, error: failure.error)
            }
        }

        for failure in sent.failedDeletes {
            guard let id = mapper.syncRecordID(from: failure.recordID) else { continue }
            let change = DriverRecordChange.delete(failure.recordID)
            switch CloudKitErrorPolicy.classify(failure.error) {
            case .resetSystemFieldsAndResend, .recreateZone:
                // Already gone on the server: the delete is done.
                state.systemFields.removeValue(forKey: id.recordName)
                confirmSent(id, as: change)
            case .retry(let after):
                keepPending(change)
                noteFailure("CloudKit error \(failure.error.code.rawValue)")
                scheduleRetry(suggested: after)
            case .accountUnavailable(let reason):
                keepPending(change)
                setPhase(.unavailable(reason))
            case .quotaExceeded, .resolveConflict:
                keepPending(change)
            case .discard:
                discard(id, change, error: failure.error)
            }
        }

        if !conflicts.isEmpty { await resolveConflicts(conflicts) }
    }

    /// `serverRecordChanged`: merge the server copy into the local one, apply the merge locally,
    /// and resend if the local copy won anything (including a delete the server has not seen).
    /// When the server copy wins everything it is applied as it is (its version included) and the
    /// pending save is dropped, so nothing goes back up. [A20]
    private func resolveConflicts(_ conflicts: [(SyncRecordID, CKRecord)]) async {
        guard let database else { return }
        var upserts: [SyncRecord] = []
        for (id, serverCK) in conflicts {
            let generation = inFlight.removeValue(forKey: id)
            let ckID = mapper.recordID(for: id)
            guard let server = try? mapper.decode(serverCK) else {
                // Undecodable server copy: overwrite it with ours on the next send.
                state.systemFields[id.recordName] = RecordMapper.encodeSystemFields(of: serverCK)
                keepPending(.save(ckID))
                continue
            }
            state.systemFields[id.recordName] = server.meta.backendSystemFields
            guard let local = await database.record(for: id),
                  let outcome = RecordMerge.merge(local: local, server: server)
            else {
                upserts.append(server)
                state.pending.remove(id, ifGeneration: generation)
                driver?.removePending([.save(ckID)])
                continue
            }
            upserts.append(outcome.merged)
            if outcome.needsUpload {
                keepPending(.save(ckID))
            } else if state.pending.remove(id, ifGeneration: generation) {
                driver?.removePending([.save(ckID)])
            } else {
                keepPending(.save(ckID))
            }
        }
        do {
            try await database.apply(RemoteChangeBatch(upserts: upserts))
        } catch {
            noteFailure("Applying merged records failed: \(error)")
        }
    }

    // MARK: - Zones and account

    private func handleZonesDeleted(_ deleted: [CKRecordZone.ID: DriverZoneDeletionReason]) async {
        guard let reason = deleted[zone.zoneID] else { return }
        let knownRecords = state.systemFields.keys.compactMap(RecordMapper.syncRecordID(fromRecordName:))
        state.systemFields.removeAll()
        state.zoneSaved = false
        inFlight.removeAll()
        switch reason {
        case .encryptedDataReset:
            // The server lost our encrypted data; upload everything we know about again.
            await enqueue(knownRecords.map { .save($0) })
        case .deleted, .purged:
            // The user removed the app's iCloud data. Local data stays; nothing is re-uploaded
            // until the app enqueues new changes (the zone is created again then).
            state.pending.removeAll()
            if let driver { driver.removePending(driver.pendingChanges) }
        }
    }

    private func handleAccountChange(_ change: DriverAccountChange) async {
        switch change {
        case .signIn:
            if !state.zoneSaved { driver?.addPendingZoneSave(zone) }
            setPhase(.idle)
        case .signOut:
            // Keep local data and the pending queue (edits made while signed out still go up
            // after the next sign-in); drop everything tied to the old account.
            state.engineState = nil
            state.systemFields.removeAll()
            state.zoneSaved = false
            inFlight.removeAll()
            setPhase(.unavailable(.noAccount))
        case .switchAccounts:
            // Never merge one account's sidebar into another's without the app deciding:
            // pause until the app calls resetLocalSyncState().
            state = PersistedSyncState()
            state.awaitingAccountReset = true
            inFlight.removeAll()
            setPhase(.unavailable(.accountChanged))
            await persist()
            if let driver { await driver.cancel() }
            driver = nil
        }
    }
}

// MARK: - Driver delegate

extension CloudKitSyncStore: SyncEngineDriverDelegate {

    func driverHandle(_ event: SyncDriverEvent) async {
        switch event {
        case .stateUpdate(let data):
            state.engineState = data
        case .accountChange(let change):
            await handleAccountChange(change)
        case .zonesDeleted(let deleted):
            await handleZonesDeleted(deleted)
        case .fetchedRecordChanges(let modified, let deleted):
            await handleFetched(modified: modified, deleted: deleted)
        case .sentZoneChanges(let saved, let failed):
            if saved.contains(zone.zoneID) { state.zoneSaved = true }
            if let error = failed[zone.zoneID] {
                noteFailure("Creating the iCloud zone failed: CloudKit error \(error.code.rawValue)")
                switch CloudKitErrorPolicy.classify(error) {
                case .accountUnavailable(let reason):
                    setPhase(.unavailable(reason))
                case .quotaExceeded:
                    driver?.addPendingZoneSave(zone)
                case .retry(let after):
                    driver?.addPendingZoneSave(zone)
                    scheduleRetry(suggested: after)
                case .resolveConflict, .recreateZone, .resetSystemFieldsAndResend, .discard:
                    // Records cannot go up without the zone: keep trying with backoff. (B63)
                    driver?.addPendingZoneSave(zone)
                    scheduleRetry(suggested: nil)
                }
            }
        case .sentRecordChanges(let sent):
            await handleSent(sent)
        case .willFetchChanges, .willSendChanges:
            cycleFailure = nil
            if !isAccountBlocked { setPhase(.syncing) }
        case .didFetchChanges(let reason), .didSendChanges(let reason):
            finishEngineCycle(reason)
        }
        await persist()
        publishStatus()
    }

    func driverNextBatch(pending: [DriverRecordChange]) async -> DriverBatch? {
        guard let database, !isAccountBlocked else { return nil }
        var saves: [CKRecord] = []
        var deletes: [CKRecord.ID] = []
        var unsendable: [DriverRecordChange] = []
        for change in pending {
            guard saves.count + deletes.count < configuration.maxRecordsPerBatch else { break }
            guard let id = mapper.syncRecordID(from: change.recordID) else {
                unsendable.append(change)
                continue
            }
            let generation = state.pending.entry(for: id)?.generation
            if id.type.isLocalOnly {
                // Never sent, in either direction (B73).
                unsendable.append(change)
                state.pending.remove(id)
                continue
            }
            switch change {
            case .delete(let ckID):
                deletes.append(ckID)
                inFlight[id] = generation
            case .save(let ckID):
                guard let record = await database.record(for: id) else {
                    // Gone locally (purged): nothing to send.
                    unsendable.append(change)
                    state.pending.remove(id, ifGeneration: generation)
                    continue
                }
                if !configuration.scope.includes(record) {
                    // Left the sync scope: remove the server copy instead.
                    unsendable.append(change)
                    deletes.append(ckID)
                    inFlight[id] = generation
                    continue
                }
                let systemFields = state.systemFields[id.recordName] ?? record.meta.backendSystemFields
                saves.append(mapper.makeCKRecord(record, systemFields: systemFields))
                inFlight[id] = generation
            }
        }
        if !unsendable.isEmpty { driver?.removePending(unsendable) }
        guard !saves.isEmpty || !deletes.isEmpty else { return nil }
        return DriverBatch(recordsToSave: saves, recordIDsToDelete: deletes)
    }
}
