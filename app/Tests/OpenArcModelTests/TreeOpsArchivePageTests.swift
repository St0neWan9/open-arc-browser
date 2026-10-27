import XCTest
@testable import OpenArcModel

/// Plan B82: `TreeOps.archivePage`, the archive of an idle Little Arc page that never had a tab.
/// [03 §Links] observed "Archive Little Arcs after" (default 6 hours).
final class TreeOpsArchivePageTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let profileID = UUID()
    private let spaceID = UUID()

    private func state() throws -> WorkspaceState {
        var s = WorkspaceState()
        s.profiles[profileID] = Profile(id: profileID, name: "Default", now: t0)
        return try TreeOps.createSpace(s, id: spaceID, profileID: profileID, name: "Space", now: t0)
    }

    func testArchivePageCreatesALiveItemAndTouchesNothingElse() throws {
        let base = try state()
        let id = UUID()
        let url = URL(string: "https://little.example/a")
        let stamp = t0.addingTimeInterval(60)
        let s = try TreeOps.archivePage(base, id: id, url: url, title: "A", spaceID: spaceID, now: stamp)
        let item = try XCTUnwrap(s.archive[id])
        XCTAssertFalse(item.meta.isTombstone)
        XCTAssertEqual(item.url, url)
        XCTAssertEqual(item.title, "A")
        XCTAssertEqual(item.spaceID, spaceID)
        XCTAssertEqual(item.folderPath, [])
        XCTAssertEqual(item.reason, .autoArchived)
        XCTAssertEqual(item.archivedAt, stamp)
        XCTAssertEqual(item.meta.createdAt, stamp)
        XCTAssertEqual(s.tabs, base.tabs)
        XCTAssertEqual(s.spaces, base.spaces)
    }

    func testArchivedPageRestoresIntoItsSpace() throws {
        let id = UUID(), tab = UUID()
        var s = try TreeOps.archivePage(try state(), id: id, url: URL(string: "https://little.example"), title: "L", spaceID: spaceID, now: t0)
        s = try TreeOps.restoreFromArchive(s, itemID: id, newTabID: tab, spaceID: spaceID, now: t0.addingTimeInterval(1))
        XCTAssertEqual(s.today(spaceID: spaceID).first?.id, tab)
        XCTAssertEqual(s.archive[id]?.meta.isTombstone, true)
    }

    func testArchivePageRejectsUsedIdsAndDeadSpaces() throws {
        let tab = UUID()
        let base = try TreeOps.openTab(try state(), id: tab, spaceID: spaceID, url: nil, title: "T", now: t0)
        XCTAssertThrowsError(try TreeOps.archivePage(base, id: tab, url: nil, title: "x", spaceID: nil, now: t0)) {
            XCTAssertEqual($0 as? TreeError, .idInUse(tab))
        }
        let id = UUID()
        let once = try TreeOps.archivePage(base, id: id, url: nil, title: "x", spaceID: nil, now: t0)
        XCTAssertNil(once.archive[id]?.spaceID)
        XCTAssertThrowsError(try TreeOps.archivePage(once, id: id, url: nil, title: "x", spaceID: nil, now: t0))
        let gone = try TreeOps.deleteSpace(base, id: spaceID, now: t0.addingTimeInterval(1))
        XCTAssertThrowsError(try TreeOps.archivePage(gone, id: UUID(), url: nil, title: "x", spaceID: spaceID, now: t0.addingTimeInterval(2))) {
            XCTAssertEqual($0 as? TreeError, .tombstoned(self.spaceID))
        }
    }
}
