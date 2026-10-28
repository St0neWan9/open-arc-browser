import Foundation

/// Saved back/forward lists of the tabs that were live at the last quit (plan C20).
///
/// [03 §Advanced] inferred (analysis): with "When opening Arc, restore windows from previous
/// session" on, each restored tab keeps its back/forward history across relaunch, not only its
/// URL. The engine hands each tab's list over as opaque bytes (`TabSessionHistory`); this file
/// keeps them per device, next to the workspace file, keyed by the model tab id.
///
/// Never synced and never part of `WorkspaceState`: the lists hold page state (form contents,
/// scroll positions) and belong to this device's engine. A missing, damaged or newer file is
/// ignored: the tabs then load their URL alone, as before C20.
public struct TabHistorySnapshot: Hashable, Sendable {
    /// One tab's saved list.
    public struct Entry: Hashable, Sendable {
        /// The tab's URL in the workspace when the list was saved. A tab whose URL changed since
        /// (edited on another device, a build without C20 ran in between) drops its list.
        public var url: URL?
        /// The engine's bytes (`TabSessionHistory.data`).
        public var data: Data

        public init(url: URL?, data: Data) {
            self.url = url
            self.data = data
        }
    }

    /// Bump when the format changes incompatibly. A file with a newer version is ignored.
    public static let currentVersion = 1

    public var entries: [UUID: Entry]

    public init(entries: [UUID: Entry] = [:]) {
        self.entries = entries
    }
}

extension PersistenceDefaults {
    /// Saved back/forward lists (plan C20), next to the workspace file. Persisted name; never rename.
    public static let tabHistoryFileName = "tab-history.plist"
}

/// Reads and writes `tab-history.plist` (a binary property list). Written once per quit (and on
/// an explicit flush), so there is no debounce.
public enum TabHistoryFile {
    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(PersistenceDefaults.tabHistoryFileName)
    }

    /// The saved lists, or nil when the file is missing, unreadable or from a newer version.
    public static func load(from directory: URL) -> TabHistorySnapshot? {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let file = try? PropertyListDecoder().decode(FileFormat.self, from: data),
              file.version <= TabHistorySnapshot.currentVersion
        else { return nil }
        var entries: [UUID: TabHistorySnapshot.Entry] = [:]
        for tab in file.tabs {
            guard let id = UUID(uuidString: tab.id) else { continue }
            entries[id] = TabHistorySnapshot.Entry(url: tab.url.flatMap(URL.init(string:)), data: tab.history)
        }
        return TabHistorySnapshot(entries: entries)
    }

    /// Writes the lists atomically; an empty snapshot removes the file.
    public static func save(_ snapshot: TabHistorySnapshot, to directory: URL) throws {
        guard !snapshot.entries.isEmpty else {
            try remove(from: directory)
            return
        }
        let tabs = snapshot.entries
            .sorted { $0.key.uuidString < $1.key.uuidString }
            .map { FileFormat.Tab(id: $0.key.uuidString, url: $0.value.url?.absoluteString, history: $0.value.data) }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(FileFormat(version: TabHistorySnapshot.currentVersion, tabs: tabs))
        } catch {
            throw PersistenceError.encodingFailed(String(describing: error))
        }
        try AtomicFile.write(data, to: url(in: directory))
    }

    /// Removes the file (the setting is off, or nothing is left to keep).
    public static func remove(from directory: URL) throws {
        try AtomicFile.remove(url(in: directory))
    }

    /// On-disk layout. Persisted key names; never rename.
    private struct FileFormat: Codable {
        struct Tab: Codable {
            var id: String
            var url: String?
            var history: Data
        }
        var version: Int
        var tabs: [Tab]
    }
}
