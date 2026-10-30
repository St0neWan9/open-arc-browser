import Foundation
import OpenArcEngine

// Icons of sites the command bar lists but this window never showed in a tab (plan B132).
//
// Spec: docs/arc-spec/05-surfaces.md §命令栏 (observed): site rows carry the site's icon, also for
// sites never visited on the machine ("Weather.com — weather.com", "National Weather Service —
// weather.gov"; E30 saw Weebly, WebMD, Yahoo, Hacker News with their own icons), and the field's
// glyph turns into the completed site's icon.
//
// Our rules (inferred):
// - Asked only for `.site` rows (site completions, navigation suggestions, most visited pages,
//   tab rows) whose icon the favicon cache does not have; never for other rows.
// - One request per site (host without "www.") at a time; a site that answered nothing is not asked
//   again for `retryInterval`, so typing does not refetch the same missing icon.
// - The answer goes into the window's favicon cache under the site (`FaviconCache.storeSiteIcon`),
//   so the sidebar, the archive and the next command bar find it too; then the bar redraws. Until
//   then the row shows the globe; typing never waits.
// - At most `maxConcurrent` requests run; extra sites wait for the next list.

/// Fetches missing site icons through the engine. One per workspace controller.
@MainActor
final class SiteIconLoader {
    /// How long a site without an icon is left alone. inferred.
    static let retryInterval: TimeInterval = 10 * 60
    /// Requests running at once. inferred (a list shows at most 8 rows).
    static let maxConcurrent = 6

    private var running: [String: Task<Void, Never>] = [:]
    private var failedAt: [String: Date] = [:]

    /// Starts requests for the site rows of `results` whose icon `hasIcon` lacks; `didLoad` runs
    /// (main actor) once per site whose icon was stored.
    func request(
        _ results: [CommandBarResult],
        hasIcon: (CommandBarResult) -> Bool,
        now: Date,
        fetch: @escaping @Sendable (URL) async -> Data?,
        store: @escaping @MainActor (Data, URL) -> Void,
        didLoad: @escaping @MainActor () -> Void
    ) {
        for row in results {
            guard running.count < Self.maxConcurrent else { return }
            guard case .site = row.iconHint, let url = row.url, let key = Self.siteKey(url),
                  running[key] == nil, !hasIcon(row) else { continue }
            if let failed = failedAt[key], now.timeIntervalSince(failed) < Self.retryInterval { continue }
            running[key] = Task { @MainActor [weak self] in
                let data = await fetch(url)
                guard let self else { return }
                self.running[key] = nil
                guard let data, !data.isEmpty else {
                    self.failedAt[key] = now
                    return
                }
                self.failedAt[key] = nil
                store(data, url)
                didLoad()
            }
        }
    }

    /// Stops every request (the window closed).
    func cancelAll() {
        running.values.forEach { $0.cancel() }
        running = [:]
    }

    /// Requests running now. For tests.
    var runningCount: Int { running.count }

    /// The site of an http(s) page: its host, lowercased, without "www.". nil otherwise.
    nonisolated static func siteKey(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}

extension FaviconCache {
    /// Remembers a site icon the engine fetched for `pageURL` (plan B132): under the page and its
    /// site, like a tab's favicon without an icon URL.
    func storeSiteIcon(_ pngData: Data, pageURL: URL) {
        store(Favicon(url: nil, pngData: pngData), pageURL: pageURL)
    }
}

extension WorkspaceController {
    /// Fetches the icons of `results`' site rows that the favicon cache lacks (plan B132), for the
    /// window's profile `profileID`; `bar` redraws when one arrives.
    func loadMissingCommandBarIcons(_ results: [CommandBarResult], profileID: UUID?, bar: CommandBarViewModel) {
        guard let profileID else { return }
        let autocomplete = dependencies.engine.autocomplete
        guard autocomplete.capabilities.contains(.siteIcons) else { return }
        let offTheRecord = isOffTheRecord
        siteIcons.request(
            results,
            hasIcon: { [weak self] row in self?.commandBarFavicon(for: row) != nil },
            now: now(),
            fetch: { url in await autocomplete.siteIcon(for: url, profileID: profileID, isOffTheRecord: offTheRecord) },
            store: { [weak self] data, url in self?.favicons.storeSiteIcon(data, pageURL: url) },
            didLoad: { [weak bar] in bar?.faviconsDidChange() }
        )
    }
}
