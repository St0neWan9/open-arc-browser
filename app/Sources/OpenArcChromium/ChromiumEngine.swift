import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `BrowserEngine` on top of OpenArcCore.framework, our Chromium fork's Objective-C bridge (plan C8;
// chromium-bridge/README.md §From callbacks to the Swift protocols).
//
// Isolation (decision Q11): the protocols stay nonisolated. Every `OAC*` object is main-actor only,
// so each command hops to the main actor (`ChromiumEngineCore`, `ChromiumTabCore`), and the tab
// state is cached behind a lock so `events()` can hand out `.snapshot(state)` synchronously.
//
// Supported: tab creation per profile (on-disk or off-the-record), load / back / forward / reload
// (also bypassing the cache) / stop, mute, state snapshot and events (URL, committed URL, title,
// favicon, load progress, navigation state, audio, security, zoom, fullscreen, theme color, hovered
// link, find results, crash, close requests), new-tab requests (plain URL requests and
// script-opened windows as `PendingTabToken`s), NSView hosting, preferred color scheme, zoom, find,
// edit commands, selected text, snapshots, view source, exit fullscreen, the beforeunload close
// path, shell-drawn dialogs (C12: JavaScript alert / confirm / prompt / beforeunload, permission
// prompts, HTTP auth, file chooser, external protocol), downloads (C12), and the page tools of
// C15: DevTools (its own window per tab), printing (the macOS print panel), Save Page As (complete
// page, HTML only, one MHTML file), Picture in Picture (Chromium's PiP window, also entered
// automatically when the user leaves a video tab) and Chromium's PDF viewer; extensions (C14:
// //chrome's extension system per profile, unpacked loading, Web Store installs with a
// shell-drawn confirmation, action state and popups for the Site Control Center).
//
// Profiles (C11): one on-disk Chromium profile per model Profile at `<user data dir>/<UUID>`
// (cookies, storage, cache, HTTP auth cache, permissions, history, favicons, service workers and
// downloads all live in it), its off-the-record profile for incognito tabs (destroyed by the
// bridge once the last incognito tab of the profile closes), `deleteProfileData` (removes the
// directory) and `clearBrowsingData` (Chromium's browsing-data remover). A live tab cannot change
// profile: the shell closes it and makes a new one in the other profile, which loads the tab's
// URL again (`WorkspaceController.reconcileLiveTabProfiles`).
//
// Not supported yet (the bridge has no implementation):
// - Document Picture in Picture (`documentPictureInPicture.requestWindow`) is refused: it needs a
//   Chrome window type the embedder does not have (C15).
// - Downloads list the on-disk profile only; downloads of incognito windows are not listed (C12
//   follow-up).
// - Capture state stays empty (C9).

/// The Chromium engine. Create it on the main actor at launch; it starts Chromium's browser process
/// once (at `NSApplication.willFinishLaunching`, or on first use) and shuts it down in `shutdown()`.
public final class ChromiumEngine: BrowserEngine {
    /// `"Chromium <version>"`, for Settings ▸ About.
    public let engineVersion: String
    public let downloads: any EngineDownloads
    /// //chrome's extension system per profile (plan C14).
    public let extensions: any EngineExtensions
    /// Chromium's subresource filter with the bundled EasyList + EasyPrivacy ruleset (plan C16).
    public let adBlocking: any EngineAdBlocking
    /// History and password import from other browsers (plan D3b).
    public let importer: any EngineImporter
    /// Chromium's translate component with shell-drawn surfaces (plan B47).
    public let translation: any EngineTranslation

    private let core: ChromiumEngineCore
    private let broadcaster: AsyncBroadcaster<EngineEvent>

    /// - Parameters:
    ///   - userDataDirectory: Chromium's user data directory, `<app data dir>/Chromium`.
    ///   - crashReportsDirectory: the Crashpad database for local crash reports (plan D8, decision
    ///     Q8: never uploaded), `<app data dir>/Crash Reports` in the app. It covers the browser
    ///     process (which is the app process, so Swift crashes too, once the engine started) and
    ///     every helper. nil: `<userDataDirectory>/Crashpad`.
    ///   - additionalSwitches: extra Chromium switches (development only).
    @MainActor
    public init(userDataDirectory: URL, crashReportsDirectory: URL? = nil, additionalSwitches: [String] = []) {
        let broadcaster = AsyncBroadcaster<EngineEvent>()
        self.broadcaster = broadcaster
        self.core = ChromiumEngineCore(
            userDataDirectory: userDataDirectory,
            crashReportsDirectory: crashReportsDirectory,
            additionalSwitches: additionalSwitches,
            broadcaster: broadcaster
        )
        engineVersion = "Chromium " + OACApplication.shared.chromiumVersion
        downloads = ChromiumDownloads(core: core)
        let extensions = ChromiumExtensions(core: core)
        self.extensions = extensions
        // Every loaded profile gets the extensions delegate at once, so a Web Store install from a
        // page finds someone to confirm it.
        core.onProfileLoaded = { [weak extensions] id, profile in extensions?.attach(to: id, extensions: profile.extensions) }
        adBlocking = ChromiumAdBlocking(core: core)
        importer = ChromiumImporter(core: core)
        translation = ChromiumTranslation(core: core)
        core.startAtLaunch()
    }

