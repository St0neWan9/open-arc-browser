import Foundation
import OpenArcModel

// Air Traffic Control (plan B52): rules that pick where a link opened from another app goes.
// [06 §25] observed: Settings ▸ Links ▸ "Air Traffic Control…" opens a sheet of routes. Each
// route is "URL <Contains | Is equal to> <text>" → "Open in <Space | Most Recent Space | Little
// Arc>"; a "Default" row below the list says where links go when no route matches. Changes save
// at once (no Save button) and ⊖ deletes without confirmation.
//
// Storage: per device, in `AppPreferences`. [03 §对复刻的含义] observed: Links is an app-level
// settings page, and app-level settings are not the synced account level; so the rules do not
// sync and need no record type or field group (inferred from that split; the spec does not say
// whether Arc syncs them).

/// How a route compares its text with the link. [06 §25.2] observed menu items.
public enum AirTrafficMatch: String, CaseIterable, Identifiable, Codable, Sendable {
    // Raw values are persisted (per-device preferences); never rename them.
    case contains
    case isEqualTo

    public var id: String { rawValue }

    /// Menu title. [06 §25.2] observed.
    public var title: String {
        switch self {
        case .contains: return "Contains"
        case .isEqualTo: return "Is equal to"
        }
    }
}

/// Where a route (or the Default row) sends a link. [06 §25.2] observed: every Space, then
/// "Most Recent Space", then "Little Arc".
public enum AirTrafficTarget: Hashable, Sendable, Codable {
    /// The current Space of the frontmost browser window.
    case mostRecentSpace
    /// A new Little Arc window.
    case littleArc
    /// This Space, in the frontmost browser window (which switches to it). [06 §25.3] observed.
    case space(UUID)

    // Persisted as one string ("mostRecentSpace", "littleArc", "space:<uuid>"); never change it.
    var storageValue: String {
        switch self {
        case .mostRecentSpace: return "mostRecentSpace"
        case .littleArc: return "littleArc"
        case .space(let id): return "space:\(id.uuidString)"
        }
    }

    init(storageValue: String) {
        switch storageValue {
        case "littleArc": self = .littleArc
        case let value where value.hasPrefix("space:"):
            if let id = UUID(uuidString: String(value.dropFirst("space:".count))) {
                self = .space(id)
            } else {
                self = .mostRecentSpace
            }
        default: self = .mostRecentSpace
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(storageValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}

/// One route of the Air Traffic Control list. [06 §25.2] observed.
public struct AirTrafficRoute: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public var match: AirTrafficMatch
    /// The URL text (placeholder "arc.net" in Arc, observed).
    public var pattern: String
    public var target: AirTrafficTarget

    /// "New Route" adds Contains, empty text, Most Recent Space. [06 §25.2] observed.
    public init(id: UUID, match: AirTrafficMatch = .contains, pattern: String = "", target: AirTrafficTarget = .mostRecentSpace) {
        self.id = id
        self.match = match
        self.pattern = pattern
        self.target = target
    }

    /// Whether this route takes `url`. [06 §25.3] inferred: Contains = the full URL string contains
    /// the text, Is equal to = the full URL string equals it. Our choices (inferred): the text is
    /// trimmed, comparison ignores case, and an empty text matches nothing.
    public func matches(_ url: URL) -> Bool {
        let text = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let candidate = url.absoluteString
        switch match {
        case .contains: return candidate.range(of: text, options: .caseInsensitive) != nil
        case .isEqualTo: return candidate.compare(text, options: .caseInsensitive) == .orderedSame
        }
    }
}

/// The routes plus the Default row, and the routing decision.
public struct AirTrafficRules: Hashable, Sendable {
    public var routes: [AirTrafficRoute]
    /// The Default row. [06 §25.2] observed; its fresh-install value is unknown, so it follows the
    /// "Open links from other apps in Little Arc" toggle (inferred link between the two, see
    /// `AppPreferences.airTrafficDefaultTarget`).
    public var defaultTarget: AirTrafficTarget

    public init(routes: [AirTrafficRoute] = [], defaultTarget: AirTrafficTarget = .mostRecentSpace) {
        self.routes = routes
        self.defaultTarget = defaultTarget
    }

    /// The first route that matches, in list order. [06 §25.3] unknown (priority not tested);
    /// list order is inferred.
    public func route(for url: URL) -> AirTrafficRoute? {
        routes.first { $0.matches(url) }
    }

    /// Where `url` opens. Only web links follow the rules; local files always open in the
    /// frontmost window (inferred: the rules are about links). A route or Default naming a Space
    /// that no longer exists falls back to Most Recent Space ([06 §25.4] unknown; inferred).
    public func destination(for url: URL, in workspace: WorkspaceState) -> ExternalOpenDestination {
        guard ExternalOpen.isWebLink(url) else { return .frontmostWindow }
        switch route(for: url)?.target ?? defaultTarget {
        case .mostRecentSpace: return .frontmostWindow
        case .littleArc: return .littleArc
        case .space(let id):
            guard let space = workspace.spaces[id], !space.meta.isTombstone else { return .frontmostWindow }
            return .space(id)
        }
    }
}

/// The external-link router of the app: Air Traffic Control rules, read from the preferences on
/// every link (they may change while the app runs).
public struct AirTrafficControlRouter: ExternalLinkRouting {
    private let preferences: AppPreferences

    public init(preferences: AppPreferences) {
        self.preferences = preferences
    }

    public func destination(for url: URL, in workspace: WorkspaceState) -> ExternalOpenDestination {
        preferences.airTrafficRules.destination(for: url, in: workspace)
    }
}

// MARK: - Storage

extension AppPreferences {
    // Persisted keys; never rename.
    static let airTrafficRoutesKey = "\(keyPrefix)links.airTrafficRoutes"
    static let airTrafficDefaultSpaceKey = "\(keyPrefix)links.airTrafficDefaultSpace"

    /// The routes, in list order. Stored as JSON. Unreadable data reads as no routes.
    public var airTrafficRoutes: [AirTrafficRoute] {
        get {
            guard let json = stringValue(Self.airTrafficRoutesKey), let data = json.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([AirTrafficRoute].self, from: data)) ?? []
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            setString(String(decoding: data, as: UTF8.self), Self.airTrafficRoutesKey)
        }
    }

    /// The Default row. Little Arc is the "Open links from other apps in Little Arc" toggle itself
    /// (on ⇔ Default is Little Arc; [06 §25.2] inferred link); otherwise a chosen Space, or Most
    /// Recent Space. Setting it updates the toggle to match.
    public var airTrafficDefaultTarget: AirTrafficTarget {
        get {
            if opensExternalLinksInLittleArc { return .littleArc }
            if let text = stringValue(Self.airTrafficDefaultSpaceKey), let id = UUID(uuidString: text) { return .space(id) }
            return .mostRecentSpace
        }
        set {
            switch newValue {
            case .littleArc:
                setString("", Self.airTrafficDefaultSpaceKey)
                opensExternalLinksInLittleArc = true
            case .mostRecentSpace:
                setString("", Self.airTrafficDefaultSpaceKey)
                opensExternalLinksInLittleArc = false
            case .space(let id):
                setString(id.uuidString, Self.airTrafficDefaultSpaceKey)
                opensExternalLinksInLittleArc = false
            }
        }
    }

    public var airTrafficRules: AirTrafficRules {
        AirTrafficRules(routes: airTrafficRoutes, defaultTarget: airTrafficDefaultTarget)
    }
}
