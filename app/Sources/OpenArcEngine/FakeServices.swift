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
    private var directories: [Profile.ID: URL] = [:]

    public init() {}

    /// Commands received, as "pause:<id>" etc. For tests.
    public var commands: [String] { lock.withLock { commandLog } }
    /// Live `events(profileID:)` streams of a profile. For tests.
    public func subscriberCount(profileID: Profile.ID) -> Int {
        lock.withLock { broadcasters[profileID]?.subscriberCount ?? 0 }
    }
    /// Download folders set through `setDefaultDirectory(_:profileID:)`. For tests.
    public var defaultDirectories: [Profile.ID: URL] { lock.withLock { directories } }

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

    public func setDefaultDirectory(_ url: URL, profileID: Profile.ID) async {
        lock.withLock { directories[profileID] = url }
    }

    /// nil until set: the caller falls back to the user's Downloads folder.
    public func defaultDirectory(profileID: Profile.ID) async -> URL? {
        lock.withLock { directories[profileID] }
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

/// Fake extensions: seeded with `simulateInstalled`; `install` and `loadUnpacked` add a placeholder
/// entry; `runAction` on an extension with a popup returns a `FakeExtensionPopup`.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeExtensions: EngineExtensions, @unchecked Sendable {
    private let lock = NSLock()
    private var installedByProfile: [Profile.ID: [EngineExtensionInfo]] = [:]
    private var tabProfiles: [EngineTabID: Profile.ID] = [:]
    private var actionLog: [String] = []
    private var broadcasters: [Profile.ID: AsyncBroadcaster<ExtensionEvent>] = [:]
    private var openPopup: FakeExtensionPopup?
    /// Keyboard commands per extension (plan C26): command name → shortcut text.
    private var commandsByExtension: [String: [String: String]] = [:]
    private var commandLog: [String] = []
    private let keyboardPopups = AsyncBroadcaster<ExtensionPopupOpenedFromKeyboard>()

    public init() {}

    /// "<extension id>@<tab id>" for every action run. For tests.
    public var actionsRun: [String] { lock.withLock { actionLog } }
    /// The popup `runAction` opened last, until it closes. For tests.
    public var popup: FakeExtensionPopup? { lock.withLock { openPopup.flatMap { $0.isClosed ? nil : $0 } } }

    private var actionMenus: [String: [PageContextMenuItem]] = [:]
    private var actionMenuLog: [String] = []

    /// The `contexts: ["action"]` items of an extension (plan B124).
    public func simulateActionMenuItems(_ items: [PageContextMenuItem], extensionID: String) {
        lock.withLock { actionMenus[extensionID] = items }
    }

    /// "<extension id>#<item id>@<tab id>" for every action menu item run. For tests.
    public var actionMenuItemsRun: [String] { lock.withLock { actionMenuLog } }

    public func actionMenuItems(extensionID: String, tabID: EngineTabID) async -> [PageContextMenuItem] {
        lock.withLock { actionMenus[extensionID] ?? [] }
    }

    public func performActionMenuItem(_ itemID: Int, extensionID: String, tabID: EngineTabID) async {
        lock.withLock { actionMenuLog.append("\(extensionID)#\(itemID)@\(tabID)") }
    }

    public func simulateInstalled(_ info: EngineExtensionInfo, profileID: Profile.ID) {
        let target: AsyncBroadcaster<ExtensionEvent> = lock.withLock {
            installedByProfile[profileID, default: []].append(info)
            return broadcaster(profileID)
        }
        target.yield(.changed)
    }

    /// An extension changed its action on a tab (`chrome.action.setBadgeText`…).
    public func simulateActionUpdate(_ info: EngineExtensionInfo, profileID: Profile.ID, tabID: EngineTabID?) {
        let target: AsyncBroadcaster<ExtensionEvent> = lock.withLock {
            if let index = installedByProfile[profileID]?.firstIndex(where: { $0.id == info.id }) {
                installedByProfile[profileID]?[index] = info
            }
            return broadcaster(profileID)
        }
        target.yield(.actionUpdated(extensionID: info.id, tabID: tabID))
    }

    // MARK: Keyboard commands and errors (plan C26)

    /// The extension declares `commands` (name → shortcut, e.g. "c26-run": "⇧⌘Y"; the name
    /// "_execute_action" runs its action).
    public func simulateCommands(_ commands: [String: String], extensionID: String) {
        lock.withLock { commandsByExtension[extensionID] = commands }
    }

    /// "<extension id>:<command>@<tab id>" for every named command sent. For tests.
    public var commandsSent: [String] { lock.withLock { commandLog } }

    /// The user pressed `shortcut` while `tabID` had the keyboard: like the Chromium engine, a
    /// named command goes to its extension with the tab, `_execute_action` runs the action (and a
    /// popup it opens comes out of `popupsOpenedFromKeyboard()`). Returns whether a command took
    /// the key.
    @discardableResult
    public func simulateShortcut(_ shortcut: String, tabID: EngineTabID) async -> Bool {
        let match: (extensionID: String, command: String)? = lock.withLock {
            guard let profile = tabProfiles[tabID] else { return nil }
            let enabled = Set((installedByProfile[profile] ?? []).filter(\.isEnabled).map(\.id))
            for (extensionID, commands) in commandsByExtension where enabled.contains(extensionID) {
                if let command = commands.first(where: { $0.value == shortcut })?.key {
                    return (extensionID, command)
                }
            }
            return nil
        }
        guard let match else { return false }
        if match.command == "_execute_action" {
            if let popup = await runAction(match.extensionID, on: tabID) {
                keyboardPopups.yield(ExtensionPopupOpenedFromKeyboard(popup: popup))
            }
        } else {
            lock.withLock { commandLog.append("\(match.extensionID):\(match.command)@\(tabID)") }
        }
        return true
    }

    /// The extension's error count changed (plan C26): it reports a runtime error, or its errors
    /// were cleared.
    public func simulateErrors(count: Int, extensionID: String, profileID: Profile.ID) {
        let target: AsyncBroadcaster<ExtensionEvent> = lock.withLock {
            if let index = installedByProfile[profileID]?.firstIndex(where: { $0.id == extensionID }) {
                installedByProfile[profileID]?[index].errorCount = count
            }
            return broadcaster(profileID)
        }
        target.yield(.errorsChanged(extensionID: extensionID))
    }

    public func popupsOpenedFromKeyboard() -> AsyncStream<ExtensionPopupOpenedFromKeyboard> {
        keyboardPopups.subscribe()
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

    @discardableResult
    public func runAction(_ extensionID: String, on tabID: EngineTabID) async -> (any ExtensionPopup)? {
        let (made, previous): (FakeExtensionPopup?, FakeExtensionPopup?) = lock.withLock {
            actionLog.append("\(extensionID)@\(tabID)")
            let previous = openPopup
            openPopup = nil
            guard let profile = tabProfiles[tabID],
                  let info = installedByProfile[profile]?.first(where: { $0.id == extensionID }),
                  info.isEnabled, info.hasPopup else { return (nil, previous) }
            let popup = FakeExtensionPopup(extensionID: extensionID, tabID: tabID)
            openPopup = popup
            return (popup, previous)
        }
        previous?.simulateClose()
        return made
    }

    public func install(webStoreID: String, profileID: Profile.ID) async throws {
        simulateInstalled(EngineExtensionInfo(id: webStoreID, name: webStoreID), profileID: profileID)
    }

    public func loadUnpacked(_ folder: URL, profileID: Profile.ID) async throws -> String {
        let id = folder.lastPathComponent
        simulateInstalled(EngineExtensionInfo(id: id, name: id, isUnpacked: true), profileID: profileID)
        return id
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

/// A fake extension popup: the test drives its page with `simulateLoad`, `simulateResize` and
/// `simulateClose` (the page calling `window.close()`); the host shows a placeholder.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeExtensionPopup: ExtensionPopup, @unchecked Sendable {
    public let extensionID: String
    public let tabID: EngineTabID
    private let lock = NSLock()
    private var history: [ExtensionPopupEvent] = []
    private var closed = false
    private var focusCount = 0
    private let broadcaster = AsyncBroadcaster<ExtensionPopupEvent>()

    init(extensionID: String, tabID: EngineTabID) {
        self.extensionID = extensionID
        self.tabID = tabID
    }

    public var isClosed: Bool { lock.withLock { closed } }
    /// Times the shell gave the page the keyboard.
    public var focusRequests: Int { lock.withLock { focusCount } }

    public func events() -> AsyncStream<ExtensionPopupEvent> {
        lock.withLock {
            let stream = broadcaster.subscribe(initial: history)
            return stream
        }
    }

    @MainActor public func attach(to host: any SurfaceHost) {
        host.show(.placeholder(SurfacePlaceholder(title: extensionID, url: nil)))
    }

    @MainActor public func focus() {
        lock.withLock { focusCount += 1 }
    }

    public func close() async { simulateClose() }

    public func simulateLoad() { record(.loaded) }
    public func simulateResize(width: Double, height: Double) { record(.resized(width: width, height: height)) }

    public func simulateClose() {
        let wasClosed: Bool = lock.withLock {
            defer { closed = true }
            if !closed {
                history.append(.closed)
                broadcaster.yield(.closed)
            }
            return closed
        }
        if !wasClosed { broadcaster.finish() }
    }

    private func record(_ event: ExtensionPopupEvent) {
        lock.withLock {
            guard !closed else { return }
            // A later size replaces the earlier one in what new subscribers see.
            if case .resized = event { history.removeAll { if case .resized = $0 { return true } else { return false } } }
            history.append(event)
            broadcaster.yield(event)
        }
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
    private let versionChanges = AsyncBroadcaster<String>()

    public init(rulesetVersion: String? = "fake-ruleset") {
        version = rulesetVersion
    }

    /// "global:on", "site:<host>:off" … in call order. For tests.
    public var changes: [String] { lock.withLock { changeLog } }

    /// Sets the version `rulesetVersion()` reports (nil: no ruleset). A new non-nil version is
    /// also delivered to `rulesetVersionChanges()`, like a live update (plan C19).
    public func simulateRuleset(_ rulesetVersion: String?) {
        let changed: Bool = lock.withLock {
            defer { version = rulesetVersion }
            return rulesetVersion != nil && rulesetVersion != version
        }
        if changed, let rulesetVersion { versionChanges.yield(rulesetVersion) }
    }

    public func rulesetVersionChanges() -> AsyncStream<String> {
        versionChanges.subscribe()
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

// MARK: - Translation (plan B47)

/// In-memory `EngineTranslation`: a short language list and a log of resets.
// @unchecked: `resets` is read and written only under `lock`.
public final class FakeTranslation: EngineTranslation, @unchecked Sendable {
    private let lock = NSLock()
    private var resets: [Profile.ID] = []

    public init() {}

    /// Profiles whose decisions were reset, in call order. For tests.
    public var resetProfileIDs: [Profile.ID] { lock.withLock { resets } }

    public func targetLanguages() async -> [TranslationLanguage] {
        ["de", "en", "es", "fr", "ja", "zh-CN"].map { TranslationLanguage(code: $0, name: FakeTab.languageName($0)) }
            .sorted { $0.name < $1.name }
    }

    public func resetDecisions(profileID: Profile.ID) async {
        lock.withLock { resets.append(profileID) }
    }
}