    /// Makes the process's `NSApplication` an `OACBrowserApplication`, which Chromium's event
    /// handling needs (chromium-bridge/include/OpenArcCore/OACBrowserApplication.h). Call before
    /// anything touches `NSApplication.shared`, i.e. first thing in `main.swift`.
    @MainActor
    public static func installApplicationClass() {
        _ = OACBrowserApplication.shared
    }

    public func makeTab(_ configuration: TabConfiguration) async throws -> any BrowserTab {
        try await core.makeTab(configuration)
    }

    public func tab(for id: EngineTabID) async -> (any BrowserTab)? {
        await core.tabs[id]
    }

    public func closeTab(_ id: EngineTabID) async {
        await core.closeTab(id)
    }

    public func events() -> AsyncStream<EngineEvent> {
        broadcaster.subscribe()
    }

    public func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) async throws -> any BrowserTab {
        try await core.adoptTab(token, requestedID: requestedID)
    }

    public func declineTab(_ token: PendingTabToken) async {
        await core.declineTab(token)
    }

    public func shutdown() async {
        await core.shutdown()
    }

    public func deleteProfileData(_ profileID: Profile.ID) async throws {
        try await core.deleteProfileData(profileID)
    }

    public func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async {
        await core.clearBrowsingData(profileID, types: types, since: since)
    }
}

// MARK: - Engine core (main actor)

/// The engine's main-actor state: Chromium's lifetime, loaded profiles, live tabs and pending
/// script-opened windows.
@MainActor
final class ChromiumEngineCore {
    private let userDataDirectory: URL
    private let crashReportsDirectory: URL?
    private let additionalSwitches: [String]
    private let broadcaster: AsyncBroadcaster<EngineEvent>
    private(set) var tabs: [EngineTabID: ChromiumTab] = [:]
    private var pending: [PendingTabToken: (request: OACNewTabRequest, opener: EngineTabID)] = [:]
    private var isShutDown = false
    private var launchObserver: NSObjectProtocol?
    /// Called once per on-disk profile after it loaded (C14 attaches the extensions delegate).
    var onProfileLoaded: ((Profile.ID, OACProfile) -> Void)?

    init(
        userDataDirectory: URL, crashReportsDirectory: URL?, additionalSwitches: [String],
        broadcaster: AsyncBroadcaster<EngineEvent>
    ) {
        self.userDataDirectory = userDataDirectory
        self.crashReportsDirectory = crashReportsDirectory
        self.additionalSwitches = additionalSwitches
        self.broadcaster = broadcaster
    }

