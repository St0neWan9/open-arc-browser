import SwiftUI
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence

/// App identity placeholders.
public enum AppIdentity {
    /// Placeholder bundle id of the release build; final product name and id are not decided yet.
    public static let releaseBundleIdentifier = PersistenceDefaults.releaseBundleIdentifier
    /// Bundle id of the development build (`scripts/make-app.sh --dev`, plan B37).
    public static let developmentBundleIdentifier = PersistenceDefaults.developmentBundleIdentifier
    /// The running app's bundle id (release or development build); the release id outside an app
    /// bundle. Everything derived from the id (data directory, defaults domain, drag types) uses
    /// this, so the two builds never share state.
    public static var bundleIdentifier: String { PersistenceDefaults.bundleIdentifier }
    /// True for the release id and the development-build ids.
    public static func isOwnBundleIdentifier(_ id: String) -> Bool { PersistenceDefaults.isOwnBundleIdentifier(id) }
    /// The product name used in UI copy. The development build keeps it ("Open Arc Dev" is only
    /// the bundle's name in the Dock and menu bar), so both builds lay out the same.
    public static let displayName = "Open Arc"
}

/// Dependency-injection entry point: everything the shell needs from the outside.
/// Build one at launch and put it in the SwiftUI environment with `.appDependencies(_:)`.
public struct AppDependencies: Sendable {
    public var engine: any BrowserEngine
    public var sync: any SyncStore
    /// On-disk workspace store. nil keeps everything in memory (previews, tests, `.fake()`).
    public var persistence: WorkspaceStore?
    /// Per-device settings (Settings window). The default keeps them in memory, so tests and
    /// previews never touch the user's defaults; the app passes `AppPreferences.standard`.
    public var preferences: AppPreferences
    /// Reads and sets the system's default browser (D2). The default is in memory, so tests and
    /// previews never change the real default; the app passes `SystemDefaultBrowserService`.
    public var defaultBrowser: any DefaultBrowserService
    /// Checks for app updates (D7). The default cannot update, so tests and previews never reach
    /// the network; the app passes its Sparkle-backed checker.
    public var updateChecker: any UpdateChecker
    /// The system's light/dark setting, for themes set to Automatic (B21). The default is a fixed
    /// light setting, so tests and previews never depend on the machine; the app passes
    /// `ApplicationSystemAppearance`.
    public var systemAppearance: any SystemAppearanceSource

    public init(
        engine: any BrowserEngine,
        sync: any SyncStore,
        persistence: WorkspaceStore? = nil,
        preferences: AppPreferences = .inMemory(),
        defaultBrowser: (any DefaultBrowserService)? = nil,
        updateChecker: (any UpdateChecker)? = nil,
        systemAppearance: (any SystemAppearanceSource)? = nil
    ) {
        self.engine = engine
        self.sync = sync
        self.persistence = persistence
        self.preferences = preferences
        self.defaultBrowser = defaultBrowser ?? InMemoryDefaultBrowserService()
        self.updateChecker = updateChecker ?? UnavailableUpdateChecker()
        self.systemAppearance = systemAppearance ?? ManualSystemAppearance(.light)
    }

    /// FakeEngine + sync disabled + no persistence (never touches the disk). Used for UI
    /// development, previews and tests, and as the environment default until the Chromium bridge
    /// exists.
    public static func fake() -> AppDependencies {
        AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore())
    }
}

private struct AppDependenciesKey: EnvironmentKey {
    static let defaultValue: AppDependencies = .fake()
}

extension EnvironmentValues {
    public var appDependencies: AppDependencies {
        get { self[AppDependenciesKey.self] }
        set { self[AppDependenciesKey.self] = newValue }
    }

    /// Shortcut for `appDependencies.engine`.
    public var browserEngine: any BrowserEngine { appDependencies.engine }

    /// Shortcut for `appDependencies.sync`.
    public var syncStore: any SyncStore { appDependencies.sync }
}

extension View {
    /// Injects the dependencies into this view hierarchy.
    public func appDependencies(_ dependencies: AppDependencies) -> some View {
        environment(\.appDependencies, dependencies)
    }
}
