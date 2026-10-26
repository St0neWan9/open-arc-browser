import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// "—" on a pinned row and ⌘W on a pinned tab. Spec: [06 §16.1] observed.
@MainActor
final class PinnedUnloadTests: XCTestCase {

    /// [06 §16.1] observed: "—" keeps the pin in place, unloads the page and resets it to the
    /// pinned URL; selection moves to a neighbor row.
    func testMinusKeepsPinUnloadsAndResetsToPinnedURL() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.pinnedTab)
        await vm.settleEngineWork()
        XCTAssertNotNil(vm.liveTab(for: f.pinnedTab))
        // The pinned tab navigated away from its pinned URL.
        let moved = URL(string: "https://pinned.example.com/elsewhere")
        vm.replaceWorkspace(try! TreeOps.updateTabContent(
            vm.workspace, id: f.pinnedTab, url: moved, title: "Elsewhere", faviconURL: nil, now: f.now.addingTimeInterval(5)))
        let before = vm.workspace.tabs[f.pinnedTab]!

        vm.unloadPinnedTab(f.pinnedTab)
        await vm.settleEngineWork()

        let after = vm.workspace.tabs[f.pinnedTab]!
        XCTAssertFalse(after.meta.isTombstone)
        XCTAssertEqual(after.location, before.location, "the pin stays where it was")
        XCTAssertEqual(after.sortKey, before.sortKey)
        XCTAssertEqual(after.url, URL(string: "https://pinned.example.com"), "back to the pinned URL")
        XCTAssertEqual(after.pinnedURL, before.pinnedURL)
        XCTAssertNil(vm.workspace.archive[f.pinnedTab], "not archived")
        XCTAssertNil(vm.liveTab(for: f.pinnedTab), "page unloaded (history gone)")
        XCTAssertNotEqual(vm.selectedTabID, f.pinnedTab)
        XCTAssertNotNil(vm.selectedTabID)
        vm.stop()
    }

    /// [06 §16.1] observed: ⌘W on a pinned tab does what "—" does; on a Today tab it archives.
    func testCommandWOnPinnedTabUnloadsAndOnTodayArchives() async {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.pinnedTab)
        await vm.settleEngineWork()
        vm.closeOrUnloadTab(f.pinnedTab)
        await vm.settleEngineWork()
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.meta.isTombstone, false)
        XCTAssertEqual(vm.workspace.tabs[f.pinnedTab]?.location, .pinned(spaceID: f.home, folderID: nil))
        XCTAssertNil(vm.workspace.archive[f.pinnedTab])
        XCTAssertNil(vm.liveTab(for: f.pinnedTab))

        vm.selectTab(f.today1)
        vm.closeOrUnloadTab(f.today1)
        XCTAssertEqual(vm.workspace.tabs[f.today1]?.meta.isTombstone, true)
        XCTAssertNotNil(vm.workspace.archive[f.today1])
        vm.stop()
    }

    /// [06 §16.1]: the "Archive Tab" command (⌘W) routes through the same rule in the shell.
    func testArchiveTabCommandKeepsSelectedPin() async throws {
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: Date(timeIntervalSince1970: 0)),
                               now: { Date(timeIntervalSince1970: 0) })
        let space = try XCTUnwrap(model.selectedSpaceID)
        let pinned = UUID()
        model.sidebar.replaceWorkspace(try TreeOps.openTab(
            model.workspace, id: pinned, spaceID: space, url: URL(string: "https://pin.example.com"), title: "Pin",
            now: Date(timeIntervalSince1970: 0)))
        model.sidebar.pinTab(pinned)
        model.sidebar.selectTab(pinned)
        await model.sidebar.settleEngineWork()
        model.run(.archiveTab)
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.workspace.tabs[pinned]?.meta.isTombstone, false)
        XCTAssertNil(model.workspace.archive[pinned])
        model.stop()
    }
}
