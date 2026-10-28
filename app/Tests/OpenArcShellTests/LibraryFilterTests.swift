import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B94: the Library's Filter panel. Acceptance: `06 §8` Filter (E24), observed: "Filter"
/// swaps the search field for a title + "Done"; capsules above the list; Downloads by Profile;
/// Archived Tabs by how the tab was closed and where it was. How chips combine (OR within a
/// group, AND across groups) and that Done clears them are inferred.
@MainActor
final class LibraryFilterTests: XCTestCase {
    private var fixture = SidebarFixture()
    private let second = SidebarFixture.id(700)
    private let secondSpace = SidebarFixture.id(701)
    private var engine: FakeEngine!
    private var model: ShellModel!

    private let closedHome = SidebarFixture.id(801)
    private let autoWork = SidebarFixture.id(802)
    private let littleArc = SidebarFixture.id(803)
    private let clearedHome = SidebarFixture.id(804)
    private let favorite = SidebarFixture.id(805)

    override func setUp() async throws {
        var ws = fixture.ws
        ws = TreeOps.createProfile(ws, id: second, name: "Work Profile", now: fixture.now.addingTimeInterval(1))
        ws = try TreeOps.createSpace(ws, id: secondSpace, profileID: second, name: "Side", now: fixture.now)
        func add(_ id: UUID, _ title: String, space: UUID?, reason: ArchiveReason, littleArc: Bool = false) {
            ws.archive[id] = ArchiveItem(id: id, url: URL(string: "https://\(title).example"), title: title, faviconURL: nil,
                                         spaceID: space, folderPath: [], reason: reason, archivedAt: fixture.now,
                                         isFromLittleArc: littleArc)
        }
        add(closedHome, "closedHome", space: fixture.home, reason: .closed)
        add(autoWork, "autoWork", space: fixture.work, reason: .autoArchived)
        // A Little Arc page keeps the Space it would restore into; it still counts as Little Arc.
        add(littleArc, "littleArc", space: fixture.home, reason: .autoArchived, littleArc: true)
        add(clearedHome, "clearedHome", space: fixture.home, reason: .clearedToday)
        add(favorite, "favorite", space: nil, reason: .closed)
        engine = FakeEngine()
        let now = fixture.now
        model = ShellModel(dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()), workspace: ws, now: { now })
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private var archiveTitles: Set<String> {
        Set(model.library.archiveGroups.flatMap(\.items).map(\.title))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: Panel [06 §8] Filter

    /// [06 §8] Filter, observed: Filter opens the panel (title + Done in place of the search
    /// field); Done closes it and brings the search field back.
    func testFilterOpensPanelAndDoneRestoresSearchField() {
        let library = model.library
        model.openLibrary(.archivedTabs)
        XCTAssertFalse(library.isFilterPanelOpen)
        library.openFilterPanel()
        XCTAssertTrue(library.isFilterPanelOpen)
        XCTAssertEqual(LibraryFilter.title(for: .archivedTabs), "Filter Archived Tabs")
        XCTAssertEqual(LibraryFilter.title(for: .downloads), "Filter Downloads…")
        XCTAssertEqual(LibraryTexts.filterDone, "Done")
        library.toggleFilter(.manuallyClosed)
        library.closeFilterPanel()
        XCTAssertFalse(library.isFilterPanelOpen)
        XCTAssertTrue(library.filterSelection.isEmpty, "Done clears the chips (inferred)")
        XCTAssertEqual(archiveTitles.count, 5)

        // Sections without a Filter button have no panel; switching section closes it. inferred.
        model.openLibrary(.boosts)
        library.openFilterPanel()
        XCTAssertFalse(library.isFilterPanelOpen)
        model.openLibrary(.archivedTabs)
        library.openFilterPanel()
        model.openLibrary(.downloads)
        XCTAssertFalse(library.isFilterPanelOpen)
        XCTAssertNil(library.filterPanelSection)
    }

    /// [06 §8] Filter, observed: Archived Tabs groups "How was the tab closed?" (Auto-Closed,
    /// Manually Closed) and "Where was the tab?" (Little Arc + each Space in dock order).
    func testArchiveGroupsAndChipsInOrder() {
        model.openLibrary(.archivedTabs)
        model.library.openFilterPanel()
        let groups = model.library.filterGroups
        XCTAssertEqual(groups.map(\.title), ["How was the tab closed?", "Where was the tab?"])
        XCTAssertEqual(groups[0].chips.map(\.title), ["Auto-Closed", "Manually Closed"])
        let dockOrder = model.workspace.allLiveSpaces.map(\.name)
        XCTAssertEqual(groups[1].chips.map(\.title), ["Little Arc"] + dockOrder)
        XCTAssertEqual(Set(dockOrder), ["Home", "Work", "Side"], "every Space of every Profile")
    }

    /// [06 §8] Filter: chips filter the archive. No chip: everything; OR within a group, AND
    /// across groups (inferred).
    func testArchiveChipsFilterTheList() {
        let library = model.library
        model.openLibrary(.archivedTabs)
        library.openFilterPanel()
        XCTAssertEqual(archiveTitles, ["closedHome", "autoWork", "littleArc", "clearedHome", "favorite"])

        library.toggleFilter(.autoClosed)
        XCTAssertEqual(archiveTitles, ["autoWork", "littleArc"])
        library.toggleFilter(.autoClosed)
        library.toggleFilter(.manuallyClosed)
        XCTAssertEqual(archiveTitles, ["closedHome", "clearedHome", "favorite"], "⌘W, Clear and the rest are manual")
        library.toggleFilter(.manuallyClosed)

        library.toggleFilter(.littleArc)
        XCTAssertEqual(archiveTitles, ["littleArc"], "a Little Arc page is not its restore Space")
        library.toggleFilter(.space(fixture.home))
        XCTAssertEqual(archiveTitles, ["littleArc", "closedHome", "clearedHome"], "OR within a group")
        library.toggleFilter(.manuallyClosed)
        XCTAssertEqual(archiveTitles, ["closedHome", "clearedHome"], "AND across groups")

        // The hidden search text does not apply while the panel is open; it does again after Done.
        library.searchText[.archivedTabs] = "zzz"
        XCTAssertEqual(archiveTitles, ["closedHome", "clearedHome"])
        library.closeFilterPanel()
        XCTAssertEqual(archiveTitles, [])
    }

    /// Traits: auto-archive is Auto-Closed (sidebar and Little Arc), every other reason Manually
    /// Closed; a favorite has no Space. inferred mapping of `06 §8` Filter.
    func testArchiveTraits() throws {
        let ws = model.workspace
        XCTAssertEqual(LibraryFilter.traits(of: try XCTUnwrap(ws.archive[autoWork])), [.autoClosed, .space(fixture.work)])
        XCTAssertEqual(LibraryFilter.traits(of: try XCTUnwrap(ws.archive[littleArc])), [.autoClosed, .littleArc])
        XCTAssertEqual(LibraryFilter.traits(of: try XCTUnwrap(ws.archive[favorite])), [.manuallyClosed])
        XCTAssertTrue(LibraryFilterSelection().allows([]))
        XCTAssertFalse(LibraryFilterSelection([.littleArc]).allows([.manuallyClosed]))
    }

    // MARK: Downloads [06 §8] Filter

    /// [06 §8] Filter, observed: Downloads has one group, "Profiles", one chip per Profile. Chips
    /// list the selected profiles' downloads; no chip is the current profile (as before B94).
    func testDownloadsFilterByProfile() async throws {
        let downloads = try XCTUnwrap(engine.downloads as? FakeDownloads)
        let library = model.library
        let current = try XCTUnwrap(model.sidebar.currentProfileID)
        XCTAssertEqual(current, fixture.profile)
        model.openLibrary(.downloads)
        library.openFilterPanel()
        XCTAssertEqual(library.filterGroups.map(\.title), ["Profiles"])
        XCTAssertEqual(library.filterGroups[0].chips.map(\.title), ["Default", "Work Profile"])

        let mine = DownloadItem(id: "a", profileID: current, sourceURL: try XCTUnwrap(URL(string: "https://a.example/a.pdf")),
                                suggestedFilename: "a.pdf", startDate: Date(timeIntervalSince1970: 10))
        let theirs = DownloadItem(id: "b", profileID: second, sourceURL: try XCTUnwrap(URL(string: "https://b.example/b.pdf")),
                                  suggestedFilename: "b.pdf", startDate: Date(timeIntervalSince1970: 20))
        downloads.simulateDownload(mine)
        downloads.simulateDownload(theirs)
        try await waitUntil { library.visibleDownloads.map(\.id) == ["a"] }

        library.toggleFilter(.profile(second))
        try await waitUntil { library.visibleDownloads.map(\.id) == ["b"] }
        library.toggleFilter(.profile(current))
        try await waitUntil { library.visibleDownloads.map(\.id) == ["b", "a"] }

        library.closeFilterPanel()
        try await waitUntil { library.visibleDownloads.map(\.id) == ["a"] }
    }
}
