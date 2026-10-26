import Foundation

// Pure ranking of command bar candidates.
//
// EVIDENCE: the spec only shows the UI. Observed: the first row is selected by default; open tabs
// ("Switch to Tab") are listed before other candidates; with no input the list is open tabs and
// ends with an app command such as "Contact the Team" [04 §command bar, 05 §command bar].
// Everything else here is INFERRED, in particular all scores and tie-breaks.

public enum CommandBarRanker {
    /// Open tabs shown for an empty query (the fifth row is the closing command). inferred from the
    /// five-row panel in [04 §command bar].
    public static let emptyQueryTabLimit = 4
    /// Command that closes the empty-query list. [04 §command bar] observed.
    public static let emptyQueryClosingCommand = CommandBarCommand.contactTheTeam

    // Score tiers, inferred. Higher is better.
    enum Score {
        static let exactTitle: Double = 1000
        static let exactURL: Double = 950
        static let typedURL: Double = 900
        static let titlePrefix: Double = 800
        static let urlPrefix: Double = 750
        static let webSearch: Double = 700
        static let titleWordPrefix: Double = 600
        static let keywordCap: Double = 500
        static let titleSubstring: Double = 400
        static let urlSubstring: Double = 300
        static let suggestionBase: Double = 300
        static let allTokens: Double = 250
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
        for candidate in candidates {
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

    /// Score of one candidate for a non-empty query; nil drops the candidate.
    static func score(_ result: CommandBarResult, query: String, context: CommandBarQueryContext) -> Double? {
        switch result.kind {
        case .typedURL:
            return Score.typedURL
        case .webSearch:
            return Score.webSearch
        case .searchSuggestion:
            return Score.suggestionBase - Double(min(result.sourceOrder, 50))
        case .todayTab, .pinnedTab, .favoriteTab:
            guard var value = textScore(query: query, title: result.title, url: result.url) else { return nil }
            if let space = context.currentSpaceID, result.spaceID == space { value += Score.currentSpaceBonus }
            return value
        case .archivedItem:
            guard let value = textScore(query: query, title: result.title, url: result.url) else { return nil }
            return value - Score.archivePenalty
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
    /// - a typed-URL row when a tab or archived item has the same URL (switch to it instead);
    /// - a suggestion equal to the typed text (the search row covers it).
    static func deduplicate(_ sorted: [CommandBarResult], query: String) -> [CommandBarResult] {
        var tabKeys = Set<String>()
        var archivedKeys = Set<String>()
        for result in sorted {
            guard let url = result.url else { continue }
            if result.kind.isTab { tabKeys.insert(CommandBarTextNormalizer.urlKey(url)) }
            if result.kind == .archivedItem { archivedKeys.insert(CommandBarTextNormalizer.urlKey(url)) }
        }
        let foldedQuery = CommandBarTextNormalizer.fold(query)
        var seenSuggestions = Set<String>()
        var out: [CommandBarResult] = []
        for result in sorted {
            let key = result.url.map(CommandBarTextNormalizer.urlKey)
            switch result.kind {
            case .archivedItem:
                if let key, tabKeys.contains(key) { continue }
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

    /// Empty query: most recently used open tabs (current space first, never the tab being viewed),
    /// then the closing app command. [04 §command bar] observed shape; ordering inferred.
    static func emptyQueryList(_ candidates: [CommandBarResult], context: CommandBarQueryContext, limit: Int) -> [CommandBarResult] {
        let tabs = candidates
            .filter { result in
                guard result.kind.isTab else { return false }
                if case .switchToTab(let id) = result.action, id == context.currentTabID { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lIn = lhs.spaceID != nil && lhs.spaceID == context.currentSpaceID
                let rIn = rhs.spaceID != nil && rhs.spaceID == context.currentSpaceID
                if lIn != rIn { return lIn }
                return tieBreak(lhs, rhs)
            }
        var list = Array(tabs.prefix(emptyQueryTabLimit))
        if let closing = candidates.first(where: { $0.action == .runCommand(emptyQueryClosingCommand) }) {
            list.append(closing)
        }
        return Array(list.prefix(max(0, limit)))
    }
}
