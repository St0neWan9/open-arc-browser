import XCTest
@testable import OpenArcModel

/// Tree operations behind the sidebar's right-click menus (plan B55).
/// Spec: docs/arc-spec/06-flows.md §21.1 (favorites per Profile), §21.5 (menus), §21.6 (Separate All Tabs).
final class TreeOpsSidebarMenuTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100)
    private let t1 = Date(timeIntervalSince1970: 200)
    private func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    private func base() throws -> WorkspaceState {
        var s = WorkspaceState()
        s = TreeOps.createProfile(s, id: id(1), name: "Default", now: t0)
        s = TreeOps.createProfile(s, id: id(2), name: "Work", now: t0)
        s = try TreeOps.createSpace(s, id: id(10), profileID: id(1), name: "Home", now: t0)
        return s
    }

    /// 06 §21.1 observed: a Space set to another Profile shows that Profile's favorites; only the
    /// `profile` group is stamped.
    func testSetSpaceProfileStampsOnlyProfileGroup() throws {
        var s = try base()
        s = try TreeOps.openTab(s, id: id(20), spaceID: id(10), url: URL(string: "https://a.example"), title: "a", now: t0)
        s = try TreeOps.moveTab(s, id: id(20), to: .favorite(profileID: id(2)), position: .last, now: t0)
        let before = s.spaces[id(10)]!
        s = try TreeOps.setSpaceProfile(s, id: id(10), profileID: id(2), now: t1)
        let after = s.spaces[id(10)]!
        XCTAssertEqual(after.profileID, id(2))
        XCTAssertEqual(after.meta.modifiedAt(Space.FieldGroup.profile), t1)
        XCTAssertEqual(after.meta.modifiedAt(Space.FieldGroup.naming), before.meta.modifiedAt(Space.FieldGroup.naming))
        XCTAssertEqual(after.meta.modifiedAt(Space.FieldGroup.placement), before.meta.modifiedAt(Space.FieldGroup.placement))
        XCTAssertEqual(s.favorites(profileID: after.profileID).map(\.id), [id(20)])
        // Same profile again: nothing changes.
        XCTAssertEqual(try TreeOps.setSpaceProfile(s, id: id(10), profileID: id(2), now: t1), s)
        XCTAssertThrowsError(try TreeOps.setSpaceProfile(s, id: id(10), profileID: id(99), now: t1))
    }

    /// 06 §21.5 observed Folder ▸ Delete; inferred like Delete Space (06 §11): tabs archived,
    /// folders tombstoned, nested ones too; other folders untouched.
    func testDeleteFolderArchivesTabsAndTombstonesSubtree() throws {
        var s = try base()
        s = try TreeOps.createFolder(s, id: id(30), spaceID: id(10), title: "Outer", now: t0)
        s = try TreeOps.createFolder(s, id: id(31), spaceID: id(10), parentFolderID: id(30), title: "Inner", now: t0)
        s = try TreeOps.createFolder(s, id: id(32), spaceID: id(10), title: "Other", now: t0)
        for (tab, folder) in [(id(40), id(30)), (id(41), id(31)), (id(42), id(32))] {
            s = try TreeOps.openTab(s, id: tab, spaceID: id(10), url: URL(string: "https://x.example"), title: "x", now: t0)
            s = try TreeOps.moveTab(s, id: tab, to: .pinned(spaceID: id(10), folderID: folder), position: .last, now: t0)
        }
        s = try TreeOps.deleteFolder(s, id: id(30), now: t1)
        XCTAssertTrue(s.folders[id(30)]!.meta.isTombstone)
        XCTAssertTrue(s.folders[id(31)]!.meta.isTombstone)
        XCTAssertFalse(s.folders[id(32)]!.meta.isTombstone)
        XCTAssertTrue(s.tabs[id(40)]!.meta.isTombstone)
        XCTAssertTrue(s.tabs[id(41)]!.meta.isTombstone)
        XCTAssertFalse(s.tabs[id(42)]!.meta.isTombstone)
        XCTAssertEqual(s.archive[id(40)]?.folderPath, ["Outer"])
        XCTAssertEqual(s.archive[id(41)]?.reason, .closed)
        XCTAssertThrowsError(try TreeOps.deleteFolder(s, id: id(30), now: t1))
    }

    /// 06 §21.6 observed: Separate All Tabs ends the split; the tabs stay where they are.
    func testSeparateSplitTombstonesLayoutOnly() throws {
        var s = try base()
        s = try TreeOps.openTab(s, id: id(50), spaceID: id(10), url: nil, title: "a", now: t0)
        s = try TreeOps.openTab(s, id: id(51), spaceID: id(10), url: nil, title: "b", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: id(60), existingTabID: id(50), newTabID: id(51), now: t0)
        let tabs = s.tabs
        s = try TreeOps.separateSplit(s, layoutID: id(60), now: t1)
        XCTAssertTrue(s.splits[id(60)]!.meta.isTombstone)
        XCTAssertEqual(s.tabs, tabs)
    }

    /// 06 §21.5 observed "Convert to Vertical Split View": the axis flips, fractions stay; only `layout` is stamped.
    func testSetSplitAxisKeepsFractions() throws {
        var s = try base()
        s = try TreeOps.openTab(s, id: id(50), spaceID: id(10), url: nil, title: "a", now: t0)
        s = try TreeOps.openTab(s, id: id(51), spaceID: id(10), url: nil, title: "b", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: id(60), existingTabID: id(50), newTabID: id(51), now: t0)
        s = try TreeOps.setSplitAxis(s, layoutID: id(60), axis: .vertical, now: t1)
        guard case .split(let axis, let children) = s.splits[id(60)]!.root else { return XCTFail("not a split") }
        XCTAssertEqual(axis, .vertical)
        XCTAssertEqual(children.map(\.fraction), [0.5, 0.5])
        XCTAssertEqual(s.splits[id(60)]!.meta.modifiedAt(SplitLayout.FieldGroup.layout), t1)
        // Same axis: no change.
        XCTAssertEqual(try TreeOps.setSplitAxis(s, layoutID: id(60), axis: .vertical, now: t1), s)
    }
}
