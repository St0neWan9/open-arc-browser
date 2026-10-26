import SwiftUI

/// Window menu items that open the Library. Titles [01 §Window] observed, in that order; ⇧⌘L is
/// "View Library" [02] observed, the others have no recorded key. Kept apart from `ShellCommands`
/// so the scene only lists it.
struct LibraryCommands: Commands {
    @ObservedObject var model: ShellModel
    /// A browser window is key; without one the items are disabled.
    let hasWindow: Bool

    var body: some Commands {
        // [01 §Archive] observed: Go Back · Go Forward · View History · View Archive… · Clear Archive.
        // Only View Archive… has a surface so far; the rest join this menu with their features.
        CommandMenu("Archive") {
            Button("View Archive…") { model.openLibrary(.archivedTabs) }
                .disabled(!hasWindow)
        }

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
