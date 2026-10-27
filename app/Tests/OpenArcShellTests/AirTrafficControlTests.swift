import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
@testable import OpenArcShell

/// B52: Air Traffic Control. [06 §25] observed: routes "URL Contains / Is equal to <text>" →
/// "Open in <Space | Most Recent Space | Little Arc>", a Default row, instant save; a link from
/// another app that a route matches switches the window to the route's Space.
@MainActor
final class AirTrafficControlTests: XCTestCase {
    private let link = URL(string: "https://example.net/?q=1")!
    private let other = URL(string: "https://elsewhere.example.org/")!
    private var suiteNames: [String] = []

    override func tearDown() async throws {
        for name in suiteNames { UserDefaults().removePersistentDomain(forName: name) }
        suiteNames = []
        try await super.tearDown()
    }

    private func makeController(_ f: SidebarFixture, preferences: AppPreferences) -> WorkspaceController {
        let deps = AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore(), preferences: preferences)
        var counter = 1_000
        let controller = WorkspaceController(
            dependencies: deps, workspace: f.ws, now: { f.now.addingTimeInterval(10) },
            makeID: { counter += 1; return SidebarFixture.id(counter) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID?) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private func sheetModel(_ preferences: AppPreferences, _ f: SidebarFixture) -> AirTrafficControlModel {
        var counter = 2_000
        let ws = f.ws
        return AirTrafficControlModel(preferences: preferences, workspace: { ws }, makeID: { counter += 1; return SidebarFixture.id(counter) })
    }

    // MARK: Matching [06 §25.3]

    /// [06 §25.3] Contains: the full URL contains the text (inferred); Is equal to: the full URL
    /// equals it. Empty text matches nothing (our choice).
    func testMatchTypes() {
        let contains = AirTrafficRoute(id: UUID(), match: .contains, pattern: "example.net")
        XCTAssertTrue(contains.matches(link))
        XCTAssertTrue(AirTrafficRoute(id: UUID(), pattern: "EXAMPLE.net").matches(link), "case-insensitive")
        XCTAssertFalse(contains.matches(other))
        let equal = AirTrafficRoute(id: UUID(), match: .isEqualTo, pattern: "https://example.net/?q=1")
        XCTAssertTrue(equal.matches(link))
        XCTAssertFalse(AirTrafficRoute(id: UUID(), match: .isEqualTo, pattern: "example.net").matches(link))
        XCTAssertFalse(AirTrafficRoute(id: UUID(), pattern: "  ").matches(link))
        XCTAssertEqual(AirTrafficMatch.allCases.map(\.title), ["Contains", "Is equal to"])
    }

    /// [06 §25.3] priority unknown; the first matching route in list order wins (inferred). No
    /// match: the Default row. Files ignore the rules.
    func testFirstRouteWinsThenDefault() {
        let f = SidebarFixture()
        let rules = AirTrafficRules(routes: [
            AirTrafficRoute(id: UUID(), pattern: "example.net", target: .space(f.work)),
            AirTrafficRoute(id: UUID(), pattern: "example", target: .littleArc),
        ], defaultTarget: .littleArc)
        XCTAssertEqual(rules.destination(for: link, in: f.ws), .space(f.work))
        XCTAssertEqual(rules.destination(for: other, in: f.ws), .littleArc)
        XCTAssertEqual(rules.destination(for: URL(string: "https://unmatched.test/")!, in: f.ws), .littleArc)
        XCTAssertEqual(rules.destination(for: URL(fileURLWithPath: "/tmp/example.net.pdf"), in: f.ws), .frontmostWindow)
        let mostRecent = AirTrafficRules(routes: [], defaultTarget: .mostRecentSpace)
        XCTAssertEqual(mostRecent.destination(for: link, in: f.ws), .frontmostWindow)
    }

    /// [06 §25.4] a deleted target Space is unknown; the link falls back to the frontmost window
    /// (inferred).
    func testDeletedSpaceFallsBackToFrontmostWindow() throws {
        let f = SidebarFixture()
        let ws = try TreeOps.deleteSpace(f.ws, id: f.work, now: f.now.addingTimeInterval(5))
        let rules = AirTrafficRules(routes: [AirTrafficRoute(id: UUID(), pattern: "example.net", target: .space(f.work))])
        XCTAssertEqual(rules.destination(for: link, in: ws), .frontmostWindow)
    }

    // MARK: Sheet [06 §25.2]

    /// [06 §25.2] "New Route" appends Contains / empty / Most Recent Space at the end; edits and ⊖
    /// save at once (a new model on the same preferences sees them).
    func testNewRouteDefaultsAndInstantSave() throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        let sheet = sheetModel(preferences, f)
        let first = sheet.addRoute()
        let second = sheet.addRoute()
        XCTAssertEqual(sheet.routes.map(\.id), [first, second], "appended at the end")
        let fresh = try XCTUnwrap(sheet.routes.last)
        XCTAssertEqual(fresh.match, .contains)
        XCTAssertEqual(fresh.pattern, "")
        XCTAssertEqual(fresh.target, .mostRecentSpace)

        sheet.setPattern("example.net", for: first)
        sheet.setMatch(.isEqualTo, for: first)
        sheet.setTarget(.space(f.work), for: first)
        sheet.removeRoute(second)

        let reopened = sheetModel(preferences, f)
        XCTAssertEqual(reopened.routes, [AirTrafficRoute(id: first, match: .isEqualTo, pattern: "example.net", target: .space(f.work))])
    }

