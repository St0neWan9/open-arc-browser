import Foundation
import OpenArcModel

/// Top-level JSON envelope of `workspace.json`.
///
/// ```json
/// { "schemaVersion": 1, "savedAt": 0.0, "workspace": { "profiles": [...], "tabs": [...], ... } }
/// ```
///
/// Records are stored as arrays (sorted by id for stable output) instead of the id-keyed
/// dictionaries of `WorkspaceState`; each record already carries its id. Tombstones are stored
/// like any other record until the sync layer purges them.
struct WorkspaceFileEnvelope: Codable, Sendable {
    /// Bump when the on-disk format changes incompatibly, and add a migration in `WorkspaceFileCodec`.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var savedAt: Date
    var workspace: PersistedWorkspace
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

    init(_ state: WorkspaceState) {
        func sorted<T: Identifiable>(_ values: Dictionary<UUID, T>.Values) -> [T] where T.ID == UUID {
            values.sorted { $0.id.uuidString < $1.id.uuidString }
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
        case workspace(WorkspaceState)
        /// The file is from a newer schema; it must not be overwritten.
        case newerSchema(Int)
        /// The contents are not a valid workspace file.
        case corrupt
    }

    static func encode(_ envelope: WorkspaceFileEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
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
        return .workspace(envelope.workspace.state)
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

    static func remove(_ url: URL, fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw PersistenceError.io("Cannot remove \(url.path): \(error)")
        }
    }
}
