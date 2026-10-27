import Foundation
import Security

/// Reads the iCloud entitlements of the running process.
///
/// `CKContainer(identifier:)` traps when the process is not entitled to the container, which is
/// the case for `swift run`, the ad-hoc signed bundle and tests (plan D4: no team or container
/// yet). `CloudKitSyncStore` asks this before it creates any CloudKit object.
public enum CloudKitEntitlements {
    static let containersKey = "com.apple.developer.icloud-container-identifiers"
    static let servicesKey = "com.apple.developer.icloud-services"
    /// macOS name of the push entitlement (iOS uses `aps-environment`).
    static let pushKey = "com.apple.developer.aps-environment"

    /// True when the process is signed with CloudKit enabled for `containerIdentifier`.
    public static func allowsContainer(_ containerIdentifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(task, containersKey as CFString, nil) as? [String]
        let services = SecTaskCopyValueForEntitlement(task, servicesKey as CFString, nil) as? [String]
        return allows(containerIdentifier, containers: containers, services: services)
    }

    /// True when the process may receive APNs pushes (B65), so CloudKit's silent notifications for
    /// CKSyncEngine's database subscription reach the running app. Registering without it only
    /// fails, so the app skips registration then.
    public static func allowsPush() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return allowsPush(environment: SecTaskCopyValueForEntitlement(task, pushKey as CFString, nil) as? String)
    }

    /// The push decision on an already-read value: "production" or "development".
    static func allowsPush(environment: String?) -> Bool {
        environment == "production" || environment == "development"
    }

    /// The decision on already-read entitlement values (testable without a signed process).
    static func allows(_ containerIdentifier: String, containers: [String]?, services: [String]?) -> Bool {
        guard let containers, containers.contains(containerIdentifier) else { return false }
        // `services` may also be the wildcard "*" in development profiles.
        guard let services else { return false }
        return services.contains("CloudKit") || services.contains("*")
    }
}
