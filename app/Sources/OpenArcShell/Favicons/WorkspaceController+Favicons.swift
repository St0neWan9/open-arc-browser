import Foundation
import OpenArcModel
import OpenArcEngine

// Favicons of model tabs (C9). Live tabs show the engine's image; tabs without an engine tab (not
// loaded yet, after relaunch) and archived items show the cached image of their stored
// `faviconURL`, else of their site. See FaviconCache.swift for the cache rules (inferred).

extension WorkspaceController {
    /// Caches the image of live tab `id`'s current favicon.
    func rememberFavicon(of id: UUID) {
        guard let live = liveStates[id], let favicon = live.currentFavicon else { return }
        favicons.store(favicon, pageURL: live.committedURL ?? live.url)
    }

    /// The favicon URL to keep in the tab record: the live page's icon; without one, the stored
    /// icon while the tab stays on the same site, else none (the old site's icon would be wrong).
    static func faviconURLToStore(live: SidebarTabLiveState, storedURL: URL?, storedFaviconURL: URL?) -> URL? {
        if let url = live.currentFavicon?.url { return url }
        let page = live.committedURL ?? live.url
        guard page != nil else { return storedFaviconURL }
        return FaviconCache.isSameSite(page, storedURL) ? storedFaviconURL : nil
    }

    /// PNG bytes of the icon to draw for tab `id`: the live favicon, else the cached image of the
    /// stored favicon URL or of the tab's site. nil draws the placeholder.
    public func faviconImage(for id: UUID) -> Data? {
        if let data = liveStates[id]?.currentFavicon?.pngData { return data }
        guard let tab = workspace.tabs[id] else { return nil }
        let page = liveStates[id].flatMap { $0.committedURL ?? $0.url } ?? tab.url ?? tab.pinnedURL
        // A stored icon URL from another site (navigated away before the new icon came) is skipped.
        let iconURL = FaviconCache.isSameSite(page, tab.url) || tab.url == nil ? tab.faviconURL : nil
        return favicons.image(iconURL: iconURL, pageURL: page)
    }

    /// PNG bytes for an archived item or a command bar row: its favicon URL, else its site.
    public func faviconImage(iconURL: URL?, pageURL: URL?) -> Data? {
        favicons.image(iconURL: iconURL, pageURL: pageURL)
    }

    /// Favicon of a command bar row (C9): a tab row shows its tab's icon; other site rows (history,
    /// typed URLs) the cached icon of their site.
    func commandBarFavicon(for result: CommandBarResult) -> Data? {
        if case .switchToTab(let id) = result.action, let data = faviconImage(for: id) { return data }
        // History rows (B66): the site's icon when this window has seen the site; else the clock.
        if case .history = result.iconHint { return favicons.image(forPage: result.url) }
        guard case .site(let iconURL) = result.iconHint else { return nil }
        return favicons.image(iconURL: iconURL, pageURL: result.url)
    }
}
