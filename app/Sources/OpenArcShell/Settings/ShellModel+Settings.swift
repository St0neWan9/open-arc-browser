import Foundation
import OpenArcModel

/// Profile-level settings in the window. [03 §Profiles] observed: the search engine and "Archive
/// tabs after" are per-profile settings. They live in `Profile.settings` (synced, A18), so the
/// shell reads them from the workspace instead of copying them around: the search URL follows
/// the current Space's profile, and auto-archive reads each tab's profile in `TreeOps`.
extension ShellModel {
    /// Settings of the current window's profile (the selected Space's profile, else Default). An
    /// incognito window reads its parent profile's settings (`WorkspaceController.profileSettings`).
    public var currentProfileSettings: ProfileSettings {
        controller.profileSettings(for: sidebar.currentProfileID)
    }

    /// Search URL template of the current profile's engine; `%@` is replaced by the escaped query.
    /// [03 §Profiles] observed: the default is Google.
    public var searchURLTemplate: String { currentProfileSettings.searchEngine.searchURLTemplate }
}
