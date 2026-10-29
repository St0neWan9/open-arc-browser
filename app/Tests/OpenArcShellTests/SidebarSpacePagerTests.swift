import XCTest
import SwiftUI
import AppKit
import QuartzCore
import OpenArcModel
import OpenArcDesign
import OpenArcEngine
@testable import OpenArcShell

/// The sidebar's Space pager (B101): Space pages stay built after they were shown and slide on a
/// Core Animation spring. [07 §11] observed: the page container moves by one sidebar width
/// (276 pt) on a critically damped spring (response 0.2 s), no fade; [05 §window hierarchy]
/// observed: the Spaces are horizontal pages.
@MainActor
final class SidebarSpacePagerTests: XCTestCase {
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

    /// [07 §11]: the slide uses the Space-switch spring (response 0.2 s, critically damped), from
    /// the given offset to the page's place, in the x translation only (no fade).
    func testSlideAnimationIsTheSpaceSwitchSpring() throws {
        let slide = SpacePagerMotion.slide(from: 276)
        let constants = try XCTUnwrap(Motion.spaceSwitch.curve.springConstants)
        XCTAssertEqual(slide.keyPath, "transform.translation.x")
        XCTAssertEqual(slide.mass, 1)
        XCTAssertEqual(slide.stiffness, constants.stiffness, accuracy: 0.001)
        XCTAssertEqual(slide.damping, constants.damping, accuracy: 0.001)
        XCTAssertEqual(slide.stiffness, 987, accuracy: 1, "[07 §11] stiffness ≈ 987")
        XCTAssertEqual(slide.damping, 62.8, accuracy: 0.1, "[07 §11] damping ≈ 63")
        XCTAssertEqual((slide.fromValue as? NSNumber)?.doubleValue, 276)
        XCTAssertEqual((slide.toValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual(slide.duration, slide.settlingDuration)
    }

    /// A switch keeps the shown page and slides the new one in from the side it lies on in the dock
    /// order; the outgoing page leaves the other way and is taken out of the view tree once the
    /// slide ended, but kept, so switching back reuses it. [07 §11], [05 §window hierarchy].
    func testSwitchKeepsPagesAndSlidesThem() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        XCTAssertEqual(pager.attachedSpaceIDs, [f.home])

        vm.selectSpace(f.work)
        hosted.settle()
        XCTAssertEqual(pager.keptSpaceIDs, [f.home, f.work])
        XCTAssertEqual(Set(pager.attachedSpaceIDs), [f.home, f.work], "both pages are on screen during the slide")
        let incoming = try XCTUnwrap(pager.pageHost(for: f.work)?.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        let outgoing = try XCTUnwrap(pager.pageHost(for: f.home)?.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        // Work is after Home in the dock: it comes in from the right, Home leaves to the left.
        XCTAssertEqual((incoming.fromValue as? NSNumber)?.doubleValue, 276)
        XCTAssertEqual((incoming.toValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((outgoing.fromValue as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((outgoing.toValue as? NSNumber)?.doubleValue, -276)

        pager.finishSlideForTesting()
        XCTAssertEqual(pager.attachedSpaceIDs, [f.work], "the outgoing page leaves the view tree")
        let workHost = pager.pageHost(for: f.work)
        let homeHost = pager.pageHost(for: f.home)

        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertTrue(pager.pageHost(for: f.home) === homeHost, "switching back reuses the kept page")
        let back = try XCTUnwrap(homeHost?.layer?.animation(forKey: SpacePagerMotion.key) as? CASpringAnimation)
        XCTAssertEqual((back.fromValue as? NSNumber)?.doubleValue, -276, "Home is before Work: it comes back from the left")
        pager.finishSlideForTesting()
        XCTAssertEqual(pager.attachedSpaceIDs, [f.home])
        XCTAssertTrue(pager.pageHost(for: f.work) === workHost, "the other page stays kept")
    }

    /// Each page draws its own Space: its name, and the selection that Space shows. The page
    /// sliding in already shows the tab selected again on switching back.
    func testPagesDrawTheirOwnSpace() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        vm.selectTab(f.today2)
        XCTAssertEqual(vm.pageSelectedTabID(for: f.home), f.today2)
        vm.selectSpace(f.work)
        vm.selectTab(f.workTab)
        // The window's selection on the shown page; the remembered tab on the other.
        XCTAssertEqual(vm.pageSelectedTabID(for: f.work), f.workTab)
        XCTAssertEqual(vm.pageSelectedTabID(for: f.home), f.today2)
        XCTAssertEqual(vm.listContent(for: f.home).snapshot.spaceID, f.home)
        XCTAssertEqual(vm.listContent(for: f.work).snapshot.spaceID, f.work)
        XCTAssertTrue(vm.listContent(for: f.work) === vm.listContent, "the shown page's rows are the sidebar's rows")
        let row = try XCTUnwrap(vm.listContent(for: f.home).snapshot.today.first { $0.id == f.today2 })
        guard case .tab(let tab) = row.kind else { return XCTFail("today2 is a tab row") }
        XCTAssertTrue(vm.tabRowState(tab, depth: 0, area: .today, palette: vm.palette(forSpace: f.home),
                                     selectedTabID: vm.pageSelectedTabID(for: f.home)).isSelected)
        XCTAssertFalse(vm.tabRowState(tab, depth: 0, area: .today, palette: vm.palette).isSelected,
                       "on the shown page only the window's selection is selected")
        vm.selectSpace(f.home)
        XCTAssertEqual(vm.selectedTabID, f.today2, "switching back selects what the page showed")
    }

    /// A switch during a slide (straight back) starts the page from where it is drawn, and leaves
    /// only the two pages of the latest switch in the view tree.
    func testSwitchDuringSlide() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        vm.selectSpace(f.work)
        hosted.settle()
        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertEqual(Set(pager.attachedSpaceIDs), [f.home, f.work])
        XCTAssertNotNil(pager.pageHost(for: f.home)?.layer?.animation(forKey: SpacePagerMotion.key))
        pager.finishSlideForTesting()
        XCTAssertEqual(pager.attachedSpaceIDs, [f.home])
    }

    /// The list on screen is the one drag auto-scroll and the jump button move (B20, B76).
    func testListScrollerFollowsTheShownPage() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let scroll = try XCTUnwrap(vm.listScrollState)
        let homeHook = try XCTUnwrap(scroll.scrollHook(for: f.home))
        XCTAssertTrue(vm.listScroller === homeHook)
        vm.selectSpace(f.work)
        hosted.settle()
        let workHook = try XCTUnwrap(scroll.scrollHook(for: f.work))
        XCTAssertFalse(workHook === homeHook)
        XCTAssertTrue(vm.listScroller === workHook)
        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertTrue(vm.listScroller === homeHook, "the kept page's list is the scroller again")
    }

    /// The pager keeps at most `maxPages` pages, dropping the one shown longest ago.
    func testPagerKeepsAFewPages() throws {
        let f = SidebarFixture()
        var ws = f.ws
        var spaces = [f.home, f.work]
        var after = f.work
        for n in 0..<SidebarSpacePager.maxPages {
            let id = SidebarFixture.id(900 + n)
            ws = try TreeOps.createSpace(ws, id: id, profileID: f.profile, name: "S\(n)", afterSpaceID: after, now: f.now)
            spaces.append(id)
            after = id
        }
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: ws, selectedSpaceID: f.home, now: { f.now })
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        for id in spaces.dropFirst() {
            vm.selectSpace(id)
            hosted.settle()
            pager.finishSlideForTesting()
        }
        XCTAssertEqual(pager.keptSpaceIDs.count, SidebarSpacePager.maxPages)
        XCTAssertEqual(pager.keptSpaceIDs, Array(spaces.suffix(SidebarSpacePager.maxPages)))
        XCTAssertEqual(pager.attachedSpaceIDs, [spaces.last])
        XCTAssertNil(vm.listScrollState?.scrollHook(for: f.home), "a dropped page's list is forgotten")
    }
}
