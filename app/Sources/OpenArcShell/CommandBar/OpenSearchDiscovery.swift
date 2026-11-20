import Foundation
import OpenArcModel
import OpenArcEngine

// Sites' own search engines for "Tab to Search" (plan B233, user 2026-11-16: the known gap "Sites'
// own search engines (OpenSearch) are not picked up automatically").
//
// Arc's keyword list comes from Chromium's TemplateURLService, which adds a site when one of its
// pages links an OpenSearch description (`<link rel="search"
// type="application/opensearchdescription+xml">`). Our bridge does not expose that service and the
// detection needs a TabInterface on Chromium 157 (plan C36), so the shell does it itself:
// - after a page of a normal (not off-the-record) window finishes loading, it reads the page's
//   OpenSearch link;
// - it fetches the description from the page's own site only (no cookies, ≤ 64 KB), and keeps
//   the site's name and its HTML search URL when the URL is http(s) on that site and has
//   `{searchTerms}`;
// - each host is tried once per run; the sites found are kept on this device (`AppPreferences`).
// The command bar offers them after its built-in sites. Everything here is inferred (Chromium's
// documented behavior, not Arc observations).

/// What an OpenSearch description document says about searching a site.
public struct OpenSearchDescription: Equatable, Sendable {
    public var shortName: String
    /// The `text/html` search URL template, `{searchTerms}` and all.
    public var template: String

    /// Reads `<ShortName>` and the first `<Url type="text/html" template="…">`; nil when either is
    /// missing.
    public static func parse(_ data: Data) -> OpenSearchDescription? {
        let delegate = Reader()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        let name = delegate.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let template = delegate.htmlTemplate else { return nil }
        return OpenSearchDescription(shortName: name, template: template)
    }

    /// The search URL template in the command bar's form (`%@` for the query), when it is an
    /// http(s) URL on `pageURL`'s site with `{searchTerms}`. Optional parameters (`{x?}`) are
    /// dropped; any other required parameter makes it unusable.
    public func searchTemplate(forPage pageURL: URL) -> String? {
        guard template.contains("{searchTerms}") else { return nil }
        var text = template.replacingOccurrences(of: "{searchTerms}", with: "\u{1}")
        // Optional parameters: empty. A required one we cannot fill: give up.
        while let open = text.range(of: "{"), let close = text.range(of: "}", range: open.upperBound..<text.endIndex) {
            let name = text[open.upperBound..<close.lowerBound]
            guard name.hasSuffix("?") else { return nil }
            text.removeSubrange(open.lowerBound..<close.upperBound)
        }
        guard let url = URL(string: text.replacingOccurrences(of: "\u{1}", with: "QUERY")),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              FaviconCache.isSameSite(url, pageURL) else { return nil }
        guard !text.contains("%@") else { return nil }
        return text.replacingOccurrences(of: "\u{1}", with: "%@")
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var shortName = ""
        var htmlTemplate: String?
        private var inShortName = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if local == "ShortName" { inShortName = true }
            if local == "Url", htmlTemplate == nil, (attributes["type"] ?? "").lowercased() == "text/html",
               let template = attributes["template"], !template.isEmpty {
                htmlTemplate = template
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            if (elementName.split(separator: ":").last.map(String.init) ?? elementName) == "ShortName" { inShortName = false }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inShortName { shortName += string }
        }
    }
}

/// The sites found through OpenSearch descriptions, kept on this device.
@MainActor
public final class OpenSearchDiscovery {
    /// Script that returns the page's OpenSearch link (absolute) as text, or nothing.
    static let linkScript = """
    (() => { const l = document.querySelector('link[rel~="search"][type="application/opensearchdescription+xml"][href]'); \
    return l ? l.href : null; })()
    """
    /// Largest description we read. inferred.
    nonisolated static let maxDescriptionBytes = 64 * 1024
    /// Most sites kept; the oldest go first. inferred.
    static let maxSites = 200
    static let preferencesKey = "\(AppPreferences.keyPrefix)commandBar.openSearchSites"

    /// Downloads a description. Tests replace it.
    var fetch: @Sendable (URL) async -> Data? = { url in await OpenSearchDiscovery.download(url) }

    private let preferences: AppPreferences
    private(set) public var sites: [CommandBarSearchSite]
    /// Hosts tried in this run (found or not).
    private var tried: Set<String> = []

    public init(preferences: AppPreferences) {
        self.preferences = preferences
        sites = Self.decode(preferences.stringValue(Self.preferencesKey))
    }

    /// A page of a normal window finished loading: look for its OpenSearch description once per
    /// host. `evaluate` runs script in the page.
    func pageLoaded(_ pageURL: URL?, evaluate: @escaping @MainActor (String) async -> String?) {
        guard let pageURL, let scheme = pageURL.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = Self.bareHost(pageURL), tried.insert(host).inserted,
              !CommandBarSearchSites.builtIn.contains(where: { $0.host == host }),
              !sites.contains(where: { $0.host == host }) else { return }
        Task { @MainActor [weak self] in
            guard let href = await evaluate(Self.linkScript), let descriptionURL = URL(string: href),
                  let descriptionScheme = descriptionURL.scheme?.lowercased(),
                  descriptionScheme == "https" || descriptionScheme == "http",
                  FaviconCache.isSameSite(descriptionURL, pageURL),
                  let fetch = self?.fetch, let data = await fetch(descriptionURL),
                  data.count <= Self.maxDescriptionBytes,
                  let description = OpenSearchDescription.parse(data),
                  let template = description.searchTemplate(forPage: pageURL) else { return }
            self?.add(CommandBarSearchSite(id: "opensearch:\(host)", name: description.shortName, host: host,
                                           searchURLTemplate: template))
        }
    }

    func add(_ site: CommandBarSearchSite) {
        sites.removeAll { $0.host == site.host }
        sites.append(site)
        if sites.count > Self.maxSites { sites.removeFirst(sites.count - Self.maxSites) }
        preferences.setString(Self.encode(sites), Self.preferencesKey)
    }

    static func bareHost(_ url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    private struct Stored: Codable {
        var name: String
        var host: String
        var template: String
    }

    static func encode(_ sites: [CommandBarSearchSite]) -> String {
        let stored = sites.map { Stored(name: $0.name, host: $0.host, template: $0.searchURLTemplate) }
        return (try? String(data: JSONEncoder().encode(stored), encoding: .utf8)) ?? "[]"
    }

    static func decode(_ text: String?) -> [CommandBarSearchSite] {
        guard let data = text?.data(using: .utf8), let stored = try? JSONDecoder().decode([Stored].self, from: data) else { return [] }
        return stored.map { CommandBarSearchSite(id: "opensearch:\($0.host)", name: $0.name, host: $0.host, searchURLTemplate: $0.template) }
    }

    /// An ephemeral GET (no cookies, no cache), at most `maxDescriptionBytes + 1` bytes kept.
    nonisolated static func download(_ url: URL) async -> Data? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (bytes, response) = try? await session.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxDescriptionBytes { return nil }
            }
        } catch { return nil }
        return data
    }
}
