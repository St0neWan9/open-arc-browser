import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// App commands, space rows and "Move Tab to" rows of the command bar (plan B15).
/// Observed: menu item names [01 §menus], default keys [02], app command rows have no action label
/// [06 §6], open tabs come first [05 §command bar]. Inferred: availability filtering, space rows,
/// move rows and every ranking tier between tabs and web suggestions.
@MainActor
final class CommandBarCommandsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func makeModel() -> ShellModel {
        ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { Date(timeIntervalSince1970: 0) })
    }

    /// Adds a second space "Work" after the demo's "Home" and returns its id.
    @discardableResult
    private func addWorkSpace(_ model: ShellModel) throws -> UUID {
        let id = UUID()
        let profile = try XCTUnwrap(model.selectedSpace?.profileID)
        model.sidebar.replaceWorkspace(try TreeOps.createSpace(model.workspace, id: id, profileID: profile, name: "Work", themeID: nil, now: t0))
        return id
    }

    private func firstTodayTab(_ model: ShellModel) throws -> UUID {
        let space = try XCTUnwrap(model.selectedSpaceID)
        return try XCTUnwrap(model.workspace.today(spaceID: space).first?.id)
    }

    private func selectFirstTab(_ model: ShellModel) async throws -> UUID {
        let id = try firstTodayTab(model)
        try await model.activate(tabID: id)
        return id
    }

    private func split(_ model: ShellModel) async throws {
        _ = try await selectFirstTab(model)
        model.addSplitView()
        await model.sidebar.settleEngineWork()
        model.dismissCommandBar()
        XCTAssertTrue(model.hasActiveSplit)
    }

    // MARK: Titles and hints

    /// [01 §menus] observed names; Archive Tab / Collapse All Folders / Expand All Folders come from
    /// the [02] shortcut list (observed) because no menu lists them.
    func testTitlesMatchMenuNames() {
        let expected: [CommandBarCommand: String] = [
            .newTab: "New Tab…", .newWindow: "New Window", .newIncognitoWindow: "New Incognito Window",
            .newLittleArcWindow: "New Little Arc Window",
            .restoreLastClosedTab: "Restore Last Closed Tab", .copyURL: "Copy URL",
            .toggleSidebar: "Hide Sidebar", .reload: "Refresh the Page",
            .addSplitView: "Add Split View", .closeSplitPane: "Close this Split Pane",
            .separateFromSplit: "Separate Page from Split View", .expandSplit: "Expand Current Split",
            .newSpace: "New Space…", .editTheme: "Edit Theme…", .renameSpace: "Rename Space",
            .nextSpace: "Next Space", .previousSpace: "Previous Space", .manageSpaces: "Manage Spaces…",
            .archiveTab: "Archive Tab", .togglePin: "Pin/Unpin Tab", .favoriteTab: "Favorite Tab", .newFolder: "New Folder…",
            .nextTab: "Next Tab", .previousTab: "Previous Tab", .clearToday: "Clear Today",
            .collapseAllFolders: "Collapse All Folders", .expandAllFolders: "Expand All Folders",
            .goBack: "Go Back", .goForward: "Go Forward", .viewArchive: "View Archive…",
            .openLibrary: "Open Library…", .viewDownloads: "View Downloads…", .viewEasels: "View Easels…",
            .viewMedia: "View Media…", .viewBoosts: "View Boosts…", .openSettings: "Settings…",
            .contactTheTeam: "Contact the Team", .airTrafficControl: "Air Traffic Control",
            // B78: [06 §16.2] observed rows, [02 §tabs, §page] observed names.
            .addTopSplit: "Add Top Split", .addLeftSplit: "Add Left Split", .addRightSplit: "Add Right Split",
            .addBottomSplit: "Add Bottom Split", .convertToVerticalSplit: "Convert to Vertical Split View",
            .convertToHorizontalSplit: "Convert to Horizontal Split View",
            .clearCookiesAndRefresh: "Clear Cookies and Refresh", .moveToToday: "Move to Today",
            .replacePinWithCurrentPage: "Replace Pin with Current Page",
            .resetTabToOriginalURL: "Reset Tab to Original URL", .duplicateTab: "Duplicate",
            .renameCurrentItem: "Rename Current Item",
        ]
        XCTAssertEqual(Set(expected.keys), Set(CommandBarCommand.allCases), "every command has a spec title")
        for command in CommandBarCommand.allCases {
            XCTAssertEqual(command.title, expected[command], "\(command)")
        }
        // "Show Sidebar" while hidden is inferred, like the View menu item.
        XCTAssertEqual(CommandBarCommand.toggleSidebar.title(in: CommandBarCommandState(isSidebarVisible: false)), "Show Sidebar")
    }

    /// [02] observed default keys; commands without a recorded key show no hint.
    func testShortcutHintsMatchDefaultShortcuts() {
        let expected: [CommandBarCommand: String] = [
            .newTab: "⌘T", .toggleSidebar: "⌘S", .newWindow: "⌘N", .newIncognitoWindow: "⇧⌘N", .newLittleArcWindow: "⌥⌘N", .restoreLastClosedTab: "⇧⌘T", .copyURL: "⇧⌘C",
            .reload: "⌘R", .addSplitView: "⌃⇧=", .closeSplitPane: "⌃⇧-", .nextSpace: "⌥⌘→",
            .previousSpace: "⌥⌘←", .archiveTab: "⌘W", .togglePin: "⌘D", .nextTab: "⌥⌘↓",
            .previousTab: "⌥⌘↑", .clearToday: "⇧⌘K", .goBack: "⌘[", .goForward: "⌘]",
            .openLibrary: "⇧⌘L", .openSettings: "⌘,",
        ]
        for command in CommandBarCommand.allCases {
            XCTAssertEqual(command.shortcutHint, expected[command], "\(command)")
        }
    }

    /// [06 §6] observed: app command rows have no action label, also inside a pane.
    func testCommandRowsHaveNoActionLabelAndCarryHint() async {
        let ctx = CommandBarQueryContext(text: "pin", mode: .newTab)
        let rows = await CommandBarCommandsSource().results(for: ctx)
        XCTAssertEqual(rows.count, CommandBarCommand.allCases.count)
        XCTAssertTrue(rows.allSatisfy { $0.actionLabel == nil && $0.trailingLabel(for: .pane) == nil })
        XCTAssertEqual(rows.first { $0.action == .runCommand(.togglePin) }?.shortcutHint, "⌘D")
    }

    /// No dead rows (inferred, like disabled menu items [01 §View]): state-bound commands are left
    /// out while they cannot run.
    func testUnavailableCommandsAreNotListed() async {
        let state = CommandBarCommandState(
            hasSelectedTab: false, spaceCount: 1, canRestoreLastClosedTab: false,
            hasActiveSplit: false, canGoBack: false, canGoForward: false, isSidebarVisible: false
        )
        let rows = await CommandBarCommandsSource(state: { state }).results(for: CommandBarQueryContext(text: "x", mode: .newTab))
        let listed = Set(rows.compactMap { row -> CommandBarCommand? in
            if case .runCommand(let command) = row.action { return command } else { return nil }
        })
        for hidden: CommandBarCommand in [.archiveTab, .togglePin, .copyURL, .reload, .addSplitView, .closeSplitPane,
                                          .separateFromSplit, .expandSplit, .goBack, .goForward,
                                          .restoreLastClosedTab, .nextSpace, .previousSpace] {
            XCTAssertFalse(listed.contains(hidden), "\(hidden)")
        }
        XCTAssertTrue(listed.contains(.newSpace))
        XCTAssertTrue(listed.contains(.contactTheTeam))
        XCTAssertEqual(rows.first { $0.action == .runCommand(.toggleSidebar) }?.title, "Show Sidebar")
    }

    /// [06 §16.2] observed: command rows show their shortcut at the right end (in the window and
    /// in a split pane); rows with right-hand text (Switch to Tab) do not.
    func testCommandRowsShowShortcutHint() async {
        let rows = await CommandBarCommandsSource().results(for: CommandBarQueryContext(text: "new window", mode: .newTab))
        let newWindow = rows.first { $0.action == .runCommand(.newWindow) }
        XCTAssertEqual(newWindow?.visibleShortcutHint(for: .window), "⌘N")
        XCTAssertEqual(newWindow?.visibleShortcutHint(for: .pane), "⌘N")
        XCTAssertNil(rows.first { $0.action == .runCommand(.newSpace) }?.visibleShortcutHint(for: .window))
        var withLabel = newWindow!
        withLabel.actionLabel = "Switch to Tab"
        // Right-hand text wins over the hint where text is drawn (a pane; the window's bar draws
        // no text on command rows, [07 §5] E27 follow-up).
        XCTAssertNil(withLabel.visibleShortcutHint(for: .pane))
        XCTAssertEqual(withLabel.visibleShortcutHint(for: .window), "⌘N")
    }

    /// [06 §16.2] observed: "Unpin Tab" (⌘D) while the selected tab is pinned.
    func testPinCommandTitleFollowsSelectedTab() {
        XCTAssertEqual(CommandBarCommand.togglePin.title(in: CommandBarCommandState(isSelectedTabPinned: true)), "Unpin Tab")
        XCTAssertEqual(CommandBarCommand.togglePin.title(in: CommandBarCommandState(isSelectedTabPinned: false)), "Pin Tab")
        XCTAssertEqual(CommandBarCommand.togglePin.title(in: .everything), "Pin/Unpin Tab")
    }

    /// [06 §16.2] observed: "Go Back" and the split commands are hidden (not dimmed) until they
    /// can run, then listed with their hint.
    func testGoBackAndSplitRowsAppearOnlyWhenRunnable() async {
        let ctx = CommandBarQueryContext(text: "x", mode: .newTab)
        let none = CommandBarCommandState(hasActiveSplit: false, canGoBack: false)
        let rowsNone = await CommandBarCommandsSource(state: { none }).results(for: ctx)
        XCTAssertFalse(rowsNone.contains { $0.action == .runCommand(.goBack) })
        XCTAssertFalse(rowsNone.contains { $0.action == .runCommand(.closeSplitPane) })
        XCTAssertFalse(rowsNone.contains { $0.action == .runCommand(.expandSplit) })
        let able = CommandBarCommandState(hasActiveSplit: true, canGoBack: true)
        let rowsAble = await CommandBarCommandsSource(state: { able }).results(for: ctx)
        XCTAssertEqual(rowsAble.first { $0.action == .runCommand(.goBack) }?.shortcutHint, "⌘[")
        XCTAssertEqual(rowsAble.first { $0.action == .runCommand(.closeSplitPane) }?.shortcutHint, "⌃⇧-")
        XCTAssertTrue(rowsAble.contains { $0.action == .runCommand(.expandSplit) })
    }

    /// The shell's live state drives availability: split items appear only with a split. [01 §View] observed.
    func testShellStateDrivesAvailability() async throws {
        let model = makeModel()
        XCTAssertFalse(CommandBarCommand.closeSplitPane.isAvailable(in: model.commandBarCommandState))
        try await split(model)
        XCTAssertTrue(CommandBarCommand.closeSplitPane.isAvailable(in: model.commandBarCommandState))
        XCTAssertEqual(model.commandBarCommandState.movableTabID, model.selectedTabID)
    }

    // MARK: Routing (table-driven)

    private struct RoutingCase {
        let command: CommandBarCommand
        var setUp: (ShellModel) async throws -> Void = { _ in }
        let check: (ShellModel) async throws -> Void
    }

    private func routingCases() -> [RoutingCase] {
        [
            RoutingCase(command: .newTab) { m in
                XCTAssertTrue(m.isCommandBarPresented)
                XCTAssertEqual(m.commandBar.mode, .newTab)
            },
            // Openers are installed by `testOpenersAreCalled`; here none exists, which is recorded.
            RoutingCase(command: .newWindow) { m in XCTAssertEqual(m.lastUnhandledCommand, .newWindow) },
            RoutingCase(command: .newIncognitoWindow) { m in XCTAssertEqual(m.lastUnhandledCommand, .newIncognitoWindow) },
            RoutingCase(command: .newLittleArcWindow) { m in XCTAssertEqual(m.lastUnhandledCommand, .newLittleArcWindow) },
            RoutingCase(command: .restoreLastClosedTab, setUp: { m in
                let id = try await self.selectFirstTab(m)
                m.sidebar.closeTab(id)
            }) { m in
                XCTAssertNotNil(m.selectedTabID)
                XCTAssertFalse(m.sidebar.canRestoreLastClosedTab)
            },
            RoutingCase(command: .copyURL, setUp: { m in
                m.siteControls.pasteboard = RecordingPasteboardWriter()
                _ = try await self.selectFirstTab(m)
            }) { m in
                let pasteboard = try XCTUnwrap(m.siteControls.pasteboard as? RecordingPasteboardWriter)
                XCTAssertEqual(pasteboard.written, [try XCTUnwrap(m.sidebar.selectedURL)])
            },
            RoutingCase(command: .toggleSidebar) { m in XCTAssertFalse(m.isSidebarVisible) },
            RoutingCase(command: .reload, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                await m.sidebar.settleEngineWork()
                XCTAssertNil(m.sidebar.lastError)
                XCTAssertNil(m.lastUnhandledCommand)
            },
            RoutingCase(command: .addSplitView, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                XCTAssertTrue(m.hasActiveSplit)
                XCTAssertNotNil(m.commandBarPaneTabID, "[06 §5] the bar opens in the new pane")
            },
            // B78 [06 §16.2]: the four placements of the web toolbar's split menu [06 §17.3].
            RoutingCase(command: .addTopSplit, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                try self.assertNewPane(m, axis: .vertical, newFirst: true)
            },
            RoutingCase(command: .addLeftSplit, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                try self.assertNewPane(m, axis: .horizontal, newFirst: true)
            },
            RoutingCase(command: .addRightSplit, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                try self.assertNewPane(m, axis: .horizontal, newFirst: false)
            },
            RoutingCase(command: .addBottomSplit, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                try self.assertNewPane(m, axis: .vertical, newFirst: false)
            },
            RoutingCase(command: .convertToVerticalSplit, setUp: { m in try await self.split(m) }) { m in
                XCTAssertEqual(try self.splitAxis(m), .vertical)
            },
            RoutingCase(command: .convertToHorizontalSplit, setUp: { m in
                try await self.split(m)
                m.perform(.runCommand(.convertToVerticalSplit))
            }) { m in
                XCTAssertEqual(try self.splitAxis(m), .horizontal)
            },
            RoutingCase(command: .clearCookiesAndRefresh, setUp: { m in
                m.siteControls.provider = FakeSiteSettingsProvider()
                _ = try await self.selectFirstTab(m)
            }) { m in
                await m.sidebar.settleEngineWork()
                let provider = try XCTUnwrap(m.siteControls.provider as? FakeSiteSettingsProvider)
                XCTAssertEqual(provider.appliedChanges, [.clearSiteData])
                let live = try XCTUnwrap(m.selectedLiveTab as? FakeTab)
                XCTAssertEqual(live.commands, [.reload(bypassingCache: false)], "cleared first, then refreshed")
            },
            RoutingCase(command: .moveToToday, setUp: { m in _ = try await self.selectPinnedTab(m) }) { m in
                let id = try XCTUnwrap(m.selectedTabID)
                let space = try XCTUnwrap(m.selectedSpaceID)
                XCTAssertEqual(m.workspace.tabs[id]?.location, .today(spaceID: space))
                XCTAssertEqual(m.workspace.today(spaceID: space).first?.id, id, "top of Today")
            },
            RoutingCase(command: .replacePinWithCurrentPage, setUp: { m in try await self.navigatePinnedTabAway(m) }) { m in
                // The replace runs after the tab's queued engine commands (B129).
                await m.sidebar.settleEngineWork()
                let id = try XCTUnwrap(m.selectedTabID)
                XCTAssertEqual(m.workspace.tabs[id]?.pinnedURL, self.elsewhere)
            },
            RoutingCase(command: .resetTabToOriginalURL, setUp: { m in try await self.navigatePinnedTabAway(m) }) { m in
                await m.sidebar.settleEngineWork()
                let id = try XCTUnwrap(m.selectedTabID)
                let tab = try XCTUnwrap(m.workspace.tabs[id])
                // Engine events of the earlier navigation arrive asynchronously; the model settles.
                try await self.waitUntil { m.workspace.tabs[id]?.url == tab.pinnedURL }
                let live = try XCTUnwrap(m.selectedLiveTab)
                let url = await live.currentState().url
                XCTAssertEqual(url, tab.pinnedURL)
            },
            RoutingCase(command: .duplicateTab, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                let copy = try XCTUnwrap(m.selectedTabID.flatMap { m.workspace.tabs[$0] })
                let original = try XCTUnwrap(m.workspace.tabs.values.first { $0.url == copy.url && $0.id != copy.id })
                XCTAssertNotEqual(copy.id, original.id, "the copy is selected")
                XCTAssertEqual(m.workspace.today(spaceID: try XCTUnwrap(m.selectedSpaceID)).first?.id, copy.id)
            },
            RoutingCase(command: .renameCurrentItem, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                XCTAssertEqual(m.sidebar.renamingItemID, m.selectedTabID)
            },
            RoutingCase(command: .closeSplitPane, setUp: { m in try await self.split(m) }) { m in
                XCTAssertFalse(m.hasActiveSplit)
            },
            RoutingCase(command: .separateFromSplit, setUp: { m in try await self.split(m) }) { m in
                XCTAssertFalse(m.hasActiveSplit)
                XCTAssertNotNil(m.selectedTabID, "the page stays open")
            },
            RoutingCase(command: .expandSplit, setUp: { m in try await self.split(m) }) { m in
                XCTAssertTrue(m.isSplitExpandedNow)
            },
            RoutingCase(command: .newSpace) { m in XCTAssertTrue(m.spaceFlow.isCreating) },
            RoutingCase(command: .editTheme) { m in XCTAssertEqual(m.spaceFlow.themeEditorSpaceID, m.selectedSpaceID) },
            RoutingCase(command: .renameSpace) { m in XCTAssertEqual(m.spaceFlow.renamingSpaceID, m.selectedSpaceID) },
            RoutingCase(command: .nextSpace, setUp: { m in try self.addWorkSpace(m) }) { m in
                XCTAssertEqual(m.selectedSpace?.name, "Work")
            },
            RoutingCase(command: .previousSpace, setUp: { m in try self.addWorkSpace(m) }) { m in
                XCTAssertEqual(m.selectedSpace?.name, "Work", "wraps from the first space to the last")
            },
            RoutingCase(command: .manageSpaces) { m in XCTAssertEqual(m.library.section, .spaces) },
            RoutingCase(command: .archiveTab, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                XCTAssertTrue(m.workspace.archive.values.contains { $0.reason == .closed })
            },
            RoutingCase(command: .togglePin, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                let id = try XCTUnwrap(m.selectedTabID)
                guard case .pinned = try XCTUnwrap(m.workspace.tabs[id]).location else { return XCTFail("not pinned") }
            },
            // [06 §21.4] observed: Favorite Tab moves the Today tab to the end of the favorites (B55).
            RoutingCase(command: .favoriteTab, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                let id = try XCTUnwrap(m.selectedTabID)
                guard case .favorite = try XCTUnwrap(m.workspace.tabs[id]).location else { return XCTFail("not a favorite") }
            },
            RoutingCase(command: .newFolder) { m in XCTAssertTrue(m.sidebar.isNewFolderSheetPresented) },
            RoutingCase(command: .nextTab, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                XCTAssertNotEqual(m.selectedTabID, try self.firstTodayTab(m))
            },
            RoutingCase(command: .previousTab, setUp: { m in _ = try await self.selectFirstTab(m) }) { m in
                XCTAssertNotEqual(m.selectedTabID, try self.firstTodayTab(m))
            },
            RoutingCase(command: .clearToday) { m in
                XCTAssertTrue(m.workspace.today(spaceID: try XCTUnwrap(m.selectedSpaceID)).isEmpty)
            },
            RoutingCase(command: .collapseAllFolders) { m in
                XCTAssertTrue(m.workspace.folders.values.allSatisfy { !$0.isExpanded })
            },
            RoutingCase(command: .expandAllFolders, setUp: { m in m.sidebar.setAllFoldersExpanded(false) }) { m in
                XCTAssertTrue(m.workspace.folders.values.allSatisfy(\.isExpanded))
            },
            RoutingCase(command: .goBack, setUp: { m in try await self.navigateTwice(m) }) { m in
                await m.sidebar.settleEngineWork()
                let state = await (try XCTUnwrap(m.selectedLiveTab)).currentState()
                XCTAssertEqual(state.url, URL(string: "https://first.example"))
            },
            RoutingCase(command: .goForward, setUp: { m in
                try await self.navigateTwice(m)
                m.sidebar.goBack()
                await m.sidebar.settleEngineWork()
                try await self.waitUntil { m.sidebar.canGoForward }
            }) { m in
                await m.sidebar.settleEngineWork()
                let state = await (try XCTUnwrap(m.selectedLiveTab)).currentState()
                XCTAssertEqual(state.url, URL(string: "https://second.example"))
            },
            RoutingCase(command: .viewArchive) { m in XCTAssertEqual(m.library.section, .archivedTabs) },
            RoutingCase(command: .openLibrary) { m in XCTAssertTrue(m.isLibraryActive) },
            RoutingCase(command: .viewDownloads) { m in XCTAssertEqual(m.library.section, .downloads) },
            RoutingCase(command: .viewEasels) { m in XCTAssertEqual(m.library.section, .easels) },
            RoutingCase(command: .viewMedia) { m in XCTAssertEqual(m.library.section, .media) },
            RoutingCase(command: .viewBoosts) { m in XCTAssertEqual(m.library.section, .boosts) },
            RoutingCase(command: .openSettings) { m in XCTAssertEqual(m.lastUnhandledCommand, .openSettings) },
            // B72: the same as Help ▸ Contact the Team, a new mail to the team.
            RoutingCase(command: .contactTheTeam) { m in
                let desktop = try XCTUnwrap(m.dependencies.desktop as? RecordingDesktopServices)
                XCTAssertEqual(desktop.opened, [OpenArcLinks.contactTheTeam])
            },
            // B61: Settings ▸ Links with the Air Traffic Control sheet; no Settings opener in tests.
            RoutingCase(command: .airTrafficControl) { m in
                XCTAssertEqual(m.controller.airTrafficControlRequests, 1)
                XCTAssertEqual(m.lastUnhandledCommand, .airTrafficControl)
            },
        ]
    }

    private let elsewhere = URL(string: "https://elsewhere.example")!

    /// The demo's pinned tab (example.com in the "Reading" folder).
    private func pinnedTab(_ model: ShellModel) throws -> UUID {
        try XCTUnwrap(model.workspace.tabs.values.first { tab in
            if case .pinned = tab.location { return !tab.meta.isTombstone } else { return false }
        }?.id)
    }

    private func selectPinnedTab(_ model: ShellModel) async throws -> UUID {
        let id = try pinnedTab(model)
        try await model.activate(tabID: id)
        return id
    }

    /// Selects the pinned tab and navigates it away from its pinned URL.
    private func navigatePinnedTabAway(_ model: ShellModel) async throws {
        let id = try await selectPinnedTab(model)
        model.sidebar.navigateSelectedTab(to: elsewhere)
        await model.sidebar.settleEngineWork()
        try await waitUntil { model.workspace.tabs[id]?.url == self.elsewhere }
    }

    private func splitAxis(_ model: ShellModel) throws -> SplitAxis? {
        guard case .split(let axis, _) = try XCTUnwrap(model.activeSplitLayout).root else { return nil }
        return axis
    }

    /// A new empty pane was added on the expected side of the selected tab, with the bar in it.
    private func assertNewPane(_ model: ShellModel, axis: SplitAxis, newFirst: Bool, line: UInt = #line) throws {
        let layout = try XCTUnwrap(model.activeSplitLayout, line: line)
        guard case .split(let actual, let children) = layout.root else { return XCTFail("no split", line: line) }
        XCTAssertEqual(actual, axis, line: line)
        let new = try XCTUnwrap(model.selectedTabID, line: line)
        XCTAssertEqual(children.first?.node == .pane(tabID: new), newFirst, line: line)
        XCTAssertNil(model.workspace.tabs[new]?.url, "an empty pane", line: line)
        XCTAssertEqual(model.commandBarPaneTabID, new, "[06 §5] the bar opens in the new pane", line: line)
    }

    /// Selects a tab and loads first.example then second.example in it.
    private func navigateTwice(_ model: ShellModel) async throws {
        _ = try await selectFirstTab(model)
        model.sidebar.navigateSelectedTab(to: URL(string: "https://first.example")!)
        await model.sidebar.settleEngineWork()
        model.sidebar.navigateSelectedTab(to: URL(string: "https://second.example")!)
        await model.sidebar.settleEngineWork()
        try await waitUntil { model.sidebar.canGoBack }
    }

    /// Lets the engine's event stream deliver state; bounded.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "condition not reached")
    }

    /// B129: Replace Pin with Current Page right after a URL was entered pins the page just
    /// loaded. The command used to read the cached live state, which still held the previous page
    /// (the load was queued, or its events were still on the tab's event stream), and pinned that
    /// page or wrote it back into the record. Here it runs before the load: deterministic.
    func testReplacePinRightAfterNavigatingPinsTheNewPage() async throws {
        let model = makeModel()
        let id = try await selectPinnedTab(model)
        let pinned = try XCTUnwrap(model.workspace.tabs[id]?.pinnedURL)
        XCTAssertNotEqual(pinned, elsewhere)
        model.sidebar.navigateSelectedTab(to: elsewhere)
        model.perform(.runCommand(.replacePinWithCurrentPage))
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.workspace.tabs[id]?.pinnedURL, elsewhere, "the page just loaded is pinned")
        XCTAssertEqual(model.workspace.tabs[id]?.url, elsewhere, "the record keeps the page shown")
        // Late engine events of the load change nothing.
        try await waitUntil { model.sidebar.liveState(for: id)?.url == self.elsewhere }
        await model.sidebar.settleEngineWork()
        XCTAssertEqual(model.workspace.tabs[id]?.url, elsewhere)
        XCTAssertEqual(model.workspace.tabs[id]?.pinnedURL, elsewhere)
        model.stop()
    }

    /// Every command routes to the change its menu item makes.
    func testEveryCommandRoutesToItsModelChange() async throws {
        let cases = routingCases()
        XCTAssertEqual(Set(cases.map(\.command)), Set(CommandBarCommand.allCases), "every command is covered")
        for routing in cases {
            let model = makeModel()
            try await routing.setUp(model)
            model.perform(.runCommand(routing.command))
            try await routing.check(model)
            if ![.newWindow, .newIncognitoWindow, .newLittleArcWindow, .openSettings, .airTrafficControl].contains(routing.command) {
                XCTAssertNil(model.lastUnhandledCommand, "\(routing.command)")
            }
            model.stop()
        }
    }

    /// B14: New Window (⌘N) and New Incognito Window (⇧⌘N) go through the window opener the scene
    /// installs on the controller. Titles [01 §File] and keys [02] observed; New Window opening on
    /// the current Space is inferred.
    func testWindowCommandsOpenBrowserWindows() {
        let model = makeModel()
        var requests: [BrowserWindowRequest] = []
        model.controller.openBrowserWindow = { requests.append($0) }
        model.perform(.runCommand(.newWindow))
        model.perform(.runCommand(.newIncognitoWindow))
        XCTAssertEqual(requests.map(\.kind), [.newWindow, .incognito])
        XCTAssertEqual(requests.first?.spaceID, model.selectedSpaceID)
        XCTAssertNil(requests.last?.spaceID)
        XCTAssertNotEqual(requests.first?.id, requests.last?.id, "every request opens its own window")
        XCTAssertNil(model.lastUnhandledCommand)
        model.stop()
    }

    /// Commands that open another scene go through the opener the main window installs.
    func testOpenersAreCalled() {
        let model = makeModel()
        var littleArc = 0, settings = 0
        model.openLittleArcWindow = { littleArc += 1 }
        model.openSettingsWindow = { settings += 1 }
        model.perform(.runCommand(.newLittleArcWindow))
        model.perform(.runCommand(.openSettings))
        XCTAssertEqual(littleArc, 1)
        XCTAssertEqual(settings, 1)
        XCTAssertNil(model.lastUnhandledCommand)
        model.stop()
    }

    // MARK: Space rows (inferred)

    /// "Go to “<Space>”" for other spaces, wording of the Spaces menu [01 §Spaces, 02 §Space] observed.
    func testTypingASpaceNameOffersGoToRow() async throws {
        let world = try CommandBarFixtures.world()
        let source = CommandBarSpacesSource(workspace: { world.workspace })
        let empty = await source.results(for: CommandBarQueryContext(text: "", mode: .newTab, currentSpaceID: world.homeSpace))
        XCTAssertTrue(empty.isEmpty, "space rows are only offered for a query")

        let ctx = CommandBarQueryContext(text: "wor", mode: .newTab, currentSpaceID: world.homeSpace)
        let ranked = CommandBarRanker.rank(await source.results(for: ctx), context: ctx)
        let row = try XCTUnwrap(ranked.first)
        XCTAssertEqual(row.title, "Go to “Work”")
        XCTAssertEqual(row.kind, .space)
        XCTAssertEqual(row.action, .goToSpace(spaceID: world.workSpace))
        XCTAssertNil(row.actionLabel)
        XCTAssertEqual(row.shortcutHint, "⌃2", "[02 §Space] ⌃N follows the dock order")
        XCTAssertFalse(ranked.contains { $0.action == .goToSpace(spaceID: world.homeSpace) }, "no row for the current space")
    }

    func testGoToSpaceSwitchesSpace() async throws {
        let model = makeModel()
        let work = try addWorkSpace(model)
        model.presentCommandBar(.newTab)
        model.commandBar.queryText = "Work"
        await model.commandBar.waitForRefresh()
        let row = try XCTUnwrap(model.commandBar.results.first { $0.kind == .space })
        XCTAssertEqual(row.action, .goToSpace(spaceID: work))
        model.perform(row.action)
        XCTAssertEqual(model.selectedSpaceID, work)
        XCTAssertFalse(model.isCommandBarPresented)
        model.stop()
    }

    // MARK: Move Tab rows (inferred)

    /// With a current tab, "Move Tab to “<Space>”" rows for every space but the tab's own.
    func testMoveTabRowsNeedACurrentTab() async throws {
        let world = try CommandBarFixtures.world()
        let github = try XCTUnwrap(world.tabIDs["GitHub"])
        let source = CommandBarSpacesSource(workspace: { world.workspace })
        let none = await source.results(for: CommandBarQueryContext(text: "move", mode: .newTab, currentSpaceID: world.homeSpace))
        XCTAssertFalse(none.contains { $0.kind == .moveTabToSpace })

        let withTab = CommandBarSpacesSource(workspace: { world.workspace }, state: { CommandBarCommandState(movableTabID: github) })
        let ctx = CommandBarQueryContext(text: "move", mode: .newTab, currentSpaceID: world.homeSpace)
        let rows = CommandBarRanker.rank(await withTab.results(for: ctx), context: ctx).filter { $0.kind == .moveTabToSpace }
        XCTAssertEqual(rows.map(\.title), ["Move Tab to “Work”"])
        XCTAssertEqual(rows.first?.action, .moveTab(tabID: github, toSpaceID: world.workSpace))
        XCTAssertNil(rows.first?.actionLabel)
    }

    /// The pane / ⌘L bar acts on its own tab (the context tab wins over the window selection).
    func testMoveTabRowsUseTheContextTab() async throws {
        let world = try CommandBarFixtures.world()
        let jira = try XCTUnwrap(world.tabIDs["Jira Board"])
        let github = try XCTUnwrap(world.tabIDs["GitHub"])
        let source = CommandBarSpacesSource(workspace: { world.workspace }, state: { CommandBarCommandState(movableTabID: github) })
        let ctx = CommandBarQueryContext(text: "home", mode: .currentTab, currentSpaceID: world.homeSpace, currentTabID: jira)
        let rows = await source.results(for: ctx).filter { $0.kind == .moveTabToSpace }
        XCTAssertEqual(rows.map(\.action), [.moveTab(tabID: jira, toSpaceID: world.homeSpace)])
    }

    /// The row calls the sidebar's Move to ▸ intent; the window stays in its space.
    func testMoveTabRowMovesTheSelectedTab() async throws {
        let model = makeModel()
        let home = try XCTUnwrap(model.selectedSpaceID)
        let work = try addWorkSpace(model)
        let tab = try await selectFirstTab(model)
        model.presentCommandBar(.newTab)
        model.commandBar.queryText = "move to work"
        await model.commandBar.waitForRefresh()
        let row = try XCTUnwrap(model.commandBar.results.first { $0.kind == .moveTabToSpace })
        XCTAssertEqual(row.action, .moveTab(tabID: tab, toSpaceID: work))
        model.perform(row.action)
        XCTAssertEqual(model.workspace.tabs[tab]?.location, .today(spaceID: work))
        XCTAssertEqual(model.selectedSpaceID, home)
        model.stop()
    }

    // MARK: Ranking with mixed results (inferred)

    /// Exact tab match > space rows > other rows > web suggestions; "Go to" above "Move Tab to".
    func testMixedRankingOrder() async throws {
        let world = try CommandBarFixtures.world()
        var ws = world.workspace
        let workTab = UUID()
        ws = try TreeOps.openTab(ws, id: workTab, spaceID: world.homeSpace, url: URL(string: "https://notes.example.com"), title: "Work", now: CommandBarFixtures.base)
        let github = try XCTUnwrap(world.tabIDs["GitHub"])
        let workspace = ws
        let sources = commandBarDefaultSources(
            workspace: { workspace },
            commandState: { CommandBarCommandState(movableTabID: github) },
            suggestions: CommandBarStaticSuggestionProvider(phrases: ["work email", "workday login"])
        )
        let ctx = CommandBarQueryContext(text: "work", mode: .newTab, currentSpaceID: world.homeSpace)
        var all: [CommandBarResult] = []
        for source in sources { all += await source.results(for: ctx) }
        let ranked = CommandBarRanker.rank(all, context: ctx, limit: 50)
        let kinds = ranked.map(\.kind)

        XCTAssertEqual(ranked.first?.action, .switchToTab(tabID: workTab), "exact tab match first")
        let goTo = try XCTUnwrap(kinds.firstIndex(of: .space))
        let move = try XCTUnwrap(kinds.firstIndex(of: .moveTabToSpace))
        let firstSuggestion = try XCTUnwrap(kinds.firstIndex(of: .searchSuggestion))
        XCTAssertEqual(goTo, 1)
        XCTAssertLessThan(goTo, move)
        XCTAssertLessThan(move, firstSuggestion)
        XCTAssertLessThan(move, try XCTUnwrap(kinds.firstIndex(of: .webSearch)), "an exact space name beats the search row")
    }

    /// Weak command matches still sit above every web suggestion, and below any matching tab of the
    /// same tier (tabs first, [05 §command bar] observed).
    func testCommandsRankAboveSuggestionsAndBelowExactTabs() async throws {
        let world = try CommandBarFixtures.world()
        var ws = world.workspace
        let spaceTab = UUID()
        ws = try TreeOps.openTab(ws, id: spaceTab, spaceID: world.homeSpace, url: URL(string: "https://space.example.com"), title: "Space", now: CommandBarFixtures.base)
        let workspace = ws
        let sources = commandBarDefaultSources(
            workspace: { workspace },
            suggestions: CommandBarStaticSuggestionProvider(phrases: ["space weather", "space x"])
        )
        let ctx = CommandBarQueryContext(text: "space", mode: .newTab, currentSpaceID: world.homeSpace)
        var all: [CommandBarResult] = []
        for source in sources { all += await source.results(for: ctx) }
        let ranked = CommandBarRanker.rank(all, context: ctx, limit: 50)

        XCTAssertEqual(ranked.first?.action, .switchToTab(tabID: spaceTab))
        let commandIndices = ranked.indices.filter { [.command, .space].contains(ranked[$0].kind) }
        let suggestionIndices = ranked.indices.filter { ranked[$0].kind == .searchSuggestion }
        XCTAssertTrue(commandIndices.contains { ranked[$0].action == .runCommand(.newSpace) })
        XCTAssertTrue(commandIndices.contains { ranked[$0].action == .goToSpace(spaceID: world.workSpace) })
        XCTAssertFalse(suggestionIndices.isEmpty)
        XCTAssertLessThan(try XCTUnwrap(commandIndices.max()), try XCTUnwrap(suggestionIndices.min()))
    }

    /// An exact command title never outranks an exact tab title. inferred.
    func testExactCommandTitleStaysBelowExactTab() {
        let tab = CommandBarResult(id: "tab:1", kind: .todayTab, title: "Clear Today", iconHint: .globe, actionLabel: "Switch to Tab", action: .switchToTab(tabID: UUID()))
        let command = CommandBarResult(id: "command:clearToday", kind: .command, title: "Clear Today", iconHint: .command, actionLabel: nil, action: .runCommand(.clearToday))
        let ctx = CommandBarQueryContext(text: "clear today", mode: .newTab)
        XCTAssertEqual(CommandBarRanker.rank([command, tab], context: ctx).map(\.id), ["tab:1", "command:clearToday"])
    }

    // MARK: B78 availability [06 §16.2]

    private func listed(_ model: ShellModel, _ query: String) async -> [CommandBarCommand] {
        let ctx = CommandBarQueryContext(text: query, mode: .newTab)
        let state = model.commandBarCommandState
        let rows = await CommandBarCommandsSource(state: { state }).results(for: ctx)
        return CommandBarRanker.rank(rows, context: ctx, limit: 50).compactMap { row in
            if case .runCommand(let command) = row.action { return command } else { return nil }
        }
    }

    /// [06 §16.2] observed: with no split, "split" finds only Add Split View and Add Top / Left /
    /// Right / Bottom Split; after a split Close this Split Pane, Expand Current Split and Convert
    /// to Vertical Split View appear. The add rows carry no hint except ⌃⇧= ([02 §split] observed).
    func testSplitRowsFollowTheSplit() async throws {
        let model = makeModel()
        defer { model.stop() }
        _ = try await selectFirstTab(model)
        let single = await listed(model, "split")
        XCTAssertEqual(Set(single), [.addSplitView, .addTopSplit, .addLeftSplit, .addRightSplit, .addBottomSplit])
        for command: CommandBarCommand in [.addTopSplit, .addLeftSplit, .addRightSplit, .addBottomSplit] {
            XCTAssertNil(command.shortcutHint, "\(command): [02] lists no key")
        }
        try await split(model)
        let splitRows = await listed(model, "split")
        for command: CommandBarCommand in [.closeSplitPane, .expandSplit, .convertToVerticalSplit] {
            XCTAssertTrue(splitRows.contains(command), "\(command)")
        }
        XCTAssertFalse(splitRows.contains(.convertToHorizontalSplit), "already side by side")
        model.perform(.runCommand(.convertToVerticalSplit))
        let stacked = await listed(model, "split")
        XCTAssertTrue(stacked.contains(.convertToHorizontalSplit))
        XCTAssertFalse(stacked.contains(.convertToVerticalSplit))
    }

    /// [06 §16.2] observed "Move to Today in <Space>" and "Replace Pin with Current Page": pinned
    /// pages only. Replace / Reset need the page to have left its pinned URL (the menu's disabled
    /// state, [06 §21.5] observed); a Today tab lists none of the three.
    func testPinnedPageRowsNeedAPinnedTab() async throws {
        let model = makeModel()
        defer { model.stop() }
        let pinned: [CommandBarCommand] = [.moveToToday, .replacePinWithCurrentPage, .resetTabToOriginalURL]
        _ = try await selectFirstTab(model)
        for command in pinned {
            XCTAssertFalse(command.isAvailable(in: model.commandBarCommandState), "\(command) on a Today tab")
        }
        _ = try await selectPinnedTab(model)
        let state = model.commandBarCommandState
        XCTAssertTrue(CommandBarCommand.moveToToday.isAvailable(in: state))
        XCTAssertEqual(CommandBarCommand.moveToToday.title(in: state), "Move to Today in Home")
        XCTAssertFalse(CommandBarCommand.replacePinWithCurrentPage.isAvailable(in: state), "still on its pinned URL")
        XCTAssertFalse(CommandBarCommand.resetTabToOriginalURL.isAvailable(in: state))
        try await navigatePinnedTabAway(model)
        XCTAssertTrue(CommandBarCommand.replacePinWithCurrentPage.isAvailable(in: model.commandBarCommandState))
        XCTAssertTrue(CommandBarCommand.resetTabToOriginalURL.isAvailable(in: model.commandBarCommandState))
        let rows = await listed(model, "move to today")
        XCTAssertEqual(rows.first, .moveToToday)
        for command in pinned + [.duplicateTab, .renameCurrentItem, .clearCookiesAndRefresh] {
            XCTAssertNil(command.shortcutHint, "\(command): [02] lists no key")
        }
    }

    /// Duplicate / Rename Current Item need a tab; rename needs a row with a rename field (not a
    /// split member). Clear Cookies and Refresh needs a web page. Every one is hidden otherwise.
    func testTabRowsNeedASuitableTab() async throws {
        let model = makeModel()
        defer { model.stop() }
        let none = model.commandBarCommandState
        for command: CommandBarCommand in [.duplicateTab, .renameCurrentItem, .clearCookiesAndRefresh, .moveToToday] {
            XCTAssertFalse(command.isAvailable(in: none), "\(command) without a tab")
        }
        _ = try await selectFirstTab(model)
        for command: CommandBarCommand in [.duplicateTab, .renameCurrentItem, .clearCookiesAndRefresh] {
            XCTAssertTrue(command.isAvailable(in: model.commandBarCommandState), "\(command)")
        }
        let blank = try XCTUnwrap(model.sidebar.newTab(url: nil))
        try await model.activate(tabID: blank)
        XCTAssertFalse(CommandBarCommand.clearCookiesAndRefresh.isAvailable(in: model.commandBarCommandState), "no site")
        try await split(model)
        XCTAssertFalse(CommandBarCommand.renameCurrentItem.isAvailable(in: model.commandBarCommandState), "split members share one row")
    }

    /// Rename Current Item reveals the row: a hidden sidebar comes back and the pinned tab's
    /// collapsed folder opens. inferred.
    func testRenameCurrentItemRevealsTheRow() async throws {
        let model = makeModel()
        defer { model.stop() }
        let id = try await selectPinnedTab(model)
        model.sidebar.setAllFoldersExpanded(false)
        model.toggleSidebar()
        model.perform(.runCommand(.renameCurrentItem))
        XCTAssertTrue(model.isSidebarVisible)
        XCTAssertTrue(model.workspace.folders.values.allSatisfy(\.isExpanded))
        XCTAssertEqual(model.sidebar.renamingItemID, id)
    }
}
