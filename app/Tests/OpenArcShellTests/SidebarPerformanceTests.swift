import XCTest
import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcImport
import OpenArcPersistence
@testable import OpenArcShell

/// A large imported Space (≈ 2000 bookmarks in nested folders, as a Chrome import makes them),
/// for the sidebar's performance. Ids and times are deterministic.
enum LargeWorkspaceFixture {
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// A Chrome-like bookmark tree: `topFolders` folders on the bar, each holding `perFolder`
    /// bookmarks and `subfolders` subfolders of `perSubfolder` bookmarks, plus `topBookmarks`
    /// loose bookmarks on the bar and an "Other bookmarks" root.
    static func tree(topFolders: Int = 20, perFolder: Int = 50, subfolders: Int = 2, perSubfolder: Int = 20,
                     topBookmarks: Int = 100, other: Int = 100) -> BookmarkTree {
        var serial = 0
        func bookmark() -> BookmarkNode {
            serial += 1
            return .bookmark(Bookmark(title: "Bookmark \(serial) with a reasonably long title", url: "https://site\(serial % 400).example.com/page/\(serial)"))
        }
        var bar: [BookmarkNode] = []
        for f in 0..<topFolders {
            var children = (0..<perFolder).map { _ in bookmark() }
            for s in 0..<subfolders {
                children.append(.folder(BookmarkFolder(title: "Sub \(f).\(s)", children: (0..<perSubfolder).map { _ in bookmark() })))
            }
            bar.append(.folder(BookmarkFolder(title: "Folder \(f)", children: children)))
        }
        bar += (0..<topBookmarks).map { _ in bookmark() }
        return BookmarkTree(bar: bar, other: (0..<other).map { _ in bookmark() })
    }

    /// A workspace with one profile, a small "Home" Space and the imported Space.
    static func make(tree: BookmarkTree = tree()) -> (workspace: WorkspaceState, home: UUID, imported: UUID) {
        var counter = 100
        func makeID() -> UUID {
            counter += 1
            return SidebarFixture.id(counter)
        }
        let profile = makeID(), home = makeID()
        var ws = TreeOps.createProfile(WorkspaceState(), id: profile, name: "Default", now: now)
        do {
            ws = try TreeOps.createSpace(ws, id: home, profileID: profile, name: "Home", now: now)
            ws = try TreeOps.openTab(ws, id: makeID(), spaceID: home, url: URL(string: "https://home.example.com"), title: "Home", now: now)
            let result = try BookmarkImportMapper.apply(tree, to: ws, source: "Chrome", profileID: profile, afterSpaceID: home,
                                                        theme: nil, now: now, makeID: makeID)
            ws = result.state
            guard let imported = result.summary.spaceID else { fatalError("no imported Space") }
            ws = try TreeOps.openTab(ws, id: makeID(), spaceID: imported, url: URL(string: "https://today.example.com"), title: "Today", now: now)
            return (ws, home, imported)
        } catch {
            fatalError("large fixture is invalid: \(error)")
        }
    }
}

/// Wall-clock timing for the benchmark: the median of `runs` runs, in milliseconds.
@MainActor
func benchmarkMedian(_ runs: Int = 5, _ body: () -> Void) -> Double {
    var samples: [Double] = []
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    return samples.sorted()[samples.count / 2]
}

/// Sidebar cost with a ≈ 2000-item imported Space (bug report: scrolling such a Space lagged and
/// slowed the whole app). Prints the timings; the bounds are generous regression guards.
@MainActor
final class SidebarPerformanceTests: XCTestCase {
    private func makeViewModel() -> (SidebarViewModel, UUID) {
        let fixture = LargeWorkspaceFixture.make()
        var counter = 50_000
        let vm = SidebarViewModel(engine: FakeEngine(), workspace: fixture.workspace, selectedSpaceID: fixture.imported,
                                  now: { LargeWorkspaceFixture.now }, makeID: { counter += 1; return SidebarFixture.id(counter) })
        addTeardownBlock { @MainActor in vm.stop() }
        return (vm, fixture.imported)
    }

    private func report(_ name: String, _ ms: Double) {
        print(String(format: "[perf] %@: %.2f ms", name, ms))
    }

