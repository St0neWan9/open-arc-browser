import Foundation
import os
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `EngineAdBlocking` on top of the bridge (plan C16): `OACApplication.adBlockingEnabled` and
// `adBlockingRulesetVersion`, `-[OACSiteSettings setAdBlockingEnabled:forOrigin:]` and
// `isAdBlockingEnabled(forOrigin:)` of the profile's settings, `OACTab.blockedAdCount`. Every call
// hops to the main actor; reading starts the engine like any other engine call does.
//
// Filter-list updates (plan C19): `ChromiumAdBlockUpdates` checks our static host once after start
// and then daily (`AdBlockRulesetUpdater`: signed manifest, hashes, atomic store swap, all in
// OpenArcEngine and unit-tested there), and hands a new ruleset to the running engine with
// `-[OACApplication loadAdBlockingRulesetFromDirectory:completionHandler:]`, which reindexes and
// publishes it without a restart. Settings shows the new version through `rulesetVersionChanges()`.
//
// The bridge method comes with the C19 Chromium patch (chromium-bridge/README.md §Ad blocking).
// A framework built before it lacks the method: the updater checks for it at run time and stays
// off, so this file builds and runs against both framework generations. Once every framework in
// use has the method, the dynamic call can become a typed one.

final class ChromiumAdBlocking: EngineAdBlocking {
    private let core: ChromiumEngineCore
    private let versionChanges = AsyncBroadcaster<String>()
    private let updates: ChromiumAdBlockUpdates

    @MainActor
    init(core: ChromiumEngineCore, userDataDirectory: URL) {
        self.core = core
        updates = ChromiumAdBlockUpdates(
            core: core, store: AdBlockRulesetStore(userDataDirectory: userDataDirectory),
            versionChanges: versionChanges
        )
    }

    /// Starts the periodic update check (no-op without a manifest URL or bridge support).
    func startUpdates() {
        Task { @MainActor [updates] in updates.start() }
    }

    /// Stops the update check (engine shutdown).
    func stopUpdates() async {
        await MainActor.run { updates.stop() }
        versionChanges.finish()
    }

    func rulesetVersion() async -> String? {
        await MainActor.run { (try? core.ensureStarted())?.adBlockingRulesetVersion }
    }

    func rulesetVersionChanges() -> AsyncStream<String> {
        versionChanges.subscribe()
    }

    func isEnabled() async -> Bool {
        await MainActor.run { (try? core.ensureStarted())?.isAdBlockingEnabled ?? false }
    }

    func setEnabled(_ enabled: Bool) async {
        await MainActor.run { (try? core.ensureStarted())?.isAdBlockingEnabled = enabled }
    }

    func isEnabled(forOrigin origin: SiteOrigin, profileID: Profile.ID) async -> Bool {
        guard let settings = await core.siteSettings(profileID) else { return true }
        return await MainActor.run { settings.isAdBlockingEnabled(forOrigin: OACOrigin(origin)) }
    }

    func setEnabled(_ enabled: Bool, forOrigin origin: SiteOrigin, profileID: Profile.ID) async {
        guard let settings = await core.siteSettings(profileID) else { return }
        await MainActor.run { settings.setAdBlockingEnabled(enabled, for: OACOrigin(origin)) }
    }

    func blockedCount(tabID: EngineTabID) async -> Int {
        await MainActor.run { core.tabs[tabID]?.core.tab?.blockedAdCount ?? 0 }
    }
}

// MARK: - Updates (plan C19)

/// The update loop. Main actor: it reads the engine's state and calls the bridge.
@MainActor
final class ChromiumAdBlockUpdates {
    /// `-[OACApplication loadAdBlockingRulesetFromDirectory:completionHandler:]` (C19 patch).
    static let loadSelector = NSSelectorFromString("loadAdBlockingRulesetFromDirectory:completionHandler:")

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.openarc.browser", category: "adblock-updates"
    )

    private let core: ChromiumEngineCore
    private let store: AdBlockRulesetStore
    private let versionChanges: AsyncBroadcaster<String>
    private var task: Task<Void, Never>?

    init(core: ChromiumEngineCore, store: AdBlockRulesetStore, versionChanges: AsyncBroadcaster<String>) {
        self.core = core
        self.store = store
        self.versionChanges = versionChanges
    }

    /// Whether the running framework can swap rulesets (runtime capability check).
    static func bridgeSupportsLiveUpdates(_ app: OACApplication) -> Bool {
        app.responds(to: loadSelector)
    }

    func start() {
        guard task == nil else { return }
        guard let manifestURL = AdBlockRulesetUpdateConfiguration.manifestURL() else {
            Self.logger.info("ad block updates off: no manifest URL (static host not set up)")
            return
        }
        let updater = AdBlockRulesetUpdater(manifestURL: manifestURL, store: store)
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: AdBlockRulesetUpdateConfiguration.initialDelay)
            while !Task.isCancelled {
                guard let self, await self.checkOnce(updater) else { return }
                try? await Task.sleep(for: AdBlockRulesetUpdateConfiguration.checkInterval)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// One check; false ends the loop (engine gone, or a framework without live updates).
    private func checkOnce(_ updater: AdBlockRulesetUpdater) async -> Bool {
        guard let app = try? core.ensureStarted() else { return false }
        guard Self.bridgeSupportsLiveUpdates(app) else {
            Self.logger.info("ad block updates off: this OpenArcCore.framework predates live ruleset loading (C19)")
            return false
        }
        let active = app.adBlockingRulesetVersion
        // Download and verification run off the main actor (the updater is a Sendable value).
        let outcome = await Task.detached(priority: .utility) { await updater.check(activeVersion: active) }.value
        switch outcome {
        case .upToDate:
            Self.logger.info("ad block ruleset \(active ?? "none", privacy: .public) is up to date")
        case .failed(let error):
            Self.logger.error("ad block update rejected: \(String(describing: error), privacy: .public)")
        case .installed(let version, let directory):
            guard OACApplication.shared.state == .running else { return false }
            if let loaded = await load(directory, into: app) {
                Self.logger.info("ad block ruleset \(loaded, privacy: .public) loaded")
                versionChanges.yield(loaded)
            } else {
                // Stored anyway: the engine picks `Current` up at its next start.
                Self.logger.error("ad block ruleset \(version, privacy: .public) stored but not loaded")
            }
        }
        return true
    }

    /// Calls the bridge method through its IMP (it is not in older headers).
    private func load(_ directory: URL, into app: OACApplication) async -> String? {
        typealias Handler = @convention(block) (NSString?, NSError?) -> Void
        typealias Method = @convention(c) (AnyObject, Selector, NSURL, Handler) -> Void
        let method = unsafeBitCast(app.method(for: Self.loadSelector), to: Method.self)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            // The bridge calls the handler exactly once, on the main thread.
            let handler: Handler = { version, _ in continuation.resume(returning: version as String?) }
            method(app, Self.loadSelector, directory as NSURL, handler)
        }
    }
}

extension OACOrigin {
    convenience init(_ origin: SiteOrigin) {
        self.init(scheme: origin.scheme, host: origin.host, port: origin.port.map { NSNumber(value: $0) })
    }
}
