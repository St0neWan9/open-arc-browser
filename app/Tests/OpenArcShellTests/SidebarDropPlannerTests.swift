import XCTest
import OpenArcModel
@testable import OpenArcShell

/// Drop-target decisions. Spec: [06 §12] hover and drag results (observed).
final class SidebarDropPlannerTests: XCTestCase {
    private let f = SidebarFixture()

    private func plan(_ item: SidebarDragItem, _ target: SidebarDropTarget) -> SidebarDropPlan? {
        SidebarDropPlanner.plan(item: item, target: target, workspace: f.ws, spaceID: f.home, profileID: f.profile)
    }

    /// [06 §12]: a Today tab dragged above the first pinned row becomes pinned, before the folders.
    func testTodayTabAboveFirstPinnedRowPinsAtTop() {
        let p = plan(.tab(f.today1), .pinnedAreaTop)
        XCTAssertEqual(p?.action, .moveTab(id: f.today1, to: .pinned(spaceID: f.home, folderID: nil), position: .first))
        // Same result when the pointer is in the top zone of the first row.
        let first = f.topLevelPinnedIDs()[0]
        let q = plan(.tab(f.today1), .row(first, .above))
        XCTAssertEqual(q?.action, .moveTab(id: f.today1, to: .pinned(spaceID: f.home, folderID: nil), position: .before(first)))
    }

    /// [06 §12]: a pinned tab dropped on a folder row goes inside, and the folder expands.
    func testPinnedTabOntoFolderMovesInside() {
        let p = plan(.tab(f.pinnedTab), .row(f.folderC, .into))
        XCTAssertEqual(p?.action, .moveTab(id: f.pinnedTab, to: .pinned(spaceID: f.home, folderID: f.folderC), position: .last))
        XCTAssertEqual(p?.expandFolderID, f.folderC)
    }

    /// [06 §12]: a folder cannot move into itself or its descendants.
    func testFolderCannotMoveIntoItselfOrDescendant() {
        XCTAssertNil(plan(.folder(f.folderA), .row(f.folderA, .into)))
        XCTAssertNil(plan(.folder(f.folderA), .row(f.folderB, .into)))
        // Dropping A next to a tab that lives inside B would nest it in its own subtree.
        XCTAssertNil(plan(.folder(f.folderA), .row(f.deepTab, .above)))
        XCTAssertNil(plan(.folder(f.folderA), .row(f.inFolderTab, .below)))
    }

    /// Legal folder moves are allowed: into a sibling folder, or before another top-level folder.
    func testFolderMovesIntoSiblingAndReorders() {
        XCTAssertEqual(plan(.folder(f.folderC), .row(f.folderA, .into))?.action,
                       .moveFolder(id: f.folderC, toSpace: f.home, parent: f.folderA, position: .last))
        XCTAssertEqual(plan(.folder(f.folderC), .row(f.folderA, .above))?.action,
                       .moveFolder(id: f.folderC, toSpace: f.home, parent: nil, position: .before(f.folderA)))
    }

    /// Dropping on yourself is a no-op; folders never enter Today or favorites.
    func testRejectedDrops() {
        XCTAssertNil(plan(.tab(f.today1), .row(f.today1, .above)))
        XCTAssertNil(plan(.folder(f.folderA), .todayAreaEnd))
        XCTAssertNil(plan(.folder(f.folderA), .favoriteGap(0)))
        XCTAssertNil(plan(.tab(f.today1), .row(f.fav1, .above)), "favorites are not rows")
        XCTAssertNil(plan(.tab(UUID()), .pinnedAreaTop), "unknown item")
    }

    /// Below an expanded folder that has children means "first slot inside"; below a collapsed or
    /// empty folder means "after it".
    func testBelowFolderRow() {
        XCTAssertEqual(plan(.tab(f.today1), .row(f.folderA, .below))?.action,
                       .moveTab(id: f.today1, to: .pinned(spaceID: f.home, folderID: f.folderA), position: .first))
        XCTAssertEqual(plan(.tab(f.today1), .row(f.folderC, .below))?.action,
                       .moveTab(id: f.today1, to: .pinned(spaceID: f.home, folderID: nil), position: .after(f.folderC)))
    }

