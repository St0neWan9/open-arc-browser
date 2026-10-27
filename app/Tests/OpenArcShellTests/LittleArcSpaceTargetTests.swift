import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// B60: the expanded Little Arc top bar. [06 §21.7] observed (E19): the window grows to 1185×832
/// with a 47 pt top bar (Profile capsule for a non-Default profile, centered domain, copy link icon,
/// "Open in <Space> ⌘O" + a dropdown of Spaces with "Search Spaces…", the default target first);
/// choosing a Space or ⌘O closes Little Arc, the page becomes the selected top Today tab of that
/// Space and the main window switches to it. [06 §25.1] observed: "Open in Work ⌘O" in the
/// Settings illustration. [02] observed: ⌘O.
@MainActor
final class LittleArcSpaceTargetTests: XCTestCase {
    private let blue = SidebarFixture.id(90)
    private let otherProfile = SidebarFixture.id(91)
    private let research = SidebarFixture.id(92)

    /// The fixture plus a themed Space ("Research") in a second profile.
    private func fixture() throws -> SidebarFixture {
        var f = SidebarFixture()
        f.ws = TreeOps.createTheme(f.ws, id: blue, style: ThemeStyle(colors: [RGBAColor(hex: 0x3355FF)]), now: f.now)
        f.ws = TreeOps.createProfile(f.ws, id: otherProfile, name: "Side", now: f.now.addingTimeInterval(1))
        f.ws = try TreeOps.createSpace(f.ws, id: research, profileID: otherProfile, name: "Research", themeID: blue, now: f.now)
        return f
    }

