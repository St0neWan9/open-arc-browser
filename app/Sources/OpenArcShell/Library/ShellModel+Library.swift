import Foundation

extension ShellModel {
    /// Enters the Library mode. With no section, Open Library picks one (`LibraryModel.openDefault`).
    /// Entry points: ⇧⌘L View Library [02] observed; Window ▸ Open Library… / View Downloads…
    /// [01 §Window] observed; Archive ▸ View Archive… [01 §Archive] observed; the command bar's
    /// Open Library / View Archive / View Downloads; the Space menu's Manage Spaces… (the Spaces
    /// board is that surface, [06 §8] observed).
    public func openLibrary(_ section: LibrarySection? = nil) {
        // Floating surfaces belong to the browser view, not the Library. inferred.
        if isCommandBarPresented { dismissCommandBar() }
        if let section { library.open(section) } else { library.openDefault() }
    }

    /// "←" at the bottom of the rail. [06 §8] observed.
    public func exitLibrary() { library.exit() }

    /// Whether the window shows the Library instead of the browser view.
    public var isLibraryActive: Bool { library.isActive }
}