    func testLargeSpaceModelCosts() {
        let tree = LargeWorkspaceFixture.tree()
        report("import mapping (\(tree.bookmarkCount) bookmarks)", benchmarkMedian(1) { _ = LargeWorkspaceFixture.make(tree: tree) })
        let (vm, _) = makeViewModel()
        let snap = vm.snapshot
        print("[perf] rows: pinned \(snap.pinned.count), today \(snap.today.count), tabs \(vm.workspace.tabs.count), folders \(vm.workspace.folders.count)")
        report("snapshot (memoized)", benchmarkMedian { _ = vm.snapshot })
        report("SidebarSnapshot.make", benchmarkMedian {
            _ = SidebarSnapshot.make(workspace: vm.workspace, spaceID: vm.selectedSpaceID, profileID: vm.currentProfileID)
        })
        let ids = snap.pinned.compactMap { item -> UUID? in if case .tab(let t) = item.kind { return t.id } else { return nil } }
        var index = 0
        report("selectTab", benchmarkMedian {
            vm.selectTab(ids[index % ids.count]); index += 7
        })
        report("hoverBegan+hoverEnded", benchmarkMedian {
            vm.hoverBegan(ids[index % ids.count]); vm.hoverEnded(ids[index % ids.count]); index += 3
        })
        let old = vm.workspace
        var changed = old
        changed.tabs[ids[0]]?.lastActiveAt = Date(timeIntervalSince1970: 2_000_000_000)
        report("WorkspaceDiff.changes (1 change)", benchmarkMedian { _ = WorkspaceDiff.changes(from: old, to: changed) })
        report("workspace == (1 change)", benchmarkMedian { _ = old == changed })
        // A page title arriving (the live tab's content mirrored into the record): one commit.
        var serial = 0
        report("controller commit (title change)", benchmarkMedian {
            serial += 1
            try? vm.controller.mutate(origin: nil) {
                try TreeOps.updateTabContent($0, id: ids[1], url: URL(string: "https://example.com/\(serial)"), title: "T\(serial)", faviconURL: nil, now: LargeWorkspaceFixture.now)
            }
            _ = vm.snapshot
        })
    }

