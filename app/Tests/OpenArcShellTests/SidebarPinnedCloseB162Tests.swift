import XCTest
import AppKit
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// B162 (user, 2026-11-04): a pinned row's — closes the page and keeps the pin ([06 §16.1]
/// observed); once the page is closed the row shows ✕, which archives the tab. The sidebar list
/// keeps its scroll offset when the sidebar is shown again.
@MainActor
final class SidebarPinnedCloseB162Tests: XCTestCase {
    func testAccessoryActionFollowsTheLoadedState_06_16_1() {
        XCTAssertEqual(SidebarTabRowView.accessoryAction(area: .pinned, isLoaded: true), .unloadKeepingPin)
        XCTAssertEqual(SidebarTabRowView.accessoryAction(area: .pinned, isLoaded: false), .archive)
        XCTAssertEqual(SidebarTabRowView.accessoryAction(area: .today, isLoaded: true), .archive)
        XCTAssertEqual(SidebarTabRowView.accessoryAction(area: .today, isLoaded: false), .archive)
    }

    func testMinusThenCrossArchivesThePinnedTab_06_16_1() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.pinnedTab)
        await vm.settleEngineWork()
        let tab = vm.workspace.tabs[f.pinnedTab]!
        XCTAssertTrue(vm.tabRowState(tab, depth: 0, area: .pinned, palette: vm.palette).isLoaded)

        vm.unloadPinnedTab(f.pinnedTab)
        await vm.settleEngineWork()
        let unloaded = vm.tabRowState(vm.workspace.tabs[f.pinnedTab]!, depth: 0, area: .pinned, palette: vm.palette)
        XCTAssertFalse(unloaded.isLoaded, "the row now shows ✕")
        XCTAssertEqual(SidebarTabRowView.accessoryAction(area: .pinned, isLoaded: unloaded.isLoaded), .archive)

        vm.closeTab(f.pinnedTab)
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.meta.isTombstone, true)
        XCTAssertNotNil(vm.workspace.archive[f.pinnedTab])
        vm.stop()
    }

    /// A rebuilt list scrolls back to the recorded offset once its content is tall enough, and
    /// does not record its own first offset (the top) over it.
    func testRebuiltListReturnsToTheRecordedOffset() throws {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 200, height: 300))
        let document = FlippedView(frame: CGRect(x: 0, y: 0, width: 200, height: 2000))
        scrollView.documentView = document
        var recorded: [CGFloat] = []
        let hook = SidebarNSScrollHook()
        hook.pendingRestoreOffset = 640
        hook.onOffset = { recorded.append($0) }
        hook.scrollView = scrollView
        XCTAssertEqual(try XCTUnwrap(hook.metrics).offset, 640, accuracy: 0.5)
        XCTAssertNil(hook.pendingRestoreOffset)
        XCTAssertFalse(recorded.contains(0), "the top was never recorded over the saved offset")
        XCTAssertEqual(try XCTUnwrap(recorded.last), 640, accuracy: 0.5)
    }

    private final class FlippedView: NSView { override var isFlipped: Bool { true } }
}
