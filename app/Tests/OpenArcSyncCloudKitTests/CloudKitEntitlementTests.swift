import XCTest
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// D5: a build without the iCloud entitlement must not trap in `CKContainer`; the store reports
/// `.unavailable(.notConfigured)` instead and never creates a driver.
final class CloudKitEntitlementTests: XCTestCase {

    func testEntitlementDecision() {
        let id = "iCloud.org.openarc.browser"
        XCTAssertTrue(CloudKitEntitlements.allows(id, containers: [id], services: ["CloudKit"]))
        XCTAssertTrue(CloudKitEntitlements.allows(id, containers: [id], services: ["*"]))
        XCTAssertFalse(CloudKitEntitlements.allows(id, containers: nil, services: ["CloudKit"]))
        XCTAssertFalse(CloudKitEntitlements.allows(id, containers: ["iCloud.other"], services: ["CloudKit"]))
        XCTAssertFalse(CloudKitEntitlements.allows(id, containers: [id], services: nil))
        XCTAssertFalse(CloudKitEntitlements.allows(id, containers: [id], services: ["CloudDocuments"]))
    }

    /// The test runner is not entitled to the container.
    func testTestProcessIsNotEntitled() {
        XCTAssertFalse(CloudKitEntitlements.allowsContainer("iCloud.org.openarc.browser"))
    }

    func testUnentitledStoreReportsNotConfigured() async throws {
        let h = StoreHarness(isEntitled: false)
        try await h.start()
        let status = await h.store.currentStatus()
        XCTAssertEqual(status.phase, .unavailable(.notConfigured))
        XCTAssertTrue(h.drivers.drivers.isEmpty, "no CloudKit object is created")
        do {
            try await h.store.syncNow()
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? CloudKitSyncStoreError, .unavailable(.notConfigured))
        }
        await h.store.stop()
        let stopped = await h.store.currentStatus()
        XCTAssertEqual(stopped.phase, .disabled)
    }
}

/// B65: the app registers for CloudKit pushes only when signed with the push entitlement.
final class PushEntitlementTests: XCTestCase {
    func testPushDecision() {
        XCTAssertTrue(CloudKitEntitlements.allowsPush(environment: "production"))
        XCTAssertTrue(CloudKitEntitlements.allowsPush(environment: "development"))
        XCTAssertFalse(CloudKitEntitlements.allowsPush(environment: nil))
        XCTAssertFalse(CloudKitEntitlements.allowsPush(environment: "staging"))
        XCTAssertEqual(CloudKitEntitlements.pushKey, "com.apple.developer.aps-environment")
    }

    /// The test runner has no push entitlement.
    func testTestProcessHasNoPush() {
        XCTAssertFalse(CloudKitEntitlements.allowsPush())
    }
}
