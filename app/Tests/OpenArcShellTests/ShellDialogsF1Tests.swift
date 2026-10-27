import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// F1 step 2 dialogs drawn by the shell (`docs/arc-spec/00-feature-inventory.md §A`, inferred
/// (analysis); looks and wording are ours: unknown): the unresponsive-page sheet (C22).
@MainActor
final class ShellDialogsF1Tests: XCTestCase {
    private var engine: FakeEngine!
    private var model: ShellModel!

    override func setUp() async throws {
        engine = FakeEngine()
        model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: .demo(now: Date(timeIntervalSince1970: 0)),
            now: { Date(timeIntervalSince1970: 0) }
        )
    }

    override func tearDown() async throws {
        model.stop()
        model = nil
        engine = nil
    }

    private func openPage(_ address: String) async throws -> FakeTab {
        let opened = try await model.openNewTab(url: try XCTUnwrap(URL(string: address)))
        let id = try XCTUnwrap(opened)
        return try XCTUnwrap(model.sidebar.liveTab(for: id) as? FakeTab)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await model.controller.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    // MARK: C22 unresponsive page

    /// A tab-modal sheet: "Leave Page" on the left, "Wait" as the default (Return) button.
    func testUnresponsivePageSheetOffersWaitAndLeave() async throws {
        let live = try await openPage("https://stuck.example")
        let center = model.controller.dialogs
        let id = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        let presentation = DialogPresentation(request)
        XCTAssertEqual(presentation.style, .sheet)
        XCTAssertEqual(presentation.buttons, ["Leave Page", "Wait"])
        XCTAssertTrue(presentation.message.contains("stuck.example"))
        XCTAssertEqual(DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false),
                       .unresponsivePage(.wait))
        XCTAssertTrue(center.answer(id, with: DialogPresentation.answer(for: request, button: 1, fieldValues: [], checkbox: false)))
        XCTAssertEqual(live.dialogAnswers[id], .unresponsivePage(.wait))
        XCTAssertNil(center.current(for: live.id))
    }

    /// "Leave Page" leaves: the renderer stops and the tab goes back.
    func testLeavePageButtonLeaves() async throws {
        let live = try await openPage("https://before.example")
        try await live.load(try XCTUnwrap(URL(string: "https://stuck.example")))
        let center = model.controller.dialogs
        let id = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id) != nil }
        let request = try XCTUnwrap(center.current(for: live.id))
        center.answer(id, with: DialogPresentation.answer(for: request, button: 0, fieldValues: [], checkbox: false))
        XCTAssertEqual(live.dialogAnswers[id], .unresponsivePage(.leave))
        for _ in 0..<400 {
            if await live.currentState().url?.host == "before.example" { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        let state = await live.currentState()
        XCTAssertEqual(state.url?.host, "before.example")
    }

    /// Escape (dismiss without a choice) waits; the page answering again removes the sheet.
    func testDismissWaitsAndResponsivePageRemovesTheSheet() async throws {
        let live = try await openPage("https://stuck.example")
        let center = model.controller.dialogs
        let first = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id) != nil }
        center.dismiss(first)
        XCTAssertEqual(live.dialogAnswers[first], .unresponsivePage(.wait))

        let second = live.simulateUnresponsivePage()
        try await waitUntil { center.current(for: live.id)?.id == second }
        live.simulatePageResponsive()
        try await waitUntil { center.current(for: live.id) == nil }
        XCTAssertNil(live.dialogAnswers[second])
    }
}
