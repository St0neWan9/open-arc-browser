import SwiftUI

/// Window menu items that open the Library. Titles [01 §Window] observed, in that order; ⇧⌘L is
/// "View Library" [02] observed, the others have no recorded key. Kept apart from `ShellCommands`
/// so the scene only lists it.
struct LibraryCommands: Commands {
    @ObservedObject var model: ShellModel
    /// A browser window is key; without one the items are disabled.
    let hasWindow: Bool

    var body: some Commands {
        CommandMenu("Archive") {
            ArchiveMenuItems(model: model, hasWindow: hasWindow)
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

/// Archive ▸. [01 §Archive] observed: Go Back · Go Forward ‖ View History · View Archive… · Clear
/// Archive (groups from the E20 capture, [01 §菜单项图标与缩进]: no icons, no indent); ⌘[ / ⌘]
/// [02 §页面与导航] observed, the other items have no key in [02]. Go Back / Go Forward act on the
/// key window's current tab. B69.
struct ArchiveMenuItems: View {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some View {
        Group {
            Button("Go Back") { model.sidebar.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!model.sidebar.canGoBack)
            Button("Go Forward") { model.sidebar.goForward() }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!model.sidebar.canGoForward)
            Divider()
            // The engine's history page in a new tab (`HistoryPage`, inferred).
            Button("View History") { model.openHistory() }
            Button("View Archive…") { model.openLibrary(.archivedTabs) }
            // Asks first (`ClearArchiveSheet`); disabled with nothing archived. inferred.
            Button("Clear Archive") { model.sidebar.requestClearArchive() }
                .disabled(!model.sidebar.canClearArchive)
        }
        .disabled(!hasWindow)
    }
}
