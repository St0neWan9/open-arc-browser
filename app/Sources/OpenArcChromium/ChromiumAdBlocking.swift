import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcCore

// `EngineAdBlocking` on top of the bridge (plan C16): `OACApplication.adBlockingEnabled` and
// `adBlockingRulesetVersion`, `-[OACSiteSettings setAdBlockingEnabled:forOrigin:]` and
// `isAdBlockingEnabled(forOrigin:)` of the profile's settings, `OACTab.blockedAdCount`. Every call
// hops to the main actor; reading starts the engine like any other engine call does.

final class ChromiumAdBlocking: EngineAdBlocking {
    private let core: ChromiumEngineCore

    init(core: ChromiumEngineCore) {
        self.core = core
    }

    func rulesetVersion() async -> String? {
        await MainActor.run { (try? core.ensureStarted())?.adBlockingRulesetVersion }
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

extension OACOrigin {
    convenience init(_ origin: SiteOrigin) {
        self.init(scheme: origin.scheme, host: origin.host, port: origin.port.map { NSNumber(value: $0) })
    }
}
