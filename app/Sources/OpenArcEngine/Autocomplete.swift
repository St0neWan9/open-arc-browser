import Foundation
import OpenArcModel

// Browsing history matches and search suggestions for the command bar (plan B66; bridge:
// chromium-bridge/include/OpenArcCore/OACAutocomplete.h).
//
// Spec: the command bar is the single entry for new tabs, search and commands ([05 §command bar]
// observed); its rows carry a globe, magnifier or clock icon ([07 §9] observed); typing a word that
// matches no command lists "only search suggestions" ([06 §16.2], [06 §19.1], [06 §23] observed);
// the profile has "Search engine" and "Include search engine suggestions" ([03 §Profiles]
// observed). The engine answers the raw data; the shell ranks and draws the rows.
//
// Both calls are async and cancellable: cancelling the calling task stops the engine's work (the
// history query or the suggestion request) and the call returns an empty result right away.

/// One page of a profile's browsing history.
public struct HistoryMatch: Hashable, Sendable {
    public var url: URL
    /// The page title the engine stored (may be empty).
    public var title: String
    /// The most recent visit.
    public var lastVisit: Date
    /// Number of visits the engine counted (at least 1).
    public var visitCount: Int
    /// Visits that came from typing the address (Chromium's typed count).
    public var typedCount: Int

    public init(url: URL, title: String, lastVisit: Date, visitCount: Int = 1, typedCount: Int = 0) {
        self.url = url
        self.title = title
        self.lastVisit = lastVisit
        self.visitCount = max(1, visitCount)
        self.typedCount = max(0, typedCount)
    }

    /// How strongly the page is part of the user's habits, 0...1: recency (stepped by age) mixed
    /// with frequency (log of visits, typed visits count three times). inferred: the spec only
    /// records that Arc ranks with a local model ([05 §command bar] inferred); the weights are ours.
    public func frecency(at now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(lastVisit)) / 86_400
        let recency: Double
        switch days {
        case ..<4: recency = 1
        case ..<14: recency = 0.7
        case ..<31: recency = 0.5
        case ..<90: recency = 0.3
        default: recency = 0.1
        }
        let weighted = Double(visitCount + 2 * typedCount)
        let frequency = min(1, log2(1 + weighted) / log2(1 + 64))
        return 0.6 * recency + 0.4 * frequency
    }

    /// Best first: higher frecency, then the more recent visit, then the URL (deterministic).
    public static func sortedByFrecency(_ matches: [HistoryMatch], now: Date) -> [HistoryMatch] {
        matches
            .map { ($0, $0.frecency(at: now)) }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                if lhs.0.lastVisit != rhs.0.lastVisit { return lhs.0.lastVisit > rhs.0.lastVisit }
                return lhs.0.url.absoluteString < rhs.0.url.absoluteString
            }
            .map(\.0)
    }

    /// Most visited first: visits (a typed visit counts three times, as in `frecency`), then the
    /// more recent visit, then the URL (deterministic). The order of `EngineAutocomplete.topSites`.
    /// inferred: the spec does not record how most-visited pages are ordered.
    public static func sortedByVisits(_ matches: [HistoryMatch]) -> [HistoryMatch] {
        matches.sorted { lhs, rhs in
            let l = lhs.visitCount + 2 * lhs.typedCount, r = rhs.visitCount + 2 * rhs.typedCount
            if l != r { return l > r }
            if lhs.lastVisit != rhs.lastVisit { return lhs.lastVisit > rhs.lastVisit }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }
}

/// A search suggestion request: the typed text and the profile's search engine endpoint.
public struct SearchSuggestionRequest: Hashable, Sendable {
    /// The text as typed (trimmed by the caller).
    public var query: String
    /// The engine's suggestion URL, `%@` standing for the escaped query
    /// (`SearchEngine.suggestURLTemplate`).
    public var urlTemplate: String
    /// The profile whose network context sends the request.
    public var profileID: Profile.ID
    /// Sent from an incognito window: the request goes through the off-the-record context.
    public var isOffTheRecord: Bool

    public init(query: String, urlTemplate: String, profileID: Profile.ID, isOffTheRecord: Bool = false) {
        self.query = query
        self.urlTemplate = urlTemplate
        self.profileID = profileID
        self.isOffTheRecord = isOffTheRecord
    }

    /// The URL to fetch; nil for an empty query or a template without `%@`.
    public var url: URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, urlTemplate.contains("%@") else { return nil }
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        guard let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: urlTemplate.replacingOccurrences(of: "%@", with: escaped))
    }
}

/// One entry of the search service's answer: a phrase to search for, or a navigation suggestion
/// (a page the service proposes, with the page's title). Plan B128; Arc observed 2026-10-30 that
/// the bar lists "National Weather Service — weather.gov" among the query suggestions
/// ([05 §命令栏] observed).
public struct SearchSuggestion: Hashable, Sendable {
    /// The suggestion's text: the phrase of a query row, the page title of a navigation row.
    public var text: String
    /// The page of a navigation row; nil for a query row.
    public var url: URL?

    public init(text: String, url: URL? = nil) {
        self.text = text
        self.url = url
    }

    /// A navigation row proposes a page rather than a phrase.
    public var isNavigation: Bool { url != nil }
}

/// What an engine build can answer (`EngineAutocomplete.capabilities`).
public struct AutocompleteCapabilities: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let history = AutocompleteCapabilities(rawValue: 1 << 0)
    public static let searchSuggestions = AutocompleteCapabilities(rawValue: 1 << 1)
}

