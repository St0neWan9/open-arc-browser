import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenArcEngine
import OpenArcDesign

// SwiftUI drawing of engine dialog requests (C7b). Behavior and placement: DialogCenter.swift.
// Sizes and colors are our own (the spec records none of these dialogs): unknown. Fonts follow the
// sheet scale of [07 §3] (title Bold 17 is for full sheets; these small cards use the 13 / 14 pt
// chrome sizes).

/// Local tokens of the dialog views. All unknown.
enum DialogLocalTokens {
    static let sheetWidth: CGFloat = 340
    static let cornerRadius: CGFloat = 12
    static let padding: CGFloat = 16
    static let topInset: CGFloat = 12
    static let scrimOpacity: Double = 0.18
}

private struct DialogCenterKey: EnvironmentKey {
    static let defaultValue: DialogCenter? = nil
}

private struct WindowDrawnPermissionTabKey: EnvironmentKey {
    static let defaultValue: EngineTabID? = nil
}

extension EnvironmentValues {
    /// The dialog queues of the window's controller; nil draws no dialogs (previews).
    var dialogCenter: DialogCenter? {
        get { self[DialogCenterKey.self] }
        set { self[DialogCenterKey.self] = newValue }
    }

    /// The tab whose permission bubble the window draws under the URL box; its web panel then
    /// leaves the permission request alone.
    var windowDrawnPermissionTab: EngineTabID? {
        get { self[WindowDrawnPermissionTabKey.self] }
        set { self[WindowDrawnPermissionTabKey.self] = newValue }
    }
}

/// Tab-modal dialogs over one web panel or split pane.
struct TabDialogOverlay: View {
    @ObservedObject var center: DialogCenter
    let tabID: EngineTabID
    let windowDrawnPermissionTab: EngineTabID?

    var body: some View {
        if let request = center.current(for: tabID) {
            let presentation = DialogPresentation(request)
            switch presentation.style {
            case .sheet:
                ZStack(alignment: .top) {
                    Color.black.opacity(DialogLocalTokens.scrimOpacity)
                        .contentShape(Rectangle())
                    DialogCardView(center: center, request: request, presentation: presentation)
                        .frame(width: DialogLocalTokens.sheetWidth)
                        .padding(.top, DialogLocalTokens.topInset)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                .id(request.id)
            case .permissionBubble:
                if windowDrawnPermissionTab != tabID {
                    DialogCardView(center: center, request: request, presentation: presentation)
                        .frame(width: PermissionPromptPlacement.bubbleWidth)
                        .padding(PermissionPromptPlacement.panelInset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(request.id)
                }
            case .filePanel:
                FileChooserPresenter(center: center, request: request)
                    .id(request.id)
            }
        }
    }
}

/// The permission bubble under the sidebar's URL box, for the selected tab.
struct PermissionBubbleUnderURLBox: View {
    @ObservedObject var center: DialogCenter
    let tabID: EngineTabID
    let origin: CGPoint

    var body: some View {
        if let request = center.current(for: tabID), case .permission = request {
            DialogCardView(center: center, request: request, presentation: DialogPresentation(request))
                .frame(width: PermissionPromptPlacement.bubbleWidth)
                .offset(x: origin.x, y: origin.y)
                .id(request.id)
        }
    }
}

/// One dialog card: title, message, fields, checkbox and buttons. The last button is the default
/// (Return); Escape closes without a choice (the request's default answer).
struct DialogCardView: View {
    let center: DialogCenter
    let request: EngineDialogRequest
    let presentation: DialogPresentation
    @State private var values: [String] = []
    @State private var isChecked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(presentation.title)
                .font(Typography.dialogBody.font.weight(.semibold))
            if !presentation.message.isEmpty {
                Text(presentation.message)
                    .font(Typography.settingsBody.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(presentation.fields.enumerated()), id: \.offset) { index, field in
                fieldView(field, index: index)
            }
            if let checkbox = presentation.checkbox {
                Toggle(checkbox, isOn: $isChecked)
                    .toggleStyle(.checkbox)
                    .font(Typography.settingsBody.font)
            }
            HStack {
                Spacer()
                ForEach(Array(presentation.buttons.enumerated()), id: \.offset) { index, title in
                    button(title, index: index)
                }
            }
        }
        .padding(DialogLocalTokens.padding)
        .background(
            RoundedRectangle(cornerRadius: DialogLocalTokens.cornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        )
        .onAppear {
            values = presentation.fields.map {
                if case .text(_, let initial) = $0 { return initial }
                return ""
            }
        }
        .onExitCommand { center.dismiss(request.id) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.dialog")
    }

    @ViewBuilder
    private func fieldView(_ field: DialogPresentation.Field, index: Int) -> some View {
        let binding = Binding(
            get: { index < values.count ? values[index] : "" },
            set: { if index < values.count { values[index] = $0 } }
        )
        switch field {
        case .text(let placeholder, _):
            TextField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        case .secure(let placeholder):
            SecureField(placeholder, text: binding).textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private func button(_ title: String, index: Int) -> some View {
        let action = {
            let answer = DialogPresentation.answer(for: request, button: index, fieldValues: values, checkbox: isChecked)
            center.answer(request.id, with: answer)
        }
        if index == presentation.buttons.count - 1 {
            Button(title, action: action)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        } else {
            Button(title, action: action)
                .controlSize(.small)
        }
    }
}

/// Shows the system open / save panel for a file chooser request and answers it.
struct FileChooserPresenter: View {
    let center: DialogCenter
    let request: EngineDialogRequest

    var body: some View {
        Color.clear
            .onAppear(perform: present)
    }

    private func present() {
        guard case .fileChooser(let chooser) = request else { return }
        let id = request.id
        let types = chooser.acceptedTypeIdentifiers.compactMap { UTType($0) }
        let finish: (NSApplication.ModalResponse, [URL]) -> Void = { response, urls in
            center.answer(id, with: .fileChooser(response == .OK && !urls.isEmpty ? .select(urls) : .cancel))
        }
        if chooser.mode == .save {
            let panel = NSSavePanel()
            if !types.isEmpty { panel.allowedContentTypes = types }
            if let url = chooser.defaultURL { panel.nameFieldStringValue = url.lastPathComponent }
            run(panel) { finish($0, panel.url.map { [$0] } ?? []) }
        } else {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = chooser.mode == .openMultiple
            panel.canChooseDirectories = chooser.mode == .openFolder
            panel.canChooseFiles = chooser.mode != .openFolder
            if !types.isEmpty { panel.allowedContentTypes = types }
            if let url = chooser.defaultURL { panel.directoryURL = url }
            run(panel) { finish($0, panel.urls) }
        }
    }

    /// As a sheet on the key window when there is one.
    private func run(_ panel: NSSavePanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
