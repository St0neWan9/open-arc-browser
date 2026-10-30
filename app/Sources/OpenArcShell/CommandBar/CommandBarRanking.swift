import Foundation

// Pure ranking of command bar candidates.
//
// EVIDENCE: the spec only shows the UI. Observed: the first row is selected by default; open tabs
// ("Switch to Tab") are listed before other candidates; with no input the list is open tabs and
// ends with an app command such as "Contact the Team" [04 §command bar, 05 §command bar].
// Everything else here is INFERRED, in particular all scores and tie-breaks. For a typed query
// (plan B66): matching open tabs first, then the typed URL / "search for" row, archived items, app
// commands and browsing history pages by match strength (a history page below an open tab or
// archived item of the same match, raised by its frecency), and the engine's search suggestions
// last, in the engine's order ([06 §16.2, §19.1, §23] observed: a word with no matching command
// lists search suggestions). Most visited pages (plan B121, [05 §command bar] inferred (analysis))
// join an empty or short query: after the open tabs, before the app commands (inferred).

public enum CommandBarRanker {
    /// Open tabs shown for an empty query (the fifth row is the closing command). inferred from the
    /// five-row panel in [04 §command bar].
    public static let emptyQueryTabLimit = 4
    /// Command that closes the empty-query list. [04 §command bar] observed.
    public static let emptyQueryClosingCommand = CommandBarCommand.contactTheTeam
    /// Most visited pages shown for an empty query, after the open tabs (plan B121). They only take
    /// the open-tab slots left free, so the observed five-row shape holds. inferred.
    public static let emptyQueryTopSiteLimit = 3

    // Score tiers, inferred. Higher is better.
    enum Score {
        static let exactTitle: Double = 1000
        static let exactURL: Double = 950
        static let typedURL: Double = 900
        static let titlePrefix: Double = 800
        static let urlPrefix: Double = 750
        static let webSearch: Double = 700
        /// A site suggestion whose host starts with the typed text (plan B128): above the plain
        /// search row and the query suggestions, below a matching open tab or a typed URL. Arc
        /// observed the completed site as the first row with the plain search second
        /// ([05 §命令栏] observed); the score itself is inferred.
        static let sitePrefix: Double = 780
        /// Site completion rows rise with how well the site is known (frecency 0...1), staying
        /// below a title-prefix match of an open tab. inferred.
        static let siteStrengthWeight: Double = 10
        static let titleWordPrefix: Double = 600
        static let keywordCap: Double = 500
        static let titleSubstring: Double = 400
        static let urlSubstring: Double = 300
        static let suggestionBase: Double = 300
        static let allTokens: Double = 250
        /// Browsing history rows (plan B66) rank below an open tab or archived item of the same
        /// match tier (open tabs first, [05 §command bar] observed), then rise with the page's
        /// frecency, and never fall below web suggestions (pages the user visited before generic
        /// suggestions). All three values inferred.
        static let historyPenalty: Double = 150
        static let historyFrecencyWeight: Double = 60
        static let historyFloor: Double = 305
        static let archivePenalty: Double = 100
        static let currentSpaceBonus: Double = 10
        /// App commands and space rows never outrank an exact tab match (exact title or URL):
        /// open tabs come first [05 §command bar] observed; the cap itself is inferred.
        static let commandCap: Double = 940
        /// ... and always outrank web search suggestions (inferred): every matching command or
        /// space row scores at least this, above the best suggestion (`suggestionBase`).
        static let commandFloor: Double = 310
        /// A "Move Tab to “X”" row ranks below the "Go to “X”" row of the same match. inferred.
        static let moveByNamePenalty: Double = 20
    }

    /// Ranks candidates for a query.
    public static func rank(_ candidates: [CommandBarResult], context: CommandBarQueryContext, limit: Int = 20) -> [CommandBarResult] {
        let query = context.trimmedText
        if query.isEmpty { return emptyQueryList(candidates, context: context, limit: limit) }

        struct Scored {
            var result: CommandBarResult
            var score: Double
        }
        var scored: [Scored] = []
        for candidate in singleSiteCompletion(candidates) {
            if let score = score(candidate, query: query, context: context) {
                scored.append(Scored(result: candidate, score: score))
            }
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return tieBreak(lhs.result, rhs.result)
        }
        let deduped = deduplicate(scored.map(\.result), query: query)
        return Array(deduped.prefix(max(0, limit)))
    }

