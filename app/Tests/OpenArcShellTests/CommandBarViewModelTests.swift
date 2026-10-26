import XCTest
import OpenArcModel
@testable import OpenArcShell

/// View model behavior. Observed in the spec: ⌘T / ⌘L open the bar, Escape closes it, the first row
/// is selected by default [05 §command bar]; ⌘T = New Tab…, ⌘L = edit the current address [02].
/// Up/Down wrapping, Tab completion and the unedited-prefill rule are INFERRED.
@MainActor
final class CommandBarViewModelTests: XCTestCase {
    /// [05 §command bar] observed: the first row is selected by default.
    func testFirstRowIsSelectedByDefault() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        XCTAssertFalse(model.results.isEmpty)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.queryText, "")
    }

    /// [02] ⌘L observed as "Open Command Bar (edit the current address)": the field is prefilled and selected.
    func testCommandLPrefillsCurrentAddressAndRequestsSelectAll() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world, mode: .currentTab, currentTab: "GitHub")
        let before = model.selectAllRequestID
        await CommandBarFixtures.open(model, world: world, mode: .currentTab, currentTab: "GitHub")
        XCTAssertEqual(model.mode, .currentTab)
        XCTAssertEqual(model.queryText, "https://github.com/")
        XCTAssertGreaterThan(model.selectAllRequestID, before)
        // Unedited prefill: the list is the empty-query list, without the viewed tab itself.
        XCTAssertTrue(model.isPrefillUnedited)
        XCTAssertFalse(model.results.contains { $0.action == .switchToTab(tabID: world.tabIDs["GitHub"]!) })
        XCTAssertEqual(model.results.last?.action, .runCommand(.contactTheTeam))
    }

    /// B26: every open asks the field to take keyboard focus, so ⌘T / ⌘L typing goes in at once.
    /// [02] observed: ⌘T "New Tab…", ⌘L "Open Command Bar (edit the current address)".
    func testEveryOpenRequestsFieldFocus() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world, mode: .newTab)
        let start = model.focusRequestID
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        XCTAssertEqual(model.focusRequestID, start + 1)
        model.dismiss()
        await CommandBarFixtures.open(model, world: world, mode: .currentTab, currentTab: "GitHub")
        XCTAssertEqual(model.focusRequestID, start + 2)
        XCTAssertTrue(model.isPrefillUnedited, "the ⌘L prefill is selected when the field takes focus")
    }

    /// [02] ⌘T observed as "New Tab…": the field starts empty.
    func testCommandTStartsEmptyAndRoutesToNewTab() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab, currentTab: "GitHub")
        XCTAssertEqual(model.mode, .newTab)
        XCTAssertEqual(model.queryText, "")
        await CommandBarFixtures.type(model, "example.com")
        XCTAssertEqual(model.activate(), .openURL(URL(string: "https://example.com")!, target: .newTab))
    }

    /// [02] ⌘L edits the current address (observed); routing to the current tab inferred.
    func testCommandLRoutesTypedURLAndSearchToCurrentTab() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world, mode: .currentTab, currentTab: "GitHub")
        await CommandBarFixtures.open(model, world: world, mode: .currentTab, currentTab: "GitHub")
        await CommandBarFixtures.type(model, "example.com")
        XCTAssertFalse(model.isPrefillUnedited)
        XCTAssertEqual(model.activate(), .openURL(URL(string: "https://example.com")!, target: .currentTab))
        await CommandBarFixtures.type(model, "purple elephants")
        XCTAssertEqual(model.activate(), .searchWeb(query: "purple elephants", target: .currentTab))
    }

    /// [05 §command bar] observed: open tabs are "Switch to Tab" candidates; the same action in both modes.
    func testSwitchToTabCarriesTabNodeIDInBothModes() async throws {
        let world = try CommandBarFixtures.world()
        for mode in [CommandBarMode.newTab, .currentTab] {
            let model = CommandBarFixtures.viewModel(world, mode: mode)
            await CommandBarFixtures.open(model, world: world, mode: mode)
            await CommandBarFixtures.type(model, "Example News")
            XCTAssertEqual(model.activate(), .switchToTab(tabID: world.tabIDs["Example News"]!))
        }
    }

    /// [06 §6] app commands run as `runCommand` (observed rows, inferred action).
    func testCommandAction() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        await CommandBarFixtures.type(model, "new little arc")
        XCTAssertEqual(model.activate(), .runCommand(.newLittleArcWindow))
    }

    // MARK: Keyboard

    /// [05 §command bar] keyboard navigation; wrapping is inferred.
    func testDownAndUpWrapAround() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        let count = model.results.count
        XCTAssertEqual(count, 5)
        XCTAssertEqual(model.handle(.up), .handled)
        XCTAssertEqual(model.selectedIndex, count - 1)
        XCTAssertEqual(model.handle(.down), .handled)
        XCTAssertEqual(model.selectedIndex, 0)
        for _ in 0..<3 { model.handle(.down) }
        XCTAssertEqual(model.selectedIndex, 3)
        model.handle(.shiftTab)
        XCTAssertEqual(model.selectedIndex, 2)
    }

    /// [05 §command bar] first row selected by default (observed).
    func testTypingResetsSelectionToFirstRow() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        model.handle(.down)
        model.handle(.down)
        XCTAssertEqual(model.selectedIndex, 2)
        model.queryText = "e"
        XCTAssertEqual(model.selectedIndex, 0, "reset immediately, before the new results arrive")
        await model.waitForRefresh()
        XCTAssertEqual(model.selectedIndex, 0)
    }

    /// [05 §command bar] Enter activates the selected row, inferred.
    func testEnterActivatesSelectedRowAndNotifies() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        var received: [CommandBarAction] = []
        model.onAction = { received.append($0) }
        model.handle(.down)
        let expected = try XCTUnwrap(model.selectedResult?.action)
        XCTAssertEqual(model.handle(.returnKey), .activate(expected))
        XCTAssertEqual(received, [expected])
    }

    /// [05 §command bar] observed: Escape closes the bar.
    func testEscapeDismisses() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        var dismissed = 0
        model.onDismiss = { dismissed += 1 }
        XCTAssertEqual(model.handle(.escape), .dismiss)
        XCTAssertEqual(dismissed, 1)
        model.dismiss()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(model.queryText, "")
    }

    /// [05 §command bar] Tab behavior unknown; completion is inferred.
    func testTabCompletesFieldWithSelectedRow() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        await CommandBarFixtures.type(model, "Apple")
        XCTAssertEqual(model.selectedResult?.title, "Apple Developer Documentation")
        XCTAssertEqual(model.handle(.tab), .handled)
        XCTAssertEqual(model.queryText, "https://developer.apple.com/documentation")
        await model.waitForRefresh()
        XCTAssertEqual(model.selectedResult?.title, "Apple Developer Documentation")
    }

    /// [05 §command bar] robustness, inferred.
    func testKeysWithNoResultsAreHarmless() {
        let model = CommandBarViewModel(sources: [])
        XCTAssertEqual(model.handle(.down), .handled)
        XCTAssertEqual(model.handle(.tab), .handled)
        XCTAssertEqual(model.handle(.returnKey), .handled)
        XCTAssertNil(model.activate())
    }

    /// [05 §command bar] result rows are activatable, inferred.
    func testClickingRowActivatesThatRow() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        XCTAssertEqual(model.activate(at: 1), model.results[1].action)
        XCTAssertNil(model.activate(at: 99))
    }

    // MARK: Staleness

    private struct SlowSource: CommandBarSource {
        func results(for context: CommandBarQueryContext) async -> [CommandBarResult] {
            if context.text == "slow" { try? await Task.sleep(nanoseconds: 150_000_000) }
            let title = "result for \(context.text)"
            return [CommandBarResult(id: "r:\(context.text)", kind: .webSearch, title: title, iconHint: .search, actionLabel: nil, action: .searchWeb(query: context.text, target: .newTab))]
        }
    }

    /// [05 §command bar] asynchronous sources must not show stale results, inferred.
    func testResultsForSupersededQueryAreDiscarded() async throws {
        let model = CommandBarViewModel(sources: [SlowSource()])
        model.queryText = "slow"
        // This refresh is not cancelled by later typing, so only the generation check can discard it.
        let slow = Task { await model.refresh() }
        try await Task.sleep(nanoseconds: 40_000_000) // let it enter the slow source with "slow"
        model.queryText = "fast"
        await model.waitForRefresh()
        XCTAssertEqual(model.results.map(\.title), ["result for fast"])
        await slow.value // the slow refresh finishes later and must not overwrite
        XCTAssertEqual(model.results.map(\.title), ["result for fast"])
    }

    /// Enter before fresh results exist must act on the typed text, not on the older selection.
    func testEnterWithStaleResultsUsesTypedText() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarFixtures.viewModel(world)
        await CommandBarFixtures.open(model, world: world, mode: .newTab)
        model.queryText = "example.org"            // refresh not awaited: results are stale
        XCTAssertEqual(model.activate(), .openURL(URL(string: "https://example.org")!, target: .newTab))
        model.queryText = "hello world"
        XCTAssertEqual(model.handle(.returnKey), .activate(.searchWeb(query: "hello world", target: .newTab)))
        await model.waitForRefresh()
    }

    /// [04 §command bar] result count limit, inferred.
    func testMaxResultsIsHonored() async throws {
        let world = try CommandBarFixtures.world()
        let model = CommandBarViewModel(
            sources: commandBarDefaultSources(workspace: { world.workspace }),
            maxResults: 3
        )
        model.queryText = "e"
        await model.waitForRefresh()
        XCTAssertEqual(model.results.count, 3)
    }
}
