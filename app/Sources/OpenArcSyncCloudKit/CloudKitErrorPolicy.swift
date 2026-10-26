import CloudKit
import OpenArcSyncAPI

/// What to do about a CloudKit error. Pure classification; the store carries out the action.
enum CloudKitErrorAction: Hashable, Sendable {
    /// Transient (network, rate limit, zone busy, server busy). Keep the change pending and retry,
    /// after `after` seconds if the server suggested a delay.
    case retry(after: TimeInterval?)
    /// The server copy changed since our last fetch: merge with `ConflictPolicy` and resend if needed.
    case resolveConflict
    /// The zone is gone: create it again and resend.
    case recreateZone
    /// The server no longer knows the record: drop the cached system fields and save it as new.
    case resetSystemFieldsAndResend
    /// The iCloud account cannot be used right now.
    case accountUnavailable(SyncUnavailableReason)
    /// The user's iCloud storage is full. Keep changes pending; retry once the user frees space.
    case quotaExceeded
    /// Permanent for this change (bad data, too large, rejected). Drop it so the queue cannot stall.
    case discard
}

enum CloudKitErrorPolicy {

    static func classify(_ error: any Error) -> CloudKitErrorAction {
        guard let ck = error as? CKError else {
            // Non-CloudKit errors (URL errors, cancellation) are treated as transient.
            return .retry(after: nil)
        }
        switch ck.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited,
             .zoneBusy, .serverResponseLost, .operationCancelled, .batchRequestFailed,
             .partialFailure, .changeTokenExpired:
            return .retry(after: ck.retryAfterSeconds)
        case .serverRecordChanged:
            return .resolveConflict
        case .zoneNotFound, .userDeletedZone:
            return .recreateZone
        case .unknownItem:
            return .resetSystemFieldsAndResend
        case .notAuthenticated:
            return .accountUnavailable(.noAccount)
        case .accountTemporarilyUnavailable:
            return .accountUnavailable(.temporarilyUnavailable)
        case .managedAccountRestricted, .permissionFailure:
            return .accountUnavailable(.restricted)
        case .quotaExceeded:
            return .quotaExceeded
        default:
            // invalidArguments, serverRejectedRequest, constraintViolation, limitExceeded (record
            // too large), incompatibleVersion, badContainer, missingEntitlement, internalError, ...
            return .discard
        }
    }

    /// Delay before the next retry: the server's suggestion if any, otherwise exponential backoff
    /// (2 s, 4 s, 8 s, ...) capped at 5 minutes. Deterministic so it can be tested.
    static func backoff(attempt: Int, suggested: TimeInterval?) -> TimeInterval {
        if let suggested, suggested > 0 { return suggested }
        let exponent = min(max(attempt, 0), 16)
        return min(2 * pow(2, Double(exponent)), 300)
    }

    /// Account status at start-up → status reason; nil means usable.
    static func unavailableReason(for status: CKAccountStatus) -> SyncUnavailableReason? {
        switch status {
        case .available: return nil
        case .noAccount: return .noAccount
        case .restricted: return .restricted
        case .temporarilyUnavailable, .couldNotDetermine: return .temporarilyUnavailable
        @unknown default: return .temporarilyUnavailable
        }
    }
}
