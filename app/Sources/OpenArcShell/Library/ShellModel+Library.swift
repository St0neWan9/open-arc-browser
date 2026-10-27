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

// MARK: - Archive menu (B69)

/// Where Archive ▸ View History goes. [01 §Archive] observed item; the spec does not record its
/// surface, and the Library has no history section ([06 §8] observed rail), so it opens the
/// engine's own history page in a new tab, as Manage Extensions… opens the extensions page.
/// inferred.
enum HistoryPage {
    static let url = URL(string: "chrome://history/")!
    static let title = "History"
}

extension ShellModel {
    /// Archive ▸ View History: the history page in a new Today tab, out of the Library.
    public func openHistory() {
        if isCommandBarPresented { dismissCommandBar() }
        library.exit()
        sidebar.newTab(url: HistoryPage.url, title: HistoryPage.title)
    }
}
