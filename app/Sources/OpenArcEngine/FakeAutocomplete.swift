import Foundation
import OpenArcModel

/// Fake history and search suggestions (plan B66). On-disk tabs of the `FakeEngine` record a visit
/// on every http(s) navigation (off-the-record tabs never do, like Chromium's history service);
/// tests can add pages with `addVisit` / `addPage` and script suggestions with
/// `suggestionProvider`.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
public final class FakeAutocomplete: EngineAutocomplete, @unchecked Sendable {
    /// Answers a suggestion request; default: no suggestions.
    public typealias SuggestionProvider = @Sendable (SearchSuggestionRequest) -> [String]
    /// Answers a suggestion request including navigation rows (plan B128).
    public typealias CompletionProvider = @Sendable (SearchSuggestionRequest) -> [SearchSuggestion]

    private struct Key: Hashable {
        var profileID: Profile.ID
        var url: URL
    }

    private let lock = NSLock()
    private var pages: [Key: HistoryMatch] = [:]
    private var provider: SuggestionProvider = { _ in [] }
    /// Scripted answers with navigation rows; nil builds them from `provider` (plan B128).
    private var completions: CompletionProvider?
    private var delay: Duration = .zero
    private var supported: AutocompleteCapabilities = [.history, .searchSuggestions, .siteIcons]
    /// Site icons by host without "www." (plan B132).
    private var icons: [String: Data] = [:]
    private var iconDelay: Duration = .zero
    private var iconLog: [URL] = []
    private var requestLog: [SearchSuggestionRequest] = []
    private var queryLog: [String] = []
    private var cancelled = 0
    private let clock: @Sendable () -> Date

    /// - Parameter clock: the visit time of recorded navigations and the "now" of frecency.
    public init(clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
    }

    public var capabilities: AutocompleteCapabilities {
        get { lock.withLock { supported } }
        set { lock.withLock { supported = newValue } }
    }
    /// Answers suggestion requests.
    public var suggestionProvider: SuggestionProvider {
        get { lock.withLock { provider } }
        set { lock.withLock { provider = newValue } }
    }
    /// Answers suggestion requests with navigation rows (plan B128); nil maps `suggestionProvider`.
    public var completionProvider: CompletionProvider? {
        get { lock.withLock { completions } }
        set { lock.withLock { completions = newValue } }
    }
    /// How long a suggestion request takes (to test cancellation). Default: none.
    public var suggestionDelay: Duration {
        get { lock.withLock { delay } }
        set { lock.withLock { delay = newValue } }
    }
    /// Site icons the fake answers, by host without "www." (plan B132). Default: none.
    public var siteIcons: [String: Data] {
        get { lock.withLock { icons } }
        set { lock.withLock { icons = newValue } }
    }
    /// How long a site icon request takes. Default: none.
    public var siteIconDelay: Duration {
        get { lock.withLock { iconDelay } }
        set { lock.withLock { iconDelay = newValue } }
    }
    /// Pages whose site icon was asked for, in order. For tests.
    public var siteIconRequests: [URL] { lock.withLock { iconLog } }
    /// Suggestion requests received, in order. For tests.
    public var suggestionRequests: [SearchSuggestionRequest] { lock.withLock { requestLog } }
    /// History texts asked for, in order. For tests.
    public var historyQueries: [String] { lock.withLock { queryLog } }
    /// Suggestion requests that ended because their task was cancelled. For tests.
    public var cancelledSuggestionCount: Int { lock.withLock { cancelled } }

    /// Every recorded page of a profile, best first. For tests.
    public func history(profileID: Profile.ID) -> [HistoryMatch] {
        let all = lock.withLock { pages.filter { $0.key.profileID == profileID }.map(\.value) }
        return HistoryMatch.sortedByFrecency(all, now: clock())
    }

    /// Records a visit (a navigation of an on-disk tab, or a test page). A later visit of the same
    /// URL counts up and keeps the newest title and time.
    public func addVisit(url: URL, title: String, profileID: Profile.ID, at time: Date? = nil, typed: Bool = false) {
        let at = time ?? clock()
        lock.withLock {
            let key = Key(profileID: profileID, url: url)
            if var page = pages[key] {
                page.visitCount += 1
                if typed { page.typedCount += 1 }
                if at >= page.lastVisit {
                    page.lastVisit = at
                    if !title.isEmpty { page.title = title }
                }
                pages[key] = page
            } else {
                pages[key] = HistoryMatch(url: url, title: title, lastVisit: at, visitCount: 1, typedCount: typed ? 1 : 0)
            }
        }
    }

