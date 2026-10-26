import Foundation
import Combine
import OpenArcModel
import OpenArcEngine

// Library ▸ Downloads (plan C12). [06 §8] observed: a search field "Search Downloads…", a "Filter"
// button, and the empty state "Nothing here yet!" / "Come back after you’ve found some cool stuff
// to save." The spec records no filled list (the section was empty when observed), so the rows are
// our own: inferred. They follow the Archived Tabs rows (icon, title, gray detail line) and keep
// Chromium's behavior: progress while running, pause / resume / cancel, a "keep or discard" step for
// files Chromium flags as dangerous, open and reveal when done.

/// Downloads of one profile, live from the engine. Owned by `LibraryModel`.
@MainActor
public final class LibraryDownloads: ObservableObject {
    /// Newest first.
    @Published public private(set) var items: [DownloadItem] = []

    private let engine: any EngineDownloads
    private var profileID: UUID?
    private var observation: Task<Void, Never>?

    init(engine: any EngineDownloads) {
        self.engine = engine
    }

    /// Follows `profileID`'s downloads (the current space's profile). Idempotent.
    func observe(profileID: UUID?) {
        guard profileID != self.profileID else { return }
        self.profileID = profileID
        observation?.cancel()
        items = []
        guard let profileID else { return }
        let engine = self.engine
        observation = Task { [weak self] in
            // Subscribe first, then read the list, so nothing that happens in between is lost;
            // events for items already in the list are applied idempotently.
            let events = engine.events(profileID: profileID)
            let initial = await engine.items(profileID: profileID)
            guard let self, !Task.isCancelled else { return }
            self.items = initial
            for await event in events {
                guard !Task.isCancelled else { return }
                self.apply(event)
            }
        }
    }

    /// Items whose file name or source URL contains `query` (case-insensitive). Empty query: all.
    public func filtered(by query: String) -> [DownloadItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.filter {
            $0.suggestedFilename.localizedCaseInsensitiveContains(trimmed)
                || $0.sourceURL.absoluteString.localizedCaseInsensitiveContains(trimmed)
        }
    }

    func apply(_ event: DownloadEvent) {
        switch event {
        case .added(let item), .updated(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
                items.sort { $0.startDate > $1.startDate }
            }
        case .removed(let id):
            items.removeAll { $0.id == id }
        }
    }

    // MARK: Commands

    public func pause(_ id: String) { Task { await engine.pause(id) } }
    /// Also "retry" of an interrupted download (Chromium resumes it where it can).
    public func resume(_ id: String) { Task { await engine.resume(id) } }
    public func cancel(_ id: String) { Task { await engine.cancel(id) } }
    /// For `.needsConfirmation`: keep (true) or discard (false) the file.
    public func confirm(_ id: String, keep: Bool) { Task { await engine.confirm(id, keep: keep) } }
    /// Removes the entry from the list (the file stays on disk).
    public func remove(_ id: String) { Task { await engine.remove(id) } }
}

/// What a download row shows. No UI types, so it is unit-testable. inferred (see the file header).
public struct DownloadRowPresentation: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case pause, resume, cancel, keep, discard, reveal, retry, remove
    }

    public var title: String
    public var detail: String
    /// 0...1 while the size is known and the download runs; nil otherwise.
    public var progress: Double?
    /// The row's buttons, left to right.
    public var actions: [Action]

    public init(_ item: DownloadItem) {
        title = item.suggestedFilename.isEmpty ? (item.sourceURL.lastPathComponent.isEmpty ? "download" : item.sourceURL.lastPathComponent)
                                               : item.suggestedFilename
        let host = item.sourceURL.host ?? item.sourceURL.absoluteString
        let received = Self.bytes(item.receivedBytes)
        let total = item.totalBytes > 0 ? Self.bytes(item.totalBytes) : nil
        switch item.state {
        case .inProgress:
            detail = total.map { "\(received) of \($0) — \(host)" } ?? "\(received) — \(host)"
            progress = item.totalBytes > 0 ? min(1, Double(item.receivedBytes) / Double(item.totalBytes)) : nil
            actions = [.pause, .cancel]
        case .paused:
            detail = "Paused — " + (total.map { "\(received) of \($0)" } ?? received)
            progress = item.totalBytes > 0 ? min(1, Double(item.receivedBytes) / Double(item.totalBytes)) : nil
            actions = [.resume, .cancel]
        case .needsConfirmation:
            detail = item.warningText ?? "This file may be dangerous."
            progress = nil
            actions = [.discard, .keep]
        case .complete:
            detail = (total ?? received) + " — " + host
            progress = nil
            actions = [.reveal, .remove]
        case .cancelled:
            detail = "Cancelled — " + host
            progress = nil
            actions = [.remove]
        case .interrupted:
            detail = "Failed — " + host
            progress = nil
            actions = [.retry, .remove]
        }
    }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
