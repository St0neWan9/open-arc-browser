import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Hand-driven ticker: tests call `fire()` instead of waiting an hour.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class ManualTicker: AutoArchiveTicker, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [AsyncStream<Void>.Continuation] = []
    private var intervals: [TimeInterval] = []

    var requestedIntervals: [TimeInterval] { lock.withLock { intervals } }

    func ticks(every interval: TimeInterval) -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock(); defer { lock.unlock() }
            intervals.append(interval)
            continuations.append(continuation)
        }
    }

    func fire() {
        lock.lock(); let current = continuations; lock.unlock()
        current.forEach { $0.yield() }
    }
}

/// Auto-archive. Spec: [05 §window and app entry points] observed (archived after 12 hours by
/// default), [03 §archive setting] observed ("Archive tabs after", default 12 hours).
@MainActor
final class AutoArchiveTests: XCTestCase {
    private let hour: TimeInterval = 3600

    /// Builds a view model whose clock is `fixture.now + elapsed`; all fixture tabs were last
    /// active at `fixture.now`.
    private func makeVM(elapsed: TimeInterval, _ f: SidebarFixture = SidebarFixture()) -> SidebarViewModel {
        SidebarViewModel(
            engine: FakeEngine(),
            workspace: f.ws,
            selectedSpaceID: f.home,
            now: { f.now.addingTimeInterval(elapsed) },
            makeID: { UUID() }
        )
    }

    private func isArchived(_ vm: SidebarViewModel, _ id: UUID) -> Bool {
        vm.workspace.tabs[id]?.meta.isTombstone == true && vm.workspace.archive[id]?.reason == .autoArchived
    }

    /// [03 §archive setting] observed: the default lifetime is 12 hours.
    func testDefaultLifetimeIsTwelveHours() {
        XCTAssertEqual(ArchivePolicy.defaultTodayLifetime, 12 * hour)
        XCTAssertEqual(makeVM(elapsed: 0).workspace.todayLifetime(forSpace: SidebarFixture().home), 12 * hour)
    }

    /// [05 §window and app entry points] observed: Today tabs idle longer than 12 h are archived.
    func testIdleTodayTabsAreArchivedAfterTwelveHours() async {
        let f = SidebarFixture()
        let vm = makeVM(elapsed: 12 * hour + 1, f)
        let archived = vm.runAutoArchive()
        XCTAssertEqual(Set(archived), [f.today1, f.today2, f.today3, f.workTab])
        for id in archived { XCTAssertTrue(isArchived(vm, id)) }
        XCTAssertTrue(vm.snapshot.today.isEmpty)
        vm.stop()
    }

    /// [05 §window and app entry points] observed: tabs idle less than 12 h are kept.
    func testRecentTodayTabsAreKept() {
        let f = SidebarFixture()
        let vm = makeVM(elapsed: 12 * hour - 1, f)
        XCTAssertTrue(vm.runAutoArchive().isEmpty)
        XCTAssertEqual(vm.workspace, f.ws)
        XCTAssertEqual(vm.snapshot.today.count, 3)
    }

    /// [05 §window and app entry points] observed: only Today tabs expire; pinned tabs and
    /// favorites never do.
    func testPinnedAndFavoritesAreNeverArchived() {
        let f = SidebarFixture()
        let vm = makeVM(elapsed: 1_000 * hour, f)
        vm.runAutoArchive()
        for id in [f.pinnedTab, f.inFolderTab, f.deepTab, f.fav1, f.fav2] {
            XCTAssertEqual(vm.workspace.tabs[id]?.meta.isTombstone, false, "\(id) must survive")
            XCTAssertNil(vm.workspace.archive[id])
        }
    }

    /// inferred: the tab being looked at is not pulled, even when it is past its lifetime. It is
    /// excluded from the pass (`TreeOps.autoArchive(excluding:)`); the pass does not touch its
    /// activity clock or stamp it.
    func testSelectedTabIsKept() async throws {
        let f = SidebarFixture()
        let vm = makeVM(elapsed: 20 * hour, f)
        vm.selectTab(f.today2)
        await vm.settleEngineWork()
        let before = try XCTUnwrap(vm.workspace.tabs[f.today2])
        let archived = vm.runAutoArchive()
        XCTAssertFalse(archived.contains(f.today2))
        XCTAssertEqual(vm.selectedTabID, f.today2)
        XCTAssertEqual(vm.workspace.tabs[f.today2], before, "the pass writes nothing to the selected tab")
        XCTAssertTrue(isArchived(vm, f.today1))
        XCTAssertNotNil(vm.liveTab(for: f.today2))
        vm.stop()
    }

