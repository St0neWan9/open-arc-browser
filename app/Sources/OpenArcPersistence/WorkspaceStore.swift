import Foundation
import OpenArcModel
import OpenArcSyncAPI

/// Runs delayed autosave work. Injectable so tests never sleep.
public protocol AutosaveScheduling: Sendable {
    /// Runs `work` once, roughly `delay` seconds from now.
    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void)
}

/// Real-time scheduler backed by `Task.sleep`.
public struct TaskAutosaveScheduler: AutosaveScheduling {
    public init() {}

    public func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0) * 1_000_000_000))
            await work()
        }
    }
}

/// How the initial load went.
public enum WorkspaceLoadOutcome: Hashable, Sendable {
    /// The workspace file was read.
    case loaded
    /// There was no workspace file (first launch). The store starts empty.
    case noFile
    /// The file was corrupt or unreadable. It was moved to `movedTo` and the store starts empty.
    case recoveredFromCorruptFile(movedTo: URL)
    /// The file could not be used and must not be overwritten (e.g. it is from a newer app
    /// version). The store starts empty and is read-only: it never writes the workspace file.
    case refused(PersistenceError)
}

/// The workspace read at launch, plus how the read went.
public struct WorkspaceLoadResult: Hashable, Sendable {
    public var workspace: WorkspaceState
    public var outcome: WorkspaceLoadOutcome

    public init(workspace: WorkspaceState, outcome: WorkspaceLoadOutcome) {
        self.workspace = workspace
        self.outcome = outcome
    }
}

/// One change to the store's workspace, delivered through `WorkspaceStore.events()`.
public struct WorkspaceStoreEvent: Hashable, Sendable {
    public enum Origin: Hashable, Sendable {
        /// The app changed the workspace (`update`/`submit`).
        case local
        /// A remote batch was applied (`SyncLocalDatabase.apply`).
        case remote
    }

    public var origin: Origin
    /// The workspace after the change.
    public var workspace: WorkspaceState
    /// Records that differ from the previous value.
    public var changes: WorkspaceDiff.Changes
    /// What to announce to the sync store (`SyncStore.enqueue`). For local changes this is every
    /// changed record; for remote changes it is only the records whose merge kept local data the
    /// server does not have yet.
    public var pendingChanges: [PendingChange]
}

