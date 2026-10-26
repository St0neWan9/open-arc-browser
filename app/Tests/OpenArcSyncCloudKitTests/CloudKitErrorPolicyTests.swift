import XCTest
import CloudKit
import OpenArcSyncAPI
@testable import OpenArcSyncCloudKit

/// CloudKitErrorPolicy: CKError code -> store action, and retry backoff.
final class CloudKitErrorPolicyTests: XCTestCase {

    private func ckError(_ code: CKError.Code, retryAfter: Double? = nil) -> CKError {
        var info: [String: Any] = [:]
        if let retryAfter { info[CKErrorRetryAfterKey] = NSNumber(value: retryAfter) }
        return CKError(code, userInfo: info)
    }

    func testTransientErrorsRetryWithServerSuggestedDelay() {
        let transient: [CKError.Code] = [
            .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
            .zoneBusy, .serverResponseLost, .operationCancelled, .batchRequestFailed,
            .partialFailure, .changeTokenExpired,
        ]
        for code in transient {
            XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(code)), .retry(after: nil), "\(code)")
            XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(code, retryAfter: 12)), .retry(after: 12), "\(code)")
        }
    }

    func testNonCloudKitErrorsAreTransient() {
        XCTAssertEqual(CloudKitErrorPolicy.classify(URLError(.notConnectedToInternet)), .retry(after: nil))
        XCTAssertEqual(CloudKitErrorPolicy.classify(CancellationError()), .retry(after: nil))
    }

    func testConflictZoneAndRecordErrors() {
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.serverRecordChanged)), .resolveConflict)
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.zoneNotFound)), .recreateZone)
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.userDeletedZone)), .recreateZone)
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.unknownItem)), .resetSystemFieldsAndResend)
    }

    func testAccountErrors() {
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.notAuthenticated)), .accountUnavailable(.noAccount))
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.accountTemporarilyUnavailable)), .accountUnavailable(.temporarilyUnavailable))
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.managedAccountRestricted)), .accountUnavailable(.restricted))
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.permissionFailure)), .accountUnavailable(.restricted))
        XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(.quotaExceeded)), .quotaExceeded)
    }

    func testPermanentErrorsGiveUp() {
        let permanent: [CKError.Code] = [
            .invalidArguments, .serverRejectedRequest, .constraintViolation, .limitExceeded,
            .incompatibleVersion, .badContainer, .missingEntitlement, .internalError, .assetFileNotFound,
        ]
        for code in permanent {
            XCTAssertEqual(CloudKitErrorPolicy.classify(ckError(code)), .discard, "\(code)")
        }
    }

    func testBackoffIsExponentialCappedAndHonoursSuggestion() {
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 0, suggested: nil), 2)
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 1, suggested: nil), 4)
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 2, suggested: nil), 8)
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 7, suggested: nil), 256)
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 8, suggested: nil), 300, "capped at 5 minutes")
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 10_000, suggested: nil), 300)
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: -3, suggested: nil), 2)
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 5, suggested: 7), 7, "server suggestion wins")
        XCTAssertEqual(CloudKitErrorPolicy.backoff(attempt: 1, suggested: 0), 4, "non-positive suggestion ignored")
    }

    func testAccountStatusMapping() {
        XCTAssertNil(CloudKitErrorPolicy.unavailableReason(for: .available))
        XCTAssertEqual(CloudKitErrorPolicy.unavailableReason(for: .noAccount), .noAccount)
        XCTAssertEqual(CloudKitErrorPolicy.unavailableReason(for: .restricted), .restricted)
        XCTAssertEqual(CloudKitErrorPolicy.unavailableReason(for: .temporarilyUnavailable), .temporarilyUnavailable)
        XCTAssertEqual(CloudKitErrorPolicy.unavailableReason(for: .couldNotDetermine), .temporarilyUnavailable)
    }
}
