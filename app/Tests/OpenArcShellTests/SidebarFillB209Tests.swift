import XCTest
import SwiftUI
import AppKit
@testable import OpenArcShell

/// Plan B209: on an opaque window (full screen, Reduce Transparency) the main window's sidebar
/// paints no fill of its own, so the window background's Space-switch blend shows through it.
@MainActor
final class SidebarFillB209Tests: XCTestCase {
    /// Alpha of the sidebar's blank area (below the list, above the dock) when drawn alone.
    private func blankAlpha(onWindowBackground: Bool) -> CGFloat {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        let view = SidebarView(viewModel: vm)
            .environment(\.windowSurface, .opaque)
            .environment(\.sidebarOnWindowBackground, onWindowBackground)
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(x: 0, y: 0, width: 276, height: 985)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.colorAt(x: 138 * Int(rep.pixelsWide) / 276, y: 800 * Int(rep.pixelsHigh) / 985)?.alphaComponent ?? -1
    }

    func testMainWindowSidebarIsClearOnAnOpaqueWindow() {
        XCTAssertEqual(blankAlpha(onWindowBackground: false), 1, accuracy: 0.01, "elsewhere it paints the window color")
        XCTAssertEqual(blankAlpha(onWindowBackground: true), 0, accuracy: 0.01, "the window background shows through")
    }
}
