import Foundation
import OpenArcModel

// In-memory downloads and extensions for FakeEngine (tests and UI development).

/// Fake downloads: items are added with `simulateDownload` (or `download`) and change state
/// instantly. Records every command.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeDownloads: EngineDownloads, @unchecked Sendable {
    private let lock = NSLock()
    private var all: [DownloadItem] = []
    private var broadcasters: [Profile.ID: AsyncBroadcaster<DownloadEvent>] = [:]
    private var commandLog: [String] = []
    private var directory: URL?

    public init() {}

    /// Commands received, as "pause:<id>" etc. For tests.
    public var commands: [String] { lock.withLock { commandLog } }
    /// Live `events(profileID:)` streams of a profile. For tests.
    public func subscriberCount(profileID: Profile.ID) -> Int {
        lock.withLock { broadcasters[profileID]?.subscriberCount ?? 0 }
    }
    public var defaultDirectory: URL? { lock.withLock { directory } }

    public func items(profileID: Profile.ID) async -> [DownloadItem] {
        lock.withLock { all.filter { $0.profileID == profileID }.sorted { $0.startDate > $1.startDate } }
    }

    public func events(profileID: Profile.ID) -> AsyncStream<DownloadEvent> {
        lock.withLock { broadcaster(profileID) }.subscribe()
    }

    public func pause(_ id: String) async { update(id, command: "pause") { $0.state = .paused } }
    public func resume(_ id: String) async { update(id, command: "resume") { $0.state = .inProgress } }
    public func cancel(_ id: String) async { update(id, command: "cancel") { $0.state = .cancelled } }

    public func confirm(_ id: String, keep: Bool) async {
        update(id, command: keep ? "keep" : "discard") { $0.state = keep ? .complete : .cancelled }
    }

    public func remove(_ id: String) async {
        let removed: (DownloadItem, AsyncBroadcaster<DownloadEvent>)? = lock.withLock {
            commandLog.append("remove:\(id)")
            guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
            let item = all.remove(at: index)
            return (item, broadcaster(item.profileID))
        }
        removed?.1.yield(.removed(id: id))
    }

    public func download(_ url: URL, profileID: Profile.ID) async {
        let item = DownloadItem(
            id: UUID().uuidString, profileID: profileID, sourceURL: url,
            suggestedFilename: url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent,
            startDate: Date(timeIntervalSince1970: 0)
        )
        simulateDownload(item)
    }

    public func setDefaultDirectory(_ url: URL) async {
        lock.withLock { directory = url }
    }

    /// Adds a download as if a page started it.
    public func simulateDownload(_ item: DownloadItem) {
        let target: AsyncBroadcaster<DownloadEvent> = lock.withLock {
            all.append(item)
            return broadcaster(item.profileID)
        }
        target.yield(.added(item))
    }

    private func update(_ id: String, command: String, _ change: (inout DownloadItem) -> Void) {
        let updated: (DownloadItem, AsyncBroadcaster<DownloadEvent>)? = lock.withLock {
            commandLog.append("\(command):\(id)")
            guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
            change(&all[index])
            return (all[index], broadcaster(all[index].profileID))
        }
        if let (item, target) = updated { target.yield(.updated(item)) }
    }

    /// Call under `lock`.
    private func broadcaster(_ profileID: Profile.ID) -> AsyncBroadcaster<DownloadEvent> {
        if let existing = broadcasters[profileID] { return existing }
        let made = AsyncBroadcaster<DownloadEvent>()
        broadcasters[profileID] = made
        return made
    }
}

