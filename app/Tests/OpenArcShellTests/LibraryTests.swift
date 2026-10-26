import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// The Library mode of the main window. Acceptance: `06 §8` (Library), `02` (⇧⌘L View Library),
/// `01 §Window` / `01 §Archive` (menu entries).
@MainActor
final class LibraryTests: XCTestCase {
    private var fixture = SidebarFixture()
    private var counter = 5000
    /// Injected clock. It equals the fixture time, so launch auto-archive cannot expire anything.
    private lazy var clock = fixture.now
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1 // Sunday
        return c
    }()

    private func makeModel() -> ShellModel {
        let model = ShellModel(
            dependencies: .fake(),
            workspace: fixture.ws,
            now: { [unowned self] in self.clock },
            makeID: { [unowned self] in
                self.counter += 1
                return SidebarFixture.id(self.counter)
            }
        )
        model.library.calendar = utc
        return model
    }

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    // MARK: Entering and exiting [06 §8]

    /// [06 §8] observed: Library is a mode of the window; "←" goes back to the browser view.
    func testEnterAndExitLibrary() {
        let model = makeModel()
        XCTAssertFalse(model.isLibraryActive)
        model.openLibrary(.easels)
        XCTAssertTrue(model.isLibraryActive)
        XCTAssertEqual(model.library.section, .easels)
        model.library.open(.boosts) // rail click
        XCTAssertEqual(model.library.section, .boosts)
        model.exitLibrary()
        XCTAssertFalse(model.isLibraryActive)
        XCTAssertNil(model.library.section)
        // Open Library (no section) comes back to the last section shown. inferred.
        model.openLibrary()
        XCTAssertEqual(model.library.section, .boosts)
        model.stop()
    }

    /// First Open Library starts on the first rail item; the rail order is the observed one. [06 §8]
    func testRailOrderAndDefaultSection() {
        XCTAssertEqual(LibrarySection.allCases.map(\.title), ["Media", "Downloads", "Easels", "Spaces", "Boosts", "Archived Tabs"])
        let model = makeModel()
        model.openLibrary()
        XCTAssertEqual(model.library.section, .media)
        model.stop()
    }

    /// Opening the Library closes the floating command bar. inferred.
    func testOpeningLibraryDismissesCommandBar() {
        let model = makeModel()
        model.presentCommandBar(.newTab)
        model.openLibrary(.downloads)
        XCTAssertFalse(model.isCommandBarPresented)
        model.stop()
    }

    // MARK: Command routing [06 §8], [01 §Window], [01 §Archive], [05 §context menus]

    func testCommandsRouteToTheirSections() {
        let cases: [(CommandBarCommand, LibrarySection)] = [
            (.openLibrary, .media), (.viewArchive, .archivedTabs), (.viewDownloads, .downloads),
        ]
        for (command, section) in cases {
            let model = makeModel()
            model.perform(.runCommand(command))
            XCTAssertEqual(model.library.section, section, "\(command)")
            XCTAssertNil(model.lastUnhandledCommand)
            model.stop()
        }
    }

    /// [06 §8] observed: the Spaces board is the Manage Spaces… surface.
    func testManageSpacesRequestOpensSpacesSection() {
        let model = makeModel()
        model.sidebar.requestFromMenu(.manageSpaces)
        XCTAssertEqual(model.library.section, .spaces)
        model.stop()
    }

    // MARK: Archived Tabs [06 §8]

    private func archive(_ id: UUID, title: String, url: String, at date: Date, in ws: inout WorkspaceState) {
        ws.archive[id] = ArchiveItem(id: id, url: URL(string: url), title: title, faviconURL: nil,
                                     spaceID: fixture.home, folderPath: [], reason: .closed, archivedAt: date)
    }

    /// Date groups with an injected clock. Today / Yesterday / Earlier This Week observed;
    /// Older and the boundaries inferred. Newest first inside a group; empty groups left out.
    func testArchiveGroupingByDate() {
        var ws = fixture.ws
        let now = at("2026-10-21T15:00:00Z") // Wednesday
        archive(SidebarFixture.id(901), title: "Morning", url: "https://a.example/1", at: at("2026-10-21T08:00:00Z"), in: &ws)
        archive(SidebarFixture.id(902), title: "Midnight", url: "https://a.example/2", at: at("2026-10-21T00:00:00Z"), in: &ws)
        archive(SidebarFixture.id(903), title: "Yesterday late", url: "https://b.example", at: at("2026-10-20T23:59:00Z"), in: &ws)
        archive(SidebarFixture.id(904), title: "Monday", url: "https://c.example", at: at("2026-10-19T10:00:00Z"), in: &ws)
        archive(SidebarFixture.id(905), title: "Sunday", url: "https://d.example", at: at("2026-10-18T00:30:00Z"), in: &ws)
        archive(SidebarFixture.id(906), title: "Saturday", url: "https://e.example", at: at("2026-10-17T12:00:00Z"), in: &ws)
        var gone = ArchiveItem(id: SidebarFixture.id(907), url: nil, title: "Restored", faviconURL: nil, spaceID: nil,
                               folderPath: [], reason: .closed, archivedAt: at("2026-10-21T09:00:00Z"))
        gone.meta.markDeleted(at: now)
        ws.archive[gone.id] = gone

        let groups = LibraryArchive.groups(in: ws, query: "", now: now, calendar: utc)
        XCTAssertEqual(groups.map(\.group.title), ["Today", "Yesterday", "Earlier This Week", "Older"])
        XCTAssertEqual(groups.map { $0.items.map(\.title) }, [
            ["Morning", "Midnight"], ["Yesterday late"], ["Monday", "Sunday"], ["Saturday"],
        ])

        // On Sunday the week has just begun: Friday is Older, not Earlier This Week.
        let sunday = at("2026-10-18T12:00:00Z")
        XCTAssertEqual(LibraryDateGroup.group(of: at("2026-10-17T12:00:00Z"), now: sunday, calendar: utc), .yesterday)
        XCTAssertEqual(LibraryDateGroup.group(of: at("2026-10-16T12:00:00Z"), now: sunday, calendar: utc), .older)
        // A date after `now` (clock skew) counts as Today.
        XCTAssertEqual(LibraryDateGroup.group(of: at("2026-10-22T12:00:00Z"), now: now, calendar: utc), .today)
    }

    /// [06 §8] observed "Search Archive…": filters by title or URL, case-insensitively. inferred matching.
    func testArchiveSearchFilters() throws {
        var ws = fixture.ws
        archive(SidebarFixture.id(911), title: "Swift Forums", url: "https://forums.swift.org/t/1", at: fixture.now, in: &ws)
        archive(SidebarFixture.id(912), title: "Recipes", url: "https://cooking.example/pasta", at: fixture.now, in: &ws)
        fixture.ws = ws
        let model = makeModel()
        model.openLibrary(.archivedTabs)
        XCTAssertEqual(Set(model.library.archiveGroups.flatMap(\.items).map(\.title)), ["Swift Forums", "Recipes"])
        model.library.searchText[.archivedTabs] = "SWIFT"
        XCTAssertEqual(model.library.archiveGroups.flatMap(\.items).map(\.title), ["Swift Forums"])
        model.library.searchText[.archivedTabs] = "pasta"
        XCTAssertEqual(model.library.archiveGroups.flatMap(\.items).map(\.title), ["Recipes"])
        model.library.searchText[.archivedTabs] = "nothing-matches"
        XCTAssertTrue(model.library.archiveGroups.isEmpty)
        // The search of one section does not filter another.
        XCTAssertEqual(model.library.query(for: .downloads), "")
        XCTAssertEqual(LibraryArchive.displayURL(URL(string: "https://forums.swift.org/t/1")), "forums.swift.org/t/1")
        model.stop()
    }

    /// Clicking an archived row restores it through `TreeOps.restoreFromArchive` and leaves the
    /// Library on the restored tab. [06 §8] list observed; click behavior inferred.
    func testRestoreFromLibraryExitsToTheTab() throws {
        let model = makeModel()
        model.selectSpace(fixture.work)
        model.sidebar.closeTab(fixture.today2) // archives a Home tab
        let item = try XCTUnwrap(model.workspace.archiveNewestFirst.first { $0.title == "today2" })
        model.openLibrary(.archivedTabs)
        let newID = try XCTUnwrap(model.library.restore(item.id))
        XCTAssertFalse(model.isLibraryActive)
        XCTAssertEqual(model.selectedTabID, newID)
        XCTAssertEqual(model.selectedSpaceID, fixture.home)
        XCTAssertEqual(model.workspace.tabs[newID]?.url, URL(string: "https://today2.example.com"))
        XCTAssertEqual(model.workspace.today(spaceID: fixture.home).first?.id, newID)
        XCTAssertTrue(model.workspace.archive[item.id]?.meta.isTombstone == true)
        XCTAssertFalse(model.library.archiveGroups.flatMap(\.items).contains { $0.id == item.id })
        model.stop()
    }

    // MARK: Spaces board [06 §8]

    /// One column per live space in dock order, with the sidebar's rows.
    func testSpacesBoardColumnsInDockOrder() throws {
        let model = makeModel()
        let columns = model.library.boardColumns
        XCTAssertEqual(columns.map(\.space.name), ["Home", "Work"])
        let home = try XCTUnwrap(columns.first)
        XCTAssertEqual(home.pinned.map(\.id), model.sidebar.snapshot.pinned.map(\.id))
        XCTAssertEqual(home.today.map(\.id), [fixture.today3, fixture.today2, fixture.today1])
        XCTAssertEqual(columns[1].today.map(\.id), [fixture.workTab])
        model.stop()
    }

    /// The drag handle reorders spaces (`TreeOps.moveSpace`); the dock follows.
    func testDragHandleReordersSpaces() {
        let model = makeModel()
        model.openLibrary(.spaces)
        model.library.draggingSpaceID = fixture.work
        // Left half of Home's column → before Home.
        XCTAssertTrue(model.library.dropDraggedSpace(on: fixture.home, locationX: 10, columnWidth: 266))
        XCTAssertEqual(model.library.boardColumns.map(\.space.name), ["Work", "Home"])
        XCTAssertEqual(model.sidebar.dockSpaces.map(\.name), ["Work", "Home"])
        XCTAssertNil(model.library.draggingSpaceID)
        XCTAssertEqual(LibraryBoard.dropPosition(dragged: fixture.work, target: fixture.home, locationX: 200, columnWidth: 266), .after(fixture.home))
        XCTAssertNil(LibraryBoard.dropPosition(dragged: fixture.home, target: fixture.home, locationX: 10, columnWidth: 266))
        // Dropping without a drag does nothing.
        XCTAssertFalse(model.library.dropDraggedSpace(on: fixture.home, locationX: 10, columnWidth: 266))
        model.stop()
    }

    /// Brush and "…" menu use the existing flows (theme editor, rename, delete).
    func testBoardColumnActionsUseExistingFlows() {
        let model = makeModel()
        model.openLibrary(.spaces)
        model.spaceFlow.beginEditTheme(spaceID: fixture.work)
        XCTAssertEqual(model.spaceFlow.themeEditorSpaceID, fixture.work)
        model.sidebar.requestDeleteSpace(fixture.work)
        model.sidebar.confirmDeleteSpace()
        XCTAssertEqual(model.library.boardColumns.map(\.space.name), ["Home"])
        model.stop()
    }

    // MARK: Empty states [06 §8]

    func testEmptyStateTexts() {
        XCTAssertEqual(LibrarySection.downloads.emptyState?.title, "Nothing here yet!")
        XCTAssertEqual(LibrarySection.downloads.emptyState?.detail, "Come back after you’ve found some cool stuff to save.")
        XCTAssertEqual(LibrarySection.easels.emptyState?.title, "Out of ideas!")
        XCTAssertEqual(LibrarySection.easels.emptyState?.detail, "Click the + sign in the Sidebar to create a new Easel.")
        XCTAssertNil(LibrarySection.easels.emptyState?.symbolName)
        XCTAssertEqual(LibrarySection.boosts.emptyState?.title, "Nothing Boosted Yet!")
        XCTAssertEqual(LibrarySection.boosts.emptyState?.detail,
                       "Click [brush] in URL bar to make your own, or grab one from the Boost Gallery.")
        XCTAssertEqual(LibraryTexts.mediaIntroTitle, "Your Media in the Library")
        XCTAssertEqual(LibraryTexts.mediaIntroDetail,
                       "Quickly grab screenshots, images, and videos from your computer by showing them in the Open Arc Library!")
        XCTAssertEqual(LibraryTexts.mediaIntroButton, "Show Media")
        XCTAssertEqual(LibraryTexts.mediaPrivacyNote, "Media never leaves your computer and is not viewable by anyone but you.")
        XCTAssertEqual(LibrarySection.allCases.compactMap(\.searchPlaceholder),
                       ["Search Media…", "Search Downloads…", "Search Easels…", "Search Boosts…", "Search Archive…"])
        XCTAssertEqual(LibrarySection.allCases.filter(\.hasFilterButton), [.downloads, .archivedTabs])
    }

    /// ✕ on the Media intro card hides it. [06 §8] observed (✕ at the top right).
    func testMediaIntroDismisses() {
        let model = makeModel()
        XCTAssertTrue(model.library.isMediaIntroVisible)
        model.library.dismissMediaIntro()
        XCTAssertFalse(model.library.isMediaIntroVisible)
        model.stop()
    }

    // MARK: Layout and rendering [06 §8]

    /// [07 §6] observed: the left part is 417 wide (rail ≈ 113 = 8 + 97 + 8, list ≈ 304, 07 §10);
    /// the web panel stays on the right with the window insets.
    func testLayoutAtReferenceSize() {
        let layout = LibraryLayout(windowSize: CGSize(width: 1920, height: 985))
        XCTAssertEqual(layout.railFrame, CGRect(x: 0, y: 0, width: 113, height: 985))
        XCTAssertEqual(layout.listFrame, CGRect(x: 113, y: 0, width: 304, height: 985))
        XCTAssertEqual(layout.webPanelFrame, CGRect(x: 417, y: 10, width: 1493, height: 965))
        XCTAssertEqual(layout.boardFrame.minX, 113)
    }

    /// Every section builds and lays out inside the full window.
    func testEverySectionRenders() {
        let model = makeModel()
        let host = NSHostingView(rootView: MainWindowView(model: model))
        host.frame = CGRect(x: 0, y: 0, width: 1920, height: 985)
        for section in LibrarySection.allCases {
            model.openLibrary(section)
            host.layoutSubtreeIfNeeded()
        }
        model.exitLibrary()
        host.layoutSubtreeIfNeeded()
        model.stop()
    }
}
