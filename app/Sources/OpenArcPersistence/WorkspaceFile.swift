import Foundation
import OpenArcModel

/// Top-level JSON envelope of `workspace.json`, the workspace snapshot.
///
/// ```json
/// { "generation": "…", "savedAt": 0.0, "schemaVersion": 1, "workspace": { "profiles": [...], "tabs": [...], ... } }
/// ```
///
/// Records are stored as arrays (sorted by id for stable output) instead of the id-keyed
/// dictionaries of `WorkspaceState`; each record already carries its id. Tombstones are stored
/// like any other record until the sync layer purges them.
///
/// B153: the snapshot is compact JSON (no indentation), records keep only a marker in place of
/// the backend's system fields (`SystemFieldsOnDisk`), and changes made after the snapshot go to
/// the journal (`WorkspaceJournal`), which names the snapshot it continues by `generation`. All
/// three are additive, so the schema version stays 1: earlier builds read such a file as before
/// (they ignore the unknown `generation` key and the journal).
struct WorkspaceFileEnvelope: Codable, Sendable {
    /// Bump when the on-disk format changes incompatibly, and add a migration in `WorkspaceFileCodec`.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var savedAt: Date
    /// Identity of this snapshot; journal entries for it carry the same value (B153). nil in files
    /// written before the journal existed, or by an earlier build: no journal entry applies then.
    var generation: UUID?
    var workspace: PersistedWorkspace
}

/// The backend's system fields on disk (B153). The sync backend keeps them in its own state
/// (`sync-state.bin`), the one place it reads them from first, so the workspace files keep only a
/// marker: an empty value where a record has system fields, nothing where it has none.
///
/// The marker keeps "this record came back from the server" (`backendSystemFields != nil`) across
/// a relaunch, which first-launch Space adoption relies on. To a backend an empty value is "no
/// usable system fields": should its own copy be missing too, it saves the record as new and the
/// server answers with its copy, which merges under the unchanged conflict policy. A missing
/// value costs a round trip, never a different merge.
enum SystemFieldsOnDisk {
    static let marker = Data()

    /// `value` as the workspace files store it.
    static func diskForm<T: SyncableEntity>(_ value: T) -> T {
        guard let fields = value.meta.backendSystemFields, fields != marker else { return value }
        var copy = value
        copy.meta.backendSystemFields = marker
        return copy
    }
}

/// Just the version field, decoded first so a newer file is recognized even if the rest of it
/// does not decode.
struct WorkspaceFileHeader: Decodable {
    var schemaVersion: Int
}

/// The on-disk shape of a `WorkspaceState`.
struct PersistedWorkspace: Codable, Hashable, Sendable {
    var profiles: [Profile]
    var themes: [Theme]
    var spaces: [Space]
    var folders: [Folder]
    var tabs: [TabNode]
    var archive: [ArchiveItem]
    var splits: [SplitLayout]
    /// Added with Easels (B56). Files written before have no such keys and decode with none, so
    /// the schema version stays 1 (older builds ignore the unknown keys).
    var easels: [Easel]
    var easelElements: [EaselElement]

    private enum CodingKeys: String, CodingKey {
        case profiles, themes, spaces, folders, tabs, archive, splits, easels, easelElements
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try c.decode([Profile].self, forKey: .profiles)
        themes = try c.decode([Theme].self, forKey: .themes)
        spaces = try c.decode([Space].self, forKey: .spaces)
        folders = try c.decode([Folder].self, forKey: .folders)
        tabs = try c.decode([TabNode].self, forKey: .tabs)
        archive = try c.decode([ArchiveItem].self, forKey: .archive)
        splits = try c.decode([SplitLayout].self, forKey: .splits)
        easels = try c.decodeIfPresent([Easel].self, forKey: .easels) ?? []
        easelElements = try c.decodeIfPresent([EaselElement].self, forKey: .easelElements) ?? []
    }

