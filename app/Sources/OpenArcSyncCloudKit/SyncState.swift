import Foundation
import OpenArcModel
import OpenArcSyncAPI

// MARK: - Storage

/// Where the CloudKit store persists its state between launches (engine state with the server
/// change tokens, the pending queue, cached system fields). Injectable for tests.
public protocol SyncStateStorage: Sendable {
    func loadState() async throws -> Data?
    /// Saves the state; nil removes it.
    func saveState(_ data: Data?) async throws
}

/// Stores the state in one file, written atomically.
public struct FileSyncStateStorage: SyncStateStorage {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func loadState() async throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try Data(contentsOf: fileURL)
    }

    public func saveState(_ data: Data?) async throws {
        guard let data else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Default storage: the app's own persistence, through `SyncLocalDatabase.loadSyncState`.
struct LocalDatabaseSyncStateStorage: SyncStateStorage {
    let database: any SyncLocalDatabase

    func loadState() async throws -> Data? { await database.loadSyncState() }
    func saveState(_ data: Data?) async throws { await database.saveSyncState(data) }
}

// MARK: - Pending queue

/// Local changes not yet confirmed by the server, in enqueue order. One entry per record; a later
/// change to the same record replaces the earlier one and bumps its generation, so a confirmation
/// for an older send does not drop a newer edit.
struct PendingQueue: Codable, Hashable, Sendable {
    enum Operation: String, Codable, Hashable, Sendable {
        case save
        case delete
    }

    struct Entry: Codable, Hashable, Sendable {
        var id: SyncRecordID
        var operation: Operation
        var generation: UInt64
    }

    private(set) var entries: [Entry] = []
    private var nextGeneration: UInt64 = 1

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty }

    func entry(for id: SyncRecordID) -> Entry? {
        entries.first { $0.id == id }
    }

    @discardableResult
    mutating func add(_ id: SyncRecordID, _ operation: Operation) -> Entry {
        let entry = Entry(id: id, operation: operation, generation: nextGeneration)
        nextGeneration += 1
        if let index = entries.firstIndex(where: { $0.id == id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        return entry
    }

    /// Removes the entry if its generation still matches (nil matches any). Returns true if removed.
    @discardableResult
    mutating func remove(_ id: SyncRecordID, ifGeneration generation: UInt64? = nil) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        if let generation, entries[index].generation != generation { return false }
        entries.remove(at: index)
        return true
    }

    mutating func removeAll() {
        entries.removeAll()
    }
}

// MARK: - Persisted state

/// Everything the CloudKit store persists. Encoded as JSON through `SyncStateStorage`.
struct PersistedSyncState: Codable, Hashable, Sendable {
    static let currentFormatVersion = 1

    var formatVersion = PersistedSyncState.currentFormatVersion
    /// `CKSyncEngine.State.Serialization`, JSON-encoded by the driver. Holds the server change tokens.
    var engineState: Data?
    var pending = PendingQueue()
    /// Record name → archived CloudKit system fields of the last server copy we saw.
    /// Kept here rather than written back through `SyncLocalDatabase.apply`, which would race
    /// with concurrent app edits. Empty data means "the server forgot this record; save as new".
    var systemFields: [String: Data] = [:]
    /// True once the custom zone was saved.
    var zoneSaved = false
    var lastSyncedAt: Date?
    /// Set when the iCloud account switched; sync stays paused until `resetLocalSyncState()`.
    var awaitingAccountReset = false
    /// Server copies whose local apply failed; merged and applied again before the next fetch.
    var deferredUpserts: [SyncRecord] = []
    var deferredDeletions: [SyncRecordID] = []
    /// Archived `CKServerChangeToken` of the store's own zone poll (`SyncEngineDriver.pollZoneChanges`),
    /// separate from the engine's tokens. nil: the next poll reads the whole zone. Optional, so a
    /// state saved before it existed still decodes. (B86)
    var zonePollToken: Data?
    /// Record name → sync schema version (`MetaFields.schemaVersion`) of its last seen server
    /// copy, kept only for copies newer than the build that saw them. A build reads such records
    /// but never saves or deletes them while the version is above its own
    /// `RecordSchema.currentVersion` (D11); after an app update the same entries no longer hold.
    /// Optional, so a state saved before it existed still decodes.
    var newerRecordVersions: [String: Int64]?
    /// Set by "Delete iCloud Data…" (D12) until the zone is saved again: a zone deletion the
    /// engine reports meanwhile is our own, not another device's, and must not drop the full
    /// upload queued when sync is turned back on. Optional, so older states still decode.
    var deletedOwnZone: Bool?

    /// `newerRecordVersions`, empty when unset.
    var newerRecords: [String: Int64] {
        get { newerRecordVersions ?? [:] }
        set { newerRecordVersions = newValue.isEmpty ? nil : newValue }
    }

    /// Reads either container: the compressed one (`encoded()`, B151) or the plain JSON written
    /// by builds before it. Anything unreadable, or of another format version, is a fresh state.
    static func decode(_ data: Data?) -> PersistedSyncState {
        guard let data, let json = SyncStateContainer.json(from: data),
              let state = try? JSONDecoder().decode(PersistedSyncState.self, from: json),
              state.formatVersion == currentFormatVersion
        else { return PersistedSyncState() }
        return state
    }

    /// The bytes to store: the JSON, compressed (`SyncStateContainer`). The engine's own
    /// serialization travels inside unchanged; compression is lossless.
    func encoded() -> Data? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        return SyncStateContainer.wrap(json)
    }

    /// True when the difference from `saved` (what is on disk) must reach disk soon (B151): a
    /// local change queued for upload, server changes waiting to be applied again, or a flag that
    /// changes what the store does next. Losing any of these in a crash loses data or misleads the
    /// next launch.
    ///
    /// Everything else is a cache the server can rebuild, and is written lazily: the engine's
    /// serialization and our zone poll token (a stale token only fetches again, and applying the
    /// same server copy twice changes nothing), the cached system fields (a stale change tag ends
    /// in `serverRecordChanged`, which merges), confirmations that shrink the queue (a change sent
    /// twice merges to nothing) and `lastSyncedAt`.
    func needsPromptSave(comparedTo saved: PersistedSyncState) -> Bool {
        if formatVersion != saved.formatVersion
            || awaitingAccountReset != saved.awaitingAccountReset
            || zoneSaved != saved.zoneSaved
            || deletedOwnZone != saved.deletedOwnZone
            || newerRecordVersions != saved.newerRecordVersions
            || deferredUpserts != saved.deferredUpserts
            || deferredDeletions != saved.deferredDeletions {
            return true
        }
        guard !pending.isEmpty else { return false }
        // A record whose change is already on disk with the same operation is covered, whatever
        // its generation: generations only guard confirmations of sends in flight, and after a
        // relaunch nothing is in flight. So repeated edits of one record cost one prompt write.
        let savedChanges = Set(saved.pending.entries.map { PendingChangeKey(id: $0.id, operation: $0.operation) })
        return pending.entries.contains { !savedChanges.contains(PendingChangeKey(id: $0.id, operation: $0.operation)) }
    }

    private struct PendingChangeKey: Hashable {
        var id: SyncRecordID
        var operation: PendingQueue.Operation
    }

    /// True when `lastSyncedAt` is the only difference from `saved`. Such a change waits for the
    /// next write that has another reason (or for `flushState` / `stop`): it only feeds the
    /// "Last synced" line, and every confirmed sync moves it.
    func differsOnlyInLastSyncedAt(from saved: PersistedSyncState) -> Bool {
        guard lastSyncedAt != saved.lastSyncedAt else { return false }
        var probe = self
        probe.lastSyncedAt = saved.lastSyncedAt
        return probe == saved
    }
}

