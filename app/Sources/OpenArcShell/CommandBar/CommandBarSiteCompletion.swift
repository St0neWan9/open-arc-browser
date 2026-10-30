import Foundation
import OpenArcEngine

// Site suggestions and the inline completion of the command bar (plan B128).
//
// Spec: docs/arc-spec/05-surfaces.md §命令栏 and 07-design-system.md §5 (Arc observed 2026-10-30 in
// a Space with no picked color, "weather" typed into ⌘T):
//   - the field completes inline: "weather" followed by a selected ".com", the leading glyph is the
//     site's favicon;
//   - the first row is that site, "Weather.com — weather.com" with its favicon, highlighted;
//   - the second row is the plain search "weather";
//   - the search service's navigation suggestion "National Weather Service — weather.gov" (favicon)
//     sits among the query suggestions "weather radar" and "weather tomorrow";
//   - ↓ moves to the search row: the completion goes away (the field shows "weather") and the
//     glyph goes back to the magnifier.
// The rules below (which site wins, the minimum prefix length, ordering) are inferred.

/// A site the bar knows and may complete a typed prefix to: a most visited page or a navigation
/// suggestion of the search service. [05 §命令栏] observed that both produce site rows.
public struct CommandBarSiteCandidate: Hashable, Sendable {
    /// The page the row opens.
    public var url: URL
    /// The page's title, shown before "— host".
    public var title: String
    /// The host without "www.", as the row's second half shows it.
    public var host: String
    /// How well the site is known, 0...1 (a most visited page's frecency; a navigation suggestion
    /// keeps a high value). inferred.
    public var strength: Double
    /// The producer's own order (breaks ties deterministically).
    public var sourceOrder: Int

    public init(url: URL, title: String, host: String, strength: Double = 0, sourceOrder: Int = 0) {
        self.url = url
        self.title = title
        self.host = host
        self.strength = strength
        self.sourceOrder = sourceOrder
    }
}

/// The inline completion shown in the field: the typed text plus a suffix the field selects, so
/// typing replaces it and Backspace removes it. [05 §命令栏] observed.
public struct CommandBarInlineCompletion: Hashable, Sendable {
    /// What the user typed (the field's text before the completion).
    public var typedText: String
    /// The whole text the field shows while the completion is up ("weather.com").
    public var completedText: String
    /// The selected part ("com").
    public var suffix: String
    /// The site row the completion belongs to.
    public var resultID: String

    public init(typedText: String, completedText: String, suffix: String, resultID: String) {
        self.typedText = typedText
        self.completedText = completedText
        self.suffix = suffix
        self.resultID = resultID
    }

    /// The range the field selects: everything after the typed text.
    public var selectedRange: NSRange {
        NSRange(location: (typedText as NSString).length, length: (suffix as NSString).length)
    }
}

/// The pure rules of the site row and its inline completion.
public enum CommandBarSiteCompletionRules {
    /// Shortest typed text that completes to a site. inferred: Arc's field already completed
    /// "weather"; a single letter would complete almost every site.
    public static let minimumPrefixLength = 2

    /// The host to complete `typed` to, or nil when it cannot complete.
    ///
    /// `typed` must be at least `minimumPrefixLength` characters, hold no whitespace and no
    /// `/ ? # :` (the user is typing a site name, not a path or a URL), and be a case-insensitive,
    /// proper prefix of `host` (a full host is not completed again). "weather" + "weather.com" →
    /// "weather.com"; "weather.com" → nil. inferred.
    public static func completedHost(forTyped typed: String, host: String) -> String? {
        guard typed.count >= minimumPrefixLength, host.count > typed.count else { return nil }
        guard !typed.contains(where: { $0.isWhitespace || "/?#:".contains($0) }) else { return nil }
        let foldedTyped = CommandBarTextNormalizer.fold(typed)
        let foldedHost = CommandBarTextNormalizer.fold(host)
        // Folding must not change the length, or the selected suffix would land off by one.
        guard foldedTyped.count == typed.count, foldedHost.count == host.count,
              foldedHost.hasPrefix(foldedTyped) else { return nil }
        return host
    }

    /// The best known site that `typed` completes to: the strongest first (a frequently visited
    /// page before a suggestion), then the shorter host, then the producer's order and the URL.
    /// inferred.
    public static func bestCandidate(
        forTyped typed: String,
        candidates: [CommandBarSiteCandidate]
    ) -> (candidate: CommandBarSiteCandidate, completedHost: String)? {
        let matches: [(CommandBarSiteCandidate, String)] = candidates.compactMap { candidate in
            guard let host = completedHost(forTyped: typed, host: candidate.host) else { return nil }
            return (candidate, host)
        }
        guard let best = matches.sorted(by: { lhs, rhs in
            if lhs.0.strength != rhs.0.strength { return lhs.0.strength > rhs.0.strength }
            if lhs.0.host.count != rhs.0.host.count { return lhs.0.host.count < rhs.0.host.count }
            if lhs.0.sourceOrder != rhs.0.sourceOrder { return lhs.0.sourceOrder < rhs.0.sourceOrder }
            return lhs.0.url.absoluteString < rhs.0.url.absoluteString
        }).first else { return nil }
        return (best.0, best.1)
    }