    /// Writes the large workspace as a data directory for a manual check of the real app
    /// (`OPENARC_DATA_DIR=<dir> "Open Arc Dev perf.app/Contents/MacOS/..."`). Runs only with
    /// `OPENARC_PERF_FIXTURE_DIR` set.
    func testWriteLargeWorkspaceFixture() async throws {
        guard let path = ProcessInfo.processInfo.environment["OPENARC_PERF_FIXTURE_DIR"] else {
            throw XCTSkip("set OPENARC_PERF_FIXTURE_DIR to write the fixture")
        }
        let store = WorkspaceStore(directory: URL(fileURLWithPath: path, isDirectory: true), autosaveDelay: 3600)
        let fixture = LargeWorkspaceFixture.make()
        await store.update(fixture.workspace)
        try await store.flush()
        // One window on the imported Space, onboarding done.
        let window = WindowUIState(selectedSpaceID: fixture.imported)
        try UIStateFile.save(UIState(selectedSpaceID: fixture.imported, windows: [window], onboardingCompleted: true),
                             to: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Saving the large workspace (`WorkspaceStore` writes off the main thread; this is its cost).
    func testLargeWorkspaceSaveCost() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("openarc-perf-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LargeWorkspaceFixture.make()
        let store = WorkspaceStore(directory: directory, autosaveDelay: 3600)
        await store.update(fixture.workspace)
        let start = DispatchTime.now().uptimeNanoseconds
        try await store.flush()
        report("WorkspaceStore flush (off main)", Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        let size = (try? FileManager.default.attributesOfItem(atPath: store.workspaceFileURL.path)[.size] as? Int) ?? 0
        print("[perf] workspace.json \(size / 1024) KB")

        // A remote batch with every tab of the import (the first sync of another device's import,
        // or a re-fetch): the store applies and writes it off the main thread, then the controller
        // merges the changed records on the main thread.
        let controller = WorkspaceController(dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), persistence: store),
                                             workspace: fixture.workspace, now: { LargeWorkspaceFixture.now },
                                             notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker())
        defer { controller.stop() }
        let later = LargeWorkspaceFixture.now.addingTimeInterval(60)
        let upserts = fixture.workspace.tabs.values.map { tab -> SyncRecord in
            var remote = tab
            remote.title += " (remote)"
            remote.meta.stamp([TabNode.FieldGroup.content], at: later)
            return .tab(remote)
        }
        // Let the controller subscribe first.
        try await Task.sleep(nanoseconds: 200_000_000)
        let mergeStart = DispatchTime.now().uptimeNanoseconds
        try await store.apply(RemoteChangeBatch(upserts: upserts))
        let applied = Double(DispatchTime.now().uptimeNanoseconds - mergeStart) / 1e6
        var merged = false
        for _ in 0..<500 where !merged {
            await Task.yield()
            merged = controller.workspace.tabs.values.allSatisfy { $0.title.hasSuffix("(remote)") }
            if !merged { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        report("remote batch of \(upserts.count) tabs: store apply + write (off main)", applied)
        report("remote batch of \(upserts.count) tabs: until shown", Double(DispatchTime.now().uptimeNanoseconds - mergeStart) / 1e6)
        XCTAssertTrue(merged, "the remote titles reach the shown workspace")
    }

    func testLargeSpaceHostedSidebarCosts() {
        let (vm, _) = makeViewModel()
        hostedCosts(vm, label: "hosted")
    }

    /// The same measurements with the 9-row sample fixture: the floor the large Space is compared with.
    func testSmallSpaceHostedSidebarCosts() {
        let (vm, _) = makeSidebarViewModel()
        addTeardownBlock { @MainActor in vm.stop() }
        hostedCosts(vm, label: "small", sweeps: false)
    }

    private func hostedCosts(_ vm: SidebarViewModel, label: String, sweeps: Bool = true) {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 276, height: 985), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        let host = NSHostingView(rootView: SidebarView(viewModel: vm))
        host.frame = CGRect(x: 0, y: 0, width: 276, height: 985)
        func settle() {
            // Some updates land on a later run-loop pass: lay out, draw and run the loop a few times.
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                RunLoop.main.run(mode: .default, before: Date())
            }
        }
        report("\(label) first layout", benchmarkMedian(1) {
            window.contentView = host
            settle()
        })
        let ids = vm.snapshot.pinned.compactMap { item -> UUID? in if case .tab(let t) = item.kind { return t.id } else { return nil } }
            + vm.snapshot.today.map(\.id)
        var index = 0
        let select = benchmarkMedian(9) {
            vm.selectTab(ids[index % ids.count]); index += 7
            settle()
        }
        report("\(label) selectTab + layout", select)
        let hover = benchmarkMedian(9) {
            vm.hoverBegan(ids[index % ids.count]); index += 3
            settle()
        }
        report("\(label) hover publish + layout", hover)
        guard sweeps else { return }
        // Switching to the small Space and back (B99: the large Space's rows are reused; B101: its
        // page is kept built, so switching back only moves it).
        if let home = vm.dockSpaces.first(where: { $0.id != vm.selectedSpaceID })?.id, let large = vm.selectedSpaceID {
            let away = benchmarkMedian(1) { vm.selectSpace(home); settle() }
            report("\(label) switch to small Space", away)
            let back = benchmarkMedian(1) { vm.selectSpace(large); settle() }
            report("\(label) switch to large Space", back)
            // Kept pages: the median of further round trips, the slide's layer animation excluded.
            var toggles = 0
            let roundTrip = benchmarkMedian(9) {
                vm.selectSpace(toggles % 2 == 0 ? home : large); toggles += 1
                settle()
            }
            report("\(label) switch between kept Space pages", roundTrip)
            if toggles % 2 == 1 { vm.selectSpace(large); settle() }
            XCTAssertLessThan(back, 60, "switching back to a large Space")
            // B101: ≈ 3–5 ms in debug (was ≈ 8 ms to the small Space, and ≈ 4 ms back only because
            // the page then had no row band yet). Loose for a busy machine.
            XCTAssertLessThan(roundTrip, 25, "switching to a Space whose page is kept")
            XCTAssertEqual(vm.selectedSpaceID, large)
        }
        // Regression guards, loose enough for a debug build on a busy machine (B97 fix: from
        // ≈ 357 ms and ≈ 307 ms; B99: ≈ 30 → 10 ms and ≈ 6 → 0.05 ms in debug).
        XCTAssertLessThan(select, 60, "selecting a tab in a large Space")
        XCTAssertLessThan(hover, 10, "hovering a row in a large Space")

        let spaceID = vm.selectedSpaceID!
        let topBand = vm.listScrollState?.rowBands[spaceID]
        XCTAssertEqual(topBand?.lowerBound, 0, "rows are built from the top")
        XCTAssertLessThan(topBand?.upperBound ?? .infinity, 2_500, "only about two screens of rows exist, not \(vm.listGeometry.contentHeight) pt")
        guard let scroller = vm.listScroller, let metrics = scroller.metrics else {
            XCTFail("no list scroller")
            return
        }
        XCTAssertEqual(metrics.contentHeight, vm.listGeometry.contentHeight, accuracy: 1, "the content has the full list height")
        // The whole list top to bottom in 120 pt steps (a trackpad fling).
        var offset: CGFloat = 0
        var steps = 0
        let sweep = benchmarkMedian(1) {
            while offset < metrics.maxOffset {
                offset = min(offset + 120, metrics.maxOffset)
                scroller.scroll(toOffset: offset)
                settle()
                steps += 1
            }
        }
        report("\(label) scroll step (120 pt, mean of \(steps) over \(Int(metrics.contentHeight)) pt)", sweep / Double(max(steps, 1)))
        XCTAssertLessThan(sweep / Double(max(steps, 1)), 25, "one scroll step")
        XCTAssertEqual(scroller.metrics?.offset ?? 0, metrics.maxOffset, accuracy: 1)
        // The rows that exist moved with the scroll: the bottom of the list, not the top.
        let bottomBand = vm.listScrollState?.rowBands[spaceID]
        XCTAssertGreaterThan(bottomBand?.lowerBound ?? 0, 0, "the top rows are gone")
        XCTAssertGreaterThanOrEqual(bottomBand?.upperBound ?? 0, metrics.maxOffset + metrics.viewportHeight,
                                    "the bottom rows are built once scrolled there")
    }
}
