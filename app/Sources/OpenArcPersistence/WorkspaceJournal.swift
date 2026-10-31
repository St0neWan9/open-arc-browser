import Foundation
import OpenArcModel
import OpenArcSyncAPI

// The workspace change journal (B153).
//
// `workspace.json` is a snapshot; the records changed after it are appended to
// `workspace.journal` instead of rewriting the snapshot on every save. A typical edit (rename,
// move, open or close a tab) costs one entry of a few KB instead of the whole file (MBs for a
// few thousand records).
//
// Format: JSON Lines. Each line is one `WorkspaceJournalEntry` as compact JSON followed by "\n"
// (`JSONEncoder` escapes newlines inside strings, so a line never contains one). An entry holds
// the full current copy of every record it changes, so applying it is a plain overwrite: replaying
// an entry twice gives the same result.
//
// Crash safety:
// - An entry counts only when its line is complete (ends with "\n") and decodes. A write cut
//   short by a crash leaves a torn last line, which replay ignores; the next append starts at the
//   end of the last complete entry and cuts the torn bytes off (`AtomicFile.append`).
// - Every entry names the snapshot it continues (`generation`). Compaction writes a new snapshot
//   with a new generation (atomic rename), then removes the journal. A crash between the two
//   leaves entries of the old generation, which replay skips: the new snapshot already holds them.
// - A snapshot without a generation (written by an earlier build, or by an earlier build after a
//   downgrade) takes no entries: the store's first write after loading it is a snapshot.

/// One journal line.
struct WorkspaceJournalEntry: Codable, Sendable {
    /// The `WorkspaceFileEnvelope.generation` of the snapshot this entry continues.
    var generation: UUID
    var savedAt: Date
    /// Records created or changed, in their disk form (`SystemFieldsOnDisk`).
    var records: PersistedWorkspace
    /// Records purged.
    var removed: [SyncRecordID]
}

enum WorkspaceJournal {
    /// The result of reading a journal.
    struct Replay {
        /// The snapshot with every applicable entry applied.
        var state: WorkspaceState
        /// Entries of the snapshot's generation that were applied.
        var appliedEntries: Int
        /// Where the next entry goes: the end of the last applied entry, or 0 when none applied
        /// (whatever the file holds then is stale or torn, and the next append cuts it off).
        var appendOffset: UInt64
    }

    /// One line: the entry as compact JSON and a newline.
    static func encode(_ entry: WorkspaceJournalEntry) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        return data
    }

    /// Applies the entries of `data` that continue `generation` to `snapshot`, in file order.
    /// Reading stops at the first line that is incomplete or does not decode.
    static func replay(_ data: Data, onto snapshot: WorkspaceState, generation: UUID) -> Replay {
        var result = Replay(state: snapshot, appliedEntries: 0, appendOffset: 0)
        let decoder = JSONDecoder()
        let bytes = [UInt8](data)
        var start = 0
        while start < bytes.count, let newline = bytes[start...].firstIndex(of: 0x0A) {
            let line = Data(bytes[start..<newline])
            guard let entry = try? decoder.decode(WorkspaceJournalEntry.self, from: line) else { break }
            start = newline + 1
            guard entry.generation == generation else { continue }
            apply(entry, to: &result.state)
            result.appliedEntries += 1
            result.appendOffset = UInt64(start)
        }
        return result
    }

    static func apply(_ entry: WorkspaceJournalEntry, to state: inout WorkspaceState) {
        let records = entry.records.state
        for id in records.allRecordIDs {
            if let record = records.record(for: id) { state.setRecord(record) }
        }
        for id in entry.removed { state.removeRecord(id) }
    }

    /// The journal size at which the next save writes a snapshot instead (compaction): the
    /// snapshot's own size, kept between `minimumCompactionBytes` and `maximumCompactionBytes`.
    /// Tying it to the snapshot bounds the write amplification of compaction to about 2x the
    /// journal's bytes, and the launch replay to about one more snapshot's worth of reading.
    /// Our own values (not from the spec).
    static func compactionLimit(snapshotBytes: Int) -> UInt64 {
        UInt64(min(maximumCompactionBytes, max(minimumCompactionBytes, snapshotBytes)))
    }

    static let minimumCompactionBytes = 256 * 1024
    static let maximumCompactionBytes = 8 * 1024 * 1024
}

extension SyncRecord {
    /// The record as the workspace files store it (`SystemFieldsOnDisk`).
    var diskForm: SyncRecord {
        guard let fields = meta.backendSystemFields, fields != SystemFieldsOnDisk.marker else { return self }
        return withBackendSystemFields(SystemFieldsOnDisk.marker)
    }
}

extension WorkspaceState {
    /// The workspace as loading it back from the files gives it (`SystemFieldsOnDisk`).
    var diskForm: WorkspaceState { PersistedWorkspace(self).state }
}
