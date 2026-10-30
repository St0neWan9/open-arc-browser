import Foundation
import OpenArcModel

// "Tab to Search" in the command bar (plan B133).
//
// Spec: docs/arc-spec/05-surfaces.md §命令栏, E30 (2026-10-31, observed in Arc, ⌘T bar):
//   - while the typed text matches a site that has a search keyword, the field's right side shows
//     "Search YouTube Tab" / "Search Wikipedia Tab" ("yout" → YouTube, "w" → Wikipedia);
//   - Tab turns the field into a site search: a red "YouTube" chip on the left of the field, the
//     placeholder "Search…", and no result rows.
//
// Where the keywords come from: Arc's list comes from the engine (Chromium keeps keyword search
// engines in its TemplateURLService). Our bridge does not expose that service
// (`OACAutocomplete.h`: the search engine choice lives in the shell's model), so this file ships a
// small built-in list of common sites. Everything in the list (sites, search URLs, colors) and the
// matching rules below are inferred. Follow-up: read the engine's keyword list through the bridge.

/// A site the command bar can search directly ("Tab to Search").
public struct CommandBarSearchSite: Hashable, Sendable, Identifiable {
    /// Our own id (not persisted).
    public var id: String
    /// The name the hint and the chip show ("YouTube").
    public var name: String
    /// The site's host without "www." ("youtube.com"); typing a prefix of it matches too.
    public var host: String
    /// Search URL; `%@` is replaced by the escaped query.
    public var searchURLTemplate: String
    /// The chip's fill: the site's brand color, nil when we know none (the chip then takes the
    /// theme's selection color). inferred.
    public var brandColor: RGBAColor?

    public init(id: String, name: String, host: String, searchURLTemplate: String, brandColor: RGBAColor? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.searchURLTemplate = searchURLTemplate
        self.brandColor = brandColor
    }

    /// The hint at the field's right end: "Search <Site>" (the "Tab" key cap is drawn apart).
    /// [05 §命令栏] E30 observed wording.
    public var hintTitle: String { "Search \(name)" }

    /// The page that searches the site for `query`; nil for an empty query.
    public func searchURL(for query: String) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let escaped = trimmed.addingPercentEncoding(withAllowedCharacters: CommandBarSearchSites.queryAllowed) else { return nil }
        return URL(string: searchURLTemplate.replacingOccurrences(of: "%@", with: escaped))
    }

    /// The site's home page (used to look up its icon).
    public var homeURL: URL? { URL(string: "https://\(host)/") }
}

/// The built-in sites and the matching rules. inferred throughout (see the file header).
public enum CommandBarSearchSites {
    /// The built-in list, in match priority order (the first site whose keyword starts with the
    /// typed text wins). Brand colors are the sites' public brand colors (inferred); YouTube's red
    /// chip with white text is [05 §命令栏] E30 observed.
    public static let builtIn: [CommandBarSearchSite] = [
        CommandBarSearchSite(id: "youtube", name: "YouTube", host: "youtube.com",
                             searchURLTemplate: "https://www.youtube.com/results?search_query=%@",
                             brandColor: RGBAColor(hex: 0xFF0000)),
        CommandBarSearchSite(id: "wikipedia", name: "Wikipedia", host: "wikipedia.org",
                             searchURLTemplate: "https://en.wikipedia.org/wiki/Special:Search?search=%@"),
        CommandBarSearchSite(id: "google", name: "Google", host: "google.com",
                             searchURLTemplate: "https://www.google.com/search?q=%@",
                             brandColor: RGBAColor(hex: 0x4285F4)),
        CommandBarSearchSite(id: "amazon", name: "Amazon", host: "amazon.com",
                             searchURLTemplate: "https://www.amazon.com/s?k=%@",
                             brandColor: RGBAColor(hex: 0x232F3E)),
        CommandBarSearchSite(id: "github", name: "GitHub", host: "github.com",
                             searchURLTemplate: "https://github.com/search?q=%@",
                             brandColor: RGBAColor(hex: 0x24292F)),
        CommandBarSearchSite(id: "reddit", name: "Reddit", host: "reddit.com",
                             searchURLTemplate: "https://www.reddit.com/search/?q=%@",
                             brandColor: RGBAColor(hex: 0xFF4500)),
        CommandBarSearchSite(id: "stackoverflow", name: "Stack Overflow", host: "stackoverflow.com",
                             searchURLTemplate: "https://stackoverflow.com/search?q=%@",
                             brandColor: RGBAColor(hex: 0xF48024)),
        CommandBarSearchSite(id: "duckduckgo", name: "DuckDuckGo", host: "duckduckgo.com",
                             searchURLTemplate: "https://duckduckgo.com/?q=%@",
                             brandColor: RGBAColor(hex: 0xDE5833)),
        CommandBarSearchSite(id: "bing", name: "Bing", host: "bing.com",
                             searchURLTemplate: "https://www.bing.com/search?q=%@",
                             brandColor: RGBAColor(hex: 0x008373)),
    ]

    /// Characters a query keeps unescaped: `urlQueryAllowed` minus the ones that split a query.
    static let queryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    /// The site the hint offers for `typed`:
    /// - nothing for an empty text, text with whitespace or `/ ? # :` (a query or a path);
    /// - the site of the inline completion's host when that is a listed site ("yout" completed to
    ///   "youtube.com");
    /// - else the first listed site whose name (spaces removed) or host starts with the text,
    ///   case-insensitively ("yout" → YouTube, "w" → Wikipedia, [05 §命令栏] E30 observed pairs).
    /// One typed character is enough ("w" observed).
    public static func match(
        typed: String,
        completedHost: String? = nil,
        sites: [CommandBarSearchSite] = builtIn
    ) -> CommandBarSearchSite? {
        guard !typed.isEmpty, typed == typed.trimmingCharacters(in: .whitespacesAndNewlines),
              !typed.contains(where: { $0.isWhitespace || "/?#:".contains($0) }) else { return nil }
        if let completedHost {
            let host = bareHost(completedHost)
            if let site = sites.first(where: { $0.host == host }) { return site }
        }
        let folded = CommandBarTextNormalizer.fold(typed)
        return sites.first { site in
            CommandBarTextNormalizer.fold(site.name.replacingOccurrences(of: " ", with: "")).hasPrefix(folded)
                || CommandBarTextNormalizer.fold(site.host).hasPrefix(folded)
        }
    }

    private static func bareHost(_ host: String) -> String {
        let lower = host.lowercased()
        return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
    }
}

extension SearchEngine {
    /// The engine's site (scheme and host of its search URL), whose icon the command bar's field
    /// shows while one character is typed (plan B133, [05 §命令栏] E30 observed Google's "G").
    public var siteURL: URL? {
        guard let components = URLComponents(string: searchURLTemplate.replacingOccurrences(of: "%@", with: "")),
              let scheme = components.scheme, let host = components.host else { return nil }
        return URL(string: "\(scheme)://\(host)/")
    }
}