    /// Keeps one completing site row (plan B128): the best known one (strength, then a known site
    /// before a suggested one, then source order); every other completing row becomes a plain site
    /// suggestion. Arc listed "National Weather Service — weather.gov" as a site row below
    /// "Weather.com — weather.com", though "weather" starts both hosts ([05 §命令栏] observed); the
    /// choice is inferred.
    static func singleSiteCompletion(_ candidates: [CommandBarResult]) -> [CommandBarResult] {
        let completing = candidates.indices.filter { candidates[$0].kind == .siteCompletion }
        guard completing.count > 1 else { return candidates }
        let keep = completing.min { l, r in
            let a = candidates[l], b = candidates[r]
            if a.frecency != b.frecency { return a.frecency > b.frecency }
            let aKnown = a.id.hasPrefix("site:"), bKnown = b.id.hasPrefix("site:")
            if aKnown != bKnown { return aKnown }
            if a.sourceOrder != b.sourceOrder { return a.sourceOrder < b.sourceOrder }
            return a.id < b.id
        }
        var out = candidates
        for index in completing where index != keep {
            out[index].kind = .siteSuggestion
            if let url = out[index].url { out[index].completion = url.absoluteString }
        }
        return out
    }

    /// Score of one candidate for a non-empty query; nil drops the candidate.
    static func score(_ result: CommandBarResult, query: String, context: CommandBarQueryContext) -> Double? {
        switch result.kind {
        case .typedURL:
            return Score.typedURL
        case .webSearch:
            return Score.webSearch
        case .searchSuggestion:
            return Score.suggestionBase - Double(min(result.sourceOrder, 50))
        case .siteCompletion:
            // A typed text that already reads as an address ("weather.co") completes to the site
            // ahead of opening it as typed. inferred.
            let base: Double
            if case .url = CommandBarInputClassifier.classify(query) { base = Score.typedURL + 5 } else { base = Score.sitePrefix }
            return base + Score.siteStrengthWeight * min(max(result.frecency, 0), 1)
        case .siteSuggestion:
            // A navigation suggestion sits among the query suggestions in the service's order
            // (Arc: "National Weather Service — weather.gov" among "weather radar" and "weather
            // tomorrow", [05 §命令栏] observed); keeping the service's order is inferred.
            return Score.suggestionBase - Double(min(result.sourceOrder, 50))
        case .todayTab, .pinnedTab, .favoriteTab:
            guard var value = textScore(query: query, title: result.title, url: result.url) else { return nil }
            if let space = context.currentSpaceID, result.spaceID == space { value += Score.currentSpaceBonus }
            return value
        case .archivedItem:
            guard let value = textScore(query: query, title: result.title, url: result.url) else { return nil }
            return value - Score.archivePenalty
        case .historyItem, .topSite:
            // A most visited page of a short query scores like a history page (plan B121, inferred).
            guard let value = textScore(query: query, title: result.title, url: result.url) else { return nil }
            let frecency = min(max(result.frecency, 0), 1)
            return max(value - Score.historyPenalty + Score.historyFrecencyWeight * frecency, Score.historyFloor)
        case .command:
            var best = textScore(query: query, title: result.title, url: nil)
            if case .runCommand(let command) = result.action {
                for keyword in command.keywords {
                    if let value = textScore(query: query, title: keyword, url: nil) {
                        best = max(best ?? 0, min(value, Score.keywordCap))
                    }
                }
            }
            return clampCommand(best)
        case .space:
            return clampCommand(bestScore(query: query, texts: [result.title, result.spaceName ?? ""] + result.matchTexts))
        case .moveTabToSpace:
            // Always below the "Go to" row of the same space. inferred.
            let best = bestScore(query: query, texts: [result.title, result.spaceName ?? ""] + result.matchTexts)
            return clampCommand(best.map { $0 - Score.moveByNamePenalty }, cap: Score.commandCap - Score.moveByNamePenalty)
        }
    }

    /// Best text score over several titles, nil when none matches.
    private static func bestScore(query: String, texts: [String]) -> Double? {
        texts.filter { !$0.isEmpty }.compactMap { textScore(query: query, title: $0, url: nil) }.max()
    }

