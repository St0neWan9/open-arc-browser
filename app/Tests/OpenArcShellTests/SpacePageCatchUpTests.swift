import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign
import OpenArcEngine
@testable import OpenArcShell

/// B106: a kept Space page that missed changes while hidden (B104) is brought up to date before it
/// is shown again, so the first frame of its slide draws its current content. [07 §11] observed:
/// the switch slides the page container by one sidebar width (276 pt), no fade, so the incoming
/// page is visible from the switch's first frame. [05 §window hierarchy] observed: each Space is
/// its own page.
@MainActor
final class SpacePageCatchUpTests: XCTestCase {
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

    /// What Home's page drew at the moment it was unhidden.
    private struct DrawnAtShow {
        var content: SidebarListContent?
        var publishCount = 0
        var isStale = true
        var header: SidebarSpaceHeaderLook?
    }

    /// Leaves Home for Work (Home's page hidden), runs `change` while Home is away, then switches
    /// back and records what Home's page had drawn when it was unhidden.
    private func switchBack(rowsChange: Bool = true, after change: (SidebarViewModel, SidebarFixture) -> Void) throws
        -> (vm: SidebarViewModel, f: SidebarFixture, home: SidebarSpacePageChanges, before: Int, atShow: DrawnAtShow) {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        vm.selectSpace(f.work)
        hosted.settle()
        pager.finishSlideForTesting()
        let home = try XCTUnwrap(pager.pageChanges(for: f.home))
        XCTAssertTrue(try XCTUnwrap(pager.pageHost(for: f.home)).isHidden)

        change(vm, f)
        XCTAssertTrue(home.isStale, "the hidden page missed the change")
        if rowsChange {
            XCTAssertFalse(home.drawnRows?.content === vm.listContent(for: f.home), "the hidden page still draws its old rows")
        }
        let before = home.publishCount

        var atShow = DrawnAtShow()
        pager.pageWillShowForTesting = { spaceID in
            guard spaceID == f.home else { return }
            atShow = DrawnAtShow(content: home.drawnRows?.content, publishCount: home.publishCount, isStale: home.isStale,
                                 header: home.drawnHeader)
        }
        vm.selectSpace(f.home)
        hosted.settle()
        pager.pageWillShowForTesting = nil
        XCTAssertEqual(pager.pagesBroughtUpToDate, 1, "the page was updated and laid out before it was shown")
        return (vm, f, home, before, atShow)
    }

    private func titles(_ content: SidebarListContent?) -> [String] {
        (content?.snapshot.pinned ?? []).compactMap { item in
            switch item.kind {
            case .tab(let tab): tab.displayTitle
            case .folder(let folder): folder.title
            case .splitGroup: nil
            }
        } + (content?.snapshot.today ?? []).compactMap { item in
            if case .tab(let tab) = item.kind { tab.displayTitle } else { nil }
        }
    }

    /// B106 ([07 §11]): a tab title changed in the away Space shows in the first frame of the slide.
    func testChangedTabTitleIsDrawnBeforeThePageIsShown() throws {
        let r = try switchBack { vm, f in vm.commitRename(f.today1, text: "Renamed while away") }
        XCTAssertTrue(r.atShow.content === r.vm.listContent(for: r.f.home), "the page drew its current rows before it was shown")
        XCTAssertTrue(titles(r.atShow.content).contains("Renamed while away"))
        XCTAssertEqual(r.atShow.publishCount, r.before + 1, "one update, before the page is shown")
    }

    /// B106 ([07 §11]): a tab archived in the away Space is gone in the first frame of the slide.
    func testArchivedTabIsGoneBeforeThePageIsShown() throws {
        let r = try switchBack { vm, f in vm.closeTab(f.today2) }
        XCTAssertTrue(r.atShow.content === r.vm.listContent(for: r.f.home))
        XCTAssertFalse(titles(r.atShow.content).contains("today2"))
        XCTAssertTrue(titles(r.atShow.content).contains("today1"))
    }

    /// B106 ([07 §11]): a folder renamed in the away Space shows its new name in the first frame.
    func testRenamedFolderIsDrawnBeforeThePageIsShown() throws {
        let r = try switchBack { vm, f in vm.commitRename(f.folderA, text: "Folder renamed") }
        XCTAssertTrue(r.atShow.content === r.vm.listContent(for: r.f.home))
        XCTAssertTrue(titles(r.atShow.content).contains("Folder renamed"))
        XCTAssertFalse(titles(r.atShow.content).contains("A"))
    }

