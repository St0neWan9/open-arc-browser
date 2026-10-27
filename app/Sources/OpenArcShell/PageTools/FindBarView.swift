import SwiftUI
import AppKit
import OpenArcDesign

// The find bar drawn over the top right of the focused web panel or split pane (B25). Its look is
// not in the spec: every value here is a local token, "own design".

/// Local tokens of the find bar. Own design (the spec records no find bar look).
enum FindBarTokens {
    /// Bar width. Own design.
    static let width: CGFloat = 300
    /// Bar height. Own design.
    static let height: CGFloat = 36
    /// Inset from the panel's top and right edges. Own design.
    static let margin: CGFloat = 10
    /// Corner radius of the bar. Own design.
    static let cornerRadius: CGFloat = 10
    /// Size of the ˄ ˅ ✕ buttons. Own design.
    static let buttonSize: CGFloat = 22
    /// Shadow under the bar. Own design.
    static let shadowRadius: CGFloat = 8
    static let shadowOpacity: Double = 0.18
    static let placeholder = "Find in page"
    /// Height of the text field line. Own design.
    static let fieldHeight: CGFloat = 18
    /// Shown instead of "n of m" when the query matches nothing. Own wording.
    static let noMatches = "No matches"
}

/// What a web panel needs to draw the find bar for the tab it shows.
@MainActor
struct FindBarHost {
    let model: FindBarModel
    /// The model tab the panel shows.
    let tabID: UUID
}

extension ShellModel {
    /// The find bar host for the single web panel (the selected tab); nil without a selection.
    var findBarHost: FindBarHost? {
        selectedTabID.map { FindBarHost(model: findBar, tabID: $0) }
    }
}

/// The find bar; shown by `WebPanel` when `FindBarModel.isVisible(for:)` is true for its tab.
struct FindBarView: View {
    @ObservedObject var model: FindBarModel
    let tabID: UUID

    var body: some View {
        let query = Binding(
            get: { model.state(for: tabID).query },
            set: { model.updateQuery($0) }
        )
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            // Enter: next match; ⇧Enter: previous match. Own design (browser convention).
            FindBarTextField(
                text: query,
                focusRequest: model.focusRequest,
                consumeFocusRequest: model.consumeFocusRequest,
                font: Typography.addressField.nsFont,
                onReturn: { shift in if shift { model.findPrevious() } else { model.findNext() } },
                onEscape: { model.close(tabID) }
            )
            .frame(height: FindBarTokens.fieldHeight)
            if let text = statusText {
                Text(text)
                    .font(Typography.settingsCaption.font.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            button("chevron.up", label: "Previous Match", action: model.findPrevious)
            button("chevron.down", label: "Next Match", action: model.findNext)
            button("xmark", label: "Close Find Bar") { model.close(tabID) }
        }
        .padding(.horizontal, 10)
        .frame(width: FindBarTokens.width, height: FindBarTokens.height)
        .background(
            RoundedRectangle(cornerRadius: FindBarTokens.cornerRadius, style: .continuous)
                .fill(.regularMaterial)
                .shadow(color: .black.opacity(FindBarTokens.shadowOpacity), radius: FindBarTokens.shadowRadius, y: 2)
        )
        .padding(.top, FindBarTokens.margin)
        .padding(.trailing, FindBarTokens.margin)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.findbar")
    }

    private var statusText: String? {
        guard let result = model.result(for: tabID) else { return nil }
        return result.matches == 0 && result.isFinal ? FindBarTokens.noMatches : FindBarModel.statusText(result)
    }

    private func button(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: FindBarTokens.buttonSize, height: FindBarTokens.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The find bar's text field, backed by AppKit. A SwiftUI `@FocusState` request made in `onAppear`
/// was lost in the real app: after ⌘F the bar showed but the page kept the keyboard, so typed text
/// went to the page and the bar's select-all selected the whole page (B19, the same failure as the
/// command bar's B26). This field takes the keyboard once per ⌘F (`focusRequest`), also when the
/// request comes before the field is in a window, and selects its text so typing replaces a kept
/// query. A field rebuilt later (tab switch, Library) leaves the keyboard where it is.
struct FindBarTextField: NSViewRepresentable {
    @Binding var text: String
    /// `FindBarModel.focusRequest`; a new value focuses the field again.
    let focusRequest: Int
    /// `FindBarModel.consumeFocusRequest`: true once per ⌘F.
    let consumeFocusRequest: () -> Bool
    let font: NSFont
    /// Return was pressed; the flag is true with Shift held.
    let onReturn: (Bool) -> Void
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField(string: text)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.font = font
        field.placeholderAttributedString = NSAttributedString(
            string: FindBarTokens.placeholder,
            attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor]
        )
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("openarc.findbar.field")
        field.delegate = context.coordinator
        field.onMoveToWindow = { [weak coordinator = context.coordinator] in coordinator?.serveFocusRequest() }
        context.coordinator.field = field
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // Never replace text while an input method is composing.
        let composing = (field.currentEditor() as? NSTextView)?.hasMarkedText() ?? false
        if field.stringValue != text, !composing {
            field.stringValue = text
        }
        coordinator.serveFocusRequest()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FocusingTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: proposal.height ?? nsView.intrinsicContentSize.height)
    }

    /// An `NSTextField` that reports when it lands in a window.
    final class FocusingTextField: NSTextField {
        var onMoveToWindow: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onMoveToWindow?() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FindBarTextField
        weak var field: FocusingTextField?

        init(parent: FindBarTextField) {
            self.parent = parent
        }

        /// Focuses the field for a ⌘F not served yet, once the field is in a window.
        func serveFocusRequest() {
            guard field?.window != nil, parent.consumeFocusRequest() else { return }
            focus()
        }

        /// Makes the field first responder and selects its text; again on the next run-loop turn,
        /// because SwiftUI may still move the first responder while it inserts the bar.
        func focus() {
            take()
            DispatchQueue.main.async { [weak self] in self?.take() }
        }

        private func take() {
            guard let field, let window = field.window else { return }
            if let editor = field.currentEditor(), window.firstResponder === editor {
                editor.selectAll(nil)
                return
            }
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field, parent.text != field.stringValue else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
                parent.onReturn(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            default:
                return false
            }
        }
    }
}

/// Puts the find bar at the top right of a web panel when it is visible for the panel's tab.
struct FindBarOverlay: View {
    let host: FindBarHost
    @ObservedObject private var model: FindBarModel

    init(host: FindBarHost) {
        self.host = host
        self.model = host.model
    }

    var body: some View {
        if model.isVisible(for: host.tabID) {
            FindBarView(model: model, tabID: host.tabID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
    }
}
