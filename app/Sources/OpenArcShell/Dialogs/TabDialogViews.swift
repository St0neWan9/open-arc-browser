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
        ZStack(alignment: .topLeading) {
            queuedDialog
            // The autofill dropdown (C13) floats under its field, beside any queued dialog.
            if let popup = center.autofillPopup(for: tabID) {
                AutofillDropdownView(center: center, popup: popup)
                    .id(popup.id)
            }
        }
    }

    @ViewBuilder
    private var queuedDialog: some View {
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
            case .dropdown:
                // Never queued (`DialogCenter.autofillPopups`).
                EmptyView()
            }
        }
    }
}

/// The permission bubble (or the password save prompt, C13) under the sidebar's URL box, for the
/// selected tab.
struct PermissionBubbleUnderURLBox: View {
    @ObservedObject var center: DialogCenter
    let tabID: EngineTabID
    let origin: CGPoint

    var body: some View {
        if let request = center.current(for: tabID), DialogPresentation(request).style == .permissionBubble {
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

// MARK: - Autofill dropdown (C13)

/// Local tokens of the autofill dropdown. Arc's dropdown is not recorded ([00 §A]: "style not
/// captured"): all unknown, sized like a macOS menu.
enum AutofillDropdownTokens {
    static let minWidth: CGFloat = 220
    static let maxWidth: CGFloat = 420
    static let rowHeight: CGFloat = 36
    static let singleLineRowHeight: CGFloat = 26
    static let separatorHeight: CGFloat = 9
    static let maxVisibleRows = 8
    static let gap: CGFloat = 2
    static let cornerRadius: CGFloat = 8
    static let padding: CGFloat = 4
}

/// Where the dropdown goes: under the field (above it when there is no room below), left-aligned
/// (right-aligned for right-to-left fields), kept inside the panel. inferred (Chromium's popup
/// placement).
enum AutofillDropdownPlacement {
    static func height(of suggestions: [AutofillSuggestion]) -> CGFloat {
        var height: CGFloat = 0
        var rows = 0
        for suggestion in suggestions {
            if suggestion.kind == .separator {
                height += AutofillDropdownTokens.separatorHeight
                continue
            }
            guard rows < AutofillDropdownTokens.maxVisibleRows else { break }
            rows += 1
            height += suggestion.label.isEmpty ? AutofillDropdownTokens.singleLineRowHeight : AutofillDropdownTokens.rowHeight
        }
        return height + 2 * AutofillDropdownTokens.padding
    }

    static func frame(for state: AutofillPopupState, in panel: CGSize) -> CGRect {
        let bounds = state.elementBounds
        let field = CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)
        let width = min(max(field.width, AutofillDropdownTokens.minWidth), AutofillDropdownTokens.maxWidth, max(panel.width, 1))
        let height = height(of: state.suggestions)
        var x = state.isRightToLeft ? field.maxX - width : field.minX
        x = min(max(x, 0), max(panel.width - width, 0))
        let below = field.maxY + AutofillDropdownTokens.gap
        let above = field.minY - AutofillDropdownTokens.gap - height
        let y = below + height <= panel.height || above < 0 ? below : above
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// The autofill dropdown under a form field. Keyboard focus stays in the page (the engine handles
/// ↑ / ↓ / Return / Escape there and updates `session`); the pointer highlights and chooses rows.
struct AutofillDropdownView: View {
    let center: DialogCenter
    let popup: AutofillPopup
    @State private var state: AutofillPopupState

    init(center: DialogCenter, popup: AutofillPopup) {
        self.center = center
        self.popup = popup
        _state = State(initialValue: popup.session.state)
    }

    var body: some View {
        GeometryReader { proxy in
            let frame = AutofillDropdownPlacement.frame(for: state, in: proxy.size)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(state.suggestions.enumerated()), id: \.offset) { index, suggestion in
                        row(suggestion, index: index)
                    }
                }
                .padding(AutofillDropdownTokens.padding)
            }
            .scrollIndicators(.never)
            .frame(width: frame.width, height: frame.height)
            .background(
                RoundedRectangle(cornerRadius: AutofillDropdownTokens.cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 3)
            )
            .clipShape(RoundedRectangle(cornerRadius: AutofillDropdownTokens.cornerRadius, style: .continuous))
            .onHover { inside in
                popup.session.send(.pointerInside(inside))
                if !inside { popup.session.send(.select(nil)) }
            }
            .offset(x: frame.minX, y: frame.minY)
        }
        .task {
            for await next in popup.session.updates() { state = next }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.autofill")
    }

    @ViewBuilder
    private func row(_ suggestion: AutofillSuggestion, index: Int) -> some View {
        switch suggestion.kind {
        case .separator:
            Divider().frame(height: AutofillDropdownTokens.separatorHeight)
        case .title:
            Text(suggestion.mainText)
                .font(Typography.settingsBody.font.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .frame(height: AutofillDropdownTokens.singleLineRowHeight, alignment: .leading)
        default:
            let highlighted = state.selectedIndex == index
            HStack(spacing: 8) {
                Image(systemName: Self.symbol(for: suggestion.kind))
                    .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(suggestion.mainText).lineLimit(1)
                        if !suggestion.minorText.isEmpty {
                            Text(suggestion.minorText).lineLimit(1).foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        }
                    }
                    .font(Typography.settingsBody.font)
                    if !suggestion.label.isEmpty {
                        Text(suggestion.label)
                            .font(Typography.settingsBody.font)
                            .foregroundStyle(highlighted ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 8)
            .frame(height: suggestion.label.isEmpty ? AutofillDropdownTokens.singleLineRowHeight : AutofillDropdownTokens.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(highlighted ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { inside in
                if inside, suggestion.isSelectable { popup.session.send(.select(index)) }
            }
            .onTapGesture {
                if suggestion.isAcceptable { popup.session.send(.accept(index)) }
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(suggestion.label.isEmpty ? suggestion.mainText : "\(suggestion.mainText), \(suggestion.label)")
        }
    }

    /// Row icon (SF Symbols; Chrome's icons are not ours to copy). unknown.
    static func symbol(for kind: AutofillSuggestion.Kind) -> String {
        switch kind {
        case .password: "key.fill"
        case .address: "mappin.and.ellipse"
        case .creditCard: "creditcard"
        case .autocomplete, .dataList: "clock.arrow.circlepath"
        case .action: "gearshape"
        case .title, .separator: "circle"
        }
    }
}