    /// B106: a page whose Space did not change while it was hidden is not updated before it is
    /// shown (only pages that would draw differently pay for the catch-up), even though the
    /// sidebar changed meanwhile (another Space's tab selected, rows hovered).
    func testPageThatMissedNothingIsNotUpdated() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        vm.selectSpace(f.work)
        hosted.settle()
        pager.finishSlideForTesting()
        let home = try XCTUnwrap(pager.pageChanges(for: f.home))
        vm.selectTab(f.workTab)
        vm.hoverBegan(f.workTab)
        vm.hoverEnded(f.workTab)
        XCTAssertTrue(home.isStale, "the sidebar changed while the page was away")
        let before = home.publishCount
        let drawn = home.drawnRows?.content
        var countAtShow: Int?
        pager.pageWillShowForTesting = { if $0 == f.home { countAtShow = home.publishCount } }
        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertEqual(countAtShow, before, "no update before showing")
        XCTAssertEqual(pager.pagesBroughtUpToDate, 0)
        XCTAssertTrue(home.drawnRows?.content === drawn, "the same rows as when it left")
    }

    /// B106 ([07 §11]): a Space renamed while its page was hidden shows its new name in the first
    /// frame of the slide.
    func testRenamedSpaceIsDrawnBeforeThePageIsShown() throws {
        let r = try switchBack(rowsChange: false) { vm, f in
            try? vm.controller.mutate(origin: nil) { try TreeOps.renameSpace($0, id: f.home, name: "Home renamed", now: f.now.addingTimeInterval(20)) }
        }
        XCTAssertEqual(r.atShow.header?.name, "Home renamed")
    }

    /// B106: once the sidebar is quiet, a hidden page whose Space changed is brought up to date
    /// while it stays hidden, so the switch back does no page work at all; a hidden page whose
    /// Space did not change is left alone.
    func testHiddenPageIsPreparedWhileHidden() throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        vm.selectSpace(f.work)
        hosted.settle()
        pager.finishSlideForTesting()
        let home = try XCTUnwrap(pager.pageChanges(for: f.home))
        let homeHost = try XCTUnwrap(pager.pageHost(for: f.home))

        vm.selectTab(f.workTab)
        pager.prepareHiddenPagesForTesting()
        XCTAssertEqual(pager.pagesPreparedWhileHidden, 0, "nothing Home draws changed")

        vm.commitRename(f.today1, text: "Renamed while away")
        pager.prepareHiddenPagesForTesting()
        XCTAssertEqual(pager.pagesPreparedWhileHidden, 1)
        XCTAssertTrue(homeHost.isHidden, "prepared while hidden")
        XCTAssertFalse(home.isStale)
        XCTAssertTrue(home.drawnRows?.content === vm.listContent(for: f.home))
        XCTAssertTrue(titles(home.drawnRows?.content).contains("Renamed while away"))

        let before = home.publishCount
        vm.selectSpace(f.home)
        hosted.settle()
        XCTAssertEqual(pager.pagesBroughtUpToDate, 0, "the switch back had nothing left to do")
        XCTAssertTrue(titles(home.drawnRows?.content).contains("Renamed while away"))
        XCTAssertLessThanOrEqual(home.publishCount, before + 1, "at most the switch's own catch-up after it is shown")
    }

    /// B106: the quiet-time preparation runs on its own after `hiddenPagePrepareDelay`.
    func testHiddenPageIsPreparedAfterTheSidebarIsQuiet() async throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        addTeardownBlock { @MainActor in vm.stop() }
        let hosted = hosted(vm)
        let pager = try XCTUnwrap(pager(in: hosted.host))
        vm.selectSpace(f.work)
        hosted.settle()
        pager.finishSlideForTesting()
        let home = try XCTUnwrap(pager.pageChanges(for: f.home))
        vm.commitRename(f.today1, text: "Renamed while away")
        XCTAssertTrue(home.isStale)
        // Bounded wait: well past the delay.
        let deadline = ContinuousClock.now + .seconds(3)
        while home.isStale, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(home.isStale)
        XCTAssertEqual(pager.pagesPreparedWhileHidden, 1)
        XCTAssertTrue(titles(home.drawnRows?.content).contains("Renamed while away"))
    }
}