    /// inferred: a split shows every member on screen, so the selected tab's split partners are
    /// kept with it ([06 §5] observed: the panes of a split are one group).
    func testSelectedTabsSplitPartnersAreKept() async throws {
        var f = SidebarFixture()
        f.ws = try TreeOps.addSplitPane(f.ws, layoutID: SidebarFixture.id(900), existingTabID: f.today1, newTabID: f.today2, now: f.now)
        let vm = makeVM(elapsed: 20 * hour, f)
        vm.selectTab(f.today2)
        await vm.settleEngineWork()
        let partner = try XCTUnwrap(vm.workspace.tabs[f.today1])
        let archived = vm.runAutoArchive()
        XCTAssertEqual(Set(archived), [f.today3, f.workTab])
        XCTAssertEqual(vm.workspace.tabs[f.today1], partner, "the partner is neither archived nor stamped")
        XCTAssertEqual(vm.workspace.splits[SidebarFixture.id(900)]?.meta.isTombstone, false)
        vm.stop()
    }

    /// Archived tabs lose their live engine tab; the selection stays on the (kept) selected tab.
    func testArchivedTabsCloseTheirLiveEngineTabs() async {
        final class Clock { var offset: TimeInterval = 0 }
        let clock = Clock()
        let f = SidebarFixture()
        let vm = SidebarViewModel(
            engine: FakeEngine(), workspace: f.ws, selectedSpaceID: f.home,
            now: { f.now.addingTimeInterval(clock.offset) }, makeID: { UUID() }
        )
        vm.selectTab(f.today1)
        await vm.settleEngineWork()
        vm.selectTab(f.fav1)
        await vm.settleEngineWork()
        XCTAssertNotNil(vm.liveTab(for: f.today1))
        clock.offset = 13 * 3600
        let archived = vm.runAutoArchive()
        await vm.settleEngineWork()
        XCTAssertTrue(archived.contains(f.today1))
        XCTAssertNil(vm.liveTab(for: f.today1))
        XCTAssertEqual(vm.selectedTabID, f.fav1)
        vm.stop()
    }

    /// A lifetime override replaces every profile's setting.
    func testLifetimeOverride() {
        let f = SidebarFixture()
        let vm = makeVM(elapsed: 7 * hour, f)
        XCTAssertTrue(vm.runAutoArchive().isEmpty)
        XCTAssertEqual(vm.runAutoArchive(lifetimeOverride: 6 * hour).count, 4)
    }

    /// [03 §Profiles] observed: "Archive tabs after" is a per-profile setting. Changing it through
    /// the sidebar (TreeOps) changes what the next pass archives.
    func testProfileLifetimeSettingDrivesAutoArchive() {
        let f = SidebarFixture()
        let vm = makeVM(elapsed: 7 * hour, f)
        XCTAssertTrue(vm.updateProfileSettings(f.profile, ProfileSettings(todayLifetime: 6 * hour)))
        XCTAssertEqual(Set(vm.runAutoArchive()), [f.today1, f.today2, f.today3, f.workTab])
    }

    // MARK: Scheduler

    /// Waits for `condition` using a bounded number of main-actor yields.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// [05 §window and app entry points] inferred cadence: runs at launch, then on every tick.
    func testSchedulerFiresAtStartAndOnTicks() async {
        let ticker = ManualTicker()
        var runs = 0
        let scheduler = AutoArchiveScheduler(ticker: ticker) { runs += 1 }
        scheduler.start()
        XCTAssertEqual(runs, 1)
        XCTAssertTrue(scheduler.isRunning)
        XCTAssertEqual(ticker.requestedIntervals, [AutoArchiveScheduler.defaultInterval])
        ticker.fire()
        let afterOne = await eventually { runs == 2 }
        XCTAssertTrue(afterOne)
        ticker.fire()
        let afterTwo = await eventually { runs == 3 }
        XCTAssertTrue(afterTwo)
        scheduler.stop()
    }

