import Foundation
import OpenArcEngine

/// `SiteSettingsProvider` with the engine's real ad blocker (plan C16) on top of another provider
/// for everything the engine does not expose yet (permissions, Developer Mode, Picture in
/// Picture, zoom, cookies, extensions: C12 / C14). `isAdBlockingOn` and `.adBlocking` go to
/// `BrowserEngine.adBlocking`; the row stays hidden when the engine has no ruleset.
///
/// The row reads "On" when the global switch is on and the site is not on the profile's allow
/// list; toggling it adds or removes the site. With the global switch off the row shows "Off"
/// whatever the list says (the blocker is off everywhere), and toggling still edits the list.
/// inferred: the spec records neither the row nor the allow list ([00 §A] "广告拦截": settings
/// toggle known, blocking UI not captured).
@MainActor
public final class EngineSiteSettingsProvider: SiteSettingsProvider {
    private let adBlocking: any EngineAdBlocking
    let base: any SiteSettingsProvider

    public init(adBlocking: any EngineAdBlocking, base: any SiteSettingsProvider) {
        self.adBlocking = adBlocking
        self.base = base
    }

    public func settings(for site: SiteOrigin, profileID: UUID?) async -> SiteSettingsState {
        var state = await base.settings(for: site, profileID: profileID)
        state.isAdBlockingOn = await adBlockingState(for: site, profileID: profileID)
        return state
    }

    public func apply(_ change: SiteSettingChange, for site: SiteOrigin, profileID: UUID?) async {
        guard case .adBlocking(let on) = change else {
            await base.apply(change, for: site, profileID: profileID)
            return
        }
        guard let profileID else { return }
        await adBlocking.setEnabled(on, forOrigin: site, profileID: profileID)
        // Turning the row on while the global switch is off would show "Off" again; the user
        // asked for blocking here, so the global switch comes back on too. inferred.
        if on, await !adBlocking.isEnabled() {
            await adBlocking.setEnabled(true)
        }
    }

    public func runExtensionAction(_ id: String, tabID: UUID, site: SiteOrigin, profileID: UUID?) async {
        await base.runExtensionAction(id, tabID: tabID, site: site, profileID: profileID)
    }

    private func adBlockingState(for site: SiteOrigin, profileID: UUID?) async -> Bool? {
        guard let profileID, await adBlocking.rulesetVersion() != nil else { return nil }
        guard await adBlocking.isEnabled() else { return false }
        return await adBlocking.isEnabled(forOrigin: site, profileID: profileID)
    }
}
