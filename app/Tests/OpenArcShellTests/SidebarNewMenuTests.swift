import XCTest
import CoreGraphics
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Plan B75. Acceptance: docs/arc-spec/06-flows.md §23 (observed: the dock "+" menu, a floating
/// 222 × 308 panel above the button; New Space · New Folder ‖ New Easel · New Boost ‖ New Split ·
/// New Tab with icons and gray key hints; no New Note), §20.2 (observed: an incognito "+" opens
/// the command bar), §1 (observed: a "Create Space" placeholder in the dock while creating; a faint
/// illustration in the new empty Space that goes away), 04-visual-metrics.md (222 × 308).
@MainActor
final class SidebarNewMenuTests: XCTestCase {
    private var fixture = SidebarFixture()
    private var counter = 9000

    private func makeModel() -> ShellModel {
        let model = ShellModel(
            dependencies: .fake(),
            workspace: fixture.ws,
            now: { [fixture] in fixture.now },
            makeID: { [unowned self] in
                self.counter += 1
                return SidebarFixture.id(self.counter)
            }
        )
        model.selectSpace(fixture.home)
        return model
    }

    // MARK: Menu items [06 §23]

    /// [06 §23] observed: six rows in three groups, in this order; no New Note.
    func testItemsAndGroupsInObservedOrder() {
        let groups = SidebarNewMenuItem.groups.map { $0.map(\.title) }
        XCTAssertEqual(groups, [["New Space", "New Folder"], ["New Easel", "New Boost"], ["New Split", "New Tab"]])
        XCTAssertEqual(SidebarNewMenuItem.groups.flatMap { $0 }, SidebarNewMenuItem.allCases)
        XCTAssertFalse(SidebarNewMenuItem.allCases.map(\.title).contains("New Note"))
    }

    /// [06 §23] observed key hints (⌃⇧E, ⌃⇧=, ⌘T), the same as `02`; the other rows have none.
    /// Every row has an icon.
    func testKeyHintsAndIcons() {
        XCTAssertEqual(SidebarNewMenuItem.allCases.map(\.keyHint), [nil, nil, "⌃⇧E", nil, "⌃⇧=", "⌘T"])
        XCTAssertTrue(SidebarNewMenuItem.allCases.allSatisfy { !$0.symbol.isEmpty })
        XCTAssertEqual(Set(SidebarNewMenuItem.allCases.map(\.accessibilityIdentifier)).count, 6)
    }

    /// [06 §23] / [04] observed: the panel is 222 × 308 with its lower-left corner just above the
    /// "+" button (x 236 in a 1920 × 985 window, [07 §4]).
    func testMenuFrameSitsAbovePlusButton() {
        let window = CGRect(x: 0, y: 0, width: 1920, height: 985)
        let plus = SidebarLayout(windowSize: window.size).dockPlusFrame
        let frame = SidebarNewMenuLayout.menuFrame(plusButton: plus, container: window)
        XCTAssertEqual(frame.size, CGSize(width: 222, height: 308))
        XCTAssertEqual(frame.minX, plus.minX)
        XCTAssertEqual(frame.maxY, plus.minY)
        // The rows, insets and separators fill the observed height.
        let L = SidebarNewMenuLayout.self
        XCTAssertEqual(6 * L.rowHeight + 2 * L.verticalInset + 2 * L.separatorHeight, 308, accuracy: 0.001)
        XCTAssertGreaterThan(L.rowHeight, 30)
    }

    /// In a short window the panel stays inside the window (inferred clamp).
    func testMenuFrameClampsInsideShortWindow() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 300)
        let plus = SidebarLayout(windowSize: window.size).dockPlusFrame
        let frame = SidebarNewMenuLayout.menuFrame(plusButton: plus, container: window)
        XCTAssertGreaterThanOrEqual(frame.minY, 0)
    }

    // MARK: "+" click [06 §23, §20.2]

    /// [06 §23] observed: in a normal window "+" opens the New menu, not the creation view.
    func testPlusOpensNewMenuInNormalWindow() {
        let model = makeModel()
        XCTAssertEqual(model.sidebar.dockPlusClicked(), .toggleNewMenu)
        XCTAssertFalse(model.spaceFlow.isCreating)
        XCTAssertFalse(model.isCommandBarPresented)
        model.stop()
    }

    /// [06 §20.2] observed: an incognito window's "+" opens the command bar for a new tab.
    func testIncognitoPlusStillOpensCommandBar() {
        let controller = WorkspaceController(dependencies: .fake(), workspace: fixture.ws, now: { [fixture] in fixture.now },
                                             notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker())
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        incognito.dismissCommandBar()
        XCTAssertEqual(incognito.sidebar.dockPlusClicked(), .openedCommandBar)
        XCTAssertTrue(incognito.isCommandBarPresented)
        XCTAssertEqual(incognito.commandBar.mode, .newTab)
        XCTAssertFalse(incognito.canPerformNewMenuItem(.newSpace))
        incognito.stop()
        controller.stop()
    }

    // MARK: Row actions [06 §23]

    /// [06 §23] observed rows; each does what its menu-bar command does.
    func testRowsRunTheirCommands() async throws {
        let model = makeModel()
        model.performNewMenuItem(.newSpace)
        XCTAssertTrue(model.spaceFlow.isCreating)
        model.spaceFlow.cancelCreate()

        model.performNewMenuItem(.newFolder)
        XCTAssertTrue(model.sidebar.isNewFolderSheetPresented)
        model.sidebar.isNewFolderSheetPresented = false

        let easelsBefore = model.workspace.easels.count
        model.performNewMenuItem(.newEasel)
        XCTAssertEqual(model.workspace.easels.count, easelsBefore + 1)

        let before = model.workspace
        model.performNewMenuItem(.newBoost)
        XCTAssertEqual(model.workspace, before, "New Boost is inert")
        XCTAssertFalse(model.isCommandBarPresented)

        model.performNewMenuItem(.newTab)
        XCTAssertTrue(model.isCommandBarPresented)
        XCTAssertEqual(model.commandBar.mode, .newTab)
        model.dismissCommandBar()

        try await model.activate(tabID: fixture.today1)
        model.performNewMenuItem(.newSplit)
        await model.sidebar.settleEngineWork()
        XCTAssertNotNil(model.activeSplitLayout)
        model.stop()
    }

    // MARK: Create Space placeholder [06 §1]

    /// [06 §1] observed: while creating, the dock shows a "Create Space" placeholder; it sits after
    /// the current Space, where the new Space goes (inferred from the observed insert position).
    func testCreateSpacePlaceholderAfterCurrentSpace() {
        let model = makeModel()
        let spaces = model.sidebar.dockSpaces
        func names(_ entries: [SidebarDockEntry]) -> [String] {
            entries.map { if case .space(let s) = $0 { s.name } else { "Create Space" } }
        }
        XCTAssertEqual(names(SidebarDockEntry.entries(spaces: spaces, selectedSpaceID: fixture.home, isCreatingSpace: false)),
                       ["Home", "Work"])
        XCTAssertEqual(names(SidebarDockEntry.entries(spaces: spaces, selectedSpaceID: fixture.home, isCreatingSpace: true)),
                       ["Home", "Create Space", "Work"])
        XCTAssertEqual(names(SidebarDockEntry.entries(spaces: spaces, selectedSpaceID: fixture.work, isCreatingSpace: true)),
                       ["Home", "Work", "Create Space"])
        XCTAssertEqual(names(SidebarDockEntry.entries(spaces: spaces, selectedSpaceID: nil, isCreatingSpace: true)),
                       ["Home", "Work", "Create Space"])
        model.stop()
    }

    /// [06 §1] observed: the placeholder's slot is where "Create Space" puts the new Space.
    func testPlaceholderSlotMatchesCreatedSpacePosition() throws {
        let model = makeModel()
        model.spaceFlow.beginCreate()
        let entries = SidebarDockEntry.entries(spaces: model.sidebar.dockSpaces, selectedSpaceID: model.selectedSpaceID,
                                               isCreatingSpace: model.spaceFlow.isCreating)
        let slot = try XCTUnwrap(entries.firstIndex(of: .createSpacePlaceholder))
        model.spaceFlow.draftName = "Reading"
        let id = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertEqual(model.sidebar.dockSpaces.firstIndex { $0.id == id }, slot)
        model.stop()
    }

    // MARK: New empty Space illustration [06 §1]

    /// [06 §1] observed: after "Create Space" the new, empty Space shows a faint illustration;
    /// Cancel (selection unchanged) and a non-empty Space show none (inferred).
    func testIllustrationOnlyForCreatedEmptySpace() throws {
        let model = makeModel()
        let start = model.selectedSpaceID
        model.spaceFlow.beginCreate()
        model.spaceFlow.draftName = "Fresh"
        let id = try XCTUnwrap(model.spaceFlow.create())
        XCTAssertTrue(model.sidebar.snapshot.isEmptySpace)
        XCTAssertEqual(NewSpaceIllustrationTrigger.spaceToGreet(startSpaceID: start, selectedSpaceID: model.selectedSpaceID,
                                                                isSelectedSpaceEmpty: model.sidebar.snapshot.isEmptySpace), id)
        XCTAssertNil(NewSpaceIllustrationTrigger.spaceToGreet(startSpaceID: start, selectedSpaceID: start, isSelectedSpaceEmpty: true))
        XCTAssertNil(NewSpaceIllustrationTrigger.spaceToGreet(startSpaceID: start, selectedSpaceID: id, isSelectedSpaceEmpty: false))
        // Faint, and it goes away.
        XCTAssertLessThan(NewSpaceIllustrationTrigger.opacity, 0.5)
        XCTAssertGreaterThan(NewSpaceIllustrationTrigger.fadeDuration, 0)
        model.stop()
    }
}