    func testStartTwiceDoesNotDoubleRun() {
        let ticker = ManualTicker()
        var runs = 0
        let scheduler = AutoArchiveScheduler(ticker: ticker) { runs += 1 }
        scheduler.start()
        scheduler.start()
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(ticker.requestedIntervals.count, 1)
        scheduler.stop()
    }

    func testStopCancelsFurtherTicks() async {
        let ticker = ManualTicker()
        var runs = 0
        let scheduler = AutoArchiveScheduler(ticker: ticker) { runs += 1 }
        scheduler.start()
        ticker.fire()
        let fired = await eventually { runs == 2 }
        XCTAssertTrue(fired)
        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning)
        ticker.fire()
        for _ in 0..<100 { await Task.yield() }
        XCTAssertEqual(runs, 2)
    }

    /// The shell archives expired tabs at launch and `stop()` ends the scheduler.
    func testShellRunsAutoArchiveAtLaunch() {
        let old = Date(timeIntervalSince1970: 0)
        let model = ShellModel(
            dependencies: .fake(),
            workspace: .demo(now: old),
            now: { old.addingTimeInterval(13 * 3600) }
        )
        let spaceID = model.selectedSpaceID!
        XCTAssertTrue(model.workspace.today(spaceID: spaceID).isEmpty)
        XCTAssertFalse(model.workspace.archive.isEmpty)
        model.stop()
    }
}

/// Restore from the archive. Spec: [02 §tabs and sidebar] observed (Restore Last Closed Tab, ⇧⌘T),
/// [01 §File] observed (menu item), [06 §8] observed (Library Archived Tabs). Which items count as
/// "closed" and which space receives the tab are inferred.
@MainActor
final class RestoreArchivedTests: XCTestCase {
    /// Mutable clock so each close gets a distinct `archivedAt`.
    private final class Clock { var now: Date; init(_ d: Date) { now = d }; func tick() { now = now.addingTimeInterval(60) } }

    private func makeVM(_ f: SidebarFixture, clock: Clock, selected: UUID? = nil) -> SidebarViewModel {
        SidebarViewModel(engine: FakeEngine(), workspace: f.ws, selectedSpaceID: selected ?? f.home, now: { clock.now }, makeID: { UUID() })
    }

    /// [06 §8] inferred: restore opens a new tab at the top of Today, selects it and tombstones the item.
    func testRestoreOpensAtTopOfTodayAndTombstonesItem() async throws {
        let f = SidebarFixture(); let clock = Clock(f.now)
        let vm = makeVM(f, clock: clock)
        clock.tick(); vm.closeTab(f.today2)
        clock.tick()
        let newID = try XCTUnwrap(vm.restoreArchived(f.today2))
        XCTAssertNotEqual(newID, f.today2)
        XCTAssertEqual(vm.snapshot.today.first?.id, newID)
        XCTAssertEqual(vm.workspace.tabs[newID]?.url, URL(string: "https://today2.example.com"))
        XCTAssertEqual(vm.selectedTabID, newID)
        XCTAssertEqual(vm.workspace.archive[f.today2]?.meta.isTombstone, true)
        XCTAssertNil(vm.restoreArchived(f.today2), "an item restores only once")
        await vm.settleEngineWork(); vm.stop()
    }

    /// Inferred: the tab goes back to the space it came from when that space is live.
    func testRestoreGoesToSourceSpace() throws {
        let f = SidebarFixture(); let clock = Clock(f.now)
        let vm = makeVM(f, clock: clock, selected: f.work)
        vm.selectSpace(f.home); vm.closeTab(f.today1)
        vm.selectSpace(f.work)
        let newID = try XCTUnwrap(vm.restoreArchived(f.today1))
        XCTAssertEqual(vm.workspace.tabs[newID]?.location.spaceID, f.home)
        XCTAssertEqual(vm.selectedSpaceID, f.home)
        vm.stop()
    }

