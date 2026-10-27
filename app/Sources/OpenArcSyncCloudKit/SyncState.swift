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

    static func decode(_ data: Data?) -> PersistedSyncState {
        guard let data,
              let state = try? JSONDecoder().decode(PersistedSyncState.self, from: data),
              state.formatVersion == currentFormatVersion
        else { return PersistedSyncState() }
        return state
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}
