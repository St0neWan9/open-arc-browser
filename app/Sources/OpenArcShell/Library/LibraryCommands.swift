import SwiftUI

/// Window menu items that open the Library. Titles [01 §Window] observed, in that order; ⇧⌘L is
/// "View Library" [02] observed, the others have no recorded key. Kept apart from `ShellCommands`
/// so the scene only lists it.
struct LibraryCommands: Commands {
    @ObservedObject var model: ShellModel
    /// A browser window is key; without one the items are disabled.
    let hasWindow: Bool

    var body: some Commands {
        // [01 §Archive] observed: Go Back · Go Forward ‖ View History · View Archive… · Clear Archive
        // (groups from the E20 capture, [01 §菜单项图标与缩进]); ⌘[ / ⌘] [02 §页面与导航] observed.
        // View History and Clear Archive are not built.
        CommandMenu("Archive") {
            Group {
                Button("Go Back") { model.sidebar.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                    .disabled(!model.sidebar.canGoBack)
                Button("Go Forward") { model.sidebar.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                    .disabled(!model.sidebar.canGoForward)
                Divider()
                Button("View Archive…") { model.openLibrary(.archivedTabs) }
            }
            .disabled(!hasWindow)
        }

        // Its own group, without icons (so not indented), between the system window groups and
        // Bring All to Front. [01 §菜单项图标与缩进] observed.
        CommandGroup(before: .windowList) {
            Group {
                Button("Open Library…") { model.openLibrary() }
                    .keyboardShortcut("l", modifiers: [.shift, .command])
                Button("View Downloads…") { model.openLibrary(.downloads) }
                Button("View Easels…") { model.openLibrary(.easels) }
                Button("View Media…") { model.openLibrary(.media) }
                Button("View Boosts…") { model.openLibrary(.boosts) }
            }
            .disabled(!hasWindow)
            Divider()
        }
    }
}
