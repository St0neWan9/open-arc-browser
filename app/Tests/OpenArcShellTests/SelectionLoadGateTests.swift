import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// Plan B107: selections that come faster than `SelectionLoadGate.burstGap` make their engine tabs
/// once the run of selections ends, the tab on screen first; a selection after a quiet moment
/// makes its engine tab right away (B103's next-pass rule).
@MainActor
final class SelectionLoadGateTests: XCTestCase {
    /// A manual clock for the gate.
    private final class Clock {
        var now: TimeInterval = 1_000
    }

    func testFirstSelectionIsNotABurst() {
        let clock = Clock()
        let gate = SelectionLoadGate(uptime: { clock.now })
        XCTAssertFalse(gate.noteSelection())
        clock.now += SelectionLoadGate.burstGap * 2
        XCTAssertFalse(gate.noteSelection(), "a selection after a quiet moment")
        clock.now += SelectionLoadGate.burstGap / 2
        XCTAssertTrue(gate.noteSelection(), "a quick second selection")
    }

    /// Waiters stay while selections keep coming, then the tab on screen goes first and the
    /// passed-over tabs follow one at a time.
    func testBurstReleasesShownTabFirstThenOneAtATime() async throws {
        let clock = Clock()
        let gate = SelectionLoadGate(uptime: { clock.now })
        let a = SidebarFixture.id(1), b = SidebarFixture.id(2), c = SidebarFixture.id(3)
        var shown = c
        gate.isOnScreen = { $0 == shown }
        var admitted: [UUID] = []
        _ = gate.noteSelection()
        for id in [a, b, c] {
            XCTAssertTrue(gate.noteSelection() || id == a)
            Task { await gate.admit(id, inBurst: true); admitted.append(id) }
        }
        for _ in 0..<50 where gate.waitingCount < 3 { await Task.yield() }
        XCTAssertEqual(gate.waitingCount, 3)
        XCTAssertEqual(admitted, [], "nothing is made during the burst")

        clock.now += SelectionLoadGate.burstGap * 2
        for _ in 0..<500 where admitted.count < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(admitted, [c, a], "the tab on screen, then the first passed-over tab")
        shown = a
        gate.finished(a)
        for _ in 0..<500 where admitted.count < 3 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(admitted, [c, a, b], "the next passed-over tab, after the previous one was made")
    }

    func testStopLetsEveryWaiterGo() async {
        let gate = SelectionLoadGate()
        var done = 0
        _ = gate.noteSelection()
        _ = gate.noteSelection()
        let task = Task { await gate.admit(SidebarFixture.id(1), inBurst: true); done += 1 }
        for _ in 0..<50 where gate.waitingCount < 1 { await Task.yield() }
        gate.stop()
        await task.value
        XCTAssertEqual(done, 1)
        await gate.admit(SidebarFixture.id(2), inBurst: true)
    }

    /// End to end with the FakeEngine: quick selections leave every selected tab with one engine
    /// tab once things settle, the shown one included.
    func testQuickSelectionsAllGetTheirEngineTabs() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let ids = SidebarIDSource()
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now }, makeID: { ids.make() },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: f.home))
        defer { model.stop(); controller.stop() }
        for id in [f.today1, f.today2, f.today3] { model.sidebar.selectTab(id) }
        XCTAssertEqual(model.selectedTabID, f.today3)
        await model.sidebar.settleEngineWork()
        for id in [f.today1, f.today2, f.today3] { XCTAssertNotNil(controller.liveTab(for: id)) }
        XCTAssertEqual(engine.tabIDs.count, 3)
    }
}
