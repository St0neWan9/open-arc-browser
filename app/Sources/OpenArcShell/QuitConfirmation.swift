import AppKit
import Foundation

// "Warn before quitting" (plan B68). [03 §General] observed: the toggle, on by default. The spec
// does not record what Arc shows when the user quits; the alert below (its title, buttons and
// "Don't ask again" box) is inferred and worded for Open Arc.

/// The user's answer to the quit question.
public enum QuitConfirmation: Equatable, Sendable {
    /// Keep the app open.
    case cancel
    /// Quit.
    case quit
    /// Quit, and turn "Warn before quitting" off ("Don't ask again" was checked).
    case quitAndStopWarning
}

/// The quit question, an app-modal alert. inferred (see the file header).
@MainActor
public enum QuitConfirmationAlert {
    public static let title = "Quit \(AppIdentity.displayName)?"
    public static let message = "You can turn this warning off in Settings ▸ General."
    public static let quitButton = "Quit"
    public static let cancelButton = "Cancel"
    public static let suppressionTitle = "Don't ask again"

    /// Sparkle's `SUUpdaterWillRestartNotification` (its literal name), posted on the default
    /// center right before the updater quits the app to install an update. Observed by name so the
    /// shell does not import Sparkle (only OpenArcApp does).
    public static let updateRelaunchNotification = Notification.Name("SUUpdaterWillRestartNotificationName")

    /// Shows the alert and waits for the answer. Return quits, Esc cancels.
    public static func run() -> QuitConfirmation {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: quitButton)
        alert.addButton(withTitle: cancelButton).keyEquivalent = "\u{1b}"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = suppressionTitle
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        return answer(for: response, suppressed: alert.suppressionButton?.state == .on)
    }

    /// Maps the alert's result. The first button is Quit.
    static func answer(for response: NSApplication.ModalResponse, suppressed: Bool) -> QuitConfirmation {
        guard response == .alertFirstButtonReturn else { return .cancel }
        return suppressed ? .quitAndStopWarning : .quit
    }
}

/// Runs an action for each notification `name` on `center`, until released. AppKit and Sparkle
/// post the observed notifications on the main thread.
final class QuitNotificationObservation {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, name: Notification.Name, action: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    deinit {
        if let token { center.removeObserver(token) }
    }
}