    private func makeController(_ f: SidebarFixture) -> WorkspaceController {
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now.addingTimeInterval(10) }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID?) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func expandedLittleArc(on shell: ShellModel, url: String = "https://example.edu/page") async throws -> LittleArcModel {
        let model = LittleArcModel(shell: shell)
        model.open(try XCTUnwrap(URL(string: url)))
        await model.settleEngineWork()
        XCTAssertEqual(model.phase, .expanded)
        return model
    }

    // MARK: Layout values

    /// [06 §21.7] observed: 1185×832 once a page is open, 47 pt top bar.
    func testExpandedSizeAndTopBarHeightMatchE19() {
        XCTAssertEqual(LittleArcTokens.expandedSize, CGSize(width: 1185, height: 832))
        XCTAssertEqual(LittleArcTokens.topBarHeight, 47)
        XCTAssertEqual(LittleArcSpaceTargetTokens.rowHeight, 39)
        XCTAssertEqual(LittleArcSpaceTargetTokens.searchPlaceholder, "Search Spaces…")
        XCTAssertEqual(LittleArcSpaceTargetTokens.keyCap, "⌘O")
    }

    // MARK: Button title and Profile capsule

    /// [06 §21.7], [06 §25.1] observed: the button reads "Open in <Space>" for the main window's
    /// current Space (default target, inferred).
    func testButtonNamesMainWindowsCurrentSpace() async throws {
        let f = try fixture()
        let controller = makeController(f)
        let main = window(controller, space: f.work)
        let model = try await expandedLittleArc(on: main)
        XCTAssertEqual(model.targetSpaceID, f.work)
        XCTAssertEqual(model.adoptButtonTitle, "Open in Work")
        main.selectSpace(f.home)
        XCTAssertEqual(model.adoptButtonTitle, "Open in Home", "the target follows the main window")
    }

    /// [06 §21.7] observed: the Profile capsule names a non-Default profile; Default is unknown
    /// (hidden here, inferred).
    func testProfileCapsuleShowsOnlyNonDefaultProfile() async throws {
        let f = try fixture()
        let controller = makeController(f)
        let main = window(controller, space: f.home)
        let onDefault = try await expandedLittleArc(on: main)
        XCTAssertNil(onDefault.profileCapsuleName)
        main.selectSpace(research)
        let onSide = try await expandedLittleArc(on: main)
        XCTAssertEqual(onSide.profileCapsuleName, "Side")
        XCTAssertEqual(onSide.adoptButtonTitle, "Open in Research")
    }

    /// The domain is centered in the bar: the host only, like the sidebar URL box. [06 §21.7] observed.
    func testTopBarShowsDomain() async throws {
        let f = try fixture()
        let model = try await expandedLittleArc(on: window(makeController(f), space: f.home), url: "https://docs.example.edu/a/b?q=1")
        XCTAssertEqual(model.addressContent, .domain("docs.example.edu", isSecure: true))
    }

    /// The copy link icon copies the full URL. [06 §21.7] observed (icon), [06 §17.3] observed (action).
    func testCopyLinkWritesFullURL() async throws {
        let f = try fixture()
        let main = window(makeController(f), space: f.home)
        let pasteboard = RecordingPasteboardWriter()
        main.siteControls.pasteboard = pasteboard
        let model = try await expandedLittleArc(on: main, url: "https://example.edu/x?y=1")
        XCTAssertTrue(model.copyLink())
        XCTAssertEqual(pasteboard.written, [URL(string: "https://example.edu/x?y=1")!])
    }

    // MARK: Dropdown

    /// [06 §21.7] observed: one row per Space, the default target first (highlighted), then the
    /// others in dock order; Spaces of every profile are listed (inferred, as in the dock).
    func testDropdownListsDefaultTargetFirst() async throws {
        let f = try fixture()
        let main = window(makeController(f), space: f.work)
        let model = try await expandedLittleArc(on: main)
        model.toggleSpacePicker()
        XCTAssertTrue(model.spacePicker.isOpen)
        let options = model.spaceOptions
        XCTAssertEqual(options.map(\.name), ["Work", "Home", "Research"])
        XCTAssertEqual(options.first?.isDefault, true)
        XCTAssertEqual(model.spacePicker.highlightedIndex, 0)
        XCTAssertEqual(model.highlightedSpaceID, f.work)
        // Theme-colored square: the theme's first color, the default base without a theme.
        XCTAssertEqual(options.last?.swatch, RGBAColor(hex: 0x3355FF))
        XCTAssertEqual(options.first?.swatch, ThemeDerivation.defaultBaseColor)
        model.toggleSpacePicker()
        XCTAssertFalse(model.spacePicker.isOpen)
    }

    /// [06 §21.7] observed: "Search Spaces…" filters the rows (case-insensitive substring, inferred).
    func testSearchFiltersSpaces() async throws {
        let f = try fixture()
        let model = try await expandedLittleArc(on: window(makeController(f), space: f.home))
        model.toggleSpacePicker()
        model.moveSpaceHighlight(by: 1)
        model.setSpaceQuery("rES")
        XCTAssertEqual(model.spaceOptions.map(\.name), ["Research"])
        XCTAssertEqual(model.spacePicker.highlightedIndex, 0, "typing highlights the first match")
        model.setSpaceQuery("nothing")
        XCTAssertTrue(model.spaceOptions.isEmpty)
        XCTAssertNil(model.chooseHighlightedSpace(), "Return with no match does nothing")
        XCTAssertEqual(model.phase, .expanded)
    }

    /// The dropdown only opens while a page is shown.
    func testDropdownNeedsExpandedWindow() throws {
        let f = try fixture()
        let model = LittleArcModel(shell: window(makeController(f), space: f.home))
        model.toggleSpacePicker()
        XCTAssertFalse(model.spacePicker.isOpen)
    }

    // MARK: Moving the page

    /// [06 §21.7] observed: choosing a Space closes Little Arc; the page becomes the selected top
    /// Today tab of that Space and the main window switches to it.
    func testChoosingSpaceMovesPageIntoThatSpace() async throws {
        let f = try fixture()
        let controller = makeController(f)
        let main = window(controller, space: f.home)
        var focused = 0
        main.focusWindow = { focused += 1 }
        let model = try await expandedLittleArc(on: main)
        model.toggleSpacePicker()
        model.setSpaceQuery("work")
        let id = try XCTUnwrap(model.chooseHighlightedSpace())
        XCTAssertEqual(model.phase, .closed)
        XCTAssertEqual(main.selectedSpaceID, f.work, "the main window switches to the chosen Space")
        XCTAssertEqual(main.workspace.today(spaceID: f.work).first?.id, id, "top of that Space's Today")
        XCTAssertEqual(main.workspace.today(spaceID: f.work).first?.url, URL(string: "https://example.edu/page"))
        XCTAssertEqual(main.selectedTabID, id)
        XCTAssertFalse(main.workspace.today(spaceID: f.home).contains { $0.id == id })
        XCTAssertEqual(focused, 1, "the main window comes to the front")
        XCTAssertFalse(model.spacePicker.isOpen)
    }

    /// ⌘O (the button) opens in the target Space, here a Space of another profile. [06 §21.7],
    /// [02] observed.
    func testCommandOOpensInTargetSpace() async throws {
        let f = try fixture()
        let controller = makeController(f)
        let main = window(controller, space: research)
        let model = try await expandedLittleArc(on: main)
        let id = try XCTUnwrap(model.adopt())
        XCTAssertEqual(main.selectedSpaceID, research)
        XCTAssertEqual(main.workspace.today(spaceID: research).first?.id, id)
        XCTAssertEqual(main.selectedTabID, id)
        XCTAssertEqual(model.phase, .closed)
    }

    /// Choosing a row directly (click) works without the search field.
    func testClickingRowMovesPage() async throws {
        let f = try fixture()
        let main = window(makeController(f), space: f.home)
        let model = try await expandedLittleArc(on: main)
        model.toggleSpacePicker()
        let id = try XCTUnwrap(model.chooseSpace(research))
        XCTAssertEqual(main.selectedSpaceID, research)
        XCTAssertEqual(main.workspace.tabs[id]?.location, .today(spaceID: research))
    }

    /// With no browser window open, the requested window opens on the chosen Space.
    func testChoosingSpaceWithNoWindowOpensOneOnThatSpace() async throws {
        let f = try fixture()
        let controller = makeController(f)
        let closed = window(controller, space: f.home)
        closed.windowDidClose()
        var requests: [BrowserWindowRequest] = []
        controller.openBrowserWindow = { requests.append($0) }
        let model = try await expandedLittleArc(on: controller.littleArcHost())
        let id = try XCTUnwrap(model.chooseSpace(f.work))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.spaceID, f.work)
        XCTAssertEqual(requests.first?.tabID, id)
        XCTAssertEqual(controller.workspace.tabs[id]?.location, .today(spaceID: f.work))
    }
}
