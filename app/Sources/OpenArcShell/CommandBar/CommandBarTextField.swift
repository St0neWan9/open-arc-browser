import SwiftUI
import AppKit

// The command bar's text field, backed by AppKit so focus does not depend on SwiftUI's
// `@FocusState` timing. A SwiftUI focus request made in `onAppear` is often lost in a real
// window (the view is not in the window yet, or the window is not key yet), and then typing goes
// nowhere until the user clicks the field (B26). This field makes itself first responder as soon
// as it is in a window, and again whenever the view model asks (`focusRequestID`).

/// Visual settings of the field, resolved by `CommandBarView`.
struct CommandBarTextFieldStyle {
    var font: NSFont
    var textColor: NSColor
    var placeholder: String
    var placeholderColor: NSColor
}

/// The AppKit field. Keys the bar reacts to arrive through the delegate's `doCommandBy`.
final class CommandBarNSTextField: NSTextField {
    /// Called when the field lands in a window (or changes window).
    var onMoveToWindow: (() -> Void)?
    /// Makes the field take the keyboard now. Installed by the representable.
    var takeFocus: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }

    /// The field editor while this field is being edited.
    var editingTextView: NSTextView? { currentEditor() as? NSTextView }

    /// Whether keyboard input currently goes to this field.
    var isEditingFocus: Bool {
        guard let editor = editingTextView else { return false }
        return window?.firstResponder === editor
    }
}

/// Hosts `CommandBarNSTextField` in SwiftUI and keeps it in step with `CommandBarViewModel`.
struct CommandBarTextField: NSViewRepresentable {
    @ObservedObject var viewModel: CommandBarViewModel
    let style: CommandBarTextFieldStyle

    func makeCoordinator() -> Coordinator { Coordinator(viewModel: viewModel) }

    func makeNSView(context: Context) -> CommandBarNSTextField {
        let field = CommandBarNSTextField(string: viewModel.queryText)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityIdentifier("openarc.commandbar.field")
        field.delegate = context.coordinator
        apply(style, to: field)
        let coordinator = context.coordinator
        coordinator.field = field
        field.onMoveToWindow = { [weak coordinator] in coordinator?.fieldDidMoveToWindow() }
        field.takeFocus = { [weak coordinator] in coordinator?.takeFocusNow() }
        return field
    }

    func updateNSView(_ field: CommandBarNSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.viewModel = viewModel
        apply(style, to: field)
        coordinator.syncText()
        coordinator.handleRequests()
    }

    /// Full width offered, the font's natural line height.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: CommandBarNSTextField, context: Context) -> CGSize? {
        // Takes the height offered (the command bar offers the measured 23 pt line, [07 §5]);
        // the font's natural line height otherwise.
        CGSize(width: proposal.width ?? 200, height: proposal.height ?? nsView.intrinsicContentSize.height)
    }

    private func apply(_ style: CommandBarTextFieldStyle, to field: NSTextField) {
        if field.font != style.font { field.font = style.font }
        if field.textColor != style.textColor { field.textColor = style.textColor }
        if field.placeholderAttributedString?.string != style.placeholder {
            field.placeholderAttributedString = NSAttributedString(
                string: style.placeholder,
                attributes: [.font: style.font, .foregroundColor: style.placeholderColor]
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var viewModel: CommandBarViewModel
        weak var field: CommandBarNSTextField?
        /// Requests already acted on. Nil until the field first reaches a window, so the request
        /// made by `open` before the view existed is still served.
        private var handledFocusRequest: Int?
        private var handledSelectAllRequest: Int?

        init(viewModel: CommandBarViewModel) {
            self.viewModel = viewModel
        }

        // MARK: Focus

        func fieldDidMoveToWindow() {
            // A field that appears belongs to a bar that was just opened: take the keyboard.
            handledFocusRequest = nil
            handleRequests()
        }

        /// Serves pending focus and select-all requests once the field is in a window.
        func handleRequests() {
            guard let field, field.window != nil else { return }
            if handledFocusRequest != viewModel.focusRequestID {
                handledFocusRequest = viewModel.focusRequestID
                handledSelectAllRequest = viewModel.selectAllRequestID
                focus(selectAll: viewModel.isPrefillUnedited)
                // SwiftUI may still move the first responder while it finishes building the
                // window's view tree; check again on the next turn of the run loop.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let field = self.field, field.window != nil, !field.isEditingFocus else { return }
                    self.focus(selectAll: self.viewModel.isPrefillUnedited)
                }
            } else if handledSelectAllRequest != viewModel.selectAllRequestID {
                handledSelectAllRequest = viewModel.selectAllRequestID
                focus(selectAll: true)
            }
        }

        private func focus(selectAll: Bool) {
            guard let field, let window = field.window else { return }
            // Bring the window forward only inside an app that is already active: never steal
            // focus from another app.
            if let app = NSApp, app.isActive, !window.isKeyWindow, window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
            }
            if !field.isEditingFocus {
                window.makeFirstResponder(field)
            }
            guard let editor = field.editingTextView else { return }
            let length = (editor.string as NSString).length
            editor.selectedRange = selectAll ? NSRange(location: 0, length: length) : NSRange(location: length, length: 0)
            // Keys typed while this bar's window was opening go in now (B29).
            if field.isEditingFocus {
                NewWindowTypeAhead.shared.commandBarFieldIsReady(in: window, isLittleArc: viewModel.presentation == .littleArc)
            }
        }

        /// Makes the field first responder now (the Little Arc window does this as it is shown, B29).
        func takeFocusNow() {
            focus(selectAll: viewModel.isPrefillUnedited)
        }

        // MARK: Text

        /// Pushes programmatic text changes (prefill, Tab completion, reset) into the field.
        func syncText() {
            guard let field, field.stringValue != viewModel.queryText else { return }
            // Never replace text while an input method is composing.
            if let editor = field.editingTextView, editor.hasMarkedText() { return }
            field.stringValue = viewModel.queryText
            if let editor = field.editingTextView {
                let length = (editor.string as NSString).length
                editor.selectedRange = NSRange(location: length, length: 0)
            }
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field, viewModel.queryText != field.stringValue else { return }
            viewModel.queryText = field.stringValue
        }

        // MARK: Keys

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let key = Self.key(for: commandSelector) else { return false }
            return viewModel.handle(key) != .ignored
        }

        /// Maps AppKit's key commands to the bar's keys.
        static func key(for selector: Selector) -> CommandBarKey? {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return .up
            case #selector(NSResponder.moveDown(_:)): return .down
            case #selector(NSResponder.insertTab(_:)): return .tab
            case #selector(NSResponder.insertBacktab(_:)): return .shiftTab
            case #selector(NSResponder.insertNewline(_:)): return .returnKey
            case #selector(NSResponder.cancelOperation(_:)): return .escape
            default: return nil
            }
        }
    }
}
