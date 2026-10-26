import Foundation
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Palettes per appearance and the pages' color scheme (plan B21).
// [04 §dark mode (E7)] observed: a Space's theme is light, dark or automatic (follows the system);
// a dark Space's pages get `prefers-color-scheme: dark`; View ▸ Appearance decides what
// "Websites, Easels, and Notes" use. How the menu and the Space setting combine was not captured:
// see `WebAppearance.colorScheme(spaceAppearance:)` (inferred).

extension WorkspaceController {
    /// The live theme of a Space, if any.
    func theme(ofSpace spaceID: UUID?) -> Theme? {
        guard let spaceID, let space = workspace.spaces[spaceID], !space.meta.isTombstone,
              let themeID = space.themeID, let theme = workspace.themes[themeID], !theme.meta.isTombstone
        else { return nil }
        return theme
    }

    /// Light or dark for a Space: its theme's appearance, automatic (or no theme) following the system.
    func resolvedAppearance(ofSpace spaceID: UUID?) -> ResolvedAppearance {
        ThemeDerivation.resolve(theme(ofSpace: spaceID)?.appearance ?? .automatic, system: systemAppearance)
    }

    /// The palette of a Space in the current system appearance.
    func palette(ofSpace spaceID: UUID?) -> ThemePalette {
        ThemeDerivation.palette(for: theme(ofSpace: spaceID), systemAppearance: systemAppearance)
    }

    // MARK: View ▸ Appearance

    /// View ▸ Appearance (per device). An incognito controller shares its parent's preferences.
    public var webAppearance: WebAppearance {
        get { dependencies.preferences.webAppearance }
        set {
            guard newValue != webAppearance else { return }
            objectWillChange.send()
            dependencies.preferences.webAppearance = newValue
            syncWebColorSchemes()
            for child in liveIncognitoChildren { child.webAppearanceDidChange() }
        }
    }

    /// The parent changed the shared preference: update this controller's pages and menus.
    func webAppearanceDidChange() {
        objectWillChange.send()
        syncWebColorSchemes()
    }

    // MARK: Color scheme of pages

    /// The Space whose appearance a tab's page follows: its own Space; a favorite (shared by every
    /// Space of its profile) follows the active window's Space. inferred.
    func colorSchemeSpaceID(forTab id: UUID) -> UUID? {
        guard let tab = workspace.tabs[id] else { return nil }
        if let spaceID = tab.location.spaceID { return spaceID }
        return activeWindow?.selectedSpaceID ?? liveSidebars.first?.selectedSpaceID
    }

    /// The color scheme a tab's page gets now.
    func webColorScheme(forTab id: UUID) -> WebColorScheme {
        webAppearance.colorScheme(spaceAppearance: resolvedAppearance(ofSpace: colorSchemeSpaceID(forTab: id)))
    }

    /// Sends every live tab whose scheme changed its new scheme (one queued command per tab), and
    /// tells pages without a model tab (Little Arc) to check theirs.
    func syncWebColorSchemes() {
        for entry in liveTabEntries { syncWebColorScheme(of: entry.id) }
        colorSchemeInputsChanged.send()
    }

    /// The color scheme for a page shown on behalf of the window whose Space is `spaceID`.
    func webColorScheme(forSpace spaceID: UUID?) -> WebColorScheme {
        webAppearance.colorScheme(spaceAppearance: resolvedAppearance(ofSpace: spaceID))
    }

    /// Sends `id`'s page its scheme if it differs from the last one sent.
    func syncWebColorScheme(of id: UUID) {
        guard let live = liveTab(for: id) else { return }
        let scheme = webColorScheme(forTab: id)
        guard sentColorSchemes[id] != scheme else { return }
        sentColorSchemes[id] = scheme
        enqueueTabCommand(live) { await $0.setPreferredColorScheme(scheme) }
    }
}