    /// Keeps a command or space score between web suggestions and exact tab matches. inferred.
    private static func clampCommand(_ score: Double?, cap: Double = Score.commandCap) -> Double? {
        score.map { min(max($0, Score.commandFloor), cap) }
    }

    /// Text match score of a title/URL pair against a query, or nil when there is no match.
    /// Order: exact title > exact URL/host > title prefix > URL prefix > word prefix in title >
    /// title substring > URL substring > every query word found somewhere. inferred.
    public static func textScore(query rawQuery: String, title rawTitle: String, url: URL?) -> Double? {
        let query = CommandBarTextNormalizer.fold(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !query.isEmpty else { return nil }
        let title = CommandBarTextNormalizer.fold(rawTitle)
        let queryKey = CommandBarTextNormalizer.urlKey(query)
        var urlKey = ""
        var host = ""
        if let url {
            urlKey = CommandBarTextNormalizer.urlKey(url)
            host = CommandBarTextNormalizer.host(url) ?? ""
        }

        if title == query { return Score.exactTitle }
        if !urlKey.isEmpty, (urlKey == queryKey || host == queryKey) { return Score.exactURL }
        if title.hasPrefix(query) { return Score.titlePrefix }
        if !urlKey.isEmpty, (urlKey.hasPrefix(queryKey) || host.hasPrefix(queryKey)) { return Score.urlPrefix }
        if title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) {
            return Score.titleWordPrefix
        }
        if title.contains(query) { return Score.titleSubstring }
        if !urlKey.isEmpty, urlKey.contains(queryKey) { return Score.urlSubstring }
        let tokens = query.split(whereSeparator: \.isWhitespace)
        if tokens.count > 1 {
            let haystack = title + " " + urlKey
            if tokens.allSatisfy({ haystack.contains($0) }) { return Score.allTokens }
        }
        return nil
    }

    /// Deterministic ordering for equal scores: recency, then shorter title, then source order, then id.
    private static func tieBreak(_ lhs: CommandBarResult, _ rhs: CommandBarResult) -> Bool {
        let l = lhs.lastActiveAt ?? .distantPast
        let r = rhs.lastActiveAt ?? .distantPast
        if l != r { return l > r }
        if lhs.title.count != rhs.title.count { return lhs.title.count < rhs.title.count }
        if lhs.sourceOrder != rhs.sourceOrder { return lhs.sourceOrder < rhs.sourceOrder }
        return lhs.id < rhs.id
    }

    /// Drops rows that duplicate a better row (input is already sorted best first):
    /// - an archived item with the URL of an open tab;
    /// - a history page with the URL of an open tab, an archived item or the typed URL;
    /// - a most visited page with the URL of an open tab, an archived item, the typed URL, a
    ///   history row or a better ranked most visited row (B121);
    /// - a typed-URL row when a tab or archived item has the same URL (switch to it instead);
    /// - a suggestion equal to the typed text (the search row covers it).
    static func deduplicate(_ sorted: [CommandBarResult], query: String) -> [CommandBarResult] {
        var tabKeys = Set<String>()
        var archivedKeys = Set<String>()
        var typedKeys = Set<String>()
        var historyKeys = Set<String>()
        var siteKeys = Set<String>()
        for result in sorted {
            guard let url = result.url else { continue }
            if result.kind.isTab { tabKeys.insert(CommandBarTextNormalizer.urlKey(url)) }
            if result.kind == .archivedItem { archivedKeys.insert(CommandBarTextNormalizer.urlKey(url)) }
            if result.kind == .typedURL { typedKeys.insert(CommandBarTextNormalizer.urlKey(url)) }
            if result.kind == .historyItem { historyKeys.insert(CommandBarTextNormalizer.urlKey(url)) }
            if result.kind == .siteCompletion || result.kind == .siteSuggestion {
                siteKeys.insert(CommandBarTextNormalizer.urlKey(url))
            }
        }
        let foldedQuery = CommandBarTextNormalizer.fold(query)
        var seenSuggestions = Set<String>()
        var seenTopSites = Set<String>()
        var seenSiteKeys = Set<String>()
        var out: [CommandBarResult] = []
        for result in sorted {
            let key = result.url.map(CommandBarTextNormalizer.urlKey)
            switch result.kind {
            case .archivedItem:
                if let key, tabKeys.contains(key) { continue }
            case .historyItem:
                // A visited page that is open, archived, exactly what was typed or already shown as
                // a site row has its row already (switch / restore / open). inferred (B66, B128).
                if let key, tabKeys.contains(key) || archivedKeys.contains(key) || typedKeys.contains(key) || siteKeys.contains(key) { continue }
            case .siteCompletion, .siteSuggestion:
                // An open or archived page has its tab row; one site row per page (B128).
                if let key, tabKeys.contains(key) || archivedKeys.contains(key) || !seenSiteKeys.insert(key).inserted { continue }
            case .topSite:
                if let key, tabKeys.contains(key) || archivedKeys.contains(key) || typedKeys.contains(key) || historyKeys.contains(key) || siteKeys.contains(key) { continue }
                if let key, !seenTopSites.insert(key).inserted { continue }
            case .typedURL:
                if let key, tabKeys.contains(key) || archivedKeys.contains(key) { continue }
            case .searchSuggestion:
                let folded = CommandBarTextNormalizer.fold(result.title)
                if folded == foldedQuery || !seenSuggestions.insert(folded).inserted { continue }
            default:
                break
            }
            out.append(result)
        }
        return out
    }