    /// Adds a page as the engine would report it (visit and typed counts included).
    public func addPage(_ match: HistoryMatch, profileID: Profile.ID) {
        lock.withLock { pages[Key(profileID: profileID, url: match.url)] = match }
    }

    /// Forgets a profile's history, or only visits from `since` on (`clearBrowsingData` with
    /// `.history`, `deleteProfileData`).
    public func removeHistory(profileID: Profile.ID, since: Date? = nil) {
        lock.withLock {
            pages = pages.filter { key, page in
                key.profileID != profileID || (since.map { page.lastVisit < $0 } ?? false)
            }
        }
    }

    public func historyMatches(for text: String, profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch] {
        let words = text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let (enabled, candidates): (Bool, [HistoryMatch]) = lock.withLock {
            queryLog.append(text)
            return (supported.contains(.history), pages.filter { $0.key.profileID == profileID }.map(\.value))
        }
        guard enabled, !words.isEmpty, maxCount > 0, !Task.isCancelled else { return [] }
        let found = candidates.filter { page in
            let haystack = page.title.lowercased() + " " + page.url.absoluteString.lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
        return Array(HistoryMatch.sortedByFrecency(found, now: clock()).prefix(maxCount))
    }

    /// The profile's recorded pages, most visited first (plan B121); none without `.history`.
    public func topSites(profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch] {
        let (enabled, candidates): (Bool, [HistoryMatch]) = lock.withLock {
            (supported.contains(.history), pages.filter { $0.key.profileID == profileID }.map(\.value))
        }
        guard enabled, maxCount > 0, !Task.isCancelled else { return [] }
        return Array(HistoryMatch.sortedByVisits(candidates).prefix(maxCount))
    }

    /// The scripted icon of the page's host (plan B132), after the scripted delay; nil without
    /// `.siteIcons`, for a non-http(s) page or a cancelled task.
    public func siteIcon(for pageURL: URL, profileID: Profile.ID, isOffTheRecord: Bool) async -> Data? {
        let (enabled, icons, delay): (Bool, [String: Data], Duration) = lock.withLock {
            iconLog.append(pageURL)
            return (supported.contains(.siteIcons), self.icons, iconDelay)
        }
        guard enabled, let scheme = pageURL.scheme?.lowercased(), scheme == "http" || scheme == "https",
              var host = pageURL.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !Task.isCancelled else { return nil }
        return icons[host]
    }

    public func searchSuggestions(_ request: SearchSuggestionRequest) async -> [String] {
        await answer(request).filter { !$0.isNavigation }.map(\.text)
    }

    /// The suggestions including navigation rows (plan B128).
    public func searchCompletions(_ request: SearchSuggestionRequest) async -> [SearchSuggestion] {
        await answer(request)
    }

    /// The scripted answer, after the scripted delay; empty when disabled, cancelled or on a
    /// request without a URL. Query rows equal to the typed text are dropped (as engines do).
    private func answer(_ request: SearchSuggestionRequest) async -> [SearchSuggestion] {
        let (enabled, provider, completions, delay): (Bool, SuggestionProvider, CompletionProvider?, Duration) = lock.withLock {
            requestLog.append(request)
            return (supported.contains(.searchSuggestions), self.provider, self.completions, self.delay)
        }
        guard enabled, request.url != nil else { return [] }
        if delay > .zero {
            do {
                try await Task.sleep(for: delay)
            } catch {
                lock.withLock { cancelled += 1 }
                return []
            }
        }
        guard !Task.isCancelled else {
            lock.withLock { cancelled += 1 }
            return []
        }
        let folded = request.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let entries = completions.map { $0(request) } ?? provider(request).map { SearchSuggestion(text: $0) }
        return entries.filter { $0.isNavigation || $0.text.lowercased() != folded }
    }
}
