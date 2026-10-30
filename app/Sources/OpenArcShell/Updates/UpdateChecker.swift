import Foundation

// Software updates (plan D7). The shell talks to an `UpdateChecker`; the app target provides the
// Sparkle-backed implementation (`SparkleUpdateChecker` in OpenArcApp), so no Shell file imports
// Sparkle. [01 §Arc] observed: the app menu has "Check for Updates…". [00 §自动更新] the update
// route is Sparkle, with the appcast on our static host (GitHub Releases / Pages).

/// Checks for and installs app updates.
///
/// Every member is used on the main actor (Sparkle's updater is main-thread only).
@MainActor
public protocol UpdateChecker: AnyObject, Sendable {
    /// nil when this build can update itself; otherwise a short, user-facing reason why not
    /// (no feed or signing key configured, not running from an app bundle).
    var unavailableReason: String? { get }
    /// Whether a user-initiated check may start now (false while one runs or before `start()`).
    var canCheckForUpdates: Bool { get }
    /// Sparkle's "check automatically" setting.
    var automaticallyChecksForUpdates: Bool { get set }
    /// Sparkle's "download and install automatically" setting.
    var automaticallyDownloadsUpdates: Bool { get set }
    /// Called whenever `canCheckForUpdates` changes. Set by `UpdatesModel`.
    var canCheckForUpdatesDidChange: (@MainActor (Bool) -> Void)? { get set }
    /// Called when a downloaded update starts or stops waiting to be installed (B111). Set by
    /// `UpdatesModel`.
    var updateReadinessDidChange: (@MainActor (UpdateReadiness) -> Void)? { get set }
    /// Starts the updater (schedules automatic checks). Called once, after the settings above
    /// were applied. Does nothing when unavailable.
    func start()
    /// A user-initiated check with the standard update UI.
    func checkForUpdates()
}

/// The checker of a build that cannot update itself: the `AppDependencies` default (tests,
/// previews, `swift run`), and what the app uses while the Info.plist still holds the placeholder
/// key. "Check for Updates…" is disabled.
@MainActor
public final class UnavailableUpdateChecker: UpdateChecker {
    public let unavailableReason: String?
    public var canCheckForUpdates: Bool { false }
    public var automaticallyChecksForUpdates = false
    public var automaticallyDownloadsUpdates = false
    public var canCheckForUpdatesDidChange: (@MainActor (Bool) -> Void)?
    public var updateReadinessDidChange: (@MainActor (UpdateReadiness) -> Void)?

    public nonisolated init(reason: String = UpdateConfiguration.Problem.notAnAppBundle.message) {
        unavailableReason = reason
    }

    public func start() {}
    public func checkForUpdates() {}
}

/// Whether a downloaded update waits to be installed (B111).
public enum UpdateReadiness {
    /// Downloaded; `installNow` installs it and relaunches when the updater offered a direct way.
    case ready(installNow: (@MainActor () -> Void)?)
    /// Nothing waits (installed, dismissed or replaced).
    case none
}

/// Reads the Sparkle keys of an Info.plist and says whether Sparkle may be started.
///
/// Sparkle refuses to start with a key it cannot decode and then shows the user an error alert,
/// so the app only builds the Sparkle checker when this returns `.ready` (see `docs/release.md`).
public enum UpdateConfiguration: Equatable, Sendable {
    case ready(feedURL: URL)
    case unavailable(Problem)

    public enum Problem: Equatable, Sendable {
        /// No bundle identifier of ours: a bare `swift run` executable or a test host.
        case notAnAppBundle
        case missingFeedURL
        /// `SUPublicEDKey` is missing or still the placeholder: the release EdDSA key pair has not
        /// been generated yet (manual release step, `docs/release.md`).
        case missingPublicKey

        public var message: String {
            switch self {
            case .notAnAppBundle: return "Updates are available only in the \(AppIdentity.displayName) app."
            case .missingFeedURL: return "This build has no update feed."
            case .missingPublicKey: return "This build is not set up for updates yet."
            }
        }
    }

    // Info.plist keys read by Sparkle. Their names are Sparkle's, not ours.
    public static let feedURLKey = "SUFeedURL"
    public static let publicKeyKey = "SUPublicEDKey"

    /// The `SUPublicEDKey` value in `app/Bundle/Info.plist` until a release key exists. Not valid
    /// base64, so even if Sparkle were started with it, it would refuse to run (fails closed).
    public static let placeholderPublicKey = "OPENARC_PLACEHOLDER_EDDSA_PUBLIC_KEY"
    /// The appcast on our static host: raw content of the public repository's `updates` branch
    /// (plan D14). Sparkle stays off until `SUPublicEDKey` is a real key.
    public static let hostedFeedURL = URL(string: "https://raw.githubusercontent.com/St0neWan9/open-arc-browser/updates/appcast.xml")!

    /// - Parameter infoDictionary: `Bundle.main.infoDictionary`.
    public init(infoDictionary: [String: Any]) {
        guard let bundleID = infoDictionary["CFBundleIdentifier"] as? String,
              AppIdentity.isOwnBundleIdentifier(bundleID)
        else {
            self = .unavailable(.notAnAppBundle)
            return
        }
        // Only the release build updates. make-app.sh --dev drops the feed; this also holds if a
        // development bundle still carried one (plan B37).
        guard bundleID == AppIdentity.releaseBundleIdentifier else {
            self = .unavailable(.missingFeedURL)
            return
        }
        guard let feed = (infoDictionary[Self.feedURLKey] as? String).flatMap(URL.init(string:)),
              feed.scheme == "https"
        else {
            self = .unavailable(.missingFeedURL)
            return
        }
        let key = (infoDictionary[Self.publicKeyKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // An Ed25519 public key is 32 bytes, base64-encoded.
        guard key != Self.placeholderPublicKey, Data(base64Encoded: key)?.count == 32 else {
            self = .unavailable(.missingPublicKey)
            return
        }
        self = .ready(feedURL: feed)
    }
}
