import SwiftUI
import AppKit
import OpenArcEngine

// JavaScript alert / confirm / prompt as a system alert sheet on the window. [06 §30] observed: bold
// "<origin> says", the message, side-by-side Cancel and OK, and for prompt a text field between them.
//
// The sheet belongs to the head of the tab's queue, so the queue's rules hold: one at a time, and only
// while the tab is on screen. A sheet whose tab leaves the screen closes without an answer and comes
// back with the tab; a request the engine withdraws closes its sheet the same way.

/// Local tokens of the alert sheet.
enum SystemAlertTokens {
    /// Width of the prompt's text field. inferred (E36 capture: about 282 pt).
    static let promptFieldWidth: CGFloat = 282
    /// inferred (the system's regular field height).
    static let promptFieldHeight: CGFloat = 24
    /// Escape as a button's key equivalent.
    static let escapeKeyEquivalent = "\u{1b}"
    /// Return as a button's key equivalent.
    static let returnKeyEquivalent = "\r"
}

/// What the alert shows. Pure, for tests; `makeAlert` turns it into the sheet.
struct SystemAlertContent: Equatable {
    var title: String
    var message: String
    /// Buttons from left to right, as in `DialogPresentation.buttons`; the last is the default.
    var buttons: [String]
    /// The prompt's text, nil for the alerts without a field.
    var fieldText: String?
    /// Title of the "prevent more dialogs" checkbox, if the page may get one.
    var checkbox: String?

    init(_ presentation: DialogPresentation) {
        title = presentation.title
        message = presentation.message
        buttons = presentation.buttons
        fieldText = presentation.fields.lazy.compactMap { field -> String? in
            if case .text(_, let initial) = field { return initial }
            return nil
        }.first
        checkbox = presentation.checkbox
    }

    /// `DialogPresentation.buttons` index of the button that ended the alert; nil when it was closed
    /// without one. `NSAlert` numbers its buttons from the right, the order they are added in.
    func buttonIndex(for response: NSApplication.ModalResponse) -> Int? {
        let fromRight = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard buttons.indices.contains(fromRight) else { return nil }
        return buttons.count - 1 - fromRight
    }

    /// The configured alert. Return presses the rightmost button, Esc the one left of it.
    @MainActor
    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        // No icon is set: run as a sheet, the system alert then shows none, 260 pt wide like Arc's.
        // [06 §30] observed.
        alert.messageText = title
        alert.informativeText = message
        for title in buttons.reversed() { alert.addButton(withTitle: title) }
        alert.buttons.first?.keyEquivalent = SystemAlertTokens.returnKeyEquivalent
        if alert.buttons.count > 1 { alert.buttons[1].keyEquivalent = SystemAlertTokens.escapeKeyEquivalent }
        if let checkbox {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = checkbox
        }
        if let fieldText {
            let t = SystemAlertTokens.self
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: t.promptFieldWidth, height: t.promptFieldHeight))
            field.stringValue = fieldText
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
        }
        return alert
    }
}

/// Runs one alert on a window and answers its request.
@MainActor
final class SystemAlertController {
    private let center: DialogCenter
    private let request: EngineDialogRequest
    private let content: SystemAlertContent
    private var alert: NSAlert?
    private weak var window: NSWindow?
    /// The view is gone: nothing may show anymore, and a closing sheet answers nothing.
    private var isClosed = false

    init(center: DialogCenter, request: EngineDialogRequest) {
        self.center = center
        self.request = request
        content = SystemAlertContent(DialogPresentation(request))
    }

    func present(on window: NSWindow) {
        guard alert == nil, !isClosed else { return }
        let alert = content.makeAlert()
        self.alert = alert
        self.window = window
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated { self?.finish(response, alert: alert) }
        }
    }

    /// Closes the sheet without answering: the request stays queued.
    func close() {
        isClosed = true
        guard let alert, let window else { return }
        window.endSheet(alert.window, returnCode: .abort)
    }

    /// Answers the request with the button that ended `alert`.
    func finish(_ response: NSApplication.ModalResponse, alert: NSAlert) {
        guard !isClosed, let index = content.buttonIndex(for: response) else { return }
        let field = (alert.accessoryView as? NSTextField)?.stringValue
        let answer = DialogPresentation.answer(
            for: request, button: index, fieldValues: field.map { [$0] } ?? [],
            checkbox: alert.suppressionButton?.state == .on
        )
        center.answer(request.id, with: answer)
    }
}

/// Shows the sheet on the window that holds this view. Give it `.id(request.id)`.
struct SystemAlertPresenter: NSViewRepresentable {
    let center: DialogCenter
    let request: EngineDialogRequest

    func makeCoordinator() -> SystemAlertController {
        SystemAlertController(center: center, request: request)
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        view.controller = context.coordinator
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    static func dismantleNSView(_ nsView: AnchorView, coordinator: SystemAlertController) {
        coordinator.close()
    }

    final class AnchorView: NSView {
        weak var controller: SystemAlertController?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Next run-loop turn: SwiftUI is mid-update here, and a sheet must not start inside it.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.controller?.present(on: window)
                }
            }
        }
    }
}
