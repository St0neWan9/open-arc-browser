import SwiftUI
import OpenArcDesign
import AppKit
import UniformTypeIdentifiers
import OpenArcImport

// The import sheet and its menu item (plan D3). [01 §Arc] observed: "Import from Another Browser…".
// The sheet's contents and layout are inferred; there is no reference screenshot.

/// Open Arc ▸ Import from Another Browser…, after Set as Default Browser. [01 §Arc] observed order.
struct BookmarkImportCommands: Commands {
    let controller: WorkspaceController

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Import from Another Browser…") { BookmarkImportPresenter.present(controller: controller) }
                .disabled(controller.isOffTheRecord)
        }
    }
}

/// Shows the import sheet on the key browser window (a floating panel when no window is open).
@MainActor
enum BookmarkImportPresenter {
    static func present(controller: WorkspaceController) {
        let model = BookmarkImportModel(controller: controller)
        let hosting = NSHostingController(rootView: BookmarkImportSheet(model: model))
        let host = NSApp.keyWindow ?? NSApp.mainWindow
        if let host, host.attachedSheet == nil {
            let sheet = NSWindow(contentViewController: hosting)
            model.onClose = { [weak host, weak sheet] in
                guard let sheet else { return }
                host?.endSheet(sheet)
            }
            host.beginSheet(sheet)
        } else {
            let panel = NSPanel(contentViewController: hosting)
            panel.title = BookmarkImportLocalTokens.title
            panel.styleMask = [.titled, .closable]
            model.onClose = { [weak panel] in panel?.close() }
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// "Choose File…": an open panel for bookmark exports. Chrome's `Bookmarks` file has no
    /// extension, so plain data files are allowed too; the content decides the format.
    static func chooseFile(_ completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .propertyList, .json, .data]
        panel.message = BookmarkImportLocalTokens.fileHint
        panel.prompt = BookmarkImportLocalTokens.importButton
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
    }
}

/// The sheet: a source list (detected Chromium-family profiles), Choose File…, then a summary.
struct BookmarkImportSheet: View {
    @ObservedObject var model: BookmarkImportModel
    typealias T = BookmarkImportLocalTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T.title).font(Typography.dialogTitle.font)
            switch model.phase {
            case .choosing: chooser
            case .done(let summary): result(BookmarkImportModel.summaryText(summary), isError: false)
            case .failed(let message): result(message, isError: true)
            }
        }
        .padding(20)
        .frame(width: T.sheetWidth)
    }

    @ViewBuilder
    private var chooser: some View {
        Text(T.message).font(Typography.settingsBody.font).foregroundStyle(.secondary)
        if model.profiles.isEmpty {
            Text(T.noProfiles).font(Typography.settingsBody.font).foregroundStyle(.secondary)
        } else {
            Picker("Source", selection: $model.selectedProfileID) {
                ForEach(model.profiles) { profile in
                    Text(model.label(for: profile)).tag(Optional(profile.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
        Text(T.laterKinds).font(Typography.settingsCaption.font).foregroundStyle(.tertiary)
        HStack {
            Button(T.chooseFile) {
                BookmarkImportPresenter.chooseFile { [model] url in model.importFile(url) }
            }
            Spacer()
            Button(T.cancel) { model.close() }
                .keyboardShortcut(.cancelAction)
            Button(T.importButton) { model.importSelectedProfile() }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedProfileID == nil)
        }
    }

    @ViewBuilder
    private func result(_ text: String, isError: Bool) -> some View {
        Text(text)
            .font(Typography.settingsBody.font)
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button(T.done) { model.close() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
