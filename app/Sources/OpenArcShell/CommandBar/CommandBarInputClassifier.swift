import Foundation

// URL-versus-search classification of the text typed into the command bar.
// The spec only says the bar is a single entry for new tab, search and commands [05 §command bar];
// every rule below is inferred from common browser behavior.

/// What the typed text means.
public enum CommandBarInputKind: Equatable, Sendable {
    case empty
    case url(URL)
    case search(String)
}

public enum CommandBarInputClassifier {
    /// Schemes accepted when typed explicitly. inferred.
    private static let explicitSchemes: Set<String> = ["http", "https", "file", "ftp", "about"]

    /// Classifies raw field text.
    ///
    /// - Text with whitespace is a search (unless it is empty after trimming).
    /// - An explicit supported scheme (`https://x`) is a URL.
    /// - `localhost`, IPv4 and bracketed IPv6 hosts (optionally with port and path) are URLs; they
    ///   get `http://`.
    /// - A dotted host whose last label is alphabetic (2+ letters) is a URL and gets `https://`.
    /// - Anything else (a bare word, `foo/bar`, `a.`) is a search.
    public static func classify(_ raw: String) -> CommandBarInputKind {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .empty }
        if text.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return .search(text) }

        if let schemeEnd = text.range(of: "://") {
            let scheme = text[text.startIndex..<schemeEnd.lowerBound].lowercased()
            if explicitSchemes.contains(scheme), let url = URL(string: text), url.scheme != nil {
                let hasHost = !(url.host ?? "").isEmpty
                if hasHost || scheme == "file" { return .url(url) }
            }
            return .search(text)
        }
        if text.lowercased() == "about:blank", let url = URL(string: "about:blank") { return .url(url) }

        // Split "host[:port]" from the rest.
        let hostAndPort: Substring
        if let cut = text.firstIndex(where: { "/?#".contains($0) }) {
            hostAndPort = text[text.startIndex..<cut]
        } else {
            hostAndPort = Substring(text)
        }
        guard let (host, _) = splitHost(hostAndPort) else { return .search(text) }

        let lower = host.lowercased()
        let useHTTP: Bool
        if lower == "localhost" || isIPv4(lower) || (lower.hasPrefix("[") && lower.hasSuffix("]")) {
            useHTTP = true
        } else if isDomain(lower) {
            useHTTP = false
        } else {
            return .search(text)
        }
        if let url = URL(string: (useHTTP ? "http://" : "https://") + text) { return .url(url) }
        return .search(text)
    }

    /// Splits an optional `:port` suffix off a host. Returns nil for malformed ports.
    private static func splitHost(_ value: Substring) -> (String, Bool)? {
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.startIndex...close])
            let rest = value[value.index(after: close)...]
            if rest.isEmpty { return (host, false) }
            guard rest.hasPrefix(":"), isPort(rest.dropFirst()) else { return nil }
            return (host, true)
        }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        switch parts.count {
        case 1: return (String(parts[0]), false)
        case 2: return isPort(parts[1]) ? (String(parts[0]), true) : nil
        default: return nil
        }
    }

    private static func isPort(_ value: Substring) -> Bool {
        !value.isEmpty && value.count <= 5 && value.allSatisfy(\.isASCIINumber) && (Int(value) ?? 0) <= 65_535
    }

    private static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCIINumber) && (Int(part) ?? 256) <= 255
        }
    }

    private static func isDomain(_ host: String) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            guard label.allSatisfy({ $0.isASCIILetter || $0.isASCIINumber || $0 == "-" }) else { return false }
        }
        let tld = labels[labels.count - 1]
        return tld.count >= 2 && tld.allSatisfy(\.isASCIILetter)
    }
}

private extension Character {
    var isASCIINumber: Bool { isASCII && isNumber }
    var isASCIILetter: Bool { isASCII && isLetter }
}

/// Normalization shared by ranking and de-duplication.
enum CommandBarTextNormalizer {
    /// Case- and diacritic-insensitive form of a string.
    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// URL key: no scheme, no `www.`, no trailing slash or fragment, lowercased.
    static func urlKey(_ url: URL) -> String {
        urlKey(url.absoluteString)
    }

    static func urlKey(_ string: String) -> String {
        var value = fold(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if let range = value.range(of: "://") { value = String(value[range.upperBound...]) }
        if let hash = value.firstIndex(of: "#") { value = String(value[value.startIndex..<hash]) }
        if value.hasPrefix("www.") { value.removeFirst(4) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    /// Host of a URL without `www.`, lowercased.
    static func host(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
}