// MARK: - Container

/// The bytes of `sync-state.bin` (B151): a 4-byte tag, a container version byte, then the
/// `PersistedSyncState` JSON compressed with LZFSE.
///
/// Most of the state is the archived CloudKit system fields of every record (about 1.6 KB each,
/// base64 in the JSON, so several MB for a few thousand records). Those archives repeat the same
/// class names, zone and owner, and compress about 30:1, so every write of the state is a small
/// fraction of the plain JSON. Plain JSON (what earlier builds wrote) is still read. An earlier
/// build reading this container sees an unreadable state and starts sync from scratch.
enum SyncStateContainer {
    /// "OASS": Open Arc sync state.
    static let tag = Data([0x4F, 0x41, 0x53, 0x53])
    static let version: UInt8 = 1
    private static var headerLength: Int { tag.count + 1 }

    static func wrap(_ json: Data) -> Data? {
        guard let compressed = try? (json as NSData).compressed(using: .lzfse) else { return nil }
        var data = tag
        data.append(version)
        data.append(compressed as Data)
        return data
    }

    /// The JSON inside `data`: decompressed from the container, or `data` itself when it is the
    /// plain JSON of an earlier build. nil for a container this build cannot read.
    static func json(from data: Data) -> Data? {
        guard data.starts(with: tag) else { return data }
        guard data.count > headerLength, data[data.startIndex + tag.count] == version else { return nil }
        let body = data.subdata(in: (data.startIndex + headerLength)..<data.endIndex)
        return try? (body as NSData).decompressed(using: .lzfse) as Data
    }
}