    /// Pinned tab dragged to the end of Today becomes unpinned; favorites gap and dock moves.
    func testUnpinFavoriteAndDockTargets() {
        XCTAssertEqual(plan(.tab(f.pinnedTab), .todayAreaEnd)?.action,
                       .moveTab(id: f.pinnedTab, to: .today(spaceID: f.home), position: .last))
        XCTAssertEqual(plan(.tab(f.today1), .favoriteGap(0))?.action,
                       .moveTab(id: f.today1, to: .favorite(profileID: f.profile), position: .before(f.fav1)))
        XCTAssertEqual(plan(.tab(f.today1), .favoriteGap(2))?.action,
                       .moveTab(id: f.today1, to: .favorite(profileID: f.profile), position: .last))
        XCTAssertEqual(plan(.tab(f.today1), .dockSpace(f.work))?.action,
                       .moveTab(id: f.today1, to: .today(spaceID: f.work), position: .first))
        XCTAssertNil(plan(.tab(f.today1), .dockSpace(f.home)), "same space")
        XCTAssertNil(plan(.tab(f.fav1), .dockSpace(f.work)), "favorites are shared")
    }

    /// Reordering a favorite onto the gap right after itself keeps it in place.
    func testFavoriteReorderAdjustsForOwnPosition() {
        XCTAssertEqual(plan(.tab(f.fav1), .favoriteGap(2))?.action,
                       .moveTab(id: f.fav1, to: .favorite(profileID: f.profile), position: .last))
        XCTAssertEqual(plan(.tab(f.fav2), .favoriteGap(0))?.action,
                       .moveTab(id: f.fav2, to: .favorite(profileID: f.profile), position: .before(f.fav1)))
    }

    /// Zone mapping: folder rows have an "into" middle band, tab rows split in half.
    func testZones() {
        XCTAssertEqual(SidebarDropZone.zone(forY: 2, rowHeight: 36, allowsInto: true), .above)
        XCTAssertEqual(SidebarDropZone.zone(forY: 18, rowHeight: 36, allowsInto: true), .into)
        XCTAssertEqual(SidebarDropZone.zone(forY: 34, rowHeight: 36, allowsInto: true), .below)
        XCTAssertEqual(SidebarDropZone.zone(forY: 10, rowHeight: 36, allowsInto: false), .above)
        XCTAssertEqual(SidebarDropZone.zone(forY: 20, rowHeight: 36, allowsInto: false), .below)
    }

    /// Every plan the planner produces must be accepted by TreeOps (no plan the model rejects).
    func testEveryPlanAppliesCleanly() throws {
        let targets: [SidebarDropTarget] = [.pinnedAreaTop, .pinnedAreaEnd, .todayAreaEnd, .favoriteGap(0), .favoriteGap(1), .favoriteGap(2), .dockSpace(f.work)]
            + [f.folderA, f.folderB, f.folderC, f.pinnedTab, f.inFolderTab, f.deepTab, f.today1, f.today2]
                .flatMap { id in [SidebarDropZone.above, .into, .below].map { SidebarDropTarget.row(id, $0) } }
        var count = 0
        for item in f.allDraggables {
            for target in targets {
                guard let p = plan(item, target) else { continue }
                count += 1
                switch p.action {
                case .moveTab(let id, let loc, let pos):
                    XCTAssertNoThrow(try TreeOps.moveTab(f.ws, id: id, to: loc, position: pos, now: f.now), "\(item) on \(target)")
                case .moveFolder(let id, let space, let parent, let pos):
                    XCTAssertNoThrow(try TreeOps.moveFolder(f.ws, id: id, toSpace: space, parentFolderID: parent, position: pos, now: f.now), "\(item) on \(target)")
                case .moveTabs(let ids, let loc, let pos):
                    XCTAssertNoThrow(try SidebarDropPlanner.moveSteps(ids: ids, position: pos).reduce(f.ws) { try TreeOps.moveTab($0, id: $1.id, to: loc, position: $1.position, now: f.now) }, "\(item) on \(target)")
                case .moveSplitLayout(let id, let space, let pos):
                    XCTAssertNoThrow(try TreeOps.moveSplitLayout(f.ws, layoutID: id, toSpaceID: space, position: pos, now: f.now), "\(item) on \(target)")
                }
            }
        }
        XCTAssertGreaterThan(count, 50)
    }
}
