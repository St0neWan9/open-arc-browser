import Foundation
import Combine

// Optional app usage analytics (plan B194). Four explicit events go to the project's PostHog
// (US) through its public capture API, from an app-owned queue: no PostHog SDK, so turning sharing
// off stops collection and drops everything pending at once. Sharing is on by default, but nothing
// is collected before the user has been shown the notice (onboarding's last page, or a one-time
// notice in the first normal window); the switch is Settings ▸ General ▸ Privacy & Usage Data,
// stored on this Mac only. Never sent: websites, URLs, titles, page contents, searches, names of
// Spaces or Profiles, or anything from incognito windows. Our own design throughout (Arc's
// telemetry is not a reference for this).

/// The events the app may send. Nothing else is ever captured.
public enum UsageEvent: Equatable, Sendable {
    /// First use of a normal browser window on a UTC day.
    case activeDay
    /// A deliberate action used a feature (once per feature and UTC day).
    case featureUsed(UsageFeature)
    /// An Arc import started while sharing was active finished.
    case arcImportFinished(UsageImportResult)
    /// The user changed "Archive tabs after".
    case archiveIntervalChanged(UsageArchiveInterval)

    var name: String {
        switch self {
        case .activeDay: return "app_active_day"
        case .featureUsed: return "feature_used"
        case .arcImportFinished: return "arc_import_finished"
        case .archiveIntervalChanged: return "archive_interval_changed"
        }
    }

    /// The event's own properties: fixed enum values only.
    var properties: [String: String] {
        switch self {
        case .activeDay: return [:]
        case .featureUsed(let feature): return ["feature": feature.rawValue]
        case .arcImportFinished(let result): return ["result": result.rawValue]
        case .archiveIntervalChanged(let interval): return ["interval": interval.rawValue]
        }
    }

    /// The daily limit this event counts against, and its size.
    var dailyLimit: (key: String, count: Int) {
        switch self {
        case .activeDay: return (name, 1)
        case .featureUsed(let feature): return ("\(name).\(feature.rawValue)", 1)
        case .arcImportFinished, .archiveIntervalChanged: return (name, 3)
        }
    }
}

public enum UsageFeature: String, CaseIterable, Sendable {
    case spaces
    case splitView = "split_view"
    case peek
    case commandBar = "command_bar"
    case tabArchive = "tab_archive"
}

public enum UsageImportResult: String, Sendable {
    case success, partial, failed, cancelled
}

public enum UsageArchiveInterval: String, Sendable {
    case hours12 = "12h", hours24 = "24h", days7 = "7d", days30 = "30d", custom

    public init(seconds: TimeInterval) {
        switch seconds {
        case 12 * 3600: self = .hours12
        case 24 * 3600: self = .hours24
        case 7 * 24 * 3600: self = .days7
        case 30 * 24 * 3600: self = .days30
        default: self = .custom
        }
    }
}

/// The stored choice. A missing value means `defaultEnabled`; a value this build does not know
/// reads as `disabled` (fails closed).
public enum UsageAnalyticsPreference: String, Sendable {
    case defaultEnabled, explicitlyEnabled, disabled

    public var isEnabled: Bool { self != .disabled }
}

/// Where events go. Only a release build with the project token in its Info.plist has one.
public struct UsageAnalyticsConfiguration: Equatable, Sendable {
    /// The project's public ingestion token (not an account credential).
    public var apiKey: String
    /// The batch capture endpoint.
    public var endpoint: URL
    public var appVersion: String
    public var osMajor: String
    public var architecture: String

    public init(apiKey: String, endpoint: URL, appVersion: String, osMajor: String, architecture: String) {
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.appVersion = appVersion
        self.osMajor = osMajor
        self.architecture = architecture
    }

    static let tokenKey = "OpenArcUsageAnalyticsToken"
    static let hostKey = "OpenArcUsageAnalyticsHost"

    /// The running app's configuration: nil outside the release bundle (development builds,
    /// `swift run`, tests) or when the Info.plist has no token or host.
    public static func live(bundle: Bundle = .main) -> UsageAnalyticsConfiguration? {
        guard bundle.bundleIdentifier == AppIdentity.releaseBundleIdentifier,
              let token = bundle.object(forInfoDictionaryKey: tokenKey) as? String, token.hasPrefix("phc_"),
              let host = bundle.object(forInfoDictionaryKey: hostKey) as? String,
              let endpoint = URL(string: "https://\(host)/batch/") else { return nil }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        return UsageAnalyticsConfiguration(
            apiKey: token, endpoint: endpoint, appVersion: version,
            osMajor: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion), architecture: architecture
        )
    }
}

