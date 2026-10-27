import XCTest
@testable import OpenArcModel

/// Fixture: one profile, one space, deterministic ids and clock.
private struct Fixture {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    let profileID = UUID()
    let spaceID = UUID()
    var state: WorkspaceState

    init() throws {
        var s = WorkspaceState()
        s.profiles[profileID] = Profile(id: profileID, name: "Default", now: t0)
        s = try TreeOps.createSpace(s, id: spaceID, profileID: profileID, name: "Space", now: t0)
        state = s
    }

    func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
}

final class TreeOpsTests: XCTestCase {

    // MARK: Spaces

    func testNewSpaceIsInsertedAfterCurrentNotAtEnd() throws {
        var f = try Fixture()
        let second = UUID(), third = UUID()
        f.state = try TreeOps.createSpace(f.state, id: second, profileID: f.profileID, name: "B", now: f.t0)
        f.state = try TreeOps.createSpace(f.state, id: third, profileID: f.profileID, name: "C", afterSpaceID: f.spaceID, now: f.t0)
        XCTAssertEqual(f.state.spaces(inProfile: f.profileID).map(\.id), [f.spaceID, third, second])
    }

    func testDeleteSpaceArchivesTabsAndTombstonesFoldersAndSpace() throws {
        var f = try Fixture()
        let folder = UUID(), pinned = UUID(), today = UUID(), fav = UUID()
        f.state = try TreeOps.createFolder(f.state, id: folder, spaceID: f.spaceID, title: "Work", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: pinned, spaceID: f.spaceID, url: URL(string: "https://a.example"), title: "A", now: f.t0)
        f.state = try TreeOps.moveTab(f.state, id: pinned, to: .pinned(spaceID: f.spaceID, folderID: folder), position: .first, now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: today, spaceID: f.spaceID, url: nil, title: "B", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: fav, spaceID: f.spaceID, url: nil, title: "Fav", now: f.t0)
        f.state = try TreeOps.moveTab(f.state, id: fav, to: .favorite(profileID: f.profileID), position: .last, now: f.t0)

        let s = try TreeOps.deleteSpace(f.state, id: f.spaceID, now: f.at(10))

        XCTAssertTrue(try XCTUnwrap(s.spaces[f.spaceID]).meta.isTombstone)
        XCTAssertTrue(try XCTUnwrap(s.folders[folder]).meta.isTombstone)
        XCTAssertTrue(try XCTUnwrap(s.tabs[pinned]).meta.isTombstone)
        XCTAssertTrue(try XCTUnwrap(s.tabs[today]).meta.isTombstone)
        XCTAssertEqual(s.archive[pinned]?.reason, .spaceDeleted)
        XCTAssertEqual(s.archive[pinned]?.folderPath, ["Work"])
        XCTAssertEqual(s.archive[today]?.reason, .spaceDeleted)
        // Favorites are shared across spaces and survive.
        XCTAssertFalse(try XCTUnwrap(s.tabs[fav]).meta.isTombstone)
        XCTAssertNil(s.archive[fav])
    }

    // MARK: Tabs

    func testNewTabGoesToTopOfToday() throws {
        var f = try Fixture()
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] {
            f.state = try TreeOps.openTab(f.state, id: id, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        }
        XCTAssertEqual(f.state.today(spaceID: f.spaceID).map(\.id), [c, b, a])
    }

    func testPinPlacesTabAfterFoldersAndExistingPins() throws {
        var f = try Fixture()
        let folder = UUID(), first = UUID(), second = UUID()
        f.state = try TreeOps.createFolder(f.state, id: folder, spaceID: f.spaceID, title: "F", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: first, spaceID: f.spaceID, url: URL(string: "https://one.example"), title: "1", now: f.t0)
        f.state = try TreeOps.pinTab(f.state, id: first, now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: second, spaceID: f.spaceID, url: nil, title: "2", now: f.t0)
        f.state = try TreeOps.pinTab(f.state, id: second, now: f.t0)

        XCTAssertEqual(f.state.pinnedChildren(spaceID: f.spaceID, folderID: nil).map(\.id), [folder, first, second])
        XCTAssertTrue(f.state.today(spaceID: f.spaceID).isEmpty)
        XCTAssertEqual(f.state.tabs[first]?.pinnedURL, URL(string: "https://one.example"))
    }

