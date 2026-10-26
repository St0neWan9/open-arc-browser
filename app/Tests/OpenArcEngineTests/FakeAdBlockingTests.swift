import XCTest
import OpenArcModel
@testable import OpenArcEngine

/// Plan C16: the engine's ad blocker contract as FakeEngine implements it. [00 §A] "广告拦截":
/// the spec records a settings switch only; the per-site allow list and blocked count are
/// inferred.
final class FakeAdBlockingTests: XCTestCase {
    private let site = SiteOrigin(scheme: "https", host: "news.example")
    private let profile = UUID()

    func testDefaultsAreOnWithARuleset() async {
        let blocker = FakeEngine().adBlocking
        let version = await blocker.rulesetVersion()
        let enabled = await blocker.isEnabled()
        let siteEnabled = await blocker.isEnabled(forOrigin: site, profileID: profile)
        XCTAssertNotNil(version)
        XCTAssertTrue(enabled)
        XCTAssertTrue(siteEnabled)
    }

    func testAllowListIsPerSiteAndProfile() async {
        let engine = FakeEngine()
        let blocker = engine.adBlocking
        await blocker.setEnabled(false, forOrigin: site, profileID: profile)
        let allowed = await blocker.isEnabled(forOrigin: site, profileID: profile)
        let otherProfile = await blocker.isEnabled(forOrigin: site, profileID: UUID())
        let otherSite = await blocker.isEnabled(forOrigin: SiteOrigin(scheme: "https", host: "other.example"), profileID: profile)
        XCTAssertFalse(allowed)
        XCTAssertTrue(otherProfile)
        XCTAssertTrue(otherSite)
        // The allow list does not change the global switch, and the switch does not clear the list.
        await blocker.setEnabled(false)
        await blocker.setEnabled(true)
        let stillAllowed = await blocker.isEnabled(forOrigin: site, profileID: profile)
        XCTAssertFalse(stillAllowed)
        await blocker.setEnabled(true, forOrigin: site, profileID: profile)
        let removed = await blocker.isEnabled(forOrigin: site, profileID: profile)
        XCTAssertTrue(removed)
        XCTAssertEqual(engine.fakeAdBlockingService.changes,
                       ["site:news.example:off", "global:off", "global:on", "site:news.example:on"])
    }

    func testBlockedCountPerTab() async throws {
        let engine = FakeEngine()
        let tab = try await engine.makeTab(TabConfiguration(profileID: profile, initialURL: URL(string: "https://news.example")))
        let before = await engine.adBlocking.blockedCount(tabID: tab.id)
        XCTAssertEqual(before, 0)
        engine.fakeAdBlockingService.simulateBlocked(7, tabID: tab.id)
        let after = await engine.adBlocking.blockedCount(tabID: tab.id)
        let unknown = await engine.adBlocking.blockedCount(tabID: EngineTabID(UUID()))
        XCTAssertEqual(after, 7)
        XCTAssertEqual(unknown, 0)
    }

    func testEngineWithoutAnAdBlockerReportsNone() async {
        let blocker = UnavailableAdBlocking()
        let version = await blocker.rulesetVersion()
        XCTAssertNil(version)
    }
}