extension UsageAnalyticsConfiguration {
    /// A development build's stand-in (`org.openarc.browser.dev…`): the notice, onboarding card
    /// and Settings card all show, but `LaunchFlow` pairs it with the recording transport, so
    /// nothing ever leaves the Mac. nil for any other bundle.
    public static func developmentPreview(bundle: Bundle = .main) -> UsageAnalyticsConfiguration? {
        guard let id = bundle.bundleIdentifier, id.hasPrefix(AppIdentity.developmentBundleIdentifier) else { return nil }
        return UsageAnalyticsConfiguration(
            apiKey: "phc_development_preview", endpoint: URL(string: "https://localhost.invalid/batch/")!,
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            osMajor: String(ProcessInfo.processInfo.operatingSystemVersion.majorVersion), architecture: "dev"
        )
    }
}

/// Sends one JSON body. Injectable so tests never reach the network.
public protocol UsageAnalyticsTransport: Sendable {
    func send(_ body: Data, to url: URL) async throws
}

/// The real transport: an ephemeral session (no cookies, no cache), a short timeout.
public struct URLSessionUsageAnalyticsTransport: UsageAnalyticsTransport {
    public init() {}

    public func send(_ body: Data, to url: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
}

/// A transport that only records (the `AppDependencies` default, tests and previews).
public final class RecordingUsageAnalyticsTransport: UsageAnalyticsTransport, @unchecked Sendable {
    // @unchecked: `bodies` and `failure` are only read and written under `lock`.
    private let lock = NSLock()
    private var bodies: [Data] = []
    private var failure: (any Error)?

    public init() {}

    public var sent: [Data] { lock.withLock { bodies } }

    /// The next sends throw this until set back to nil.
    public func fail(with error: (any Error)?) { lock.withLock { failure = error } }

    public func send(_ body: Data, to url: URL) async throws {
        try lock.withLock {
            if let failure { throw failure }
            bodies.append(body)
        }
    }
}

/// The app's one usage-analytics controller (owned by the main `WorkspaceController`).
@MainActor
public final class UsageAnalytics: ObservableObject {
    /// Version of the notice text. Showing it once allows collection; a later version does not
    /// re-ask, it only matters for a future change of what is collected.
    public static let noticeVersion = 1
    /// Global cap per installation and UTC day.
    static let dailyEventCap = 20
    static let queueLimit = 100
    static let batchSize = 20
    public static let flushInterval: TimeInterval = 60

    private let preferences: AppPreferences
    let configuration: UsageAnalyticsConfiguration?
    private let transport: any UsageAnalyticsTransport
    private let now: () -> Date
    private let makeID: () -> UUID
    private let flushDelay: TimeInterval

    /// Events waiting to be sent, in memory only.
    private(set) var queue: [[String: Any]] = []
    private var flushTask: Task<Void, Never>?
    /// Bumped when sharing is turned off: a send that was in flight does not put its events back.
    private var generation = 0

    public init(
        preferences: AppPreferences,
        configuration: UsageAnalyticsConfiguration?,
        transport: any UsageAnalyticsTransport,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init,
        flushDelay: TimeInterval = UsageAnalytics.flushInterval
    ) {
        self.preferences = preferences
        self.configuration = configuration
        self.transport = transport
        self.now = now
        self.makeID = makeID
        self.flushDelay = flushDelay
    }

    // MARK: Choice

    public var preference: UsageAnalyticsPreference { preferences.usageAnalyticsPreference }

    /// Settings ▸ General ▸ Share usage data, and the onboarding card.
    public var isSharingEnabled: Bool { preference.isEnabled }

    /// Whether this build can send at all (a release build with a token).
    public var isAvailable: Bool { configuration != nil }

    /// The notice has been shown on this Mac.
    public var hasPresentedNotice: Bool { (preferences.usageAnalyticsNoticeVersion ?? 0) >= 1 }

    /// The first normal window should show the one-time notice: sharing is on by default and the
    /// user has not seen the notice yet. Never for an explicit choice either way.
    public var needsNotice: Bool { isAvailable && preference == .defaultEnabled && !hasPresentedNotice }

    /// Events are being collected.
    public var isCollecting: Bool { isAvailable && isSharingEnabled && hasPresentedNotice }

    /// Turns sharing on or off. Off persists first, then stops collection and drops everything
    /// pending and the installation id; already sent requests cannot be recalled. On again starts
    /// with a new id.
    public func setSharingEnabled(_ isOn: Bool) {
        objectWillChange.send()
        if isOn {
            if preference == .disabled { preferences.usageAnalyticsInstallID = nil }
            preferences.usageAnalyticsPreference = .explicitlyEnabled
        } else {
            preferences.usageAnalyticsPreference = .disabled
            generation += 1
            flushTask?.cancel()
            flushTask = nil
            queue.removeAll()
            preferences.usageAnalyticsInstallID = nil
        }
    }

