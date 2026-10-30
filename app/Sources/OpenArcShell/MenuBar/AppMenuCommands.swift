import SwiftUI

/// The Arc menu's own items ([01 §Arc] observed), grouped as in [01 §菜单项图标与缩进] (E20):
/// About ‖ Settings… · Share Open Arc · Set as Default Browser ‖ Import from Another Browser… ·
/// Check for Updates… ‖ Services · Privacy Policy ‖ Hide … ‖ Quit. Settings… is SwiftUI's own item
/// (from the `Settings` scene), which macOS gives its gear icon; Share Open Arc and Set as Default
/// Browser follow it in the same group, so that group is indented as in Arc. Privacy Policy joins
/// the system Services group (`MenuBarExtrasCommands`). Arc's Sign Out is not built: Open Arc has
/// no account (`MenuBarCatalog.omittedItems`).
/// Share Open Arc and Set as Default Browser are added by `SettingsGroupCommands` on the
/// `Settings` scene: a group placed `after: .appSettings` from another scene lands before
/// Settings… (SwiftUI orders the groups by scene).
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

/// Share Open Arc and Set as Default Browser, right after Settings… in its group. Attached to the
/// `Settings` scene so they follow SwiftUI's Settings… item (see `AppMenuCommands`).
struct SettingsGroupCommands: Commands {
    let controller: WorkspaceController

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            ShareOpenArcMenuItem(desktop: controller.dependencies.desktop)
            DefaultBrowserMenuItem(model: controller.defaultBrowser)
        }
    }
}

/// Menu bar items of plan B72 outside the window-bound menus: Arc ▸ Privacy Policy, Window ▸ Stay
/// On Top, the Help items, and the system Edit submenus (plan Q15).
///
/// Window-bound items act on the key browser window. Help items that open a page use the window
/// used last when no browser window is key (Settings in front, inferred), and bring it forward.
struct MenuBarExtrasCommands: Commands {
    let controller: WorkspaceController
    /// The key window's menu state, not its model (B103, see `BrowserCommands`).
    @FocusedObject private var focusedMenuBar: MenuBarState?
    private var focused: ShellModel? { focusedMenuBar?.model }

    var body: some Commands {
        let pageWindow = focused ?? controller.activeWindow
        let pageModel = pageWindow ?? controller.appHost()
        // [01 §菜单项图标与缩进] observed: Services · Privacy Policy, one group.
        CommandGroup(after: .systemServices) {
            PrivacyPolicyMenuItem(model: pageModel, hasWindow: pageWindow != nil)
        }
        // [01 §Window] observed: Stay On Top first, then Minimize Window ….
        CommandGroup(before: .windowSize) {
            WindowMenuItems(model: focused ?? controller.appHost(), hasWindow: focused != nil)
        }
        // [01 §Help] observed items after the system search field, and nothing else (B122).
        CommandGroup(replacing: .help) {
            HelpMenuItems(model: pageModel, hasWindow: pageWindow != nil)
        }
        // Spelling and Grammar / Substitutions / Transformations / Speech and Format ([01 §Edit]
        // observed, plan Q15). They bring a system Find submenu and a top-level Format menu, which
        // `MenuBarAdjuster` hides (ours stays) and moves into Edit.
        TextEditingCommands()
        TextFormattingCommands()
    }
}
