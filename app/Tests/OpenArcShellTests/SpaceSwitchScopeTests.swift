import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
import OpenArcEngine
@testable import OpenArcShell

/// B104: a Space switch updates only what shows per-Space state. [07 §11] observed: the switch
/// moves the page container by one sidebar width (276 pt) on a critically damped spring
/// (response 0.2 s), no fade; [05 §window hierarchy] observed: the URL box, favorites and dock are
/// outside the pages and stay. The pages that leave stay in the view tree, hidden, and do not
/// follow the sidebar while away.
@MainActor
final class SpaceSwitchScopeTests: XCTestCase {
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

    /// [07 §11] B104: the outgoing page stays in the view tree (hidden), so switching back neither
    /// removes nor re-adds a hosting view; it slides on the same spring as before.
    func testLeavingPageIsHiddenNotRemoved() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        let homeHost = try XCTUnwrap(pager.pageHost(for: f.home))

        vm.selectSpace(f.work)
        hosted.settle()
        pager.finishSlideForTesting()
        XCTAssertTrue(homeHost.superview === pager, "the page stays in the pager")
        XCTAssertTrue(homeHost.isHidden)
        XCTAssertEqual(pager.attachedSpaceIDs, [f.work])

        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertTrue(pager.pageHost(for: f.home) === homeHost)
        XCTAssertFalse(homeHost.isHidden)
        let slide = try XCTUnwrap(homeHost.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        XCTAssertEqual((slide.fromValue as? NSNumber)?.doubleValue, -276, "[07 §11] one sidebar width, from the left")
    }

    /// B104: a hidden page does not follow the sidebar's changes, and catches up once when shown.
    func testHiddenPageDoesNotFollowChangesAndCatchesUpOnce() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        vm.selectSpace(f.work)
        hosted.settle()
        pager.finishSlideForTesting()
        let home = try XCTUnwrap(pager.pageChanges(for: f.home))
        let work = try XCTUnwrap(pager.pageChanges(for: f.work))
        XCTAssertFalse(home.isShown)
        XCTAssertTrue(work.isShown)

        let homeBefore = home.publishCount, workBefore = work.publishCount
        vm.selectTab(f.workTab)
        vm.hoverBegan(f.workTab)
        vm.hoverEnded(f.workTab)
        XCTAssertEqual(home.publishCount, homeBefore, "the hidden page is not told about the changes")
        XCTAssertGreaterThan(work.publishCount, workBefore, "the shown page is")
        XCTAssertTrue(home.isStale)

        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertTrue(home.isShown)
        // The catch-up runs in the pass after the one that showed the page (or now, in a test).
        home.catchUp()
        XCTAssertFalse(home.isStale)
        XCTAssertEqual(home.publishCount, homeBefore + 1, "one update when it comes back")
    }

    /// B104: the page that slides out stops following the sidebar before the switch is published,
    /// so the switch does not update it; the incoming page follows from the switch on.
    func testOutgoingPageIsNotUpdatedBySwitch() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        let home = try XCTUnwrap(pager.pageChanges(for: f.home))
        let before = home.publishCount
        vm.selectSpace(f.work)
        XCTAssertEqual(home.publishCount, before, "the switch does not update the page that leaves")
        XCTAssertFalse(home.isShown)
        hosted.settle()
        XCTAssertEqual(Set(pager.attachedSpaceIDs), [f.home, f.work], "both pages draw during the slide")

        // Straight back during the slide: the page follows the sidebar again.
        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertTrue(home.isShown)
        XCTAssertFalse(try XCTUnwrap(pager.pageChanges(for: f.work)).isShown)
    }

    /// B104: the fixed blocks get plain values; between two Spaces of one profile with the same
    /// theme only the dock's current Space differs. [05 §window hierarchy] observed: the URL box,
    /// favorites and dock stay while the pages slide.
    func testSwitchChangesOnlyTheDockAmongFixedBlocks() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let top = vm.topBarState, favorites = vm.favoritesState(vm.snapshot.favorites), dock = vm.dockState
        vm.selectSpace(f.work)
        XCTAssertEqual(vm.topBarState, top, "no tab was selected in either Space")
        XCTAssertEqual(vm.favoritesState(vm.snapshot.favorites), favorites, "favorites belong to the profile")
        XCTAssertNotEqual(vm.dockState, dock)
        XCTAssertEqual(vm.dockState.selectedSpaceID, f.work)
    }

    /// B104: a Space with another theme changes the fixed blocks' colors at once, as before
    /// ([07 §11]: only the pages slide; the rest of the sidebar switches at once).
    func testThemeChangeReachesFixedBlocks() throws {
        var f = SidebarFixture()
        let theme = SidebarFixture.id(900)
        f.ws = TreeOps.createTheme(f.ws, id: theme, style: ThemeStyle(colors: [RGBAColor(hex: 0x2E6BE6)]), now: f.now)
        f.ws = try TreeOps.setSpaceTheme(f.ws, id: f.work, themeID: theme, now: f.now)
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let homePalette = vm.palette
        vm.selectSpace(f.work)
        XCTAssertNotEqual(vm.palette, homePalette)
        XCTAssertEqual(vm.topBarState.palette, vm.palette)
        XCTAssertEqual(vm.urlBoxState.palette, vm.palette)
        XCTAssertEqual(vm.favoritesState(vm.snapshot.favorites).palette, vm.palette)
        XCTAssertEqual(vm.dockState.palette, vm.palette)
    }

    /// B104: the Space about to be selected is announced before the view model publishes the switch.
    func testSpaceChangeIsAnnouncedBeforePublishing() {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        var events: [String] = []
        let announced = vm.selectedSpaceWillChange.sink { events.append("will \($0 == f.work ? "work" : "?")") }
        let published = vm.objectWillChange.sink { events.append("publish") }
        defer { announced.cancel(); published.cancel() }
        vm.selectSpace(f.work)
        XCTAssertEqual(events.first, "will work")
        XCTAssertEqual(events.filter { $0.hasPrefix("will") }.count, 1)
    }
}
