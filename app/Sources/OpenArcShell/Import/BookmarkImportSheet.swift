import SwiftUI
import OpenArcDesign
import AppKit
import UniformTypeIdentifiers
import OpenArcImport

// The import sheet and its menu item (plans D3, D3b). [01 §Arc] observed: "Import from Another Browser…".
// The sheet's contents and layout are inferred; there is no reference screenshot.

/// Open Arc ▸ Import from Another Browser…, first of its group. [01 §Arc] observed order;
/// placed by `AppMenuCommands`.
struct BookmarkImportMenuItem: View {
    /// Not observed: the item reads only `isOffTheRecord`, which never changes, and observing the
    /// controller would rebuild the menu on every workspace change (B103).
    let controller: WorkspaceController

    var body: some View {
        Button("Import from Another Browser…") { BookmarkImportPresenter.present(controller: controller) }
            .disabled(controller.isOffTheRecord)
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

    /// "Choose File…": an open panel for bookmark, history and password exports. Chrome's
    /// `Bookmarks` file has no extension, so plain data files are allowed too; the content decides
    /// the format.
    static func chooseFile(_ completion: @escaping @MainActor (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.html, .propertyList, .json, .commaSeparatedText, .zip, .data]
        panel.message = BookmarkImportLocalTokens.fileHint
        panel.prompt = BookmarkImportLocalTokens.importButton
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { completion(url) }
        }
    }
}

/// The sheet: a source list (Arc, detected Chromium-family profiles and Safari), a checkbox per
/// data kind (D3b; for Arc the first one is its sidebar, D15), Choose File…, then a summary.
struct BookmarkImportSheet: View {
    @ObservedObject var model: BookmarkImportModel
    typealias T = BookmarkImportLocalTokens

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T.title).font(Typography.dialogTitle.font)
            switch model.phase {
            case .choosing: chooser
            case .importing:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(T.importing).font(Typography.settingsBody.font)
                }
            case .done(let lines): result(lines)
            case .failed(let message): result([ImportSummaryLine(text: message, isError: true)])
            }
        }
        .padding(20)
        .frame(width: T.sheetWidth)
    }

    @ViewBuilder
    private var chooser: some View {
        Text(T.message).font(Typography.settingsBody.font).foregroundStyle(.secondary)
        if model.sources.isEmpty {
            Text(T.noProfiles).font(Typography.settingsBody.font).foregroundStyle(.secondary)
        } else {
            Picker("Source", selection: $model.selectedSourceID) {
                ForEach(model.sources) { source in
                    Text(model.label(for: source)).tag(Optional(source.id))
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            kinds
        }
        HStack {
            Button(T.chooseFile) {
                BookmarkImportPresenter.chooseFile { [model] url in model.importFile(url) }
            }
            Spacer()
            Button(T.cancel) { model.close() }
                .keyboardShortcut(.cancelAction)
            Button(T.importButton) { Task { await model.importSelected() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canImport)
        }
    }

    /// One checkbox per kind the selected source offers.
    @ViewBuilder
    private var kinds: some View {
        let available = model.availableKinds(for: model.selectedSource)
        let isArc: Bool = { if case .arc? = model.selectedSource { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 4) {
            ForEach(available, id: \.self) { kind in
                Toggle(T.label(for: kind, isSidebarSource: isArc), isOn: Binding(
                    get: { model.selectedKinds.contains(kind) },
                    set: { on in
                        if on { model.selectedKinds.insert(kind) } else { model.selectedKinds.remove(kind) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
        if case .safari? = model.selectedSource {
            Text(T.safariHint).font(Typography.settingsCaption.font).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            if isArc, model.selectedKinds.contains(.bookmarks) {
                Text(T.arcHint).font(Typography.settingsCaption.font).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.selectedKinds.contains(.passwords) {
                Text(T.keychainHint).font(Typography.settingsCaption.font).foregroundStyle(.secondary)
            }
        }
        if !model.engineSupports(.history) {
            Text(T.noEngineKinds).font(Typography.settingsCaption.font).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func result(_ lines: [ImportSummaryLine]) -> some View {
        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
            Text(line.text)
                .font(Typography.settingsBody.font)
                .foregroundStyle(line.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            if lines.contains(where: \.needsFullDiskAccess) {
                // Opens the pane only; Open Arc never asks for the permission itself.
                Button(T.openPrivacySettings) { NSWorkspace.shared.open(T.fullDiskAccessURL) }
            }
            Spacer()
            Button(T.done) { model.close() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
