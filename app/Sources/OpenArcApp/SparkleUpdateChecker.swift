import Foundation
import OpenArcShell
import Sparkle

/// The Sparkle 2 implementation of `UpdateChecker` (plan D7). This target is the only one that
/// imports Sparkle; the shell sees the protocol.
///
/// Built only when the bundle's Info.plist passes `UpdateConfiguration` (a real `SUPublicEDKey`
/// and an https `SUFeedURL`); see `makeUpdateChecker()`. Sparkle reads the feed, the key and its
/// own defaults from the main bundle; the appcast format and release steps are in `docs/release.md`.
@MainActor
final class SparkleUpdateChecker: UpdateChecker {
    private let controller: SPUStandardUpdaterController
    private var canCheckObservation: NSKeyValueObservation?

    var canCheckForUpdatesDidChange: (@MainActor (Bool) -> Void)?

    init() {
        // Not started yet: `UpdatesModel` applies the stored settings first, then calls `start()`.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            // Sparkle changes this property on the main thread only.
            MainActor.assumeIsolated {
                self?.canCheckForUpdatesDidChange?(updater.canCheckForUpdates)
            }
        }
    }

    var unavailableReason: String? { nil }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// The update checker for this process: Sparkle when the bundle is configured for updates,
/// otherwise one that explains why not (a `swift run` executable, or a bundle whose Info.plist
/// still has the placeholder key). Starting Sparkle with a bad key would show the user an alert.
@MainActor
func makeUpdateChecker(bundle: Bundle = .main) -> any UpdateChecker {
    switch UpdateConfiguration(infoDictionary: bundle.infoDictionary ?? [:]) {
    case .ready:
        return SparkleUpdateChecker()
    case .unavailable(let problem):
        return UnavailableUpdateChecker(reason: problem.message)
    }
}
