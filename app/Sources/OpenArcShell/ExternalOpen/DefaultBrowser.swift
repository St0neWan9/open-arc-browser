import Foundation
import AppKit
import SwiftUI

// Default browser (plan D2). [03 §账号卡] observed: a banner "Arc isn’t your default browser"
// with a button "Make Arc your default"; [01 §Arc] observed the menu item "Set as Default
// Browser". Both register the app for http and https through LaunchServices; macOS then asks the
// user to confirm. Everything about the status after a refusal is inferred.

/// Reads and changes the system's default web browser. Injectable so tests never change the real
/// default (`InMemoryDefaultBrowserService`, or a fake in the tests).
@MainActor
public protocol DefaultBrowserService: AnyObject, Sendable {
    /// The app that opens `url` by default, or nil when none is registered.
    func defaultApplication(toOpen url: URL) -> URL?
    /// Makes the app at `appURL` the default for `scheme`. macOS may ask the user first; throws when
    /// the change was refused or failed.
    func setDefaultApplication(at appURL: URL, toOpenURLsWithScheme scheme: String) async throws
    /// The bundle of the running app.
    var applicationURL: URL { get }
}

/// The real service: `NSWorkspace` (macOS 12+).
@MainActor
public final class SystemDefaultBrowserService: DefaultBrowserService {
    public nonisolated init() {}

    public func defaultApplication(toOpen url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }

    public func setDefaultApplication(at appURL: URL, toOpenURLsWithScheme scheme: String) async throws {
        try await NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme)
    }

    public var applicationURL: URL { Bundle.main.bundleURL }
}

/// A default-browser registry kept in memory: the `AppDependencies` default, so tests, previews
/// and `.fake()` never touch LaunchServices. Starts with no default browser.
@MainActor
public final class InMemoryDefaultBrowserService: DefaultBrowserService {
    /// Default handler per scheme.
    public private(set) var handlers: [String: URL] = [:]
    public let applicationURL: URL

    public nonisolated init(applicationURL: URL = URL(fileURLWithPath: "/Applications/Open Arc.app", isDirectory: true)) {
        self.applicationURL = applicationURL
    }

    public func defaultApplication(toOpen url: URL) -> URL? {
        url.scheme.flatMap { handlers[$0.lowercased()] }
    }

    public func setDefaultApplication(at appURL: URL, toOpenURLsWithScheme scheme: String) async throws {
        handlers[scheme.lowercased()] = appURL
    }
}

/// Default-browser status and the "Make default" action, shared by the Settings banner and the
/// app menu item.
@MainActor
public final class DefaultBrowserModel: ObservableObject {
    /// Schemes the app registers for, matching `CFBundleURLTypes`.
    public static let schemes = ["http", "https"]
    /// The URL whose handler tells whether we are the default browser (an http link, as Mail
    /// would open it).
    static let probeURL = URL(string: "http://example.com")!

    /// Whether this app opens http links by default. Refreshed by `refresh()`.
    @Published public private(set) var isDefault: Bool
    /// True while the system is asked to change the default.
    @Published public private(set) var isRequesting = false
    /// The last failure (refused by the user or by LaunchServices), for diagnostics.
    @Published public private(set) var lastError: Error?

    private let service: any DefaultBrowserService
    private var activationObserver: ActivationObserver?

    /// - Parameter notificationCenter: where `NSApplication.didBecomeActiveNotification` is
    ///   observed to re-read the status (the user may change it in System Settings). Tests pass
    ///   their own.
    public init(service: any DefaultBrowserService, notificationCenter: NotificationCenter = .default) {
        self.service = service
        self.isDefault = Self.check(service)
        activationObserver = ActivationObserver(center: notificationCenter) { [weak self] in self?.refresh() }
    }

    /// Reads the current default again (e.g. when the Settings window appears or the app becomes
    /// active: the user may have changed it in System Settings).
    public func refresh() {
        let now = Self.check(service)
        if now != isDefault { isDefault = now }
    }

    /// Settings "Make Open Arc your default" and Open Arc ▸ Set as Default Browser: registers the
    /// app for http and https, then reads the status back. Does nothing while a request runs.
    public func makeDefault() async {
        guard !isRequesting else { return }
        isRequesting = true
        defer {
            isRequesting = false
            refresh()
        }
        lastError = nil
        let app = service.applicationURL
        for scheme in Self.schemes {
            do {
                try await service.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
            } catch {
                // The user declined (or LaunchServices refused): stop asking for the next scheme.
                lastError = error
                return
            }
        }
    }

    /// The banner line. [03 §账号卡] observed for the "isn’t" case; the other is our wording.
    public var statusText: String {
        isDefault
            ? "\(AppIdentity.displayName) is your default browser"
            : "\(AppIdentity.displayName) isn’t your default browser"
    }

    private static func check(_ service: any DefaultBrowserService) -> Bool {
        guard let handler = service.defaultApplication(toOpen: probeURL) else { return false }
        return handler.standardizedFileURL.resolvingSymlinksInPath()
            == service.applicationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

/// Runs an action when the app becomes active; removes its observer when released.
private final class ActivationObserver {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, action: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        // AppKit posts this notification on the main thread.
        token = center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    deinit { center.removeObserver(token) }
}

// MARK: - Menu

/// Open Arc ▸ Set as Default Browser. [01 §Arc] observed: after Settings… and Share Arc (Share Arc
/// is not built). Disabled while we are the default or a request runs: inferred.
struct DefaultBrowserCommands: Commands {
    @ObservedObject var model: DefaultBrowserModel

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Set as Default Browser") { Task { await model.makeDefault() } }
                .disabled(model.isDefault || model.isRequesting)
        }
    }
}
