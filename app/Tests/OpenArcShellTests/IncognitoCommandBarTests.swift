import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B61: the incognito window's command bar, docs/arc-spec/06-flows.md §20.1 (observed: the
/// window opens with the command bar, whose empty list is the help rows only, no history and no
/// open tabs) and §20.2 (observed: the Spaces menu is disabled and the tab menu has no Pin, so
/// the bar offers no Space commands either). Also the "Air Traffic Control" help row.
@MainActor
final class IncognitoCommandBarTests: XCTestCase {
    private var controller: WorkspaceController!
    private var incognito: ShellModel!

    override func setUp() async throws {
        let f = SidebarFixture()
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: .inMemory())
        controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now.addingTimeInterval(10) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
    }

    override func tearDown() async throws {
        incognito.stop()
        controller.stop()
        incognito = nil
        controller = nil
    }

    private func commands(_ results: [CommandBarResult]) -> [CommandBarCommand] {
        results.compactMap { result in
            if case .runCommand(let command) = result.action { return command } else { return nil }
        }
    }

    /// Plan B133 (F5-12): the five help rows of [06 §20.1] observed, in order: Contact the Team ·
    /// The Browser Company (ours: the project page under our app's name) · Air Traffic Control ·
    /// Tips for Organizing · Help Center. Each opens our counterpart; the normal bar lists none of
    /// the three new rows (inferred).
    func testIncognitoHelpRowsSpec06Section20_1() async throws {
        await incognito.commandBar.waitForRefresh()
        XCTAssertEqual(incognito.commandBar.results.map(\.title), [
            "Contact the Team", AppIdentity.displayName, "Air Traffic Control", "Tips for Organizing", "Help Center",
        ])
        incognito.perform(.runCommand(.helpCenter))
        incognito.perform(.runCommand(.organizingTips))
        incognito.perform(.runCommand(.aboutProject))
        await incognito.sidebar.settleEngineWork()
        let opened = incognito.workspace.tabs.values.compactMap(\.url)
        for url in [OpenArcLinks.helpCenter, OpenArcLinks.organizingTips, OpenArcLinks.site] {
            XCTAssertTrue(opened.contains(url), "\(url)")
        }

        let normal = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer { normal.stop() }
        normal.presentCommandBar(.newTab)
        normal.commandBar.queryText = "help"
        await normal.commandBar.waitForRefresh()
        let listed = commands(normal.commandBar.results)
        XCTAssertTrue(listed.contains(.contactTheTeam))
        for row in [CommandBarCommand.aboutProject, .organizingTips, .helpCenter] {
            XCTAssertFalse(listed.contains(row), "\(row) stays in the incognito bar")
        }
    }

    /// [06 §20.1] observed: opening the incognito window shows the command bar right away.
    func testIncognitoWindowOpensWithCommandBar() {
        XCTAssertTrue(incognito.isCommandBarPresented)
        XCTAssertEqual(incognito.commandBar.mode, .newTab)
        XCTAssertNil(incognito.commandBarPaneTabID)
        // A normal window does not open with it (B14 behavior unchanged).
        let normal = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        XCTAssertFalse(normal.isCommandBarPresented)
        normal.stop()
    }

    /// [06 §20.1] observed: the empty list is the help rows, no open tabs, also once the window
    /// has tabs (no history, no "Switch to Tab").
    func testEmptyListShowsHelpRowsOnly() async {
        await incognito.commandBar.waitForRefresh()
        XCTAssertEqual(commands(incognito.commandBar.results), CommandBarCommand.helpCommands)
        XCTAssertEqual(incognito.commandBar.results.first?.title, "Contact the Team")

        incognito.dismissCommandBar()
        _ = incognito.sidebar.newTab(url: URL(string: "https://one.example"), title: "One")
        _ = incognito.sidebar.newTab(url: URL(string: "https://two.example"), title: "Two")
        await incognito.sidebar.settleEngineWork()
        incognito.presentCommandBar(.newTab)
        await incognito.commandBar.waitForRefresh()
        XCTAssertFalse(incognito.commandBar.results.contains { $0.kind.isTab }, "no open tabs")
        XCTAssertEqual(commands(incognito.commandBar.results), CommandBarCommand.helpCommands)
    }

    /// The normal window keeps its empty list: open tabs, then "Contact the Team" ([04 §command
    /// bar] observed); the incognito help rows do not leak into it.
    func testNormalWindowEmptyListUnchanged() async throws {
        let normal = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer { normal.stop() }
        normal.presentCommandBar(.newTab)
        await normal.commandBar.waitForRefresh()
        XCTAssertTrue(normal.commandBar.results.contains { $0.kind.isTab })
        XCTAssertEqual(normal.commandBar.results.last?.action, .runCommand(.contactTheTeam))
        XCTAssertFalse(commands(normal.commandBar.results).contains(.airTrafficControl))
    }

    /// [06 §20.2] observed (Spaces menu disabled, no Pin in the tab menu): the incognito bar finds
    /// no Space commands, no "Go to" / "Move Tab to" Space rows, no Pin or folder commands; a
    /// normal window finds them.
    func testIncognitoBarFiltersSpaceCommands() async throws {
        let spaceCommands: [CommandBarCommand] = [.newSpace, .editTheme, .renameSpace, .nextSpace, .previousSpace, .manageSpaces]
        _ = incognito.sidebar.newTab(url: URL(string: "https://one.example"), title: "One")
        await incognito.sidebar.settleEngineWork()
        for query in ["space", "new space", "theme", "rename", "manage", "pin", "folder", "home", "work"] {
            incognito.commandBar.queryText = query
            await incognito.commandBar.waitForRefresh()
            let listed = commands(incognito.commandBar.results)
            for command in spaceCommands + [.togglePin, .favoriteTab, .newFolder, .collapseAllFolders, .expandAllFolders] {
                XCTAssertFalse(listed.contains(command), "\(command) for “\(query)”")
            }
            XCTAssertFalse(incognito.commandBar.results.contains { $0.kind == .space || $0.kind == .moveTabToSpace },
                           "no Space rows for “\(query)”")
        }
        // Help and window commands stay searchable.
        incognito.commandBar.queryText = "air traffic"
        await incognito.commandBar.waitForRefresh()
        XCTAssertEqual(commands(incognito.commandBar.results).first, .airTrafficControl)

        let normal = ShellModel.window(for: BrowserWindowRequest(kind: .newWindow), on: controller)
        defer { normal.stop() }
        normal.presentCommandBar(.newTab)
        normal.commandBar.queryText = "new space"
        await normal.commandBar.waitForRefresh()
        XCTAssertTrue(commands(normal.commandBar.results).contains(.newSpace))
    }

    /// Pure state check: an incognito state leaves out the same commands.
    func testIncognitoStateAvailability() {
        var state = CommandBarCommandState.everything
        state.isIncognito = true
        for command in CommandBarCommand.unavailableInIncognito {
            XCTAssertFalse(command.isAvailable(in: state), "\(command)")
            XCTAssertTrue(command.isAvailable(in: .everything), "\(command)")
        }
        XCTAssertTrue(CommandBarCommand.newIncognitoWindow.isAvailable(in: state))
        XCTAssertTrue(CommandBarCommand.contactTheTeam.isAvailable(in: state))
    }

    /// The "Air Traffic Control" help row ([06 §20.1] observed row) opens Settings ▸ Links with
    /// the Air Traffic Control sheet ([06 §25] observed sheet; the target is inferred). From an
    /// incognito window the request reaches the app's Settings window.
    func testAirTrafficControlRowOpensTheSheet() {
        let settings = SettingsModel(shell: controller.appHost())
        var opened = 0
        incognito.openSettingsWindow = { opened += 1 }
        incognito.perform(.runCommand(.airTrafficControl))
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(settings.selectedPane, .links)
        XCTAssertTrue(settings.isAirTrafficControlShown)
        XCTAssertNil(incognito.lastUnhandledCommand)
    }

    /// The row's request also reaches a Settings window that the row itself opens (first open:
    /// the Settings model is created after the request), once.
    func testAirTrafficControlRequestBeforeSettingsWindowExists() {
        incognito.openSettingsWindow = {}
        incognito.perform(.runCommand(.airTrafficControl))
        let settings = SettingsModel(shell: controller.appHost())
        XCTAssertEqual(settings.selectedPane, .links)
        XCTAssertTrue(settings.isAirTrafficControlShown)
        // A later Settings model (window reopened) does not act on the old request again.
        let later = SettingsModel(shell: controller.appHost())
        XCTAssertEqual(later.selectedPane, .account)
        XCTAssertFalse(later.isAirTrafficControlShown)
    }
}
