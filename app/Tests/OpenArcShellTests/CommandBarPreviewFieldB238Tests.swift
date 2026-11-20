import XCTest
import SwiftUI
import AppKit
@testable import OpenArcShell

/// B238: the arrow keys put the chosen row's address into the real field, and back on the first
/// row the typed text returns (user 2026-11-20, Arc's rule).
@MainActor
final class CommandBarPreviewFieldB238Tests: XCTestCase {
    func testDownShowsTheRowsAddressInTheField() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world, mode: .currentTab, currentTab: "GitHub")
        let host = NSHostingView(rootView: CommandBarView(viewModel: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        addTeardownBlock { @MainActor in window.close() }
        await CommandBarFixtures.open(model, world: world, mode: .currentTab, currentTab: "GitHub")
        settle()
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.string = "example"
        editor.didChangeText()
        await model.waitForRefresh()
        settle()
        let index = try XCTUnwrap(model.results.indices.dropFirst().first { model.results[$0].url != nil })
        let url = try XCTUnwrap(model.results[index].url?.absoluteString)
        for _ in 0..<index { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        settle()
        XCTAssertEqual(model.queryText, url)
        XCTAssertEqual(editor.string, url, "the field shows the chosen row's address")
        for _ in 0..<index { editor.doCommand(by: #selector(NSResponder.moveUp(_:))) }
        settle()
        XCTAssertEqual(editor.string, "example")
    }

    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
}