    /// [06 §25.2] the "Open in" and "Default" menus: every Space in sidebar order (non-Default
    /// profile in parentheses), then Most Recent Space, then Little Arc.
    func testTargetMenuOptions() throws {
        var f = SidebarFixture()
        let otherProfile = SidebarFixture.id(90), side = SidebarFixture.id(91)
        f.ws.profiles[otherProfile] = Profile(id: otherProfile, name: "Side", now: f.now.addingTimeInterval(1))
        f.ws = try TreeOps.createSpace(f.ws, id: side, profileID: otherProfile, name: "Lab", now: f.now)
        let sheet = sheetModel(.inMemory(), f)
        let order = f.ws.allLiveSpaces.map(\.id)
        XCTAssertEqual(Set(order), [f.home, f.work, side])
        let names: [UUID: String] = [f.home: "Home", f.work: "Work", side: "Lab (Side)"]
        XCTAssertEqual(sheet.options().map(\.title), order.compactMap { names[$0] } + ["Most Recent Space", "Little Arc"])
        XCTAssertEqual(sheet.options().map(\.target), order.map { AirTrafficTarget.space($0) } + [.mostRecentSpace, .littleArc])
    }

    /// [06 §25.2] the Default row and the Little Arc toggle ([03 §Links]) are one setting
    /// (inferred link): Default Little Arc ⇔ toggle on.
    func testDefaultRowFollowsLittleArcToggle() {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        XCTAssertEqual(preferences.airTrafficDefaultTarget, .mostRecentSpace)
        preferences.opensExternalLinksInLittleArc = true
        let sheet = sheetModel(preferences, f)
        XCTAssertEqual(sheet.defaultTarget, .littleArc)
        sheet.setDefaultTarget(.space(f.work))
        XCTAssertFalse(preferences.opensExternalLinksInLittleArc)
        XCTAssertEqual(preferences.airTrafficDefaultTarget, .space(f.work))
        sheet.setDefaultTarget(.littleArc)
        XCTAssertTrue(preferences.opensExternalLinksInLittleArc)
    }

    /// Routes persist in the preferences suite (per device; [03 §对复刻的含义] Links is app level).
    func testRoutesPersistInSuite() throws {
        let suite = "org.openarc.tests.b52.\(UUID().uuidString)"
        suiteNames.append(suite)
        let f = SidebarFixture()
        let route = AirTrafficRoute(id: UUID(), pattern: "example.net", target: .space(f.work))
        AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).airTrafficRoutes = [route]
        AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))).airTrafficDefaultTarget = .space(f.home)
        let reread = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(reread.airTrafficRoutes, [route])
        XCTAssertEqual(reread.airTrafficDefaultTarget, .space(f.home))
    }

    // MARK: Routing [06 §25.3]

    /// [06 §25.3] observed: "Contains example.net → Space": a link from another app switches the
    /// window (showing another Space) to that Space; the link becomes the top, selected Today tab.
    func testRouteSwitchesWindowToTargetSpace() throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.opensExternalLinksInLittleArc = true // a route beats the Default (Little Arc)
        preferences.airTrafficRoutes = [AirTrafficRoute(id: UUID(), pattern: "example.net", target: .space(f.work))]
        let controller = makeController(f, preferences: preferences)
        var littleArcs: [UUID] = []
        controller.openLittleArcWindow = { littleArcs.append($0) }
        let model = window(controller, space: f.home)

        controller.openExternal([link])

        XCTAssertEqual(model.selectedSpaceID, f.work)
        let top = try XCTUnwrap(controller.workspace.today(spaceID: f.work).first)
        XCTAssertEqual(top.url, link)
        XCTAssertEqual(model.selectedTabID, top.id)
        XCTAssertEqual(littleArcs, [], "not Little Arc")

        // A link no route matches follows the Default row: Little Arc.
        controller.openExternal([other])
        XCTAssertEqual(littleArcs.count, 1)
    }

    /// [06 §25.2] a route to Little Arc opens a Little Arc window; Default Most Recent Space keeps
    /// the window's Space.
    func testRouteToLittleArcAndDefaultMostRecent() throws {
        let f = SidebarFixture()
        let preferences = AppPreferences.inMemory()
        preferences.airTrafficRoutes = [AirTrafficRoute(id: UUID(), match: .isEqualTo, pattern: link.absoluteString, target: .littleArc)]
        let controller = makeController(f, preferences: preferences)
        var littleArcs: [UUID] = []
        controller.openLittleArcWindow = { littleArcs.append($0) }
        let model = window(controller, space: f.home)

        controller.openExternal([link, other])

        XCTAssertEqual(littleArcs.count, 1)
        XCTAssertEqual(model.selectedSpaceID, f.home)
        XCTAssertEqual(controller.workspace.today(spaceID: f.home).first?.url, other)
    }
}
