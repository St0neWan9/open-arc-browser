import XCTest
import SwiftUI
import AppKit
@testable import OpenArcShell

/// B147: a right-click on the sidebar background opens the current Space's menu everywhere: the
/// gaps between the blocks, the Space header row, the blank list, around the dock.
/// [06 §21.5] observed (the empty sidebar and the gaps between favorite tiles open the Space menu).
@MainActor
final class SidebarSpaceMenuB147Tests: XCTestCase {
    func testBackgroundRightClickOpensTheSpaceMenu_06_21_5() throws {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        defer { model.stop() }
        let height: CGFloat = 985
        let host = NSHostingView(rootView: MainWindowView(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: height),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        // Window points (top-left origin): the Space name, the gap under the URL box, the Space
        // header row right of its name and above it, the blank list, and the dock band between its buttons.
        let layout = SidebarLayout(windowSize: CGSize(width: 276, height: height),
                                   favoritesTilesHeight: model.sidebar.favoritesTilesHeight)
        let header = layout.spaceNameRowFrame
        for point in [CGPoint(x: 60, y: header.midY), CGPoint(x: 140, y: 86), CGPoint(x: 200, y: header.midY), CGPoint(x: 200, y: header.minY - 3),
                      CGPoint(x: 140, y: 700), CGPoint(x: 140, y: 960)] {
            let location = NSPoint(x: point.x, y: height - point.y)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [],
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1))
            var view = host.hitTest(location)
            var menu: NSMenu?
            while let current = view, menu == nil {
                menu = current.menu(for: event)
                view = current.superview
            }
            XCTAssertEqual(menu?.items.first?.title, "Change Space Icon…", "at \(point)")
        }
    }

    /// The "…" button opens the same system menu a right-click on the header opens (not a SwiftUI
    /// pull-down panel), in the window's light appearance. [06 §21.5] observed; B147.
    func testMoreButtonOpensTheHeaderContextMenu_06_21_5() throws {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        defer { model.stop() }
        let host = NSHostingView(rootView: MainWindowView(model: model))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1200, height: 985),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.layoutSubtreeIfNeeded()
        func triggers(in view: NSView) -> [SidebarContextMenuTrigger.TriggerView] {
            (view as? SidebarContextMenuTrigger.TriggerView).map { [$0] } ?? view.subviews.flatMap(triggers)
        }
        let trigger = try XCTUnwrap(triggers(in: host).first { !$0.isHiddenOrHasHiddenAncestor })
        let press = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(trigger.contextMenu(like: press))
        XCTAssertEqual(menu.items.first?.title, "Change Space Icon…")
        XCTAssertEqual(trigger.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
    }
}
