import AppKit
import SwiftUI
import OpenArcEngine
import OpenArcDesign

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

    /// One extension's details page (an action's "Manage Extension", B116). inferred.
    static func details(extensionID: String) -> URL? {
        var components = URLComponents(string: "chrome://extensions/")
        components?.queryItems = [URLQueryItem(name: "id", value: extensionID)]
        return components?.url
    }
}

/// The question before an action's "Remove" (B116). `06 §31` observed: Arc's own card, the
/// puzzle icon, "Remove “<name>” extension from Arc?" and Cancel (ESC) / Remove Extension (↵);
/// ours names Open Arc. A prompt card (B197) centered in the window over the dimmed window.
enum ExtensionRemovalCard {
    static func title(extensionName: String) -> String {
        "Remove “\(extensionName)” extension from \(AppIdentity.displayName)?"
    }
    static let removeButton = "Remove Extension"
    static let cancelButton = "Cancel"
    /// [06 §31] observed: the puzzle icon.
    static let symbol = "puzzlepiece.extension.fill"
}

/// Declares the removal card to the window while the Site Control Center asks.
struct ExtensionRemovalCardModal: ViewModifier {
    @ObservedObject var siteControls: SiteControlsModel
    let palette: ThemePalette

    func body(content: Content) -> some View {
        let question = siteControls.extensionRemovalQuestion
        content
            .windowModal(id: "removeExtension.\(question?.id.uuidString ?? "")", isPresented: question != nil,
                         width: Double(PromptCardTokens.width)) {
                if let question {
                    ExtensionRemovalCardView(question: question, siteControls: siteControls, palette: palette)
                }
            }
    }
}

/// The removal card itself.
struct ExtensionRemovalCardView: View {
    let question: ExtensionRemovalQuestion
    let siteControls: SiteControlsModel
    let palette: ThemePalette

    var body: some View {
        let cancel = PromptCardButtonItem(title: ExtensionRemovalCard.cancelButton, role: .cancel) {
            siteControls.answerExtensionRemoval(false)
        }
        let remove = PromptCardButtonItem(title: ExtensionRemovalCard.removeButton, role: .primary) {
            siteControls.answerExtensionRemoval(true)
        }
        PromptCard(palette: palette, header: .symbol(ExtensionRemovalCard.symbol),
                   title: ExtensionRemovalCard.title(extensionName: question.extensionName),
                   buttons: [cancel, remove]) { EmptyView() }
            .accessibilityIdentifier("openarc.removeExtension")
    }
}

extension ShellModel {
    /// Connects the Site Control Center's "+" and "Manage" buttons.
    func installExtensionHandlers() {
        siteControls.addExtensionHandler = { [weak self] in self?.openAddExtension() }
        siteControls.manageExtensionsHandler = { [weak self] in self?.openManageExtensions() }
        // An action's right-click menu (B116). Incognito windows cannot remove extensions, as the
        // Extensions menu is disabled there.
        siteControls.manageExtensionHandler = { [weak self] id in self?.openManageExtension(id) }
        if isIncognito {
            siteControls.confirmExtensionRemoval = nil
        } else {
            let controls = siteControls
            siteControls.confirmExtensionRemoval = { @MainActor [weak controls] name in
                guard let controls else { return false }
                return await controls.askToRemoveExtension(name)
            }
        }
    }

    /// An action's "Manage Extension": that extension's details page in a new tab (B116).
    func openManageExtension(_ extensionID: String) {
        siteControls.close(.action)
        guard let url = ExtensionPages.details(extensionID: extensionID) else { return }
        sidebar.newTab(url: url, title: "Extensions")
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

/// The Extensions menu, between Archive and Window. [01 §Extensions] observed: Add Extension… ·
/// Manage Extensions…, nothing else. Open Extensions (⌘E, [02] observed) is in no menu; its key
/// lives in `KeyOnlyMenuItems`. B62.
struct ExtensionCommands: Commands {
    let model: ShellModel
    /// Rebuilds these items only when a value they show changed (`MenuBarState`, B103).
    @ObservedObject private var menuBar: MenuBarState
    let hasWindow: Bool

    init(model: ShellModel, hasWindow: Bool) {
        self.model = model
        self.hasWindow = hasWindow
        _menuBar = ObservedObject(wrappedValue: model.menuBar)
    }

    var body: some Commands {
        CommandMenu("Extensions") {
            Group {
                Button("Add Extension…") { model.openAddExtension() }
                Button("Manage Extensions…") { model.openManageExtensions() }
            }
            .disabled(!hasWindow || model.isIncognito)
        }
    }
}
