import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
@testable import OpenArcShell

/// Smoke tests: the sidebar builds and lays out at the reference size. [04 §window structure]
@MainActor
final class SidebarRenderingTests: XCTestCase {
    func testSidebarLaysOutAt276By985() {
        let vm = SidebarPreviewFixtures.makeViewModel()
        let host = NSHostingView(rootView: SidebarView(viewModel: vm))
        host.frame = CGRect(x: 0, y: 0, width: 276, height: 985)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 276, accuracy: 0.5)
        vm.stop()
    }

    func testEmptySpacePreviewLaysOut() {
        let vm = SidebarPreviewFixtures.makeViewModel(emptySpace: true)
        XCTAssertTrue(vm.snapshot.isEmptySpace)
        let host = NSHostingView(rootView: SidebarView(viewModel: vm))
        host.frame = CGRect(x: 0, y: 0, width: 276, height: 985)
        host.layoutSubtreeIfNeeded()
        vm.stop()
    }

    func testPreviewHarnessLaysOut() {
        let host = NSHostingView(rootView: SidebarPreviewHarness())
        host.frame = CGRect(x: 0, y: 0, width: 700, height: 985)
        host.layoutSubtreeIfNeeded()
    }
}
