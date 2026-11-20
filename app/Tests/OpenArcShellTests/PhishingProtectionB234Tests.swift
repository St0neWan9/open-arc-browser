import XCTest
import OpenArcEngine
@testable import OpenArcShell

/// Plan B234: a page on the phishing list is stopped and covered; "Continue" allows the host for
/// the run; the Settings switch turns it off.
@MainActor
final class PhishingProtectionB234Tests: XCTestCase {
    private let tab = EngineTabID(UUID())
    private let bad = URL(string: "https://login-paypa1.example/signin")!

    private func make(_ preferences: AppPreferences = .inMemory()) -> PhishingProtection {
        PhishingProtection(preferences: preferences, list: PhishingList(data: PhishingList.file(hosts: ["login-paypa1.example"])))
    }

    func testFlagsListedHostsAndClearsOnASafePage() {
        let protection = make()
        XCTAssertFalse(protection.addressChanged(URL(string: "https://example.com/")!, in: tab))
        XCTAssertTrue(protection.addressChanged(bad, in: tab))
        XCTAssertEqual(protection.flagged[tab], bad)
        XCTAssertFalse(protection.addressChanged(URL(string: "https://example.com/")!, in: tab))
        XCTAssertNil(protection.flagged[tab], "a page on another host lifts the cover")
    }

    func testContinueAllowsTheHostForTheRun() {
        let protection = make()
        protection.addressChanged(bad, in: tab)
        XCTAssertEqual(protection.proceed(in: tab), bad)
        XCTAssertNil(protection.flagged[tab])
        XCTAssertFalse(protection.addressChanged(bad, in: tab), "allowed now")
        XCTAssertFalse(protection.addressChanged(bad, in: EngineTabID(UUID())), "in every tab")
    }

    func testSwitchOffFlagsNothing() {
        let preferences = AppPreferences.inMemory()
        let protection = make(preferences)
        protection.addressChanged(bad, in: tab)
        preferences.warnsAboutPhishingSites = false
        protection.switchChanged()
        XCTAssertTrue(protection.flagged.isEmpty)
        XCTAssertFalse(protection.addressChanged(bad, in: tab))
        XCTAssertTrue(PhishingProtection(preferences: .inMemory(), list: nil).addressChanged(bad, in: tab) == false, "no list yet")
    }
}
