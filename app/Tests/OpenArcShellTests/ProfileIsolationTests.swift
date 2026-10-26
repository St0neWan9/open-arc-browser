import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// C11: which engine profile a tab's page lives in.
/// [03 §Profiles] observed: "Profiles help keep your data separate across Spaces — like history,
/// logins, cookies, and extensions. You can use any Profile across one or more Spaces." So a
/// Space's Profile decides the engine profile of its tabs (favorites: their own Profile).
/// [06 §16.3] observed: deleting a Profile "will permanently remove any cookies, history,
/// preferences, and logins that belong to this Profile". Inferred: a live tab cannot change
/// engine profile, so it is recreated (its page loads again by URL); incognito tabs of the
/// deleted Profile close before its data goes.
@MainActor
final class ProfileIsolationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let personal = SidebarFixture.id(901)
    private let personalSpace = SidebarFixture.id(902)
    private let personalTab = SidebarFixture.id(903)

    /// The sidebar fixture plus a second Profile with one Space and one Today tab.
    private func fixture() throws -> SidebarFixture {
        var f = SidebarFixture()
        f.ws = TreeOps.createProfile(f.ws, id: personal, name: "Personal", now: now)
        f.ws = try TreeOps.createSpace(f.ws, id: personalSpace, profileID: personal, name: "Personal", now: now)
        f.ws = try TreeOps.openTab(f.ws, id: personalTab, spaceID: personalSpace, url: URL(string: "https://personal.example"), title: "personal", now: now)
        return f
    }

    private func makeController(_ f: SidebarFixture, engine: FakeEngine) -> WorkspaceController {
        let deps = AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory())
        let fixed = now.addingTimeInterval(10)
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { fixed }, notificationCenter: NotificationCenter(),
            autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    /// [03 §Profiles]: tabs of a Space use the Space's Profile, favorites use their Profile.
    func testTabsUseTheirSpacesProfile() async throws {
        let f = try fixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let shell = window(controller, space: f.home)

        try await shell.activate(tabID: f.today1)
        try await shell.activate(tabID: f.fav1)
        shell.selectSpace(personalSpace)
        try await shell.activate(tabID: personalTab)

        XCTAssertEqual(controller.liveTab(for: f.today1)?.profileID, f.profile)
        XCTAssertEqual(controller.liveTab(for: f.fav1)?.profileID, f.profile)
        XCTAssertEqual(controller.liveTab(for: personalTab)?.profileID, personal)
    }

    /// Inferred (C11): moving a live tab to a Space of another Profile closes its engine tab and
    /// makes a new one in the other profile, loading the same URL. Moving within a Profile keeps it.
    func testMovingTabToSpaceOfOtherProfileRecreatesItsEngineTab() async throws {
        let f = try fixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let shell = window(controller, space: f.home)
        try await shell.activate(tabID: f.today1)
        let original = try XCTUnwrap(controller.liveTab(for: f.today1))

        // Same Profile: the engine tab stays.
        shell.sidebar.moveTab(f.today1, toSpace: f.work)
        await controller.settleEngineWork()
        XCTAssertTrue(controller.liveTab(for: f.today1) === original)

        // Other Profile: a new engine tab in that profile, the old one is gone.
        shell.sidebar.moveTab(f.today1, toSpace: personalSpace)
        await controller.settleEngineWork()
        let moved = try XCTUnwrap(controller.liveTab(for: f.today1))
        XCTAssertFalse(moved === original)
        XCTAssertEqual(moved.profileID, personal)
        XCTAssertFalse(engine.tabIDs.contains(original.id), "the old engine tab is closed")
        XCTAssertTrue(engine.tabIDs.contains(moved.id))
        let state = await moved.currentState()
        XCTAssertEqual(state.url, URL(string: "https://today1.example.com"), "the page loads again by URL")
        XCTAssertEqual(controller.liveState(for: f.today1)?.url, URL(string: "https://today1.example.com"))
    }

    /// Inferred (C11): a favorite moved to another Profile's favorites follows the same rule.
    func testFavoriteMovedToOtherProfileRecreatesItsEngineTab() async throws {
        let f = try fixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let shell = window(controller, space: f.home)
        try await shell.activate(tabID: f.fav1)
        let original = try XCTUnwrap(controller.liveTab(for: f.fav1))

        try controller.mutate(origin: nil) {
            try TreeOps.moveTab($0, id: f.fav1, to: .favorite(profileID: self.personal), position: .last, now: self.now)
        }
        await controller.settleEngineWork()
        let moved = try XCTUnwrap(controller.liveTab(for: f.fav1))
        XCTAssertFalse(moved === original)
        XCTAssertEqual(moved.profileID, personal)
        XCTAssertEqual(engine.tabIDs, [moved.id])
    }

    /// Inferred (C11, B14): an incognito window uses the off-the-record context of the Profile of
    /// the window's current Space.
    func testIncognitoWindowUsesCurrentSpacesProfileOffTheRecord() async throws {
        let f = try fixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let shell = window(controller, space: personalSpace)
        controller.windowDidBecomeActive(shell)

        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        let opened = try await incognito.openNewTab(url: URL(string: "https://secret.example"))
        let tabID = try XCTUnwrap(opened)
        let live = try XCTUnwrap(incognito.controller.liveTab(for: tabID))
        XCTAssertEqual(live.profileID, personal)
        XCTAssertEqual(engine.offTheRecordTabIDs, [live.id])
    }

    /// [06 §16.3]: deleting a Profile removes its engine data. Its archived favorites' engine tabs
    /// and the tabs of incognito windows opened on it close first (the engine refuses otherwise).
    func testDeletingProfileClosesItsTabsThenRemovesEngineData() async throws {
        var f = try fixture()
        f.ws = try TreeOps.moveTab(f.ws, id: personalTab, to: .favorite(profileID: personal), position: .last, now: now)
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let shell = window(controller, space: personalSpace)
        controller.windowDidBecomeActive(shell)
        try await shell.activate(tabID: personalTab)
        let incognito = ShellModel.window(for: BrowserWindowRequest(kind: .incognito), on: controller)
        addTeardownBlock { @MainActor in incognito.stop() }
        _ = try await incognito.openNewTab(url: URL(string: "https://secret.example"))
        XCTAssertEqual(engine.offTheRecordTabIDs.count, 1)

        // [06 §16.3] observed: only Profiles without Spaces can be deleted.
        shell.selectSpace(f.home)
        try controller.mutate(origin: nil) { try TreeOps.deleteSpace($0, id: self.personalSpace, now: self.now) }
        XCTAssertTrue(controller.deleteProfile(personal))
        await controller.settleEngineWork()

        XCTAssertEqual(engine.deletedProfileIDs, [personal])
        XCTAssertTrue(engine.offTheRecordTabIDs.isEmpty, "incognito tabs of the profile closed")
        XCTAssertNil(controller.liveTab(for: personalTab))
    }
}
