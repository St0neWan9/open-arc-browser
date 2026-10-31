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
            case .webAuthn:
                if case .webAuthn(let dialog) = request {
                    ZStack(alignment: .top) {
                        Color.black.opacity(DialogLocalTokens.scrimOpacity)
                            .contentShape(Rectangle())
                        WebAuthnSheetView(center: center, dialog: dialog)
                            .frame(width: DialogLocalTokens.sheetWidth)
                            .padding(.top, DialogLocalTokens.topInset)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    .id(request.id)
                }
            case .dropdown, .infoBar:
                // Never queued (`DialogCenter.autofillPopups`, `DialogCenter.infoBarLists`).
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
    @State private var selection = 0

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
            if !presentation.choices.isEmpty {
                choiceList
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

    /// Single-choice rows (C25 certificates): a click selects, a double click selects and accepts.
    private var choiceList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(presentation.choices.enumerated()), id: \.offset) { index, choice in
                let chosen = index == selection
                VStack(alignment: .leading, spacing: 1) {
                    Text(choice.title)
                        .font(Typography.settingsBody.font.weight(.medium))
                        .lineLimit(1)
                    Text(choice.detail)
                        .font(Typography.settingsBody.font)
                        .foregroundStyle(chosen ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(chosen ? Color.accentColor : Color.clear))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    selection = index
                    let answer = DialogPresentation.answer(
                        for: request, button: presentation.buttons.count - 1, fieldValues: values,
                        checkbox: isChecked, selection: index
                    )
                    center.answer(request.id, with: answer)
                }
                .onTapGesture { selection = index }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.secondary.opacity(0.3)))
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
            let answer = DialogPresentation.answer(
                for: request, button: index, fieldValues: values, checkbox: isChecked, selection: selection
            )
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

/// Local tokens of the autofill dropdown (plan B148). Arc draws the engine's own dropdown: its
/// engine framework carries Chromium's autofill popup views (the popup, row and row-content views
/// and Arc's own `autofill_popup_view.cc` next to them), inferred (analysis). So the look is
/// Chromium 156's desktop popup (Arc's engine is 156.0.8078.48), restated here: a light card with
/// an 8 pt radius and a soft shadow, a 4 pt inset around the list, 36 pt rows (52 pt with a
/// second line), each row inset 4 pt with a 4 pt rounded hover fill, a 16 pt leading icon, the
/// main text Medium 13 and the second line Regular 13 secondary, and a thin divider between the
/// credentials and the footer actions ("Manage Passwords…"). inferred (analysis); the exact
/// colors in Arc's light and dark themes need a live capture (B148 report).
enum AutofillDropdownTokens {
    /// Narrowest dropdown; it is otherwise as wide as the field. inferred (analysis).
    static let minWidth: CGFloat = 156
    /// Widest dropdown. inferred (analysis).
    static let maxWidth: CGFloat = 456
    /// A row with one line. inferred (analysis).
    static let singleLineRowHeight: CGFloat = 36
    /// A row with a second line (the masked password, an address summary). inferred (analysis).
    static let rowHeight: CGFloat = 52
    /// A divider row: a 1 pt line with `padding` above and below. inferred (analysis).
    static let separatorHeight: CGFloat = 9
    /// Rows shown before the list scrolls (ours; Chromium sizes by the screen). unknown.
    static let maxVisibleRows = 8
    /// Space between the field and the dropdown (the field is taken 1 pt taller). inferred (analysis).
    static let gap: CGFloat = 1
    /// Card corner radius. inferred (analysis).
    static let cornerRadius: CGFloat = 8
    /// Inset of the list inside the card, and of each row's hover fill. inferred (analysis).
    static let padding: CGFloat = 4
    /// Hover fill corner radius. inferred (analysis).
    static let rowCornerRadius: CGFloat = 4
    /// Text inset from the row's hover fill (the row content's horizontal padding). inferred (analysis).
    static let rowContentInset: CGFloat = 8
    /// Leading icon size. inferred (analysis).
    static let iconSize: CGFloat = 16
    /// Space between the icon and the text. inferred (analysis).
    static let iconSpacing: CGFloat = 12
    /// Space between the two text lines. inferred (analysis).
    static let lineSpacing: CGFloat = 2
    /// Main text: Medium 13. inferred (analysis).
    static let mainText = TextStyle(size: 13, weight: .medium)
    /// Second line and footer actions: Regular 13. inferred (analysis).
    static let secondaryText = TextStyle(size: 13)
    /// Section headings: Bold 9, secondary. inferred (analysis).
    static let titleText = TextStyle(size: 9, weight: .bold)
    /// Hover fill: the label color at this opacity (a subtle neutral wash, not the accent).
    /// inferred (analysis).
    static let hoverOpacity: Double = 0.06
    /// Shadow under the card. inferred (analysis), restated as a SwiftUI shadow.
    static let shadowOpacity: Double = 0.18
    static let shadowRadius: CGFloat = 6
    static let shadowY: CGFloat = 2
}