    /// The completion kept while the user types along it: "weather" + ".com", then "weather."
    /// keeps "com" selected until the new list arrives (so the field does not flicker). nil when
    /// the new text leaves the completed text or reaches its end. inferred.
    public static func carriedCompletion(_ completion: CommandBarInlineCompletion?, typed: String) -> CommandBarInlineCompletion? {
        guard let completion, typed.count > completion.typedText.count,
              typed.count < completion.completedText.count,
              CommandBarTextNormalizer.fold(completion.completedText).hasPrefix(CommandBarTextNormalizer.fold(typed)) else { return nil }
        // Keep the user's own letters and the completion's remaining tail.
        let tail = String(completion.completedText.dropFirst(typed.count))
        return CommandBarInlineCompletion(
            typedText: typed,
            completedText: typed + tail,
            suffix: tail,
            resultID: completion.resultID
        )
    }

    /// The inline completion for the ranked list: only while the first row is the completing site
    /// row, it is selected and its host starts with the typed text. [05 §命令栏] observed: leaving
    /// the first row clears the completion. inferred: a typed text with surrounding spaces does
    /// not complete.
    public static func inlineCompletion(
        text: String,
        selectedIndex: Int,
        results: [CommandBarResult]
    ) -> CommandBarInlineCompletion? {
        guard selectedIndex == 0, let first = results.first, first.kind == .siteCompletion,
              text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let host = first.url.flatMap(CommandBarTextNormalizer.host),
              let completed = completedHost(forTyped: text, host: host) else { return nil }
        // The user's letters stay as typed; only the suffix comes from the host.
        let suffix = String(completed.dropFirst(text.count))
        return CommandBarInlineCompletion(
            typedText: text,
            completedText: text + suffix,
            suffix: suffix,
            resultID: first.id
        )
    }
}

/// Turns the engine's pages into known sites (plan B128). inferred throughout: the spec records
/// only that a typed prefix of a known site completes to it ([05 §命令栏] observed).
public enum CommandBarKnownSites {
    /// Strength floor of a most visited page. inferred (above a navigation suggestion's
    /// `CommandBarWebSuggestionsSource.navigationStrength`: a site the user goes to beats one the
    /// search service proposes).
    public static let topSiteMinimumStrength = 0.6

    /// One candidate per host (without "www."), from the most visited pages and the history pages
    /// of the typed text:
    /// - the row opens the site's root page; its title is the root page's stored title when the
    ///   profile visited it, else the host;
    /// - its strength is the best frecency of the host's pages (a most visited page counts at
    ///   least `topSiteMinimumStrength`, since the engine already ranks it as a habit);
    /// - only http(s) pages count.
    public static func candidates(history: [HistoryMatch], topSites: [HistoryMatch], now: Date) -> [CommandBarSiteCandidate] {
        struct Site {
            var root: URL
            var rootTitle: String?
            var strength: Double
            var order: Int
        }
        var sites: [String: Site] = [:]
        var order = 0
        func add(_ page: HistoryMatch, minimum: Double) {
            guard let scheme = page.url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let rawHost = page.url.host?.lowercased(), !rawHost.isEmpty,
                  let host = CommandBarTextNormalizer.host(page.url),
                  let root = URL(string: "\(scheme)://\(rawHost)/") else { return }
            let strength = max(page.frecency(at: now), minimum)
            let isRoot = page.url.path.isEmpty || page.url.path == "/"
            let title = page.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if sites[host] == nil {
                sites[host] = Site(root: root, rootTitle: nil, strength: 0, order: order)
                order += 1
            }
            sites[host]!.strength = max(sites[host]!.strength, strength)
            if isRoot, !title.isEmpty, sites[host]!.rootTitle == nil {
                sites[host]!.rootTitle = title
                sites[host]!.root = root
            }
        }
        for page in topSites { add(page, minimum: topSiteMinimumStrength) }
        for page in history { add(page, minimum: 0) }
        return sites
            .map { host, site in
                CommandBarSiteCandidate(url: site.root, title: site.rootTitle ?? host, host: host,
                                        strength: site.strength, sourceOrder: site.order)
            }
            .sorted { $0.sourceOrder < $1.sourceOrder }
    }
}