/// History search and search suggestions of every profile (`BrowserEngine.autocomplete`).
public protocol EngineAutocomplete: AnyObject, Sendable {
    /// What this engine build supports. A missing capability answers empty results.
    var capabilities: AutocompleteCapabilities { get }
    /// Pages of the on-disk profile `profileID` whose title or URL matches every word of `text`,
    /// best first (`HistoryMatch.sortedByFrecency`), at most `maxCount`. Off-the-record browsing
    /// is never recorded, so an incognito window has nothing to ask for (the shell does not call).
    /// Empty for an empty text, a cancelled task or an engine without `.history`.
    func historyMatches(for text: String, profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch]
    /// The search engine's suggestions for `request.query`, in the engine's order, without the
    /// query itself. Empty on any failure (offline, timeout, unreadable answer), for a cancelled
    /// task or an engine without `.searchSuggestions`.
    func searchSuggestions(_ request: SearchSuggestionRequest) async -> [String]
    /// The search engine's suggestions for `request.query` including its navigation rows, in the
    /// service's order (plan B128). Engines that only know phrases answer query rows: the default
    /// below maps `searchSuggestions`. Empty under the same conditions as `searchSuggestions`.
    func searchCompletions(_ request: SearchSuggestionRequest) async -> [SearchSuggestion]
    /// The most visited pages of the on-disk profile `profileID`, most visited first
    /// (`HistoryMatch.sortedByVisits`), at most `maxCount` (plan B121; [05 §command bar] inferred
    /// (analysis): the bar's results include most-visited pages). They come from the history, so an
    /// engine without `.history` answers nothing, and so does a cancelled task.
    func topSites(profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch]
}

extension EngineAutocomplete {
    /// Engines without a most-visited query answer nothing, so the command bar simply shows no
    /// most-visited rows. (The Chromium engine has one since B123.)
    public func topSites(profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch] { [] }

    /// An engine that only knows phrases answers query rows only (plan B128).
    public func searchCompletions(_ request: SearchSuggestionRequest) async -> [SearchSuggestion] {
        await searchSuggestions(request).map { SearchSuggestion(text: $0) }
    }
}

/// An engine without history search or suggestions (test doubles that do not provide them).
public final class UnavailableAutocomplete: EngineAutocomplete {
    public static let shared = UnavailableAutocomplete()
    public init() {}
    public var capabilities: AutocompleteCapabilities { [] }
    public func historyMatches(for text: String, profileID: Profile.ID, maxCount: Int) async -> [HistoryMatch] { [] }
    public func searchSuggestions(_ request: SearchSuggestionRequest) async -> [String] { [] }
}

/// Reads a suggestion service's answer. Every engine of `SearchEngine` answers the OpenSearch
/// suggestion format, a JSON array `["query", ["suggestion", …], ["description", …], …]`; Google
/// adds a fifth element with a `google:suggesttype` list. Entries of type `NAVIGATION` are pages:
/// the suggestion element holds the URL and the description element the page title (plan B128,
/// "githu" → "https://github.com/" / "How people build software · GitHub"); every other type
/// (queries, entities, personal results) is read as a phrase, and non-query entries without a URL
/// are dropped. An XSSI guard line (`)]}'`) before the JSON is skipped.
public enum SearchSuggestionParser {
    /// Suggestions in the service's order, trimmed, without empties, duplicates (case-insensitive
    /// and by URL) and the query itself (query rows only; a navigation row to a page the query
    /// already spells out is kept). Empty when the data is not in the format.
    public static func completions(from data: Data, query: String) -> [SearchSuggestion] {
        var body = data
        if let text = String(data: data, encoding: .utf8), text.hasPrefix(")]}'"),
           let newline = text.firstIndex(of: "\n") {
            body = Data(text[text.index(after: newline)...].utf8)
        }
        guard let array = (try? JSONSerialization.jsonObject(with: body)) as? [Any], array.count >= 2,
              let raw = array[1] as? [Any] else { return [] }
        var descriptions: [String] = []
        if array.count >= 3, let list = array[2] as? [Any] {
            descriptions = list.map { ($0 as? String) ?? "" }
        }
        var types: [String]?
        if array.count >= 5, let extras = array[4] as? [String: Any] {
            types = extras["google:suggesttype"] as? [String]
        }
        let folded = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var out: [SearchSuggestion] = []
        for (index, item) in raw.enumerated() {
            guard let text = (item as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            let type = types.flatMap { index < $0.count ? $0[index] : nil }
            if type == "NAVIGATION" {
                guard let url = navigationURL(text) else { continue }
                let title = index < descriptions.count ? descriptions[index].trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let key = "u:" + url.absoluteString.lowercased()
                guard seen.insert(key).inserted else { continue }
                out.append(SearchSuggestion(text: title.isEmpty ? (url.host ?? text) : title, url: url))
                continue
            }
            if let type, type != "QUERY" { continue }
            let key = text.lowercased()
            guard key != folded, seen.insert(key).inserted else { continue }
            out.append(SearchSuggestion(text: text))
        }
        return out
    }

    /// The suggestions without navigation rows (`EngineAutocomplete.searchSuggestions`).
    public static func suggestions(from data: Data, query: String) -> [String] {
        completions(from: data, query: query).filter { !$0.isNavigation }.map(\.text)
    }

    /// The page of a navigation entry: an absolute http(s) URL only.
    private static func navigationURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", !(url.host ?? "").isEmpty else { return nil }
        return url
    }
}
