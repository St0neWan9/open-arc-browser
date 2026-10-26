import SwiftUI
import OpenArcEngine

// Extension entry points of a browser window (plan C14).
// - Extensions menu: "Add Extension…" and "Manage Extensions…" [01 §Extensions] observed.
// - "Open Extensions" ⌘E [02 §页面与导航] observed. What it opens is not recorded; extensions live in
//   the Site Control Center ([06 §12], [06 §17.2] observed: no extension buttons elsewhere), so ⌘E
//   opens it. inferred.
// - The Site Control Center's "+" opens the same as Add Extension…, "Manage" the same as Manage
//   Extensions… [06 §12] observed buttons; targets inferred.
// - Add Extension… opens the Chrome Web Store in a new tab, where the store's own "Add" button
//   installs (the engine asks the shell to confirm). Manage Extensions… opens Chromium's extensions
//   page until a native one exists. Both inferred (the spec records neither destination).

/// Where the extension entry points go. inferred (see the file header).
enum ExtensionPages {
    static let webStore = URL(string: "https://chromewebstore.google.com/category/extensions")!
    static let manage = URL(string: "chrome://extensions/")!
}

extension ShellModel {
    /// Connects the Site Control Center's "+" and "Manage" buttons.
    func installExtensionHandlers() {
        siteControls.addExtensionHandler = { [weak self] in self?.openAddExtension() }
        siteControls.manageExtensionsHandler = { [weak self] in self?.openManageExtensions() }
    }

    /// Extensions ▸ Add Extension…: the Chrome Web Store in a new tab.
    public func openAddExtension() {
        siteControls.close(.action)
        sidebar.newTab(url: ExtensionPages.webStore, title: "Chrome Web Store")
    }

    /// Extensions ▸ Manage Extensions…: the extensions page in a new tab.
    public func openManageExtensions() {
        siteControls.close(.action)
        sidebar.newTab(url: ExtensionPages.manage, title: "Extensions")
    }

    /// ⌘E: the Site Control Center of the selected tab, where its extension actions are.
    public func openExtensions() {
        if siteControls.isPresented { siteControls.close(.action) } else { siteControls.present() }
    }
}

/// The Extensions menu, between Archive and Window. [01] observed order and items; ⌘E [02] observed.
struct ExtensionCommands: Commands {
    @ObservedObject var model: ShellModel
    let hasWindow: Bool

    var body: some Commands {
        CommandMenu("Extensions") {
            Group {
                Button("Open Extensions") { model.openExtensions() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.selectedTabID == nil)
                Divider()
                Button("Add Extension…") { model.openAddExtension() }
                Button("Manage Extensions…") { model.openManageExtensions() }
            }
            .disabled(!hasWindow || model.isIncognito)
        }
    }
}
