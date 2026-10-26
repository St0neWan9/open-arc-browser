import XCTest
@testable import OpenArcModel

/// Checks that operations honour the field-group LWW contract: each operation stamps only the
/// groups it changes, so a concurrent edit to another group on another device survives a merge.
final class SyncMetadataTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeState() throws -> (WorkspaceState, space: UUID, tab: UUID) {
        let profile = UUID(), space = UUID(), tab = UUID()
        var s = WorkspaceState()
        s.profiles[profile] = Profile(id: profile, name: "P", now: t0)
        s = try TreeOps.createSpace(s, id: space, profileID: profile, name: "S", now: t0)
        s = try TreeOps.openTab(s, id: tab, spaceID: space, url: nil, title: "T", now: t0)
        return (s, space, tab)
    }

    func testNewRecordStampsEveryGroupWithCreationTime() throws {
        let (s, _, tab) = try makeState()
        let meta = try XCTUnwrap(s.tabs[tab]).meta
        for group in TabNode.FieldGroup.allCases {
            XCTAssertEqual(meta.modifiedAt(group), t0)
        }
        XCTAssertEqual(meta.version, 1)
        XCTAssertFalse(meta.isTombstone)
    }

    func testRenameStampsOnlyNamingGroup() throws {
        let (s0, _, tab) = try makeState()
        let t1 = t0.addingTimeInterval(60)
        let s = try TreeOps.renameTab(s0, id: tab, customTitle: "Mine", now: t1)
        let meta = try XCTUnwrap(s.tabs[tab]).meta
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.naming), t1)
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.placement), t0)
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.content), t0)
        XCTAssertEqual(meta.modifiedAt, t1)
        XCTAssertEqual(meta.version, 2)
    }

    func testMoveStampsPlacementAsOneGroup() throws {
        let (s0, space, tab) = try makeState()
        let t1 = t0.addingTimeInterval(60)
        let s = try TreeOps.moveTab(s0, id: tab, to: .pinned(spaceID: space, folderID: nil), position: .first, now: t1)
        let meta = try XCTUnwrap(s.tabs[tab]).meta
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.placement), t1)
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.naming), t0)
    }

    func testContentUpdateDoesNotTouchNaming() throws {
        let (s0, _, tab) = try makeState()
        let t1 = t0.addingTimeInterval(60)
        let s = try TreeOps.updateTabContent(s0, id: tab, url: URL(string: "https://n.example"), title: "N", faviconURL: nil, now: t1)
        let meta = try XCTUnwrap(s.tabs[tab]).meta
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.content), t1)
        XCTAssertEqual(meta.modifiedAt(TabNode.FieldGroup.naming), t0)
    }

    func testTombstoneIsIdempotent() {
        var meta = SyncMetadata.new(at: t0, groups: TabNode.FieldGroup.self)
        meta.markDeleted(at: t0.addingTimeInterval(1))
        meta.markDeleted(at: t0.addingTimeInterval(2))
        XCTAssertTrue(meta.isTombstone)
        XCTAssertEqual(meta.deletedAt, t0.addingTimeInterval(1))
        XCTAssertEqual(meta.version, 2)
    }

    func testWorkspaceStateCodableRoundTrip() throws {
        let (s0, space, tab) = try makeState()
        var s = s0
        let folder = UUID(), layout = UUID(), other = UUID()
        s = try TreeOps.createFolder(s, id: folder, spaceID: space, title: "F", now: t0)
        s = try TreeOps.openTab(s, id: other, spaceID: space, url: nil, title: "O", now: t0)
        s = try TreeOps.addSplitPane(s, layoutID: layout, existingTabID: tab, newTabID: other, now: t0)
        s.themes[UUID()] = Theme(id: UUID(), colors: [RGBAColor(hex: 0x7A5AF8)], now: t0)
        s.tabs[tab]?.meta.backendSystemFields = Data([1, 2, 3])
        s = try TreeOps.archiveTab(s, id: tab, now: t0)

        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded, s)
    }
}