/// Where the dropdown goes and how big it is. inferred (analysis): Chromium's popup placement.
/// Under the field (above it when it does not fit below and there is more room above), as wide as
/// the field within the minimum and maximum, starting at the field's left edge (right edge for a
/// right-to-left field), kept inside the panel.
enum AutofillDropdownPlacement {
    /// Height of one row.
    static func rowHeight(of suggestion: AutofillSuggestion) -> CGFloat {
        switch suggestion.kind {
        case .separator: AutofillDropdownTokens.separatorHeight
        case .title: AutofillDropdownTokens.singleLineRowHeight
        default: suggestion.label.isEmpty ? AutofillDropdownTokens.singleLineRowHeight : AutofillDropdownTokens.rowHeight
        }
    }

    /// The card's height: every row up to `maxVisibleRows` non-divider rows, plus the inset.
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
            height += rowHeight(of: suggestion)
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
        let fitsBelow = below + height <= panel.height
        let moreRoomAbove = field.minY > panel.height - field.maxY
        let y = fitsBelow || above < 0 || !moreRoomAbove ? below : above
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
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(
                        color: .black.opacity(AutofillDropdownTokens.shadowOpacity),
                        radius: AutofillDropdownTokens.shadowRadius, y: AutofillDropdownTokens.shadowY
                    )
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
            Divider()
                .padding(.vertical, AutofillDropdownTokens.padding)
                .frame(height: AutofillDropdownTokens.separatorHeight)
        case .title:
            Text(suggestion.mainText)
                .font(AutofillDropdownTokens.titleText.font)
                .foregroundStyle(.secondary)
                .padding(.horizontal, AutofillDropdownTokens.rowContentInset)
                .frame(height: AutofillDropdownTokens.singleLineRowHeight, alignment: .leading)
        default:
            let highlighted = state.selectedIndex == index
            let isFooter = Self.isFooter(suggestion)
            HStack(spacing: AutofillDropdownTokens.iconSpacing) {
                Image(systemName: Self.symbol(for: suggestion))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: AutofillDropdownTokens.iconSize, height: AutofillDropdownTokens.iconSize)
                VStack(alignment: .leading, spacing: AutofillDropdownTokens.lineSpacing) {
                    HStack(spacing: 6) {
                        Text(suggestion.mainText)
                            .font((isFooter ? AutofillDropdownTokens.secondaryText : AutofillDropdownTokens.mainText).font)
                            .foregroundStyle(isFooter ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                        if !suggestion.minorText.isEmpty {
                            Text(suggestion.minorText)
                                .font(AutofillDropdownTokens.secondaryText.font)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !suggestion.label.isEmpty {
                        Text(suggestion.label)
                            .font(AutofillDropdownTokens.secondaryText.font)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, AutofillDropdownTokens.rowContentInset)
            .frame(height: AutofillDropdownPlacement.rowHeight(of: suggestion))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AutofillDropdownTokens.rowCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(highlighted ? AutofillDropdownTokens.hoverOpacity : 0))
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

    /// A footer action ("Manage Passwords…", "Use Passkey from Another Device", "Clear form"): a
    /// command row with one line, drawn lighter than the credentials above it. inferred (analysis).
    static func isFooter(_ suggestion: AutofillSuggestion) -> Bool {
        suggestion.kind == .action && suggestion.label.isEmpty
    }

    /// Row icon (SF Symbols; the engine's icons are not ours to copy). A saved credential (a
    /// password, or a passkey, which the engine reports as a command with a second line) shows the
    /// site's globe, footer actions a gear, as the engine's own dropdown does. inferred (analysis).
    static func symbol(for suggestion: AutofillSuggestion) -> String {
        switch suggestion.kind {
        case .password: "globe"
        case .address: "mappin.and.ellipse"
        case .creditCard: "creditcard"
        case .autocomplete, .dataList: "clock.arrow.circlepath"
        case .action: isFooter(suggestion) ? "gearshape" : "globe"
        case .title, .separator: "circle"
        }
    }
}
