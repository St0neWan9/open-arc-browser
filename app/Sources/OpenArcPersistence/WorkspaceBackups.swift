import Foundation
import OpenArcModel

// Rolling local backups of the workspace file (plan B117, decision Q18: Help ▸ Restore Data
// restores the sidebar from our own automatic local backup). The spec records only the menu item
// ([01 §Help] observed); everything here is our own design.
//
// Layout: `<data dir>/Backups/workspace-YYYYMMDD-HHMMSS.json` (UTC time of the backup), each a
// byte-for-byte copy of a `workspace.json` the store wrote, so it decodes with the same codec.
// At most one backup per `WorkspaceBackups.interval`; the newest `keepCount` are kept.

/// One backup file.
public struct WorkspaceBackup: Hashable, Sendable, Identifiable {
    public var url: URL
    /// When the backup was taken (from its file name, second resolution).
    public var createdAt: Date

    public var id: URL { url }

    public init(url: URL, createdAt: Date) {
        self.url = url
        self.createdAt = createdAt
    }
}

/// What a backup holds, for the Restore Data list.
public struct WorkspaceBackupSummary: Hashable, Sendable {
    /// Live Spaces.
    public var spaceCount: Int
    /// Live tabs in every place (favorites, pinned, Today).
    public var tabCount: Int

    public init(_ state: WorkspaceState) {
        spaceCount = state.spaces.values.filter { !$0.meta.isTombstone }.count
        tabCount = state.tabs.values.filter { !$0.meta.isTombstone }.count
    }
}

/// Backup file names, listing, loading and rotation.
public enum WorkspaceBackups {
    /// Folder inside the data directory. Persisted name; never rename.
    public static let directoryName = "Backups"
    /// File name prefix. Persisted; never change (listing recognizes backups by it).
    static let filePrefix = "workspace-"
    static let fileExtension = "json"
    /// How many backups are kept. Our own value (plan B117).
    public static let keepCount = 7
    /// Minimum time between two backups: at most one a day. Our own value (plan B117).
    public static let interval: TimeInterval = 24 * 3600

    /// `<dataDirectory>/Backups/`.
    public static func directory(in dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `workspace-YYYYMMDD-HHMMSS.json` for `date` (UTC, so the name never depends on the time zone).
    public static func fileName(for date: Date) -> String {
        "\(filePrefix)\(formatter().string(from: date)).\(fileExtension)"
    }

    /// The time encoded in a backup file name, or nil when the name is not one of ours.
    static func createdAt(fileName: String) -> Date? {
        let suffix = ".\(fileExtension)"
        guard fileName.hasPrefix(filePrefix), fileName.hasSuffix(suffix) else { return nil }
        let stamp = fileName.dropFirst(filePrefix.count).dropLast(suffix.count)
        return formatter().date(from: String(stamp))
    }

    /// Backups in `dataDirectory`, newest first. Files that are not ours are ignored.
    public static func list(in dataDirectory: URL) -> [WorkspaceBackup] {
        let folder = directory(in: dataDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .compactMap { name in
                createdAt(fileName: name).map { WorkspaceBackup(url: folder.appendingPathComponent(name), createdAt: $0) }
            }
            .sorted { ($0.createdAt, $0.url.lastPathComponent) > ($1.createdAt, $1.url.lastPathComponent) }
    }

    /// True when `dataDirectory` holds at least one backup.
    public static func hasBackups(in dataDirectory: URL) -> Bool {
        !list(in: dataDirectory).isEmpty
    }

    /// Reads a backup. Throws for an unreadable or corrupt file, and for one from a newer app version.
    public static func load(_ backup: WorkspaceBackup) throws -> WorkspaceState {
        let data: Data
        do {
            data = try Data(contentsOf: backup.url)
        } catch {
            throw PersistenceError.io("Cannot read \(backup.url.path): \(error)")
        }
        switch WorkspaceFileCodec.decode(data) {
        case .workspace(let state): return state
        case .newerSchema(let version):
            throw PersistenceError.unsupportedSchemaVersion(found: version, supported: WorkspaceFileEnvelope.currentSchemaVersion)
        case .corrupt:
            throw PersistenceError.io("Backup \(backup.url.lastPathComponent) is not a valid workspace file")
        }
    }

    /// Deletes all but the newest `keeping` backups.
    static func prune(in dataDirectory: URL, keeping: Int) {
        for old in list(in: dataDirectory).dropFirst(keeping) {
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'-'HHmmss"
        return formatter
    }
}

/// Writes the store's backups on a background task, one at a time and in order, so a backup
/// never delays a save: the store only checks a date under a lock and hands over bytes it already
/// has. A failed backup is forgotten, so the next save tries again.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class WorkspaceBackupWriter: @unchecked Sendable {
    /// What to back up.
    enum Source: Sendable {
        /// The bytes just written to the workspace file.
        case data(Data)
        /// The workspace file as it is on disk (the launch backup).
        case file(URL)
    }

    let dataDirectory: URL
    private let lock = NSLock()
    /// Time of the newest backup on disk or being written.
    private var newest: Date?
    /// The last backup job; each job waits for the one before it.
    private var tail: Task<Void, Never>?
    private var error: PersistenceError?

    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        newest = WorkspaceBackups.list(in: dataDirectory).first?.createdAt
    }

    /// The last failed backup, cleared by the next successful one.
    var lastError: PersistenceError? { lock.withLock { error } }

    /// True when a backup taken at `now` is due: none yet, or the newest is at least
    /// `WorkspaceBackups.interval` old. A backup dated after `now` (the clock was set back) does
    /// not hold off new backups.
    static func isDue(newest: Date?, now: Date) -> Bool {
        guard let newest else { return true }
        return newest > now || now.timeIntervalSince(newest) >= WorkspaceBackups.interval
    }

    /// Starts a backup of `source` at `now` when one is due. Returns whether one was started.
    @discardableResult
    func backUpIfDue(now: Date, _ source: @autoclosure () -> Source) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let before = newest
        guard Self.isDue(newest: before, now: now) else { return false }
        newest = now
        let source = source()
        let previous = tail
        tail = Task.detached(priority: .utility) { [self] in
            await previous?.value
            do {
                try Self.write(source, createdAt: now, dataDirectory: dataDirectory)
                lock.withLock { error = nil }
            } catch {
                lock.withLock {
                    if newest == now { newest = before }
                    self.error = (error as? PersistenceError) ?? .io(String(describing: error))
                }
            }
        }
        return true
    }

    /// Waits for every backup started so far.
    func waitUntilIdle() async {
        let last = lock.withLock { tail }
        await last?.value
    }

    private static func write(_ source: Source, createdAt: Date, dataDirectory: URL) throws {
        // Never create the data directory itself: without it there is nothing to back up (and a
        // test may just have removed it).
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dataDirectory.path, isDirectory: &isDirectory), isDirectory.boolValue else { return }
        let data: Data
        switch source {
        case .data(let bytes):
            data = bytes
        case .file(let url):
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw PersistenceError.io("Cannot read \(url.path): \(error)")
            }
        }
        let target = WorkspaceBackups.directory(in: dataDirectory).appendingPathComponent(WorkspaceBackups.fileName(for: createdAt))
        try AtomicFile.write(data, to: target)
        WorkspaceBackups.prune(in: dataDirectory, keeping: WorkspaceBackups.keepCount)
    }
}
