import XCTest
import SwiftUI
import AppKit
import QuartzCore
import OpenArcModel
@testable import OpenArcShell

/// Plan B184 (issue #1): a two-finger swipe over the sidebar moves the Space pages with the
/// fingers, commits past half a page or on a flick, springs back otherwise, and hides the list's
/// scroll knob while it runs. [05 §window hierarchy] observed: Spaces are horizontal pages switched
/// by a swipe; [07 §11] observed: the Space-switch spring. Thresholds and the edge resistance are
/// inferred (`SpaceSwipe`).
@MainActor
final class SpaceSwipeB184Tests: XCTestCase {
    @MainActor
    private struct Hosted {
        let window: NSWindow
        let host: NSHostingView<SidebarView>
        func settle() {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                RunLoop.main.run(mode: .default, before: Date())
            }
        }
    }

    private func hosted(_ vm: SidebarViewModel) -> Hosted {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 276, height: 985), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: SidebarView(viewModel: vm))
        host.frame = CGRect(x: 0, y: 0, width: 276, height: 985)
        window.contentView = host
        addTeardownBlock { @MainActor in window.close() }
        let hosted = Hosted(window: window, host: host)
        hosted.settle()
        return hosted
    }

    private func pager(in view: NSView) -> SidebarSpacePagerView? {
        if let pager = view as? SidebarSpacePagerView { return pager }
        for subview in view.subviews { if let found = pager(in: subview) { return found } }
        return nil
    }

    // MARK: Rules

    /// Half a page, or a flick toward the neighbor, commits; a short slow move or a flick back
    /// does not (inferred, as macOS paging).
    func testCommitRule() {
        XCTAssertTrue(SpaceSwipe.commits(offset: -140, velocity: 0, width: 276))
        XCTAssertFalse(SpaceSwipe.commits(offset: -100, velocity: -50, width: 276))
        XCTAssertTrue(SpaceSwipe.commits(offset: -40, velocity: -600, width: 276), "a flick commits")
        XCTAssertFalse(SpaceSwipe.commits(offset: -10, velocity: -600, width: 276), "too short for a flick")
        XCTAssertFalse(SpaceSwipe.commits(offset: -200, velocity: 600, width: 276), "a flick back cancels")
        XCTAssertFalse(SpaceSwipe.commits(offset: 0, velocity: 0, width: 276))
    }

    /// The page follows the fingers up to one page, and resists where there is no Space.
    func testDisplayedOffset() {
        XCTAssertEqual(SpaceSwipe.displayedOffset(-100, width: 276, hasNeighbor: true), -100)
        XCTAssertEqual(SpaceSwipe.displayedOffset(-400, width: 276, hasNeighbor: true), -276)
        XCTAssertEqual(SpaceSwipe.displayedOffset(100, width: 276, hasNeighbor: false), 30, accuracy: 0.001)
        XCTAssertEqual(SpaceSwipe.step(forOffset: -1), 1, "content to the left reveals the next Space")
        XCTAssertEqual(SpaceSwipe.step(forOffset: 1), -1)
    }

    // MARK: View model

    func testSwipePastHalfSelectsNextSpace() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        XCTAssertTrue(vm.spaceSwipeBegan())
        XCTAssertTrue(vm.spaceSwipe.isActive)
        vm.spaceSwipeMoved(offset: -180)
        XCTAssertEqual(vm.selectedSpaceID, f.home, "nothing switches while the fingers are down")
        vm.spaceSwipeEnded(offset: -180, velocity: 0)
        XCTAssertFalse(vm.spaceSwipe.isActive)
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        XCTAssertEqual(vm.spaceSwipe.lastEvent, .ended(target: f.work))
    }

    func testShortSwipeSpringsBack() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.spaceSwipeBegan()
        vm.spaceSwipeMoved(offset: -60)
        vm.spaceSwipeEnded(offset: -60, velocity: -40)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        XCTAssertEqual(vm.spaceSwipe.lastEvent, .ended(target: nil))
    }

    func testSwipePastTheFirstSpaceDoesNothing() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.spaceSwipeBegan()
        vm.spaceSwipeEnded(offset: 250, velocity: 900)
        XCTAssertEqual(vm.selectedSpaceID, f.home, "no Space before the first")
    }

    /// The rows slide away under the pointer: an open hover card closes when the swipe starts.
    func testSwipeClosesHoverCard() async throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.hoverDelay = 0
        vm.hoverBegan(f.today1)
        for _ in 0..<100 where vm.hoverCardTabID == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(vm.hoverCardTabID, f.today1)
        vm.spaceSwipeBegan()
        XCTAssertNil(vm.hoverCardTabID)
    }

    func testNoSwipeDuringDrag() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        defer { vm.stop() }
        vm.beginDrag(.tab(f.today1))
        XCTAssertFalse(vm.spaceSwipeBegan())
        XCTAssertFalse(vm.spaceSwipe.isActive)
        vm.endDrag()
    }

    // MARK: Pager

    /// While the fingers move, the shown page and the next Space's page move with them, one page
    /// apart; on release past half the next page slides on from where it is (no jump back).
    func testPagerFollowsTheFingersAndCommits() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))

        vm.spaceSwipeBegan()
        vm.spaceSwipeMoved(offset: -100)
        XCTAssertEqual(pager.heldOffsetForTesting(f.home), -100)
        XCTAssertEqual(pager.heldOffsetForTesting(f.work), 176, "the next page waits one page to the right")
        XCTAssertEqual(Set(pager.attachedSpaceIDs), [f.home, f.work])

        vm.spaceSwipeMoved(offset: -200)
        vm.spaceSwipeEnded(offset: -200, velocity: 0)
        hosted.settle()
        XCTAssertEqual(vm.selectedSpaceID, f.work)
        let incoming = try XCTUnwrap(pager.pageHost(for: f.work)?.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        XCTAssertEqual((incoming.fromValue as? NSNumber)?.doubleValue ?? 0, 76, accuracy: 0.5, "slides on from where the fingers left it")
        let outgoing = try XCTUnwrap(pager.pageHost(for: f.home)?.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        XCTAssertEqual((outgoing.fromValue as? NSNumber)?.doubleValue ?? 0, -200, accuracy: 0.5)
        pager.finishSlideForTesting()
        XCTAssertEqual(pager.attachedSpaceIDs, [f.work])
        XCTAssertEqual(pager.heldOffsetForTesting(f.work), 0)
    }

    /// Released short, both pages spring back on the Space-switch spring and the neighbor hides.
    func testPagerSpringsBack() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))

        vm.spaceSwipeBegan()
        vm.spaceSwipeMoved(offset: -60)
        vm.spaceSwipeEnded(offset: -60, velocity: 0)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        let back = try XCTUnwrap(pager.pageHost(for: f.home)?.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        XCTAssertEqual((back.fromValue as? NSNumber)?.doubleValue ?? 0, -60, accuracy: 0.5)
        XCTAssertEqual((back.toValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(pager.heldOffsetForTesting(f.home), 0, "the layer rests at 0 under the animation")
        pager.finishSlideForTesting()
        XCTAssertEqual(pager.attachedSpaceIDs, [f.home], "the neighbor is hidden again")
    }

    /// At the last Space the page moves only a little (rubber band) and no neighbor shows.
    func testPagerResistsAtTheEnd() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))

        vm.spaceSwipeBegan()
        vm.spaceSwipeMoved(offset: 100)
        XCTAssertEqual(pager.heldOffsetForTesting(f.home), 30, accuracy: 0.001)
        XCTAssertEqual(pager.attachedSpaceIDs, [f.home])
        vm.spaceSwipeEnded(offset: 100, velocity: 0)
        pager.finishSlideForTesting()
        XCTAssertEqual(pager.heldOffsetForTesting(f.home), 0)
    }
}