    /// Starts Chromium when AppKit is about to finish launching (the moment the bridge documents),
    /// or right away when the app already launched.
    func startAtLaunch() {
        if OACApplication.shared.state != .notStarted { return }
        let center = NotificationCenter.default
        launchObserver = center.addObserver(
            forName: Notification.Name("NSApplicationWillFinishLaunchingNotification"), object: nil, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.launchObserver { center.removeObserver(observer) }
                self.launchObserver = nil
                _ = try? self.ensureStarted()
            }
        }
    }

    /// Starts the browser process once. Chromium cannot start twice in one process.
    @discardableResult
    func ensureStarted() throws -> OACApplication {
        let app = OACApplication.shared
        switch app.state {
        case .running:
            return app
        case .notStarted:
            guard !isShutDown else { throw EngineError.shuttingDown }
            let configuration = OACApplicationConfiguration(userDataDirectory: userDataDirectory)
            configuration.crashDumpDirectory = crashReportsDirectory
            configuration.additionalSwitches = additionalSwitches
            do {
                try app.start(configuration: configuration)
            } catch {
                throw EngineError.engineFailure("Chromium failed to start: \(error.localizedDescription)")
            }
            return app
        case .shuttingDown, .terminated:
            throw EngineError.shuttingDown
        @unknown default:
            throw EngineError.shuttingDown
        }
    }

    /// The on-disk profile's site settings (its off-the-record profile inherits the ad blocking
    /// allow list). nil when the profile cannot be loaded.
    func siteSettings(_ id: Profile.ID) async -> OACSiteSettings? {
        guard !isShutDown, let profile = try? await profile(id, offTheRecord: false) else { return nil }
        return profile.siteSettings
    }

    /// The on-disk profile (B47: its translate settings). nil when it cannot be loaded.
    func onDiskProfile(_ id: Profile.ID) async -> OACProfile? {
        guard !isShutDown else { return nil }
        return try? await profile(id, offTheRecord: false)
    }

    /// The profile's extensions (C14). nil when the profile cannot be loaded.
    func extensions(_ id: Profile.ID) async -> OACExtensions? {
        guard !isShutDown, let profile = try? await profile(id, offTheRecord: false) else { return nil }
        return profile.extensions
    }

    /// The profile's downloads (C12). nil when the profile cannot be loaded.
    func downloads(_ id: Profile.ID) async -> OACDownloads? {
        guard !isShutDown, let profile = try? await profile(id, offTheRecord: false) else { return nil }
        return profile.downloads
    }

    private func profile(_ id: Profile.ID, offTheRecord: Bool) async throws -> OACProfile {
        let app = try ensureStarted()
        let profile: OACProfile
        if let loaded = app.loadedProfile(identifier: id) {
            profile = loaded
        } else {
            profile = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<OACProfile, Error>) in
                app.loadProfile(identifier: id) { profile, error in
                    if let profile {
                        continuation.resume(returning: profile)
                    } else {
                        continuation.resume(throwing: error.map { EngineError(bridge: $0) } ?? EngineError.profileUnavailable)
                    }
                }
            }
        }
        onProfileLoaded?(id, profile)
        return offTheRecord ? profile.offTheRecordProfile : profile
    }

    func makeTab(_ configuration: TabConfiguration) async throws -> ChromiumTab {
        guard !isShutDown else { throw EngineError.shuttingDown }
        if let requested = configuration.requestedID, tabs[requested] != nil {
            throw EngineError.duplicateTabID(requested)
        }
        let profile = try await profile(configuration.profileID, offTheRecord: configuration.isOffTheRecord)
        guard !isShutDown else { throw EngineError.shuttingDown }
        let tabConfiguration = OACTabConfiguration(profile: profile)
        tabConfiguration.initialURL = configuration.initialURL
        tabConfiguration.requestedIdentifier = configuration.requestedID?.rawValue
        tabConfiguration.opener = configuration.opener.flatMap { tabs[$0]?.core.tab }
        tabConfiguration.preferredColorScheme = OACColorScheme(configuration.preferredColorScheme)
        // Hidden until a host attaches the surface (`TabSurface.attach`).
        tabConfiguration.startsHidden = true
        let tab: OACTab
        do {
            tab = try OACTab(configuration: tabConfiguration)
        } catch {
            throw EngineError(bridge: error)
        }
        return register(tab, profileID: configuration.profileID, colorScheme: configuration.preferredColorScheme)
    }

    private func register(_ tab: OACTab, profileID: Profile.ID, colorScheme: WebColorScheme) -> ChromiumTab {
        let wrapper = ChromiumTab(tab: tab, profileID: profileID, colorScheme: colorScheme, engine: self)
        tabs[wrapper.id] = wrapper
        return wrapper
    }

    func closeTab(_ id: EngineTabID) {
        guard let tab = tabs.removeValue(forKey: id) else { return }
        // Bridge rule: an unanswered script-opened window is declined when its opener closes.
        for (token, entry) in pending where entry.opener == id {
            entry.request.decline()
            pending.removeValue(forKey: token)
        }
        tab.core.close()
        broadcaster.yield(.tabClosed(id))
    }

    /// The bridge closed a tab on its own (engine shutdown).
    func tabDidClose(_ id: EngineTabID) {
        guard tabs.removeValue(forKey: id) != nil else { return }
        broadcaster.yield(.tabClosed(id))
    }

    func newTabRequested(_ request: OACNewTabRequest, opener: EngineTabID) {
        guard !isShutDown else {
            request.decline()
            return
        }
        var token: PendingTabToken?
        if request.hasPendingContents {
            let newToken = PendingTabToken(UUID())
            pending[newToken] = (request, opener)
            token = newToken
        }
        broadcaster.yield(.newTabRequested(NewTabRequest(
            opener: opener,
            url: request.url,
            disposition: NewTabDisposition(request.disposition),
            hasUserGesture: request.hasUserGesture,
            pendingTab: token
        )))
    }

    func adoptTab(_ token: PendingTabToken, requestedID: EngineTabID?) throws -> ChromiumTab {
        guard !isShutDown else { throw EngineError.shuttingDown }
        if let requestedID, tabs[requestedID] != nil { throw EngineError.duplicateTabID(requestedID) }
        guard let entry = pending.removeValue(forKey: token) else { throw EngineError.requestFinished }
        let tab: OACTab
        do {
            tab = try entry.request.adopt(identifier: requestedID?.rawValue)
        } catch {
            throw EngineError(bridge: error)
        }
        let profileID = tabs[entry.opener]?.profileID ?? entry.request.profile.identifier
        // The shell sends the tab's scheme right away for adopted tabs.
        return register(tab, profileID: profileID, colorScheme: .light)
    }

    func declineTab(_ token: PendingTabToken) {
        pending.removeValue(forKey: token)?.request.decline()
    }

    func shutdown() async {
        if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
        launchObserver = nil
        guard !isShutDown else { return }
        isShutDown = true
        for entry in pending.values { entry.request.decline() }
        pending.removeAll()
        for id in Array(tabs.keys) { closeTab(id) }
        let app = OACApplication.shared
        guard app.state == .running else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            app.shutdown { continuation.resume() }
        }
    }

    /// Deletes the profile's on-disk engine profile (C11): the bridge wipes its browsing data
    /// through Chromium, destroys the profile (and its off-the-record context) and removes
    /// `<user data dir>/<UUID>` and its cache directory. Every tab of the profile, regular or
    /// off the record, must be closed first. Never started engine: there is nothing loaded, but
    /// the directory may exist from an earlier run, so the engine starts to remove it.
    func deleteProfileData(_ profileID: Profile.ID) async throws {
        guard !isShutDown else { throw EngineError.shuttingDown }
        guard !tabs.values.contains(where: { $0.profileID == profileID }) else { throw EngineError.invalidArgument }
        let app = try ensureStarted()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            app.deleteProfile(identifier: profileID) { error in
                if let error {
                    continuation.resume(throwing: EngineError(bridge: error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func clearBrowsingData(_ profileID: Profile.ID, types: BrowsingDataTypes, since: Date?) async {
        guard !isShutDown, let profile = try? await profile(profileID, offTheRecord: false) else { return }
        var bridgeTypes: OACBrowsingDataTypes = []
        if types.contains(.history) { bridgeTypes.insert(.history) }
        if types.contains(.cookies) { bridgeTypes.insert(.cookies) }
        if types.contains(.cache) { bridgeTypes.insert(.cache) }
        if types.contains(.siteStorage) { bridgeTypes.insert(.siteStorage) }
        if types.contains(.downloads) { bridgeTypes.insert(.downloadsList) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            profile.clearBrowsingData(of: bridgeTypes, since: since) { continuation.resume() }
        }
    }
}

// MARK: - Value mapping

extension EngineError {
    /// Maps an `OACErrorDomain` error onto the engine error the shell understands.
    init(bridge error: Error, tabID: EngineTabID? = nil) {
        let nsError = error as NSError
        guard nsError.domain == OACErrorDomain, let code = OACError.Code(rawValue: nsError.code) else {
            self = .engineFailure(nsError.localizedDescription)
            return
        }
        switch code {
        case .notStarted, .shuttingDown, .alreadyStarted: self = .shuttingDown
        case .profileUnavailable: self = .profileUnavailable
        case .tabClosed: self = tabID.map { .tabClosed($0) } ?? .engineFailure(nsError.localizedDescription)
        case .duplicateTabIdentifier: self = tabID.map { .duplicateTabID($0) } ?? .invalidArgument
        case .snapshotUnavailable: self = .snapshotUnavailable
        case .invalidURL: self = .invalidURL
        case .invalidArgument: self = .invalidArgument
        case .requestFinished: self = .requestFinished
        @unknown default: self = .engineFailure(nsError.localizedDescription)
        }
    }
}

extension OACColorScheme {
    init(_ scheme: WebColorScheme) {
        self = scheme == .dark ? .dark : .light
    }
}

extension NewTabDisposition {
    init(_ disposition: OACNewTabDisposition) {
        switch disposition {
        case .backgroundTab: self = .backgroundTab
        case .newWindow: self = .newWindow
        case .popup: self = .popup
        default: self = .foregroundTab
        }
    }
}
