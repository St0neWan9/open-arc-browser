import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `EngineExtensions` on top of `OACExtensions` (plan C14; chromium-bridge/include/OpenArcCore/
// OACExtensions.h): //chrome's extension system per on-disk profile (an off-the-record tab uses its
// profile's extensions). Action state goes to the Site Control Center; a popup's page is a native
// view the shell hosts in its own bubble (`ChromiumExtensionPopup`); install confirmations become
// `.extensionInstall` dialog requests on the tab that asked (the Web Store page).

final class ChromiumExtensions: EngineExtensions, @unchecked Sendable {
    // @unchecked: `core` is main-actor isolated and only touched through `MainActor` hops;
    // `observers` is read and written only on the main actor.
    private let core: ChromiumEngineCore
    @MainActor private var observers: [Profile.ID: ExtensionsObserver] = [:]

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    func installed(profileID: Profile.ID) async -> [EngineExtensionInfo] {
        await installedOnMain(profileID)
    }

    @MainActor
    private func installedOnMain(_ profileID: Profile.ID) async -> [EngineExtensionInfo] {
        guard let extensions = await extensions(profileID) else { return [] }
        return extensions.installedExtensions.map(EngineExtensionInfo.init)
    }

    func actions(for tabID: EngineTabID) async -> [EngineExtensionInfo] {
        await actionsOnMain(tabID)
    }

    @MainActor
    private func actionsOnMain(_ tabID: EngineTabID) async -> [EngineExtensionInfo] {
        guard let wrapper = core.tabs[tabID], let tab = wrapper.core.tab,
              let extensions = await extensions(wrapper.profileID) else { return [] }
        return extensions.actions(for: tab).map(EngineExtensionInfo.init)
    }

    @discardableResult
    func runAction(_ extensionID: String, on tabID: EngineTabID) async -> (any ExtensionPopup)? {
        await runActionOnMain(extensionID, tabID: tabID)
    }

    @MainActor
    private func runActionOnMain(_ extensionID: String, tabID: EngineTabID) async -> (any ExtensionPopup)? {
        guard let wrapper = core.tabs[tabID], let tab = wrapper.core.tab,
              let extensions = await extensions(wrapper.profileID),
              let popup = extensions.runAction(ofExtension: extensionID, on: tab) else { return nil }
        return ChromiumExtensionPopup(popup: popup, tabID: tabID)
    }

    func install(webStoreID: String, profileID: Profile.ID) async throws {
        try await installOnMain(webStoreID, profileID: profileID)
    }

    @MainActor
    private func installOnMain(_ webStoreID: String, profileID: Profile.ID) async throws {
        guard let extensions = await extensions(profileID) else { throw EngineError.profileUnavailable }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            extensions.installFromWebStore(withIdentifier: webStoreID) { error in
                if let error { continuation.resume(throwing: EngineError.engineFailure(error.localizedDescription)) }
                else { continuation.resume() }
            }
        }
    }

    func loadUnpacked(_ folder: URL, profileID: Profile.ID) async throws -> String {
        try await loadUnpackedOnMain(folder, profileID: profileID)
    }

    @MainActor
    private func loadUnpackedOnMain(_ folder: URL, profileID: Profile.ID) async throws -> String {
        guard let extensions = await extensions(profileID) else { throw EngineError.profileUnavailable }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            extensions.loadUnpacked(from: folder) { identifier, error in
                if let identifier {
                    continuation.resume(returning: identifier)
                } else {
                    continuation.resume(throwing: EngineError.engineFailure(error?.localizedDescription ?? "The extension did not load."))
                }
            }
        }
    }

    func setEnabled(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async {
        await setEnabledOnMain(enabled, extensionID: extensionID, profileID: profileID)
    }

    @MainActor
    private func setEnabledOnMain(_ enabled: Bool, extensionID: String, profileID: Profile.ID) async {
        await extensions(profileID)?.setEnabled(enabled, forExtension: extensionID)
    }

    func uninstall(_ extensionID: String, profileID: Profile.ID) async {
        await uninstallOnMain(extensionID, profileID: profileID)
    }

    @MainActor
    private func uninstallOnMain(_ extensionID: String, profileID: Profile.ID) async {
        await extensions(profileID)?.uninstallExtension(extensionID)
    }

    func events(profileID: Profile.ID) -> AsyncStream<ExtensionEvent> {
        let (stream, continuation) = AsyncStream<ExtensionEvent>.makeStream(bufferingPolicy: .unbounded)
        let task = Task { @MainActor [weak self] in
            guard let self, let extensions = await self.extensions(profileID) else {
                continuation.finish()
                return
            }
            self.observer(for: profileID, extensions: extensions).add(continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: Internals

    /// The profile's extensions, with this object's observer attached (it also routes install
    /// confirmations), so confirmations work before anyone subscribed to events.
    @MainActor
    private func extensions(_ profileID: Profile.ID) async -> OACExtensions? {
        guard let extensions = await core.extensions(profileID) else { return nil }
        _ = observer(for: profileID, extensions: extensions)
        return extensions
    }

    @MainActor
    private func observer(for profileID: Profile.ID, extensions: OACExtensions) -> ExtensionsObserver {
        if let existing = observers[profileID], extensions.delegate === existing { return existing }
        let made = ExtensionsObserver(core: core)
        extensions.delegate = made
        observers[profileID] = made
        return made
    }

    /// Attaches the observer to every profile as soon as it is loaded, so a Web Store install from a
    /// page reaches the shell even when nothing asked for the profile's extensions yet.
    @MainActor
    func attach(to profileID: Profile.ID, extensions: OACExtensions) {
        _ = observer(for: profileID, extensions: extensions)
    }
}

/// One profile's `OACExtensionsDelegate`: fans changes out to the engine's streams and turns
/// install confirmations into dialog requests of the asking tab.
@MainActor
private final class ExtensionsObserver: NSObject, OACExtensionsDelegate {
    private weak var core: ChromiumEngineCore?
    private var continuations: [UUID: AsyncStream<ExtensionEvent>.Continuation] = [:]

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    func add(_ continuation: AsyncStream<ExtensionEvent>.Continuation) {
        let id = UUID()
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
    }

    private func send(_ event: ExtensionEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    func extensionsDidChange(_ extensions: OACExtensions) {
        send(.changed)
    }

    func extensions(_ extensions: OACExtensions, didUpdateActionOfExtension extensionIdentifier: String, tab: OACTab?) {
        send(.actionUpdated(extensionID: extensionIdentifier, tabID: tab.map { EngineTabID($0.identifier) }))
    }

    /// The confirmation goes over the tab that asked; a tab-less install (from the API) goes over
    /// a visible tab of the profile. inferred: the spec does not record the install flow.
    func extensions(_ extensions: OACExtensions, confirmInstall request: OACExtensionInstallRequest) -> Bool {
        guard let core else { return false }
        if let tab = request.tab, let wrapper = core.tabs[EngineTabID(tab.identifier)] {
            return wrapper.core.deliverExtensionInstall(request)
        }
        let profileID = extensions.profile?.identifier
        let candidates = core.tabs.values.filter { $0.profileID == profileID }
        let visible = candidates.first { $0.core.isVisible }
        guard let target = visible ?? candidates.first else { return false }
        return target.core.deliverExtensionInstall(request)
    }
}

// MARK: - Popup

/// An extension action's popup (`OACExtensionPopup`).
final class ChromiumExtensionPopup: ExtensionPopup, @unchecked Sendable {
    // @unchecked: `extensionID` and `tabID` are immutable; `core` is main-actor isolated and only
    // touched on the main actor; `channel` is lock-protected.
    let extensionID: String
    let tabID: EngineTabID
    private let core: PopupCore
    private let channel = PopupChannel()

    @MainActor
    init(popup: OACExtensionPopup, tabID: EngineTabID) {
        self.extensionID = popup.extensionIdentifier
        self.tabID = tabID
        self.core = PopupCore(popup: popup, channel: channel)
    }

    func events() -> AsyncStream<ExtensionPopupEvent> {
        channel.subscribe()
    }

    @MainActor func attach(to host: any SurfaceHost) {
        core.attach(to: host)
    }

    @MainActor func focus() {
        core.popup.focus()
    }

    func close() async {
        await MainActor.run { core.popup.close() }
    }
}

/// The popup's events with replay of what already happened. Thread-safe.
// @unchecked: `history` and `isClosed` are read and written only under `lock`.
private final class PopupChannel: @unchecked Sendable {
    private let lock = NSLock()
    private var history: [ExtensionPopupEvent] = []
    private var isClosed = false
    private let broadcaster = AsyncBroadcaster<ExtensionPopupEvent>()

    func subscribe() -> AsyncStream<ExtensionPopupEvent> {
        lock.withLock { broadcaster.subscribe(initial: history) }
    }

    func send(_ event: ExtensionPopupEvent) {
        let finish: Bool = lock.withLock {
            guard !isClosed else { return false }
            if case .resized = event {
                history.removeAll { if case .resized = $0 { return true } else { return false } }
            }
            history.append(event)
            broadcaster.yield(event)
            if event == .closed { isClosed = true }
            return event == .closed
        }
        if finish { broadcaster.finish() }
    }
}

@MainActor
private final class PopupCore: NSObject, OACExtensionPopupDelegate {
    let popup: OACExtensionPopup
    private let channel: PopupChannel
    private weak var host: (any SurfaceHost)?

    init(popup: OACExtensionPopup, channel: PopupChannel) {
        self.popup = popup
        self.channel = channel
        super.init()
        popup.delegate = self
        // What happened before the delegate was set (both arrive from posted tasks, so normally
        // nothing did).
        if popup.hasLoaded { channel.send(.loaded) }
        let size = popup.preferredSize
        if size.width > 0, size.height > 0 { channel.send(.resized(width: size.width, height: size.height)) }
        if popup.isClosed { channel.send(.closed) }
    }

    func attach(to newHost: any SurfaceHost) {
        if let host, host !== newHost { host.clear() }
        host = newHost
        if let view = popup.view {
            newHost.show(.native(view))
        }
    }

    func extensionPopupDidLoad(_ popup: OACExtensionPopup) {
        channel.send(.loaded)
    }

    func extensionPopup(_ popup: OACExtensionPopup, didResizeTo size: CGSize) {
        channel.send(.resized(width: size.width, height: size.height))
    }

    func extensionPopupDidClose(_ popup: OACExtensionPopup) {
        host?.clear()
        host = nil
        channel.send(.closed)
    }
}

// MARK: - Value mapping

extension EngineExtensionInfo {
    init(_ info: OACExtensionInfo) {
        self.init(
            id: info.identifier,
            name: info.name,
            version: info.version,
            isEnabled: info.isEnabled,
            isAllowedInIncognito: info.allowedInIncognito,
            isUnpacked: info.isUnpacked,
            iconPNGData: info.iconPNGData,
            badgeText: info.badgeText,
            actionTitle: info.actionTitle,
            isActionEnabled: info.isActionEnabled,
            hasPopup: info.hasPopup
        )
    }
}