/// Loads and saves the workspace as JSON on disk, and serves it to the sync store as its
/// `SyncLocalDatabase`.
///
/// - Files (B153): `<directory>/workspace.json`, a snapshot (`WorkspaceFileEnvelope`: schema
///   version, generation, workspace), replaced atomically; and `<directory>/workspace.journal`,
///   the records changed since that snapshot, one appended entry per save (`WorkspaceJournal`).
///   Neither holds the backend's system fields, only a marker (`SystemFieldsOnDisk`).
/// - Saves append a journal entry holding just the records whose disk form changed. A snapshot is
///   written instead (compaction, which also removes the journal) when there is no snapshot of
///   this format yet (first launch, or a file from an earlier build: the silent migration), when
///   the journal would pass `WorkspaceJournal.compactionLimit`, and by `flush()`, so a clean quit
///   leaves one self-contained file (what an earlier build reads after a downgrade).
/// - Load: synchronous, in `init`, so the app has its workspace before the first frame: the
///   snapshot, then the journal entries of its generation. Read the result from `loadResult`.
/// - Autosave: the first unsaved change schedules a write `autosaveDelay` seconds later; further
///   changes within that window ride along, so a burst of edits costs one write. `flush()` writes
///   immediately (app termination).
/// - Remote changes (`apply`) are merged under `ConflictPolicy` and written immediately, because
///   the sync backend may persist its change token right after `apply` returns. A batch that only
///   refreshes the backend's opaque system fields (the server echoing this device's own upload)
///   is not written on its own; it rides on the next write or `flush` (B151). The backend keeps
///   the same system fields in its own state, so a crash before then loses nothing.
/// - Backups (plan B117, Help ▸ Restore Data): rolling copies in `<directory>/Backups/`
///   (`WorkspaceBackups`): one at launch when the newest is a day old or more, then at most one a
///   day, taken from a successful save; the last 7 are kept. They are written on a background task
///   (from the bytes a snapshot save encoded, or encoded there), so they never delay or fail a
///   save. A read-only store writes none.
public actor WorkspaceStore: SyncLocalDatabase {

    /// The directory holding the workspace and sync state files.
    public nonisolated let directory: URL
    /// What `init` read from disk.
    public nonisolated let loadResult: WorkspaceLoadResult

    public nonisolated var workspaceFileURL: URL {
        directory.appendingPathComponent(PersistenceDefaults.workspaceFileName)
    }

    public nonisolated var syncStateFileURL: URL {
        directory.appendingPathComponent(PersistenceDefaults.syncStateFileName)
    }

    public nonisolated var journalFileURL: URL {
        directory.appendingPathComponent(PersistenceDefaults.workspaceJournalFileName)
    }

    // MARK: State

    /// The current workspace (what the next save writes).
    public private(set) var workspace: WorkspaceState
    /// True while the in-memory workspace has changes not yet on disk.
    public private(set) var hasUnsavedChanges = false
    /// Number of successful workspace writes, snapshots and journal entries (diagnostics and tests).
    public private(set) var writeCount = 0
    /// Bytes written by those writes (diagnostics and tests, B151).
    public private(set) var bytesWritten = 0
    /// How many of `writeCount` were snapshots (B153).
    public private(set) var snapshotWriteCount = 0
    /// Size of the last write, snapshot or journal entry (diagnostics and tests, B153).
    public private(set) var lastWriteBytes = 0
    /// Number of sync state writes and their bytes (diagnostics and tests, B151).
    public private(set) var syncStateWriteCount = 0
    public private(set) var syncStateBytesWritten = 0
    /// The workspace the files on disk describe, apart from system fields (as loaded or last
    /// written); nil when there is none. Saves write the records whose disk form differs from it.
    private var lastWrittenWorkspace: WorkspaceState?
    /// Records changed since the last write (candidates for the next journal entry).
    private var dirtyRecords: Set<SyncRecordID> = []
    /// Generation of the snapshot on disk; nil when there is none of this format (no journal entry
    /// may be written until a snapshot is).
    private var snapshotGeneration: UUID?
    /// Size of that snapshot, for the compaction limit.
    private var snapshotBytes = 0
    /// End of the journal's last valid entry: where the next entry goes.
    private var journalLength: UInt64 = 0
    /// The sync state bytes on disk (as last written by this store); nil when unknown.
    private var lastWrittenSyncState: Data?
    /// The last failed autosave, cleared by the next successful write.
    public private(set) var lastSaveError: PersistenceError?
    /// True if the file on disk must not be overwritten (see `WorkspaceLoadOutcome.refused`).
    public nonisolated let isReadOnly: Bool

    private let autosaveDelay: TimeInterval
    private let scheduler: any AutosaveScheduling
    private let now: @Sendable () -> Date
    /// Generation of the scheduled autosave, nil when none is scheduled.
    private var scheduledAutosave: Int?
    private var autosaveGeneration = 0
    private var subscribers: [UUID: AsyncStream<WorkspaceStoreEvent>.Continuation] = [:]
    /// Values handed over through the nonisolated `submit`, newest wins.
    private nonisolated let inbox = SubmissionInbox()
    /// Writes the rolling backups; nil for a read-only store.
    private nonisolated let backupWriter: WorkspaceBackupWriter?

    /// Creates the store and loads `workspace.json` from `directory` synchronously.
    public init(
        directory: URL = PersistenceDefaults.defaultDirectory,
        autosaveDelay: TimeInterval = PersistenceDefaults.autosaveDelay,
        scheduler: any AutosaveScheduling = TaskAutosaveScheduler(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.directory = directory
        self.autosaveDelay = autosaveDelay
        self.scheduler = scheduler
        self.now = now
        let loaded = Self.load(directory: directory, now: now())
        let result = loaded.result
        self.loadResult = result
        self.workspace = result.workspace
        if result.outcome == .loaded {
            lastWrittenWorkspace = result.workspace
            snapshotGeneration = loaded.generation
            snapshotBytes = loaded.snapshotBytes
            journalLength = loaded.journalLength
        }
        if case .refused = result.outcome { isReadOnly = true } else { isReadOnly = false }
        backupWriter = isReadOnly ? nil : WorkspaceBackupWriter(dataDirectory: directory)
        // The launch backup, when the newest backup is a day old or more: the file as loaded, or
        // the workspace as loaded when journal entries were applied to it.
        if result.outcome == .loaded {
            let file = directory.appendingPathComponent(PersistenceDefaults.workspaceFileName)
            let source: WorkspaceBackupWriter.Source = loaded.journalEntries > 0 ? .workspace(result.workspace) : .file(file)
            backupWriter?.backUpIfDue(now: now(), source)
        }
    }

    // MARK: - Backups

    /// The rolling backups in `directory`, newest first (`WorkspaceBackups.list`).
    public nonisolated func backups() -> [WorkspaceBackup] {
        WorkspaceBackups.list(in: directory)
    }

    /// True when a backup exists and the store can take a restored workspace (it is not
    /// read-only). Lists the backup folder; cheap, but it does touch the disk.
    public nonisolated var canRestoreBackup: Bool {
        !isReadOnly && WorkspaceBackups.hasBackups(in: directory)
    }

    /// The last backup that failed to write, cleared by the next successful one (diagnostics).
    public nonisolated var lastBackupError: PersistenceError? { backupWriter?.lastError }

    /// Waits until every backup started so far is on disk (tests, quitting).
    public func waitForBackups() async {
        await backupWriter?.waitUntilIdle()
    }

    // MARK: - Local changes

    /// Replaces the workspace with a locally changed value and schedules an autosave.
    /// Emits a `.local` event with the records that changed.
    public func update(_ new: WorkspaceState) {
        guard new != workspace else { return }
        let changes = WorkspaceDiff.changes(from: workspace, to: new)
        workspace = new
        noteChanged(changes)
        emit(WorkspaceStoreEvent(origin: .local, workspace: new, changes: changes, pendingChanges: changes.pendingChanges))
        scheduleAutosave()
    }

    /// Hands a locally changed value to the store from any context without awaiting. Values are
    /// applied in submission order (only the newest pending value is kept), so calling this from a
    /// synchronous callback can never let an older workspace overwrite a newer one.
    ///
    /// The value replaces the store's workspace as a whole. A caller that keeps its own copy of the
    /// workspace, while `apply` may change the store's, uses `submit(changesFrom:to:)` instead.
    public nonisolated func submit(_ new: WorkspaceState) {
        if inbox.put(new) {
            Task { await self.drainInbox() }
        }
    }

    /// Hands the records that differ between two locally made values to the store, from any
    /// context without awaiting. Only those records are written: every other record keeps the
    /// store's copy. So a value built before a remote batch reached the caller cannot revert or
    /// purge what `apply` stored meanwhile. Submissions are applied in order.
    ///
    /// Both values must come from `TreeOps` (directly, or records taken from this store): which
    /// records changed is decided by their sync metadata (`WorkspaceDiff.stampedChanges`), not by
    /// comparing contents. The caller's thread does no comparing at all; the store diffs on its
    /// own executor, and only the records whose stamps changed (B102: a tab select stamps one tab
    /// of thousands, and this runs on the main thread).
    public nonisolated func submit(changesFrom old: WorkspaceState, to new: WorkspaceState) {
        if inbox.put(changesFrom: old, to: new) {
            Task { await self.drainInbox() }
        }
    }

    /// Writes unsaved changes now and cancels the pending autosave. Call on app termination.
    ///
    /// It also compacts (B153): whenever the journal holds entries, the workspace is written as a
    /// fresh snapshot and the journal removed, so a clean quit leaves `workspace.json` complete
    /// on its own (an earlier build reads only that file).
    public func flush() throws {
        drainInbox()
        scheduledAutosave = nil
        guard hasUnsavedChanges || journalLength > 0 else { return }
        try writeWorkspace(compacting: true)
    }

    /// The workspace with every submission handed over so far applied: what the next save writes.
    public func currentWorkspace() -> WorkspaceState {
        drainInbox()
        return workspace
    }

    // MARK: - Events

    /// A new independent stream of workspace changes. It ends when the consumer stops iterating.
    public func events() -> AsyncStream<WorkspaceStoreEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<WorkspaceStoreEvent>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func emit(_ event: WorkspaceStoreEvent) {
        for continuation in subscribers.values { continuation.yield(event) }
    }

    // MARK: - SyncLocalDatabase

    public func record(for id: SyncRecordID) async -> SyncRecord? {
        drainInbox()
        return workspace.record(for: id)
    }

    /// Merges each upsert with the local copy under `ConflictPolicy` (a no-op when the backend has
    /// already merged it), purges deletions, and writes the file before returning. An upsert the
    /// server wins entirely is stored as the server copy and announces nothing; only a merge the
    /// local copy contributed to (`RecordMerge.Outcome.needsUpload`) is announced for upload. On a write
    /// failure the in-memory workspace is left unchanged and the error is thrown, so the backend
    /// can retry the same batch. Local-only records (Profile, plan Q13) in the batch are ignored.
    public func apply(_ batch: RemoteChangeBatch) async throws {
        drainInbox()
        guard !isReadOnly else { throw PersistenceError.readOnly }
        let old = workspace
        var next = old
        var resend: [SyncRecordID] = []
        // Local-only records (Profile, plan Q13) are never taken from a remote batch, whatever
        // the backend sends; this device's own copy stays as it is.
        for server in batch.upserts where !server.id.type.isLocalOnly {
            if let local = next.record(for: server.id),
               let outcome = RecordMerge.merge(local: local, server: server) {
                next.setRecord(outcome.merged)
                if outcome.needsUpload { resend.append(server.id) }
            } else {
                next.setRecord(server)
            }
        }
        for id in batch.deletions where !id.type.isLocalOnly { next.removeRecord(id) }
        guard next != old else { return }

        let changes = WorkspaceDiff.changes(from: old, to: next)
        let wasUnsaved = hasUnsavedChanges
        let wasDirty = dirtyRecords
        workspace = next
        noteChanged(changes)
        if Self.onlySystemFieldsChanged(changes, from: old, to: next) {
            // Only the backend's opaque data changed (the server echoing this device's own
            // upload with a new change tag). Nothing the user sees changed, and the backend keeps
            // the same data in its own state, so nothing is written for it now: what the files
            // keep of it (a marker, `SystemFieldsOnDisk`) rides on the next write. B151.
        } else {
            do {
                try writeWorkspace()
            } catch {
                workspace = old
                hasUnsavedChanges = wasUnsaved
                dirtyRecords = wasDirty
                throw error
            }
        }
        let pending = resend
            .sorted { $0.recordName < $1.recordName }
            .map(PendingChange.save)
        emit(WorkspaceStoreEvent(origin: .remote, workspace: next, changes: changes, pendingChanges: pending))
    }

    public func loadSyncState() async -> Data? {
        try? Data(contentsOf: syncStateFileURL)
    }

    /// Stores the backend's opaque state atomically; nil removes it. Skipped when read-only.
    public func saveSyncState(_ data: Data?) async {
        guard !isReadOnly else { return }
        if let data {
            // The same bytes again (B151): nothing to write.
            guard data != lastWrittenSyncState else { return }
            do {
                try AtomicFile.write(data, to: syncStateFileURL)
                lastWrittenSyncState = data
                syncStateWriteCount += 1
                syncStateBytesWritten += data.count
            } catch {
                lastWrittenSyncState = nil
            }
        } else {
            lastWrittenSyncState = nil
            try? AtomicFile.remove(syncStateFileURL)
        }
    }

    // MARK: - Internals

    /// True when records were only changed, none added or removed, and each differs from its
    /// previous copy in `SyncMetadata.backendSystemFields` alone.
    static func onlySystemFieldsChanged(_ changes: WorkspaceDiff.Changes, from old: WorkspaceState, to new: WorkspaceState) -> Bool {
        guard changes.removed.isEmpty, !changes.saved.isEmpty else { return false }
        for id in changes.saved {
            guard let before = old.record(for: id), let after = new.record(for: id),
                  before.withBackendSystemFields(nil) == after.withBackendSystemFields(nil)
            else { return false }
        }
        return true
    }

    private func drainInbox() {
        let (base, steps) = inbox.take()
        if let base { update(base) }
        guard !steps.isEmpty else { return }
        // Fold every step's stamped records onto the store's copy in place, remembering each
        // touched record as it was, then announce exactly the records that ended up different
        // (what `update` would find with a full compare: nothing else changed).
        var previous: [SyncRecordID: SyncRecord?] = [:]
        for step in steps {
            let diff = WorkspaceDiff.stampedChanges(from: step.old, to: step.new)
            for id in diff.saved {
                guard let record = step.new.record(for: id) else { continue }
                if previous.index(forKey: id) == nil { previous[id] = .some(workspace.record(for: id)) }
                workspace.setRecord(record)
            }
            for id in diff.removed {
                if previous.index(forKey: id) == nil { previous[id] = .some(workspace.record(for: id)) }
                workspace.removeRecord(id)
            }
        }
        var changes = WorkspaceDiff.Changes()
        for (id, before) in previous {
            let after = workspace.record(for: id)
            guard after != before else { continue }
            if after == nil { changes.removed.append(id) } else { changes.saved.append(id) }
        }
        guard !changes.isEmpty else { return }
        changes.saved.sort { $0.recordName < $1.recordName }
        changes.removed.sort { $0.recordName < $1.recordName }
        noteChanged(changes)
        emit(WorkspaceStoreEvent(origin: .local, workspace: workspace, changes: changes, pendingChanges: changes.pendingChanges))
        scheduleAutosave()
    }

    /// Marks records as changed since the last write.
    private func noteChanged(_ changes: WorkspaceDiff.Changes) {
        hasUnsavedChanges = true
        dirtyRecords.formUnion(changes.saved)
        dirtyRecords.formUnion(changes.removed)
    }

    private func scheduleAutosave() {
        guard !isReadOnly, scheduledAutosave == nil else { return }
        autosaveGeneration += 1
        let generation = autosaveGeneration
        scheduledAutosave = generation
        scheduler.schedule(after: autosaveDelay) { [weak self] in
            await self?.autosaveFired(generation)
        }
    }

    private func autosaveFired(_ generation: Int) {
        guard scheduledAutosave == generation else { return }
        scheduledAutosave = nil
        guard hasUnsavedChanges else { return }
        do {
            try writeWorkspace()
        } catch let error as PersistenceError {
            lastSaveError = error
        } catch {
            lastSaveError = .io(String(describing: error))
        }
    }

    /// Writes the changed records as a journal entry, or the whole workspace as a snapshot when
    /// `compacting`, when there is no snapshot of this format yet, or when the journal would grow
    /// past its limit (see the type comment).
    private func writeWorkspace(compacting: Bool = false) throws {
        guard !isReadOnly else { throw PersistenceError.readOnly }
        let savedAt = now()
        guard let generation = snapshotGeneration, lastWrittenWorkspace != nil else {
            return try writeSnapshot(savedAt: savedAt)
        }
        let changes = changesOnDisk()
        if changes.saved.isEmpty && changes.removed.isEmpty {
            // Changes that cancelled out (an edit undone within the autosave window), or that only
            // touched system fields, leave the files as they are (B151).
            if compacting && journalLength > 0 { return try writeSnapshot(savedAt: savedAt) }
            markWritten()
            return
        }
        if compacting { return try writeSnapshot(savedAt: savedAt) }
        var records = WorkspaceState()
        for record in changes.saved { records.setRecord(record) }
        let entry = WorkspaceJournalEntry(generation: generation, savedAt: savedAt, records: PersistedWorkspace(records), removed: changes.removed)
        let data: Data
        do {
            data = try WorkspaceJournal.encode(entry)
        } catch {
            throw PersistenceError.encodingFailed(String(describing: error))
        }
        if journalLength + UInt64(data.count) > WorkspaceJournal.compactionLimit(snapshotBytes: snapshotBytes)
            || journalOnDiskLength() < journalLength {
            // Too long, or the journal lost entries this store wrote (removed or cut short by
            // something else): the whole workspace goes into a new snapshot.
            return try writeSnapshot(savedAt: savedAt)
        }
        journalLength = try AtomicFile.append(data, to: journalFileURL, at: journalLength)
        markWritten()
        noteWrite(bytes: data.count)
        // At most one backup a day: a full file, encoded on the backup task from this value.
        backupWriter?.backUpIfDue(now: savedAt, .workspace(workspace))
    }

    /// Replaces `workspace.json` with the whole workspace under a new generation, then removes
    /// the journal. A crash between the two leaves entries of the old generation, which the next
    /// load skips (the new snapshot holds them).
    private func writeSnapshot(savedAt: Date) throws {
        let envelope = WorkspaceFileEnvelope(
            schemaVersion: WorkspaceFileEnvelope.currentSchemaVersion,
            savedAt: savedAt,
            generation: UUID(),
            workspace: PersistedWorkspace(workspace)
        )
        let data: Data
        do {
            data = try WorkspaceFileCodec.encode(envelope)
        } catch {
            throw PersistenceError.encodingFailed(String(describing: error))
        }
        try AtomicFile.write(data, to: workspaceFileURL)
        snapshotGeneration = envelope.generation
        snapshotBytes = data.count
        // Stale now whether or not removing it works: the next entry starts the file over.
        journalLength = 0
        try? AtomicFile.remove(journalFileURL)
        markWritten()
        snapshotWriteCount += 1
        noteWrite(bytes: data.count)
        // At most one backup a day, from the bytes just written (no second encode, no read back).
        backupWriter?.backUpIfDue(now: savedAt, .data(data))
    }

    /// The records whose disk form differs from what the files hold, in record name order.
    private func changesOnDisk() -> (saved: [SyncRecord], removed: [SyncRecordID]) {
        var saved: [SyncRecord] = []
        var removed: [SyncRecordID] = []
        for id in dirtyRecords.sorted(by: { $0.recordName < $1.recordName }) {
            let current = workspace.record(for: id)?.diskForm
            guard current != lastWrittenWorkspace?.record(for: id)?.diskForm else { continue }
            if let current { saved.append(current) } else { removed.append(id) }
        }
        return (saved, removed)
    }

    /// The journal's size on disk (0 when missing).
    private func journalOnDiskLength() -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: journalFileURL.path))?[.size] as? NSNumber
        return size?.uint64Value ?? 0
    }

    private func markWritten() {
        hasUnsavedChanges = false
        dirtyRecords.removeAll()
        lastWrittenWorkspace = workspace
    }

    private func noteWrite(bytes: Int) {
        writeCount += 1
        bytesWritten += bytes
        lastWriteBytes = bytes
        lastSaveError = nil
    }

    // MARK: - Loading

    /// What `load` read: the result, and where the files stand for the next write.
    struct LoadedFiles {
        var result: WorkspaceLoadResult
        /// The snapshot's generation (nil: none, or written before the journal existed).
        var generation: UUID?
        var snapshotBytes = 0
        /// End of the journal's last applied entry.
        var journalLength: UInt64 = 0
        /// Journal entries applied on top of the snapshot.
        var journalEntries = 0
    }

    /// Reads the snapshot and the journal entries that continue it (B153).
    static func load(directory: URL, now: Date) -> LoadedFiles {
        let snapshot = load(from: directory.appendingPathComponent(PersistenceDefaults.workspaceFileName), now: now)
        var loaded = LoadedFiles(result: snapshot.result, generation: snapshot.generation, snapshotBytes: snapshot.bytes)
        guard snapshot.result.outcome == .loaded, let generation = snapshot.generation,
              let journal = try? Data(contentsOf: directory.appendingPathComponent(PersistenceDefaults.workspaceJournalFileName))
        else { return loaded }
        let replay = WorkspaceJournal.replay(journal, onto: snapshot.result.workspace, generation: generation)
        loaded.result.workspace = replay.state
        loaded.journalLength = replay.appendOffset
        loaded.journalEntries = replay.appliedEntries
        return loaded
    }

    /// Reads the workspace file. A corrupt or unreadable file is moved aside as
    /// `workspace.corrupt-<timestamp>.json`; a file from a newer schema is left untouched.
    static func load(from url: URL, now: Date) -> (result: WorkspaceLoadResult, generation: UUID?, bytes: Int) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return (WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .noFile), nil, 0)
        }
        if let data = try? Data(contentsOf: url) {
            switch WorkspaceFileCodec.decode(data) {
            case .workspace(let state, let generation):
                return (WorkspaceLoadResult(workspace: state, outcome: .loaded), generation, data.count)
            case .newerSchema(let version):
                let error = PersistenceError.unsupportedSchemaVersion(
                    found: version,
                    supported: WorkspaceFileEnvelope.currentSchemaVersion
                )
                return (WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .refused(error)), nil, 0)
            case .corrupt:
                break
            }
        }
        do {
            let moved = try moveAside(url, now: now)
            return (WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .recoveredFromCorruptFile(movedTo: moved)), nil, 0)
        } catch let error as PersistenceError {
            // Could not keep the bad file safe, so never overwrite it.
            return (WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .refused(error)), nil, 0)
        } catch {
            return (WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .refused(.io(String(describing: error)))), nil, 0)
        }
    }

    static func moveAside(_ url: URL, now: Date) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = formatter.string(from: now)
        let directory = url.deletingLastPathComponent()
        let fileManager = FileManager.default
        var candidate = directory.appendingPathComponent("\(PersistenceDefaults.corruptFilePrefix)\(stamp).json")
        var suffix = 1
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(PersistenceDefaults.corruptFilePrefix)\(stamp)-\(suffix).json")
            suffix += 1
        }
        do {
            try fileManager.moveItem(at: url, to: candidate)
        } catch {
            throw PersistenceError.io("Cannot move corrupt workspace file aside: \(error)")
        }
        return candidate
    }
}

