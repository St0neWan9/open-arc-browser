import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// B67 (review F1 #5): a split that names a tab another device deleted is repaired when the
/// controller merges the remote batch (`mergeRemote` runs `TreeOps.repairSplits`), and the repair
/// is saved like any local edit. Spec: [06 §5] observed (one pane left is a single page; a split's
/// tabs are one sidebar group), [06 §21.6] observed (the ratio is relative); conflict policy:
/// delete wins (`OpenArcSyncAPI/ConflictPolicy.swift`). Applying it to remote deletes is inferred.
@MainActor
final class RemoteSplitRepairTests: XCTestCase {
    /// A unique directory under app/.build/b67-tmp, removed after each test.
    private nonisolated let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b67-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override nonisolated func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private let layoutID = SidebarFixture.id(700)

    private func makeController(_ ws: WorkspaceState, now: Date, store: WorkspaceStore) -> WorkspaceController {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), persistence: store, preferences: .inMemory())
        let fixed = now.addingTimeInterval(10)
        let controller = WorkspaceController(
            dependencies: deps, workspace: ws, now: { fixed }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func letBackgroundWorkRun(_ controller: WorkspaceController) async {
        await controller.sidebarSync.settle()
        for _ in 0..<300 { await Task.yield() }
    }

    /// Applies a remote tombstone of `tabID` to the store and waits until the controller merged it.
    private func deleteRemotely(_ tabID: UUID, at time: Date, store: WorkspaceStore, controller: WorkspaceController) async throws {
        var tab = try XCTUnwrap(controller.workspace.tabs[tabID])
        tab.meta.markDeleted(at: time)
        try await store.apply(RemoteChangeBatch(upserts: [.tab(tab)]))
        for _ in 0..<2_000 where controller.workspace.tabs[tabID]?.meta.isTombstone != true { await Task.yield() }
        XCTAssertEqual(controller.workspace.tabs[tabID]?.meta.isTombstone, true)
    }

    /// B67 acceptance: a remote tab tombstone merged into a two-pane split tombstones the layout;
    /// the other tab is a plain row again, and the repair reaches the store.
    func testRemoteDeleteEndsTwoPaneSplit() async throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today1, newTabID: f.today2, now: f.now)
        let store = WorkspaceStore(directory: directory)
        let controller = makeController(f.ws, now: f.now, store: store)
        await letBackgroundWorkRun(controller)
        let before = try XCTUnwrap(controller.workspace.tabs[f.today1])

        try await deleteRemotely(f.today2, at: f.now.addingTimeInterval(100), store: store, controller: controller)

        XCTAssertEqual(controller.workspace.splits[layoutID]?.meta.isTombstone, true, "delete wins")
        XCTAssertEqual(controller.workspace.tabs[f.today1], before, "the other tab is untouched")
        XCTAssertNil(SplitPaneLayout.activeLayout(in: controller.workspace, containing: f.today1))
        let rows = SidebarSnapshot.make(workspace: controller.workspace, spaceID: f.home, profileID: f.profile).today
        XCTAssertTrue(rows.contains { $0.id == f.today1 }, "a plain tab row")
        XCTAssertFalse(rows.contains { $0.id == layoutID }, "no split group row")

        try await store.flush()
        let saved = await store.workspace
        XCTAssertEqual(saved.splits[layoutID]?.meta.isTombstone, true, "the repair is saved")
    }

    /// B67: a three-pane split losing one pane remotely becomes a two-pane split with the
    /// remaining fractions renormalized in proportion. [06 §21.6] observed: the ratio is relative.
    func testRemoteDeleteShrinksThreePaneSplit() async throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today1, newTabID: f.today2, now: f.now)
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: layoutID, existingTabID: f.today2, newTabID: f.today3, now: f.now)
        f.ws = try TreeOps.setSplitFractions(f.ws, layoutID: layoutID, path: [], fractions: [0.2, 0.5, 0.3], now: f.now)
        let store = WorkspaceStore(directory: directory)
        let controller = makeController(f.ws, now: f.now, store: store)
        await letBackgroundWorkRun(controller)

        try await deleteRemotely(f.today2, at: f.now.addingTimeInterval(100), store: store, controller: controller)

        let layout = try XCTUnwrap(controller.workspace.splits[layoutID])
        XCTAssertFalse(layout.meta.isTombstone)
        guard case .split(_, let children) = layout.root else { return XCTFail("still a split") }
        XCTAssertEqual(children.map(\.node), [.pane(tabID: f.today1), .pane(tabID: f.today3)])
        XCTAssertEqual(children[0].fraction, 0.4, accuracy: 1e-9)
        XCTAssertEqual(children[1].fraction, 0.6, accuracy: 1e-9)
    }
}
