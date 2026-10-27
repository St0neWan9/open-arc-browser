import SwiftUI

/// The Arc menu's own items ([01 §Arc] observed), grouped as in [01 §菜单项图标与缩进] (E20):
/// About ‖ Settings… · (Share Arc) · Set as Default Browser ‖ Import from Another Browser… · Check
/// for Updates… ‖ Services … . Settings… is SwiftUI's own item (from the `Settings` scene), which
/// macOS gives its gear icon; Set as Default Browser follows it in the same group, so that group is
/// indented as in Arc. Share Arc, Privacy Policy and Sign Out are not built.
/// Set as Default Browser is added by `SettingsGroupCommands` on the `Settings` scene: a group
/// placed `after: .appSettings` from another scene lands before Settings… (SwiftUI orders the
/// groups by scene).
struct AppMenuCommands: Commands {
    let controller: WorkspaceController

    var body: some Commands {
        CommandGroup(before: .systemServices) {
            Divider()
            BookmarkImportMenuItem(controller: controller)
            UpdateMenuItem(model: controller.updates)
            Divider()
        }
    }
}

/// Set as Default Browser, right after Settings… in its group. Attached to the `Settings` scene so
/// it follows SwiftUI's Settings… item (see `AppMenuCommands`).
struct SettingsGroupCommands: Commands {
    let controller: WorkspaceController

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            DefaultBrowserMenuItem(model: controller.defaultBrowser)
        }
    }
}