    /// The window notice is showing (it stays until a button is pressed, after `needsNotice` turned
    /// false).
    @Published public private(set) var isNoticeOnScreen = false

    /// The window notice appeared: it counts as shown, so collection may start.
    public func noticeDidAppear() {
        isNoticeOnScreen = true
        markNoticePresented()
    }

    /// One of the notice's buttons was pressed.
    public func dismissNotice() {
        isNoticeOnScreen = false
    }

    /// The notice (onboarding card or the window notice) is on screen: collection may start.
    public func markNoticePresented() {
        guard !hasPresentedNotice else { return }
        objectWillChange.send()
        preferences.usageAnalyticsNoticeVersion = Self.noticeVersion
    }

    // MARK: Events

    /// Records `event` if collecting, within the daily limits. `isPrivate` (an incognito window's
    /// action) is never recorded. Returns whether it was queued.
    @discardableResult
    public func record(_ event: UsageEvent, isPrivate: Bool = false) -> Bool {
        guard !isPrivate, isCollecting, let configuration else { return false }
        let stamp = now()
        var ledger = UsageDailyLedger(preferences.usageAnalyticsLedger, day: Self.utcDay(stamp))
        let limit = event.dailyLimit
        guard ledger.total < Self.dailyEventCap, ledger.counts[limit.key, default: 0] < limit.count else { return false }
        ledger.counts[limit.key, default: 0] += 1
        ledger.total += 1
        preferences.usageAnalyticsLedger = ledger.stored

        var properties: [String: Any] = [
            "distinct_id": installID(),
            "$process_person_profile": false,
            "$geoip_disable": true,
            "$lib": "openarc-macos",
            "schema_version": 1,
            "app_version": configuration.appVersion,
            "os_major": configuration.osMajor,
            "architecture": configuration.architecture,
            "environment": "production",
            "surface": "macos",
        ]
        for (key, value) in event.properties { properties[key] = value }
        queue.append([
            "event": event.name,
            "properties": properties,
            "timestamp": ISO8601DateFormatter().string(from: stamp),
        ])
        if queue.count > Self.queueLimit { queue.removeFirst(queue.count - Self.queueLimit) }
        scheduleFlush(immediately: queue.count >= Self.batchSize)
        return true
    }

    private func installID() -> String {
        if let id = preferences.usageAnalyticsInstallID { return id }
        let id = makeID().uuidString.lowercased()
        preferences.usageAnalyticsInstallID = id
        return id
    }

    static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Sending

    private func scheduleFlush(immediately: Bool) {
        if immediately { flushTask?.cancel(); flushTask = nil }
        guard flushTask == nil else { return }
        let delay = immediately ? 0 : flushDelay
        flushTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Sends up to one batch now. Failures keep the events (bounded) for the next attempt.
    func flush() async {
        flushTask = nil
        guard isCollecting, let configuration, !queue.isEmpty else { return }
        let batch = Array(queue.prefix(Self.batchSize))
        queue.removeFirst(batch.count)
        let sentGeneration = generation
        let body = (try? JSONSerialization.data(withJSONObject: ["api_key": configuration.apiKey, "batch": batch], options: [.sortedKeys])) ?? Data()
        do {
            try await transport.send(body, to: configuration.endpoint)
        } catch {
            // Put the batch back unless sharing was turned off meanwhile.
            guard generation == sentGeneration, isCollecting else { return }
            queue.insert(contentsOf: batch, at: 0)
            if queue.count > Self.queueLimit { queue.removeLast(queue.count - Self.queueLimit) }
            scheduleFlush(immediately: false)
            return
        }
        if !queue.isEmpty { scheduleFlush(immediately: queue.count >= Self.batchSize) }
    }

    /// Stops the timer (app quit, tests). Pending events are dropped.
    public func stop() {
        flushTask?.cancel()
        flushTask = nil
    }
}

/// Per-day counters, stored as `["day": "yyyy-MM-dd", "total": n, "counts": [key: n]]`.
struct UsageDailyLedger {
    var day: String
    var total: Int
    var counts: [String: Int]

    init(_ stored: [String: Any]?, day: String) {
        if let stored, stored["day"] as? String == day {
            self.day = day
            total = stored["total"] as? Int ?? 0
            counts = stored["counts"] as? [String: Int] ?? [:]
        } else {
            self.day = day
            total = 0
            counts = [:]
        }
    }

    var stored: [String: Any] { ["day": day, "total": total, "counts": counts] }
}
