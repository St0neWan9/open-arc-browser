import Foundation
import Combine
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcEngine

// Library ▸ Downloads (plan C12). [06 §8] observed: a search field "Search Downloads…", a "Filter"
// button, and the empty state "Nothing here yet!" / "Come back after you’ve found some cool stuff
// to save." The spec records no filled list (the section was empty when observed), so the rows are
// our own: inferred. They follow the Archived Tabs rows (icon, title, gray detail line) and keep
// Chromium's behavior: progress while running, pause / resume / cancel, a "keep or discard" step for
// files Chromium flags as dangerous, open and reveal when done.

/// Downloads of one or more profiles, live from the engine. Owned by `LibraryModel`. Normally the
/// current space's profile; the Filter panel's Profiles chips (B94, [06 §8] observed) widen it to
/// the selected profiles.
@MainActor
public final class LibraryDownloads: ObservableObject {
    /// Newest first.
    @Published public private(set) var items: [DownloadItem] = []

    private let engine: any EngineDownloads
    /// Profiles followed, in the order given.
    private(set) var profileIDs: [UUID] = []
    private var observations: [Task<Void, Never>] = []

    init(engine: any EngineDownloads) {
        self.engine = engine
    }

    /// Follows `profileID`'s downloads (the current space's profile). Idempotent.
    func observe(profileID: UUID?) {
        observe(profileIDs: profileID.map { [$0] } ?? [])
    }

    /// Follows the downloads of every profile in `profileIDs`, merged newest first. Idempotent for
    /// the same set.
    func observe(profileIDs: [UUID]) {
        var seen = Set<UUID>()
        let ids = profileIDs.filter { seen.insert($0).inserted }
        guard Set(ids) != Set(self.profileIDs) else { return }
        self.profileIDs = ids
        observations.forEach { $0.cancel() }
        items = []
        let engine = self.engine
        observations = ids.map { profileID in
            Task { [weak self] in
                // Subscribe first, then read the list, so nothing that happens in between is lost;
                // events for items already in the list are applied idempotently.
                let events = engine.events(profileID: profileID)
                let initial = await engine.items(profileID: profileID)
                guard let self, !Task.isCancelled else { return }
                self.merge(initial)
                for await event in events {
                    guard !Task.isCancelled else { return }
                    self.apply(event)
                }
            }
        }
    }

    private func merge(_ list: [DownloadItem]) {
        for item in list { apply(.added(item)) }
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

/// One age group of the Library's Downloads list (B229).
public struct LibraryDownloadGroup: Equatable, Sendable {
    public var age: LibraryAge
    public var items: [DownloadItem]
}

/// The Library's Downloads list: rows grouped by age, a second line naming the file's kind and
/// where it came from. B229 observed (user's Arc screenshot, 2026-11-15): "2 weeks ago" groups,
/// "Disk Image from deepseek.com", "PDF from coursera.org", "Image from twimg.com", "PDF" without a
/// source, "Download from …" for other files.
public enum LibraryDownloadList {
    /// When a download counts: when it finished (else when it started); a running, paused or held
    /// one is now. inferred.
    static func date(of item: DownloadItem, now: Date) -> Date {
        switch item.state {
        case .inProgress, .paused, .needsConfirmation: return now
        default: return item.endDate ?? item.startDate
        }
    }

    /// `items` grouped by age, newest group first and newest first inside a group.
    public static func groups(_ items: [DownloadItem], now: Date, calendar: Calendar) -> [LibraryDownloadGroup] {
        let sorted = items.sorted { date(of: $0, now: now) > date(of: $1, now: now) }
        var buckets: [LibraryAge: [DownloadItem]] = [:]
        for item in sorted { buckets[LibraryAge.of(date(of: item, now: now), now: now, calendar: calendar), default: []].append(item) }
        return buckets.keys.sorted().map { LibraryDownloadGroup(age: $0, items: buckets[$0] ?? []) }
    }

    /// The kind a finished file is shown as. Disk Image, PDF and Image and the "Download" fallback
    /// are observed; Video, Audio and Archive are inferred.
    public static func kind(ofFileNamed name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "Download" }
        if type.conforms(to: .diskImage) { return "Disk Image" }
        if type.conforms(to: .pdf) { return "PDF" }
        if type.conforms(to: .image) { return "Image" }
        if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { return "Video" }
        if type.conforms(to: .audio) { return "Audio" }
        if type.conforms(to: .archive) { return "Archive" }
        return "Download"
    }

    /// The row's second line: "<kind> from <host>" for a finished file ("www." dropped; the kind
    /// alone without a web source); progress, size and state for the others as before.
    public static func detail(for item: DownloadItem) -> String {
        guard item.state == .complete else { return DownloadRowPresentation(item).detail }
        let title = DownloadRowPresentation(item).title
        let kind = kind(ofFileNamed: item.fileURL?.lastPathComponent ?? title)
        guard let scheme = item.sourceURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = item.sourceURL.host, !host.isEmpty else { return kind }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return "\(kind) from \(host)"
    }
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