    /// Inferred: a deleted source space falls back to the current space.
    func testRestoreFallsBackToCurrentSpaceWhenSourceDeleted() throws {
        var f = SidebarFixture(); let clock = Clock(f.now)
        f.ws = try TreeOps.archiveTab(f.ws, id: f.workTab, reason: .closed, now: f.now)
        var work = try XCTUnwrap(f.ws.spaces[f.work])
        work.meta.markDeleted(at: f.now)
        f.ws.spaces[f.work] = work
        let vm = makeVM(f, clock: clock)
        let newID = try XCTUnwrap(vm.restoreArchived(f.workTab))
        XCTAssertEqual(vm.workspace.tabs[newID]?.location.spaceID, f.home)
        vm.stop()
    }

    /// [02 §tabs and sidebar] observed (⇧⌘T): restores the latest closed tab; repeated presses go
    /// back through older ones in order.
    func testRestoreLastClosedTabWalksBackInOrder() throws {
        let f = SidebarFixture(); let clock = Clock(f.now)
        let vm = makeVM(f, clock: clock)
        clock.tick(); vm.closeTab(f.today1)
        clock.tick(); vm.closeTab(f.today2)
        clock.tick(); vm.closeTab(f.today3)
        XCTAssertTrue(vm.canRestoreLastClosedTab)
        let urls = (0..<3).compactMap { _ -> URL? in
            clock.tick()
            return vm.restoreLastClosedTab().flatMap { vm.workspace.tabs[$0]?.url }
        }
        XCTAssertEqual(urls.map(\.absoluteString), ["http://today3.example.com", "https://today2.example.com", "https://today1.example.com"])
        XCTAssertFalse(vm.canRestoreLastClosedTab)
        vm.stop()
    }

    /// Inferred: auto-archived and cleared items are not "closed", so ⇧⌘T skips them.
    func testRestoreLastClosedTabIgnoresNonClosedReasons() throws {
        var f = SidebarFixture(); let clock = Clock(f.now)
        f.ws = try TreeOps.archiveTab(f.ws, id: f.today1, reason: .closed, now: f.now.addingTimeInterval(10))
        f.ws = try TreeOps.archiveTab(f.ws, id: f.today2, reason: .autoArchived, now: f.now.addingTimeInterval(20))
        f.ws = try TreeOps.archiveTab(f.ws, id: f.today3, reason: .clearedToday, now: f.now.addingTimeInterval(30))
        let vm = makeVM(f, clock: clock)
        let newID = try XCTUnwrap(vm.restoreLastClosedTab())
        XCTAssertEqual(vm.workspace.tabs[newID]?.url, URL(string: "https://today1.example.com"))
        XCTAssertNil(vm.restoreLastClosedTab())
        XCTAssertEqual(vm.workspace.archive[f.today2]?.meta.isTombstone, false, "auto-archived item stays archived")
        vm.stop()
    }

    /// Nothing to restore is a no-op.
    func testRestoreLastClosedTabWithEmptyArchiveIsNoOp() {
        let f = SidebarFixture(); let clock = Clock(f.now)
        let vm = makeVM(f, clock: clock)
        let before = vm.workspace
        XCTAssertFalse(vm.canRestoreLastClosedTab)
        XCTAssertNil(vm.restoreLastClosedTab())
        XCTAssertEqual(vm.workspace, before)
        XCTAssertNil(vm.restoreArchived(UUID()))
        vm.stop()
    }

    /// [05 §command bar] inferred: the shell routes `.restoreArchived` to the sidebar and closes the bar.
    func testShellRoutesRestoreArchivedAction() throws {
        let t0 = Date(timeIntervalSince1970: 0)
        let model = ShellModel(dependencies: .fake(), workspace: .demo(now: t0), now: { t0 })
        let spaceID = try XCTUnwrap(model.selectedSpaceID)
        let tabID = try XCTUnwrap(model.workspace.today(spaceID: spaceID).first?.id)
        let url = model.workspace.tabs[tabID]?.url
        model.sidebar.closeTab(tabID)
        model.presentCommandBar(.newTab)
        model.perform(.restoreArchived(itemID: tabID))
        XCTAssertFalse(model.isCommandBarPresented)
        XCTAssertEqual(model.workspace.today(spaceID: spaceID).first?.url, url)
        XCTAssertEqual(model.workspace.archive[tabID]?.meta.isTombstone, true)
        XCTAssertEqual(model.selectedTabID, model.workspace.today(spaceID: spaceID).first?.id)
        model.stop()
    }
}
