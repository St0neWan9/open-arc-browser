import Foundation
import OpenArcEngine

/// `SiteSettingsProvider` with the engine's real ad blocker (plan C16) and extensions (C14) on top
/// of another provider for everything the engine does not expose yet (permissions, Developer Mode,
/// Picture in Picture, zoom, cookies). `isAdBlockingOn` and `.adBlocking` go to
/// `BrowserEngine.adBlocking`; the row stays hidden when the engine has no ruleset. Extension
/// actions and their popups go to `BrowserEngine.extensions` for the tab's engine tab.
///
/// The row reads "On" when the global switch is on and the site is not on the profile's allow
/// list; toggling it adds or removes the site. With the global switch off the row shows "Off"
/// whatever the list says (the blocker is off everywhere), and toggling still edits the list.
/// inferred: the spec records neither the row nor the allow list ([00 §A] "广告拦截": settings
/// toggle known, blocking UI not captured).
@MainActor
public final class EngineSiteSettingsProvider: SiteSettingsProvider {
    private let adBlocking: any EngineAdBlocking
    private let extensions: (any EngineExtensions)?
    /// The live engine tab of a model tab, if any.
    private let engineTab: @MainActor (UUID) -> EngineTabID?
    let base: any SiteSettingsProvider

    public init(
        adBlocking: any EngineAdBlocking, extensions: (any EngineExtensions)? = nil,
        engineTab: @escaping @MainActor (UUID) -> EngineTabID? = { _ in nil }, base: any SiteSettingsProvider
    ) {
        self.adBlocking = adBlocking
        self.extensions = extensions
        self.engineTab = engineTab
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

    public func extensionActions(tabID: UUID, profileID: UUID?) async -> [SiteExtensionAction]? {
        guard let extensions else { return await base.extensionActions(tabID: tabID, profileID: profileID) }
        guard let engineTabID = engineTab(tabID) else { return [] }
        return await extensions.actions(for: engineTabID).map(SiteExtensionAction.init)
    }

    public func runExtensionAction(_ id: String, tabID: UUID, site: SiteOrigin, profileID: UUID?) async -> (any ExtensionPopup)? {
        guard let extensions else { return await base.runExtensionAction(id, tabID: tabID, site: site, profileID: profileID) }
        guard let engineTabID = engineTab(tabID) else { return nil }
        return await extensions.runAction(id, on: engineTabID)
    }

    private func adBlockingState(for site: SiteOrigin, profileID: UUID?) async -> Bool? {
        guard let profileID, await adBlocking.rulesetVersion() != nil else { return nil }
        guard await adBlocking.isEnabled() else { return false }
        return await adBlocking.isEnabled(forOrigin: site, profileID: profileID)
    }
}
