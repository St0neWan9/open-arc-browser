import XCTest
import SwiftUI
import AppKit
@testable import OpenArcShell

/// B26: the command bar field takes keyboard focus as soon as the bar is in a real window, for
/// every presentation, without a click. ⌘L's prefill is fully selected.
/// [02] observed: ⌘T "New Tab…", ⌘L "Open Command Bar (edit the current address)"; select-all inferred.
@MainActor
final class CommandBarFocusTests: XCTestCase {
    private func show(_ model: CommandBarViewModel) -> NSWindow {
        let host = NSHostingView(rootView: CommandBarView(viewModel: model))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in window.close() }
        return window
    }

    /// Lets the deferred focus pass run.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func focusedField(in window: NSWindow) -> CommandBarNSTextField? {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return nil }
        return (editor.delegate as AnyObject?) as? CommandBarNSTextField
    }

    func testFieldIsFirstResponderInEveryPresentation() async throws {
        for presentation in [CommandBarPresentation.window, .pane, .littleArc] {
            let model = await CommandBarPreviewSupport.makeViewModel(presentation: presentation)
            let window = show(model)
            settle()
            let field = try XCTUnwrap(focusedField(in: window), "\(presentation): typing must go to the field")
            XCTAssertEqual(field.accessibilityIdentifier(), "openarc.commandbar.field")
        }
    }

    func testCommandLPrefillIsSelectedAndTypingReplacesIt() async throws {
        let model = await CommandBarPreviewSupport.makeViewModel(mode: .newTab)
        let window = show(model)
        settle()
        // ⌘L on the open bar: prefill plus select-all.
        model.open(mode: .currentTab, currentURL: URL(string: "https://swift.org/")!)
        settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.string, "https://swift.org/")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: ("https://swift.org/" as NSString).length))

        editor.insertText("github", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.queryText, "github", "typed text reaches the view model")
        XCTAssertFalse(model.isPrefillUnedited)
    }

    func testCommandTStartsEmptyWithCaretInField() async throws {
        let model = await CommandBarPreviewSupport.makeViewModel(mode: .newTab)
        let window = show(model)
        settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        XCTAssertEqual(editor.string, "")
        editor.insertText("swi", replacementRange: editor.selectedRange())
        XCTAssertEqual(model.queryText, "swi")
    }

    /// Arrow keys, Tab, Return and Escape still reach the view model through the AppKit field.
    func testKeyCommandsMapToBarKeys() {
        typealias C = CommandBarTextField.Coordinator
        XCTAssertEqual(C.key(for: #selector(NSResponder.moveUp(_:))), .up)
        XCTAssertEqual(C.key(for: #selector(NSResponder.moveDown(_:))), .down)
        XCTAssertEqual(C.key(for: #selector(NSResponder.insertTab(_:))), .tab)
        XCTAssertEqual(C.key(for: #selector(NSResponder.insertBacktab(_:))), .shiftTab)
        XCTAssertEqual(C.key(for: #selector(NSResponder.insertNewline(_:))), .returnKey)
        XCTAssertEqual(C.key(for: #selector(NSResponder.cancelOperation(_:))), .escape)
        XCTAssertNil(C.key(for: #selector(NSResponder.moveLeft(_:))))
    }

    func testEscapeInFieldDismisses() async throws {
        let model = await CommandBarPreviewSupport.makeViewModel(mode: .newTab)
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        let window = show(model)
        settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(dismissed, 1)
    }
}
