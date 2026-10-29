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
/// - File: `<directory>/workspace.json`, a `WorkspaceFileEnvelope` (schema version + workspace),
///   replaced atomically on every save.
/// - Load: synchronous, in `init`, so the app has its workspace before the first frame. Read the
///   result from `loadResult`.
/// - Autosave: the first unsaved change schedules a write `autosaveDelay` seconds later; further
///   changes within that window ride along, so a burst of edits costs one write. `flush()` writes
///   immediately (app termination).
/// - Remote changes (`apply`) are merged under `ConflictPolicy` and written immediately, because
///   the sync backend may persist its change token right after `apply` returns.
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

    // MARK: State

    /// The current workspace (what the next save writes).
    public private(set) var workspace: WorkspaceState
    /// True while the in-memory workspace has changes not yet on disk.
    public private(set) var hasUnsavedChanges = false
    /// Number of successful workspace file writes (diagnostics and tests).
    public private(set) var writeCount = 0
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
        let result = Self.load(
            from: directory.appendingPathComponent(PersistenceDefaults.workspaceFileName),
            now: now()
        )
        self.loadResult = result
        self.workspace = result.workspace
        if case .refused = result.outcome { isReadOnly = true } else { isReadOnly = false }
    }

    // MARK: - Local changes

    /// Replaces the workspace with a locally changed value and schedules an autosave.
    /// Emits a `.local` event with the records that changed.
    public func update(_ new: WorkspaceState) {
        guard new != workspace else { return }
        let changes = WorkspaceDiff.changes(from: workspace, to: new)
        workspace = new
        hasUnsavedChanges = true
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
        inbox.put(new)
        Task { await self.drainInbox() }
    }

    /// Hands the records that differ between two locally made values to the store, from any
    /// context without awaiting. Only those records are written: every other record keeps the
    /// store's copy. So a value built before a remote batch reached the caller cannot revert or
    /// purge what `apply` stored meanwhile. Submissions are applied in order.
    public nonisolated func submit(changesFrom old: WorkspaceState, to new: WorkspaceState) {
        guard old != new else { return }
        inbox.put(changesFrom: old, to: new)
        Task { await self.drainInbox() }
    }

    /// Writes unsaved changes now and cancels the pending autosave. Call on app termination.
    public func flush() throws {
        drainInbox()
        scheduledAutosave = nil
        guard hasUnsavedChanges else { return }
        try writeWorkspace()
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

        let wasUnsaved = hasUnsavedChanges
        workspace = next
        hasUnsavedChanges = true
        do {
            try writeWorkspace()
        } catch {
            workspace = old
            hasUnsavedChanges = wasUnsaved
            throw error
        }
        let changes = WorkspaceDiff.changes(from: old, to: next)
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
            try? AtomicFile.write(data, to: syncStateFileURL)
        } else {
            try? AtomicFile.remove(syncStateFileURL)
        }
    }

    // MARK: - Internals

    private func drainInbox() {
        guard let latest = inbox.take(applyingTo: workspace) else { return }
        update(latest)
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

    private func writeWorkspace() throws {
        guard !isReadOnly else { throw PersistenceError.readOnly }
        let envelope = WorkspaceFileEnvelope(
            schemaVersion: WorkspaceFileEnvelope.currentSchemaVersion,
            savedAt: now(),
            workspace: PersistedWorkspace(workspace)
        )
        let data: Data
        do {
            data = try WorkspaceFileCodec.encode(envelope)
        } catch {
            throw PersistenceError.encodingFailed(String(describing: error))
        }
        try AtomicFile.write(data, to: workspaceFileURL)
        hasUnsavedChanges = false
        writeCount += 1
        lastSaveError = nil
    }

    // MARK: - Loading

    /// Reads the workspace file. A corrupt or unreadable file is moved aside as
    /// `workspace.corrupt-<timestamp>.json`; a file from a newer schema is left untouched.
    static func load(from url: URL, now: Date) -> WorkspaceLoadResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .noFile)
        }
        if let data = try? Data(contentsOf: url) {
            switch WorkspaceFileCodec.decode(data) {
            case .workspace(let state):
                return WorkspaceLoadResult(workspace: state, outcome: .loaded)
            case .newerSchema(let version):
                let error = PersistenceError.unsupportedSchemaVersion(
                    found: version,
                    supported: WorkspaceFileEnvelope.currentSchemaVersion
                )
                return WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .refused(error))
            case .corrupt:
                break
            }
        }
        do {
            let moved = try moveAside(url, now: now)
            return WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .recoveredFromCorruptFile(movedTo: moved))
        } catch let error as PersistenceError {
            // Could not keep the bad file safe, so never overwrite it.
            return WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .refused(error))
        } catch {
            return WorkspaceLoadResult(workspace: WorkspaceState(), outcome: .refused(.io(String(describing: error))))
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
/// it (`put(changesFrom:to:)`), in order. `take` folds them onto the store's workspace and empties
/// the box.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
private final class SubmissionInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: WorkspaceState?
    private var changes: [(old: WorkspaceState, new: WorkspaceState)] = []

    /// A whole value: replaces everything still pending.
    func put(_ value: WorkspaceState) {
        lock.lock()
        latest = value
        changes.removeAll()
        lock.unlock()
    }

    /// The records that differ between `old` and `new`, applied after what is already pending.
    /// The diff itself is computed in `take`, off the caller's thread.
    func put(changesFrom old: WorkspaceState, to new: WorkspaceState) {
        lock.lock()
        changes.append((old, new))
        lock.unlock()
    }

    /// The pending value folded onto `current`, or nil when nothing is pending.
    func take(applyingTo current: WorkspaceState) -> WorkspaceState? {
        lock.lock()
        let base = latest
        let pending = changes
        latest = nil
        changes.removeAll()
        lock.unlock()
        guard base != nil || !pending.isEmpty else { return nil }
        var result = base ?? current
        for (old, new) in pending {
            let diff = WorkspaceDiff.changes(from: old, to: new)
            for id in diff.saved {
                if let record = new.record(for: id) { result.setRecord(record) }
            }
            for id in diff.removed { result.removeRecord(id) }
        }
        return result
    }
}