    /// The disk form of `state`: system fields reduced to the marker (`SystemFieldsOnDisk`, B153).
    init(_ state: WorkspaceState) {
        func sorted<T: SyncableEntity>(_ values: Dictionary<UUID, T>.Values) -> [T] {
            values.sorted { $0.id.uuidString < $1.id.uuidString }.map(SystemFieldsOnDisk.diskForm)
        }
        profiles = sorted(state.profiles.values)
        themes = sorted(state.themes.values)
        spaces = sorted(state.spaces.values)
        folders = sorted(state.folders.values)
        tabs = sorted(state.tabs.values)
        archive = sorted(state.archive.values)
        splits = sorted(state.splits.values)
        easels = sorted(state.easels.values)
        easelElements = sorted(state.easelElements.values)
    }

    var state: WorkspaceState {
        func keyed<T: Identifiable>(_ values: [T]) -> [UUID: T] where T.ID == UUID {
            Dictionary(values.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        }
        return WorkspaceState(
            profiles: keyed(profiles),
            themes: keyed(themes),
            spaces: keyed(spaces),
            folders: keyed(folders),
            tabs: keyed(tabs),
            archive: keyed(archive),
            splits: keyed(splits),
            easels: keyed(easels),
            easelElements: keyed(easelElements)
        )
    }
}

/// Encoding and decoding of the workspace file.
enum WorkspaceFileCodec {
    /// Outcome of decoding file contents.
    enum Decoded {
        case workspace(WorkspaceState, generation: UUID?)
        /// The file is from a newer schema; it must not be overwritten.
        case newerSchema(Int)
        /// The contents are not a valid workspace file.
        case corrupt
    }

    static func encode(_ envelope: WorkspaceFileEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        // Compact (B153): indentation was about a tenth of a large file. Sorted keys keep the
        // output stable.
        encoder.outputFormatting = [.sortedKeys]
        // Default date strategy (seconds since the reference date as a Double) round-trips exactly,
        // which keeps field-group timestamps identical after a reload.
        return try encoder.encode(envelope)
    }

    static func decode(_ data: Data) -> Decoded {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(WorkspaceFileHeader.self, from: data) else { return .corrupt }
        if header.schemaVersion > WorkspaceFileEnvelope.currentSchemaVersion {
            return .newerSchema(header.schemaVersion)
        }
        // Version 1 is the first format; older versions do not exist. Migrations go here.
        guard header.schemaVersion == WorkspaceFileEnvelope.currentSchemaVersion,
              let envelope = try? decoder.decode(WorkspaceFileEnvelope.self, from: data)
        else { return .corrupt }
        return .workspace(envelope.workspace.state, generation: envelope.generation)
    }
}

/// Crash-safe file writes: write a temporary file in the same directory, flush it to disk, then
/// rename it over the destination. A reader sees either the old file or the new one, never a
/// partial write.
enum AtomicFile {
    static func write(_ data: Data, to url: URL, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw PersistenceError.io("Cannot create \(directory.path): \(error)")
        }
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(atPath: temp.path, contents: nil) else {
            throw PersistenceError.io("Cannot create \(temp.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: temp)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? fileManager.removeItem(at: temp)
            throw PersistenceError.io("Cannot write \(temp.path): \(error)")
        }
        // rename(2) replaces the destination atomically within one volume.
        if rename(temp.path, url.path) != 0 {
            let code = errno
            try? fileManager.removeItem(at: temp)
            throw PersistenceError.io("Cannot replace \(url.path): errno \(code)")
        }
    }

    /// Writes `data` at `offset` of `url` (created when missing), cutting the file at `offset`
    /// first so whatever an interrupted earlier write left there is replaced, then flushes it to
    /// disk. Returns the new length. For the journal (B153), where `offset` is the end of its last
    /// complete entry.
    static func append(_ data: Data, to url: URL, at offset: UInt64, fileManager: FileManager = .default) throws -> UInt64 {
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil) else {
                throw PersistenceError.io("Cannot create \(url.path)")
            }
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            throw PersistenceError.io("Cannot append to \(url.path): \(error)")
        }
        return offset + UInt64(data.count)
    }

    static func remove(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw PersistenceError.io("Cannot remove \(url.path): \(error)")
        }
    }
}
