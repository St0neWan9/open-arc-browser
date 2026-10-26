import Foundation

/// Default search engine of a profile. [03 §Profiles] observed: a dropdown whose default is
/// Google. The option list itself was not recorded; these five are our choice (inferred).
///
/// Raw values are persisted (workspace file, CloudKit `settings_searchEngine`, legacy per-device
/// preferences); never rename them. Decoding an unknown raw value (written by a newer build)
/// falls back to `.default` instead of failing the whole record.
public enum SearchEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case google, bing, duckDuckGo, yahoo, ecosia

    public static let `default`: SearchEngine = .google

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .google: return "Google"
        case .bing: return "Bing"
        case .duckDuckGo: return "DuckDuckGo"
        case .yahoo: return "Yahoo"
        case .ecosia: return "Ecosia"
        }
    }

    /// Search URL template; `%@` is replaced by the escaped query.
    public var searchURLTemplate: String {
        switch self {
        case .google: return "https://www.google.com/search?q=%@"
        case .bing: return "https://www.bing.com/search?q=%@"
        case .duckDuckGo: return "https://duckduckgo.com/?q=%@"
        case .yahoo: return "https://search.yahoo.com/search?p=%@"
        case .ecosia: return "https://www.ecosia.org/search?q=%@"
        }
    }

    /// Lenient lookup: unknown or missing raw values give `.default`.
    public init(lenient rawValue: String?) {
        self = rawValue.flatMap(SearchEngine.init(rawValue:)) ?? .default
    }

    public init(from decoder: Decoder) throws {
        self.init(lenient: try decoder.singleValueContainer().decode(String.self))
    }
}

/// Settings that belong to a profile and sync with it: the `Profile.settings` field group.
///
/// [03 §Profiles] observed: the Profiles pane shows, per profile, "Search engine" (default
/// Google) and "Archive tabs after" (default 12 hours); [03 §对复刻的含义] observed: search,
/// archive, downloads and privacy are profile-level settings. Download location is not modeled
/// yet (C12). All values are plain (not user content).
///
/// The whole struct is one field group: an edit replaces and stamps it as a unit, and a merge
/// copies it as a unit. Every new profile-level setting must be added here (with a decode
/// default) so it joins the group.
public struct ProfileSettings: Codable, Hashable, Sendable {
    public var searchEngine: SearchEngine
    /// How long an idle Today tab of this profile's Spaces lives before auto-archive.
    public var todayLifetime: TimeInterval

    public static let `default` = ProfileSettings()

    public init(
        searchEngine: SearchEngine = .default,
        todayLifetime: TimeInterval = ArchivePolicy.defaultTodayLifetime
    ) {
        self.searchEngine = searchEngine
        self.todayLifetime = todayLifetime
    }

    private enum CodingKeys: String, CodingKey { case searchEngine, todayLifetime }

    /// Every key is optional so data written before a setting existed decodes with its default.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        searchEngine = try c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? .default
        let lifetime = try c.decodeIfPresent(TimeInterval.self, forKey: .todayLifetime)
        todayLifetime = ProfileSettings.validLifetime(lifetime)
    }

    /// A non-positive or missing lifetime would archive everything at once; use the default.
    public static func validLifetime(_ value: TimeInterval?) -> TimeInterval {
        guard let value, value.isFinite, value > 0 else { return ArchivePolicy.defaultTodayLifetime }
        return value
    }
}