/// Pending submissions: the newest whole value (`put(_:)`) plus the record changes submitted after
/// it (`put(changesFrom:to:)`), in order. `take` empties the box; the store applies the whole value
/// first, then the changes. Putting is O(1) (two references kept, no copying or comparing), so the
/// submitting thread pays nothing for the size of the workspace.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class SubmissionInbox: @unchecked Sendable {
    struct Step {
        var old: WorkspaceState
        var new: WorkspaceState
    }

    private let lock = NSLock()
    private var latest: WorkspaceState?
    private var steps: [Step] = []

    /// A whole value: replaces everything still pending. Returns true when the box was empty, so
    /// the caller schedules one drain per batch instead of one per submission.
    func put(_ value: WorkspaceState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = latest == nil && steps.isEmpty
        latest = value
        steps.removeAll()
        return wasEmpty
    }

    /// The records that differ between `old` and `new`, applied after what is already pending.
    /// The diff itself is computed by the store, off the caller's thread. Returns true when the box
    /// was empty (see `put(_:)`).
    func put(changesFrom old: WorkspaceState, to new: WorkspaceState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let wasEmpty = latest == nil && steps.isEmpty
        steps.append(Step(old: old, new: new))
        return wasEmpty
    }

    /// Everything pending, in order, and an empty box.
    func take() -> (base: WorkspaceState?, steps: [Step]) {
        lock.lock()
        defer { lock.unlock() }
        let pending = (latest, steps)
        latest = nil
        steps.removeAll()
        return pending
    }
}
