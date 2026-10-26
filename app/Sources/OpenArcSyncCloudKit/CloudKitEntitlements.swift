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

    /// True when the process is signed with CloudKit enabled for `containerIdentifier`.
    public static func allowsContainer(_ containerIdentifier: String) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let containers = SecTaskCopyValueForEntitlement(task, containersKey as CFString, nil) as? [String]
        let services = SecTaskCopyValueForEntitlement(task, servicesKey as CFString, nil) as? [String]
        return allows(containerIdentifier, containers: containers, services: services)
    }

    /// The decision on already-read entitlement values (testable without a signed process).
    static func allows(_ containerIdentifier: String, containers: [String]?, services: [String]?) -> Bool {
        guard let containers, containers.contains(containerIdentifier) else { return false }
        // `services` may also be the wildcard "*" in development profiles.
        guard let services else { return false }
        return services.contains("CloudKit") || services.contains("*")
    }
}