    /// Empty query: the most recently used open tabs of every Space of the window's profile (the
    /// sources leave other profiles out), never the tab being viewed;
    /// then the profile's most visited pages that are not open, in the tab slots left free (B121);
    /// then the closing app command. [04 §command bar] observed shape (five rows: open tabs, then
    /// an app command); F4 live E2 (2026-10-29) observed tabs of other Spaces in this list (plan
    /// B109; most of its rows were other Spaces' tabs). Ordering by recency across Spaces (the
    /// window's Space only breaks ties; before B109 it came first, which hid the other Spaces) and
    /// the place of the most visited pages are inferred.
    ///
    /// Rows carry no subtitle here: the window's empty list reads the title alone, without
    /// " — domain" (F4 live E2 observed). Little Arc keeps "title — domain" ([06 §7] observed).
    static func emptyQueryList(_ candidates: [CommandBarResult], context: CommandBarQueryContext, limit: Int) -> [CommandBarResult] {
        // The incognito window's bar: the help rows only, no history and no open tabs.
        // [06 §20.1] observed (B61).
        if context.listsHelpOnlyWhenEmpty {
            let help = CommandBarCommand.helpCommands.compactMap { command in
                candidates.first { $0.action == .runCommand(command) }
            }
            return Array(help.prefix(max(0, limit)))
        }
        let tabs = candidates
            .filter { result in
                guard result.kind.isTab else { return false }
                if case .switchToTab(let id) = result.action, id == context.currentTabID { return false }
                return true
            }
            .sorted { lhs, rhs in
                let l = lhs.lastActiveAt ?? .distantPast
                let r = rhs.lastActiveAt ?? .distantPast
                if l != r { return l > r }
                let lIn = lhs.spaceID != nil && lhs.spaceID == context.currentSpaceID
                let rIn = rhs.spaceID != nil && rhs.spaceID == context.currentSpaceID
                if lIn != rIn { return lIn }
                return tieBreak(lhs, rhs)
            }
        var list = Array(tabs.prefix(emptyQueryTabLimit))
        // Most visited pages that are not open tabs, in the engine's order (B121).
        let openKeys = Set(candidates.filter(\.kind.isTab).compactMap { $0.url.map(CommandBarTextNormalizer.urlKey) })
        var seen = Set<String>()
        let topSites = candidates
            .filter { $0.kind == .topSite }
            .sorted { $0.sourceOrder < $1.sourceOrder }
            .filter { row in
                guard let key = row.url.map(CommandBarTextNormalizer.urlKey) else { return false }
                return !openKeys.contains(key) && seen.insert(key).inserted
            }
        list += topSites.prefix(min(emptyQueryTopSiteLimit, max(0, emptyQueryTabLimit - list.count)))
        if let closing = candidates.first(where: { $0.action == .runCommand(emptyQueryClosingCommand) }) {
            list.append(closing)
        }
        if context.presentation != .littleArc {
            for index in list.indices { list[index].subtitle = nil }
        }
        return Array(list.prefix(max(0, limit)))
    }
}
