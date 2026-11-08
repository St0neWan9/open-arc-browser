import Foundation

// Settings ▸ General ▸ Privacy & Usage Data (plan B194).
extension SettingsModel {
    /// The app's usage-analytics controller.
    public var usageAnalytics: UsageAnalytics { shell.controller.usageAnalytics }

    /// "Privacy Policy": our page in a tab of the window used last.
    @discardableResult
    public func openPrivacyPolicy() -> UUID? {
        let controller = shell.controller
        guard let spaceID = controller.activeWindow?.selectedSpaceID ?? controller.workspace.allLiveSpaces.first?.id else { return nil }
        return openInTab(OpenArcLinks.privacyPolicy, title: "Privacy Policy", spaceID: spaceID)
    }
}
