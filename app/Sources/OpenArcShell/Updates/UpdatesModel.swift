import Foundation
import SwiftUI

/// Update state and actions shared by the app menu and the Settings window (plan D7).
///
/// The two automatic-update choices are per-device app settings kept in `AppPreferences`; they are
/// pushed into the checker when the model is created (before the checker starts) and on every
/// change. The spec records no update settings in Arc's Settings window ([03 §Advanced] observed
/// list has none), so the controls and their defaults are ours (inferred).
@MainActor
public final class UpdatesModel: ObservableObject {
    public let checker: any UpdateChecker
    private let preferences: AppPreferences

    /// Mirrors `checker.canCheckForUpdates`.
    @Published public private(set) var canCheckForUpdates: Bool

    /// Applies the stored choices to `checker`, then starts it.
    public init(checker: any UpdateChecker, preferences: AppPreferences) {
        self.checker = checker
        self.preferences = preferences
        checker.automaticallyChecksForUpdates = preferences.automaticallyChecksForUpdates
        checker.automaticallyDownloadsUpdates = preferences.automaticallyDownloadsUpdates
        canCheckForUpdates = checker.canCheckForUpdates
        checker.canCheckForUpdatesDidChange = { [weak self] value in self?.canCheckForUpdates = value }
        checker.start()
        canCheckForUpdates = checker.canCheckForUpdates
    }

    /// False when this build cannot update itself; the controls are then disabled.
    public var isAvailable: Bool { checker.unavailableReason == nil }

    /// Shown under the controls when updates are unavailable.
    public var unavailableReason: String? { checker.unavailableReason }

    /// "Check for Updates…" (menu and Settings) is enabled.
    public var isCheckEnabled: Bool { isAvailable && canCheckForUpdates }

    /// "Automatically check for updates". Default on (inferred).
    public var automaticallyChecksForUpdates: Bool {
        get { preferences.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            preferences.automaticallyChecksForUpdates = newValue
            checker.automaticallyChecksForUpdates = newValue
        }
    }

    /// "Automatically download and install updates". Default off (inferred). Only takes effect
    /// while automatic checks are on, so the view disables it otherwise (inferred).
    public var automaticallyDownloadsUpdates: Bool {
        get { preferences.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            preferences.automaticallyDownloadsUpdates = newValue
            checker.automaticallyDownloadsUpdates = newValue
        }
    }

    /// Starts a user-initiated check. Ignored while disabled.
    public func checkForUpdates() {
        guard isCheckEnabled else { return }
        checker.checkForUpdates()
    }
}

extension AppPreferences {
    // Persisted keys; never rename.
    static let automaticUpdateChecksKey = "\(keyPrefix)updates.automaticChecks"
    static let automaticUpdateDownloadsKey = "\(keyPrefix)updates.automaticDownloads"

    /// "Automatically check for updates". Per device; on by default (inferred).
    public var automaticallyChecksForUpdates: Bool {
        get { boolValue(Self.automaticUpdateChecksKey) ?? true }
        set { setBool(newValue, Self.automaticUpdateChecksKey) }
    }

    /// "Automatically download and install updates". Per device; off by default (inferred).
    public var automaticallyDownloadsUpdates: Bool {
        get { boolValue(Self.automaticUpdateDownloadsKey) ?? false }
        set { setBool(newValue, Self.automaticUpdateDownloadsKey) }
    }
}

// MARK: - Menu

/// Open Arc ▸ Check for Updates…. [01 §Arc] observed: after Import from Another Browser…, in its
/// group, directly before Services. Placed by `AppMenuCommands`.
struct UpdateMenuItem: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        Button(UpdateStrings.checkForUpdates) { model.checkForUpdates() }
            .disabled(!model.isCheckEnabled)
    }
}

// MARK: - Settings

/// The update controls in Settings ▸ Advanced (our addition; [03 §Advanced] observed no update
/// controls in Arc, which updates itself silently).
struct UpdateSettingsSection: View {
    @ObservedObject var model: UpdatesModel

    var body: some View {
        // Drawn like Arc's Advanced rows (B100): a tiled card. The automatic-check switch lives in
        // General ("Automatically update Open Arc", B100); this card keeps downloads and the
        // manual check.
        SettingsCard {
            SettingsToggleRow(
                label: UpdateStrings.automaticDownloads,
                isOn: Binding(get: { model.automaticallyDownloadsUpdates }, set: { model.automaticallyDownloadsUpdates = $0 }),
                subtitle: model.unavailableReason,
                tile: SettingsTile(symbol: "arrow.down.circle.fill", color: SettingsTile.gray)
            )
            .disabled(!model.isAvailable || !model.automaticallyChecksForUpdates)
            SettingsDivider()
            SettingsControlRow(label: UpdateStrings.sectionTitle,
                               tile: SettingsTile(symbol: "arrow.triangle.2.circlepath", color: SettingsTile.gray)) {
                Button(UpdateStrings.checkForUpdates) { model.checkForUpdates() }
                    .buttonStyle(SettingsButtonStyle())
                    .disabled(!model.isCheckEnabled)
            }
        }
    }
}

/// User-facing strings. The menu title is observed ([01 §Arc]); the rest are ours (inferred).
enum UpdateStrings {
    static let checkForUpdates = "Check for Updates…"
    static let sectionTitle = "Software Update"
    static let automaticChecks = "Automatically check for updates"
    static let automaticDownloads = "Automatically download and install updates"
}