/// Fake extensions: seeded with `simulateInstalled`; `install` adds a placeholder entry.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeExtensions: EngineExtensions, @unchecked Sendable {
    private let lock = NSLock()
    private var installedByProfile: [Profile.ID: [EngineExtensionInfo]] = [:]
    private var tabProfiles: [EngineTabID: Profile.ID] = [:]
    private var actionLog: [String] = []
    private var broadcasters: [Profile.ID: AsyncBroadcaster<ExtensionEvent>] = [:]

    public init() {}

    /// "<extension id>@<tab id>" for every action run. For tests.
    public var actionsRun: [String] { lock.withLock { actionLog } }

    public func simulateInstalled(_ info: EngineExtensionInfo, profileID: Profile.ID) {
        let target: AsyncBroadcaster<ExtensionEvent> = lock.withLock {
            installedByProfile[profileID, default: []].append(info)
            return broadcaster(profileID)
        }
        target.yield(.changed)
    }

    /// FakeEngine tells this object which profile a tab belongs to.
    func register(tab: EngineTabID, profileID: Profile.ID) {
        lock.withLock { tabProfiles[tab] = profileID }
    }

    public func installed(profileID: Profile.ID) async -> [EngineExtensionInfo] {
        lock.withLock { installedByProfile[profileID] ?? [] }
    }

    public func actions(for tabID: EngineTabID) async -> [EngineExtensionInfo] {
        lock.withLock {
            guard let profile = tabProfiles[tabID] else { return [] }
            return (installedByProfile[profile] ?? []).filter(\.isEnabled)
        }
    }

    public func runAction(_ extensionID: String, on tabID: EngineTabID) async {
        lock.withLock { actionLog.append("\(extensionID)@\(tabID)") }
    }

    public func install(webStoreID: String, profileID: Profile.ID) async throws {
        simulateInstalled(EngineExtensionInfo(id: webStoreID, name: webStoreID), profileID: profileID)
    }

    public func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async {
        let target: AsyncBroadcaster<ExtensionEvent> = lock.withLock {
            if let index = installedByProfile[profileID]?.firstIndex(where: { $0.id == extensionID }) {
                installedByProfile[profileID]?[index].isEnabled = enabled
            }
            return broadcaster(profileID)
        }
        target.yield(.changed)
    }

    public func uninstall(_ extensionID: String, profileID: Profile.ID) async {
        let target: AsyncBroadcaster<ExtensionEvent> = lock.withLock {
            installedByProfile[profileID]?.removeAll { $0.id == extensionID }
            return broadcaster(profileID)
        }
        target.yield(.changed)
    }

    public func events(profileID: Profile.ID) -> AsyncStream<ExtensionEvent> {
        lock.withLock { broadcaster(profileID) }.subscribe()
    }

    /// Call under `lock`.
    private func broadcaster(_ profileID: Profile.ID) -> AsyncBroadcaster<ExtensionEvent> {
        if let existing = broadcasters[profileID] { return existing }
        let made = AsyncBroadcaster<ExtensionEvent>()
        broadcasters[profileID] = made
        return made
    }
}

/// Fake ad blocker (plan C16): in-memory switches, a fixed ruleset version and blocked counts set
/// with `simulateBlocked`. Records every switch change.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeAdBlocking: EngineAdBlocking, @unchecked Sendable {
    private struct SiteKey: Hashable {
        var origin: SiteOrigin
        var profileID: Profile.ID
    }

    private let lock = NSLock()
    private var version: String?
    private var enabled = true
    private var allowList: Set<SiteKey> = []
    private var counts: [EngineTabID: Int] = [:]
    private var changeLog: [String] = []

    public init(rulesetVersion: String? = "fake-ruleset") {
        version = rulesetVersion
    }

    /// "global:on", "site:<host>:off" … in call order. For tests.
    public var changes: [String] { lock.withLock { changeLog } }

    /// Sets the version `rulesetVersion()` reports (nil: no ruleset).
    public func simulateRuleset(_ rulesetVersion: String?) {
        lock.withLock { version = rulesetVersion }
    }

    /// Sets a tab's blocked count as if its page loaded ads.
    public func simulateBlocked(_ count: Int, tabID: EngineTabID) {
        lock.withLock { counts[tabID] = count }
    }

    public func rulesetVersion() async -> String? { lock.withLock { version } }

    public func isEnabled() async -> Bool { lock.withLock { enabled } }

    public func setEnabled(_ enabled: Bool) async {
        lock.withLock {
            self.enabled = enabled
            changeLog.append("global:\(enabled ? "on" : "off")")
        }
    }

    public func isEnabled(forOrigin origin: SiteOrigin, profileID: Profile.ID) async -> Bool {
        lock.withLock { !allowList.contains(SiteKey(origin: origin, profileID: profileID)) }
    }

    public func setEnabled(_ enabled: Bool, forOrigin origin: SiteOrigin, profileID: Profile.ID) async {
        lock.withLock {
            let key = SiteKey(origin: origin, profileID: profileID)
            if enabled { allowList.remove(key) } else { allowList.insert(key) }
            changeLog.append("site:\(origin.displayHost):\(enabled ? "on" : "off")")
        }
    }

    public func blockedCount(tabID: EngineTabID) async -> Int {
        lock.withLock { counts[tabID] ?? 0 }
    }
}