    func testDragAboveFirstRowPlacesBeforeFolders() throws {
        var f = try Fixture()
        let folder = UUID(), tab = UUID()
        f.state = try TreeOps.createFolder(f.state, id: folder, spaceID: f.spaceID, title: "F", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: tab, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.moveTab(f.state, id: tab, to: .pinned(spaceID: f.spaceID, folderID: nil), position: .first, now: f.t0)
        XCTAssertEqual(f.state.pinnedChildren(spaceID: f.spaceID, folderID: nil).map(\.id), [tab, folder])
    }

    func testMoveBeforeAndAfterAnchors() throws {
        var f = try Fixture()
        let a = UUID(), b = UUID(), c = UUID()
        for id in [a, b, c] {
            f.state = try TreeOps.openTab(f.state, id: id, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        }
        // Today order is [c, b, a]. Move c after a.
        f.state = try TreeOps.moveTab(f.state, id: c, to: .today(spaceID: f.spaceID), position: .after(a), now: f.t0)
        XCTAssertEqual(f.state.today(spaceID: f.spaceID).map(\.id), [b, a, c])
        f.state = try TreeOps.moveTab(f.state, id: c, to: .today(spaceID: f.spaceID), position: .before(b), now: f.t0)
        XCTAssertEqual(f.state.today(spaceID: f.spaceID).map(\.id), [c, b, a])
    }

    func testMoveWithForeignAnchorThrowsAndLeavesStateUntouched() throws {
        let f = try Fixture()
        var s = try TreeOps.openTab(f.state, id: UUID(), spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        let tab = try XCTUnwrap(s.today(spaceID: f.spaceID).first).id
        let stranger = UUID()
        XCTAssertThrowsError(try TreeOps.moveTab(s, id: tab, to: .today(spaceID: f.spaceID), position: .before(stranger), now: f.t0)) {
            XCTAssertEqual($0 as? TreeError, .anchorNotInContainer(stranger))
        }
        s = try TreeOps.moveTab(s, id: tab, to: .today(spaceID: f.spaceID), position: .first, now: f.t0)
        XCTAssertEqual(s.today(spaceID: f.spaceID).count, 1)
    }

    func testOperationsOnTombstonedRecordsThrow() throws {
        var f = try Fixture()
        let tab = UUID()
        f.state = try TreeOps.openTab(f.state, id: tab, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.archiveTab(f.state, id: tab, now: f.t0)
        XCTAssertThrowsError(try TreeOps.renameTab(f.state, id: tab, customTitle: "x", now: f.t0)) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(tab))
        }
        XCTAssertThrowsError(try TreeOps.renameTab(f.state, id: UUID(), customTitle: "x", now: f.t0))
    }

    // MARK: Folders

    func testNewFolderGoesToTopOfPinnedAndIsExpanded() throws {
        var f = try Fixture()
        let tab = UUID(), folder = UUID()
        f.state = try TreeOps.openTab(f.state, id: tab, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.pinTab(f.state, id: tab, now: f.t0)
        f.state = try TreeOps.createFolder(f.state, id: folder, spaceID: f.spaceID, title: "New", now: f.t0)
        XCTAssertEqual(f.state.pinnedChildren(spaceID: f.spaceID, folderID: nil).map(\.id), [folder, tab])
        XCTAssertEqual(f.state.folders[folder]?.isExpanded, true)
    }

    func testFolderCannotMoveIntoItselfOrDescendant() throws {
        var f = try Fixture()
        let outer = UUID(), inner = UUID()
        f.state = try TreeOps.createFolder(f.state, id: outer, spaceID: f.spaceID, title: "Outer", now: f.t0)
        f.state = try TreeOps.createFolder(f.state, id: inner, spaceID: f.spaceID, parentFolderID: outer, title: "Inner", now: f.t0)
        XCTAssertThrowsError(try TreeOps.moveFolder(f.state, id: outer, toSpace: f.spaceID, parentFolderID: inner, position: .first, now: f.t0)) {
            XCTAssertEqual($0 as? TreeError, .wouldCreateCycle)
        }
        XCTAssertThrowsError(try TreeOps.moveFolder(f.state, id: outer, toSpace: f.spaceID, parentFolderID: outer, position: .first, now: f.t0)) {
            XCTAssertEqual($0 as? TreeError, .wouldCreateCycle)
        }
        // The legal direction works.
        let s = try TreeOps.moveFolder(f.state, id: inner, toSpace: f.spaceID, parentFolderID: nil, position: .last, now: f.t0)
        XCTAssertEqual(s.pinnedChildren(spaceID: f.spaceID, folderID: nil).map(\.id), [outer, inner])
    }

    func testMovingFolderAcrossSpacesMovesSubtree() throws {
        var f = try Fixture()
        let other = UUID(), outer = UUID(), inner = UUID(), tab = UUID()
        f.state = try TreeOps.createSpace(f.state, id: other, profileID: f.profileID, name: "Other", now: f.t0)
        f.state = try TreeOps.createFolder(f.state, id: outer, spaceID: f.spaceID, title: "Outer", now: f.t0)
        f.state = try TreeOps.createFolder(f.state, id: inner, spaceID: f.spaceID, parentFolderID: outer, title: "Inner", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: tab, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.moveTab(f.state, id: tab, to: .pinned(spaceID: f.spaceID, folderID: inner), position: .first, now: f.t0)

        let s = try TreeOps.moveFolder(f.state, id: outer, toSpace: other, parentFolderID: nil, position: .first, now: f.t0)
        XCTAssertEqual(s.folders[inner]?.spaceID, other)
        XCTAssertEqual(s.tabs[tab]?.location, .pinned(spaceID: other, folderID: inner))
        XCTAssertTrue(s.pinnedChildren(spaceID: f.spaceID, folderID: nil).isEmpty)
    }

    func testFolderInOtherSpaceIsRejectedAsTabTarget() throws {
        var f = try Fixture()
        let other = UUID(), folder = UUID(), tab = UUID()
        f.state = try TreeOps.createSpace(f.state, id: other, profileID: f.profileID, name: "Other", now: f.t0)
        f.state = try TreeOps.createFolder(f.state, id: folder, spaceID: other, title: "F", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: tab, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        XCTAssertThrowsError(try TreeOps.moveTab(f.state, id: tab, to: .pinned(spaceID: f.spaceID, folderID: folder), position: .first, now: f.t0)) {
            XCTAssertEqual($0 as? TreeError, .spaceMismatch)
        }
    }

    // MARK: Archive

    func testArchiveTabCreatesItemWithSameIdAndTombstonesTab() throws {
        var f = try Fixture()
        let tab = UUID()
        f.state = try TreeOps.openTab(f.state, id: tab, spaceID: f.spaceID, url: URL(string: "https://x.example"), title: "X", now: f.t0)
        f.state = try TreeOps.renameTab(f.state, id: tab, customTitle: "Renamed", now: f.t0)
        let s = try TreeOps.archiveTab(f.state, id: tab, now: f.at(5))
        XCTAssertTrue(try XCTUnwrap(s.tabs[tab]).meta.isTombstone)
        let item = try XCTUnwrap(s.archive[tab])
        XCTAssertEqual(item.reason, .closed)
        XCTAssertEqual(item.title, "Renamed")
        XCTAssertEqual(item.archivedAt, f.at(5))
        XCTAssertTrue(s.today(spaceID: f.spaceID).isEmpty)
    }

    func testClearTodayArchivesOnlyTodayTabs() throws {
        var f = try Fixture()
        let pinned = UUID(), t1 = UUID(), t2 = UUID()
        f.state = try TreeOps.openTab(f.state, id: pinned, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.pinTab(f.state, id: pinned, now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: t1, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: t2, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        let s = try TreeOps.clearToday(f.state, spaceID: f.spaceID, now: f.t0)
        XCTAssertTrue(s.today(spaceID: f.spaceID).isEmpty)
        XCTAssertEqual(s.archive[t1]?.reason, .clearedToday)
        XCTAssertEqual(s.archive[t2]?.reason, .clearedToday)
        XCTAssertEqual(s.pinnedChildren(spaceID: f.spaceID, folderID: nil).map(\.id), [pinned])
    }

    func testAutoArchiveUsesTwelveHourDefaultAndActivityClock() throws {
        var f = try Fixture()
        let stale = UUID(), fresh = UUID(), pinned = UUID()
        f.state = try TreeOps.openTab(f.state, id: stale, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: fresh, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: pinned, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.pinTab(f.state, id: pinned, now: f.t0)
        f.state = try TreeOps.markTabActive(f.state, id: fresh, now: f.at(6 * 3600))

        XCTAssertEqual(ArchivePolicy.defaultTodayLifetime, 12 * 3600)
        let justBefore = TreeOps.autoArchive(f.state, now: f.at(12 * 3600 - 1))
        XCTAssertTrue(justBefore.archive.isEmpty)

        let s = TreeOps.autoArchive(f.state, now: f.at(12 * 3600))
        XCTAssertEqual(s.archive[stale]?.reason, .autoArchived)
        XCTAssertNil(s.archive[fresh])
        XCTAssertNil(s.archive[pinned])
    }

    func testRestoreFromArchiveOpensNewTabAtTopOfToday() throws {
        var f = try Fixture()
        let old = UUID(), other = UUID(), restored = UUID()
        f.state = try TreeOps.openTab(f.state, id: old, spaceID: f.spaceID, url: URL(string: "https://r.example"), title: "R", now: f.t0)
        f.state = try TreeOps.archiveTab(f.state, id: old, now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: other, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        let s = try TreeOps.restoreFromArchive(f.state, itemID: old, newTabID: restored, spaceID: f.spaceID, now: f.at(1))
        XCTAssertEqual(s.today(spaceID: f.spaceID).map(\.id), [restored, other])
        XCTAssertEqual(s.tabs[restored]?.url, URL(string: "https://r.example"))
        XCTAssertTrue(s.archiveNewestFirst.isEmpty)
    }

    /// 01 §Archive (Clear Archive, B69): every archive item is tombstoned (delete by tombstone);
    /// live tabs and older tombstones are left as they were.
    func testClearArchiveTombstonesItemsAndLeavesTabsAlone() throws {
        var f = try Fixture()
        let a = UUID(), b = UUID(), kept = UUID(), restored = UUID()
        for id in [a, b, kept] {
            f.state = try TreeOps.openTab(f.state, id: id, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        }
        f.state = try TreeOps.archiveTab(f.state, id: a, now: f.t0)
        f.state = try TreeOps.archiveTab(f.state, id: b, now: f.t0)
        // `a` was restored earlier: its item is already a tombstone.
        f.state = try TreeOps.restoreFromArchive(f.state, itemID: a, newTabID: restored, spaceID: f.spaceID, now: f.at(1))
        let earlier = try XCTUnwrap(f.state.archive[a]).meta

        let s = TreeOps.clearArchive(f.state, now: f.at(9))
        XCTAssertTrue(s.archiveNewestFirst.isEmpty)
        XCTAssertEqual(s.archive.count, 2, "items are tombstoned, not removed")
        XCTAssertEqual(s.archive[b]?.meta.deletedAt, f.at(9))
        XCTAssertEqual(s.archive[a]?.meta, earlier, "an old tombstone is not stamped again")
        XCTAssertEqual(Set(s.today(spaceID: f.spaceID).map(\.id)), [kept, restored], "no tab is archived")
        XCTAssertEqual(s.tabs, f.state.tabs)
    }

    // MARK: Split view

    func testSplitAddAndRemoveCollapsesToSinglePage() throws {
        var f = try Fixture()
        let left = UUID(), right = UUID(), third = UUID(), layout = UUID()
        for id in [left, right, third] {
            f.state = try TreeOps.openTab(f.state, id: id, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        }
        f.state = try TreeOps.addSplitPane(f.state, layoutID: layout, existingTabID: left, newTabID: right, now: f.t0)
        XCTAssertEqual(f.state.splits[layout]?.root.tabIDs, [left, right])

        f.state = try TreeOps.addSplitPane(f.state, layoutID: UUID(), existingTabID: right, newTabID: third, now: f.t0)
        XCTAssertEqual(f.state.splits.count, 1, "extends the existing layout instead of creating another")
        guard case .split(_, let children)? = f.state.splits[layout]?.root else { return XCTFail("expected split") }
        XCTAssertEqual(children.map(\.fraction), [1.0 / 3, 1.0 / 3, 1.0 / 3])

        f.state = TreeOps.removeSplitPane(f.state, tabID: third, now: f.t0)
        XCTAssertEqual(f.state.splits[layout]?.root.tabIDs, [left, right])
        // Archiving one of the last two panes ends the split.
        f.state = try TreeOps.archiveTab(f.state, id: right, now: f.t0)
        XCTAssertTrue(try XCTUnwrap(f.state.splits[layout]).meta.isTombstone)
    }

    func testSplitRejectsTabsFromDifferentSpaces() throws {
        var f = try Fixture()
        let other = UUID(), a = UUID(), b = UUID()
        f.state = try TreeOps.createSpace(f.state, id: other, profileID: f.profileID, name: "Other", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: a, spaceID: f.spaceID, url: nil, title: "", now: f.t0)
        f.state = try TreeOps.openTab(f.state, id: b, spaceID: other, url: nil, title: "", now: f.t0)
        XCTAssertThrowsError(try TreeOps.addSplitPane(f.state, layoutID: UUID(), existingTabID: a, newTabID: b, now: f.t0)) {
            XCTAssertEqual($0 as? TreeError, .spaceMismatch)
        }
    }

    func testSplitNodeRemovalRenormalizesNestedFractions() {
        let a = UUID(), b = UUID(), c = UUID()
        let tree = SplitNode.split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 0.5),
            SplitChild(node: .split(axis: .vertical, children: [
                SplitChild(node: .pane(tabID: b), fraction: 0.5),
                SplitChild(node: .pane(tabID: c), fraction: 0.5),
            ]), fraction: 0.5),
        ])
        let result = tree.removing(b)
        XCTAssertEqual(result, .split(axis: .horizontal, children: [
            SplitChild(node: .pane(tabID: a), fraction: 0.5),
            SplitChild(node: .pane(tabID: c), fraction: 0.5),
        ]))
        XCTAssertNil(SplitNode.pane(tabID: a).removing(a))
    }
}

/// Pin URL and profile operations added for the sidebar menus.
final class TreeOpsPinAndProfileTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)
    private let t1 = Date(timeIntervalSince1970: 10)

    private func pinnedFixture() throws -> (WorkspaceState, UUID) {
        let profile = UUID(), space = UUID(), tab = UUID()
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "S", now: t0)
        s = try TreeOps.openTab(s, id: tab, spaceID: space, url: URL(string: "https://a.example"), title: "A", now: t0)
        s = try TreeOps.pinTab(s, id: tab, now: t0)
        s = try TreeOps.updateTabContent(s, id: tab, url: URL(string: "https://a.example/deep"), title: "A", faviconURL: nil, now: t0)
        return (s, tab)
    }

    /// [05 §context menus] observed: Edit Pinned Page ▸ Replace Pinned URL with Current.
    func testReplacePinnedURLStampsOnlyPin() throws {
        let (s, tab) = try pinnedFixture()
        let before = s.tabs[tab]!.meta
        let out = try TreeOps.replacePinnedURLWithCurrent(s, id: tab, now: t1)
        XCTAssertEqual(out.tabs[tab]?.pinnedURL, URL(string: "https://a.example/deep"))
        XCTAssertEqual(out.tabs[tab]?.meta.modifiedAt(TabNode.FieldGroup.pin), t1)
        XCTAssertEqual(out.tabs[tab]?.meta.modifiedAt(TabNode.FieldGroup.content), before.modifiedAt(TabNode.FieldGroup.content))
    }

    /// [02 §tabs] observed: Reset Tab to Original URL.
    func testResetToPinnedURLStampsOnlyContent() throws {
        let (s, tab) = try pinnedFixture()
        let out = try TreeOps.resetTabToPinnedURL(s, id: tab, now: t1)
        XCTAssertEqual(out.tabs[tab]?.url, URL(string: "https://a.example"))
        XCTAssertEqual(out.tabs[tab]?.meta.modifiedAt(TabNode.FieldGroup.content), t1)
        XCTAssertEqual(out.tabs[tab]?.meta.modifiedAt(TabNode.FieldGroup.pin), t0)
    }

    func testTodayTabsHaveNoPinnedURLToReplace() throws {
        let profile = UUID(), space = UUID(), tab = UUID()
        var s = TreeOps.createProfile(WorkspaceState(), id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "S", now: t0)
        s = try TreeOps.openTab(s, id: tab, spaceID: space, url: URL(string: "https://a.example"), title: "A", now: t0)
        XCTAssertThrowsError(try TreeOps.replacePinnedURLWithCurrent(s, id: tab, now: t1))
    }

    /// [01, 05 §context menus] observed: New Profile.
    func testCreateAndRenameProfile() throws {
        let id = UUID()
        var s = TreeOps.createProfile(WorkspaceState(), id: id, name: "Work", now: t0)
        XCTAssertEqual(s.profiles[id]?.name, "Work")
        s = try TreeOps.renameProfile(s, id: id, name: "Job", now: t1)
        XCTAssertEqual(s.profiles[id]?.name, "Job")
        XCTAssertEqual(s.profiles[id]?.meta.modifiedAt(Profile.FieldGroup.naming), t1)
    }
}
