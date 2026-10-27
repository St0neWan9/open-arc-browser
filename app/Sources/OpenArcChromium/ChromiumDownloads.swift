import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `EngineDownloads` on top of `OACDownloads` (plan C12; chromium-bridge/include/OpenArcCore/
// OACDownloads.h): the profile's Chromium download manager with //chrome's delegate (history-backed
// list, dangerous-file checks). The Library's Downloads section lists these ([06 §8] observed).

/// Downloads of the Chromium engine, per on-disk profile.
final class ChromiumDownloads: EngineDownloads, @unchecked Sendable {
    // @unchecked: `core` is main-actor isolated and only touched through `MainActor` hops;
    // `observers` is read and written only on the main actor.
    private let core: ChromiumEngineCore
    @MainActor private var observers: [Profile.ID: DownloadsObserver] = [:]

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    func items(profileID: Profile.ID) async -> [DownloadItem] {
        await itemsOnMain(profileID)
    }

    @MainActor
    private func itemsOnMain(_ profileID: Profile.ID) async -> [DownloadItem] {
        guard let downloads = await core.downloads(profileID) else { return [] }
        return downloads.items.map { DownloadItem($0, profileID: profileID) }
    }

    func events(profileID: Profile.ID) -> AsyncStream<DownloadEvent> {
        let (stream, continuation) = AsyncStream<DownloadEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { @MainActor [weak self] in
            guard let self, let downloads = await self.core.downloads(profileID) else {
                continuation.finish()
                return
            }
            self.observer(for: profileID, downloads: downloads).add(continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func pause(_ id: String) async { await perform { $0.pauseItem(withIdentifier: id) } }
    func resume(_ id: String) async { await perform { $0.resumeItem(withIdentifier: id) } }
    func cancel(_ id: String) async { await perform { $0.cancelItem(withIdentifier: id) } }
    func confirm(_ id: String, keep: Bool) async { await perform { $0.confirmItem(withIdentifier: id, keep: keep) } }
    func remove(_ id: String) async { await perform { $0.removeItem(withIdentifier: id) } }

    func download(_ url: URL, profileID: Profile.ID) async {
        await downloadOnMain(url, profileID: profileID)
    }

    @MainActor
    private func downloadOnMain(_ url: URL, profileID: Profile.ID) async {
        await core.downloads(profileID)?.downloadURL(url)
    }

    /// Plan B83: Settings ▸ Profiles ▸ Download location. The bridge stores it in the profile's
    /// `download.default_directory` pref (`DownloadPrefs::SetDownloadPath`, patch 0017), so Chromium
    /// keeps it across launches; incognito downloads of the profile follow it. Loads the profile
    /// (and starts the engine) when needed.
    func setDefaultDirectory(_ url: URL, profileID: Profile.ID) async {
        await setDefaultDirectoryOnMain(url, profileID: profileID)
    }

    @MainActor
    private func setDefaultDirectoryOnMain(_ url: URL, profileID: Profile.ID) async {
        guard url.isFileURL, let downloads = await core.downloads(profileID), downloads.profile?.isValid == true else { return }
        downloads.defaultDirectory = url
    }

    func defaultDirectory(profileID: Profile.ID) async -> URL? {
        await defaultDirectoryOnMain(profileID)
    }

    @MainActor
    private func defaultDirectoryOnMain(_ profileID: Profile.ID) async -> URL? {
        // The getter returns nil once the profile is gone, although the header says nonnull: read
        // it only from a valid profile.
        guard let downloads = await core.downloads(profileID), downloads.profile?.isValid == true else { return nil }
        return downloads.defaultDirectory
    }

    // MARK: Internals

    /// Item commands go to every loaded profile: ids (Chromium GUIDs) are unique, and the profile
    /// that does not know the id ignores it.
    private func perform(_ body: @escaping @MainActor (OACDownloads) -> Void) async {
        await MainActor.run {
            for downloads in self.loadedDownloads() { body(downloads) }
        }
    }

    @MainActor
    private func loadedDownloads() -> [OACDownloads] {
        guard OACApplication.shared.state == .running else { return [] }
        return OACApplication.shared.loadedProfiles.filter(\.isValid).map(\.downloads)
    }

    @MainActor
    private func observer(for profileID: Profile.ID, downloads: OACDownloads) -> DownloadsObserver {
        if let existing = observers[profileID] { return existing }
        let made = DownloadsObserver(profileID: profileID)
        downloads.add(made)
        observers[profileID] = made
        return made
    }
}

/// Fans one profile's `OACDownloadsObserver` callbacks out to the engine's streams.
@MainActor
private final class DownloadsObserver: NSObject, OACDownloadsObserver {
    let profileID: Profile.ID
    private var continuations: [UUID: AsyncStream<DownloadEvent>.Continuation] = [:]

    init(profileID: Profile.ID) {
        self.profileID = profileID
    }

    func add(_ continuation: AsyncStream<DownloadEvent>.Continuation) {
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
    }

    private func send(_ event: DownloadEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func downloads(_ downloads: OACDownloads, didAdd item: OACDownloadItem) {
        send(.added(DownloadItem(item, profileID: profileID)))
    }

    func downloads(_ downloads: OACDownloads, didUpdate item: OACDownloadItem) {
        send(.updated(DownloadItem(item, profileID: profileID)))
    }

    func downloads(_ downloads: OACDownloads, didRemoveItemWithIdentifier identifier: String) {
        send(.removed(id: identifier))
    }
}

extension DownloadItem {
    init(_ item: OACDownloadItem, profileID: Profile.ID) {
        self.init(
            id: item.identifier,
            profileID: profileID,
            sourceURL: item.sourceURL,
            referrerURL: item.referrerURL,
            fileURL: item.fileURL,
            suggestedFilename: item.suggestedFilename,
            mimeType: item.mimeType,
            state: DownloadState(item.state),
            receivedBytes: item.receivedBytes,
            totalBytes: item.totalBytes,
            startDate: item.startDate,
            endDate: item.endDate,
            isOffTheRecord: item.isOffTheRecord,
            warningText: item.warningText
        )
    }
}

extension DownloadState {
    init(_ state: OACDownloadState) {
        switch state {
        case .paused: self = .paused
        case .complete: self = .complete
        case .cancelled: self = .cancelled
        case .interrupted: self = .interrupted
        case .needsConfirmation: self = .needsConfirmation
        default: self = .inProgress
        }
    }
}
