import SwiftUI
import AppKit
import OpenArcEngine
import OpenArcShell
import OpenArcSyncCloudKit
#if canImport(OpenArcChromium)
import OpenArcChromium
#endif

// Executable entry point. Runs the shell with Chromium when the build has the OpenArcCore
// xcframework (the default; `OPENARC_ENGINE=fake` selects FakeEngine for development), and keeps the workspace on disk (`WorkspaceStore`, overridable with `OPENARC_DATA_DIR`). Sync is
// CloudKit when the build carries the iCloud entitlement (B65; `OPENARC_SYNC` overrides it for development); without it (D4) the
// CloudKit store then reports itself as not configured instead of starting. With the push
// entitlement (B65) the app registers for CloudKit's silent pushes once sync has started, and the
// app delegate forwards them to the sync controller. Updates use Sparkle
// (D7, `SparkleUpdateChecker`) once the Info.plist carries a real EdDSA public key. Crash reports
// stay local (D8, decision Q8): Chromium's Crashpad writes them to `<app data dir>/Crash Reports`.

struct OpenArcApp: App {
    /// Receives links and files opened from other apps (`application(_:open:)`, D2).
    @NSApplicationDelegateAdaptor(OpenArcAppDelegate.self) private var appDelegate
    /// Built once: creating the store loads the workspace file.
    private let dependencies: AppDependencies

    init() {
        // Kept on purpose. `swift run` starts a bare executable with no Info.plist, which
        // would otherwise get no Dock icon, menu bar or key window. Inside the app bundle
        // built by scripts/make-app.sh the policy is already `.regular`, so this is a no-op.
        NSApplication.shared.setActivationPolicy(.regular)
        var dependencies = AppDependencies.live(
            makeCloudKitStore: { CloudKitSyncStore() },
            // B65: a build signed for the iCloud container gets the CloudKit store; the user
            // turns sync on in Settings ▸ Account (no launch switch, as in Arc).
            isCloudKitEntitled: CloudKitEntitlements.allowsContainer(CloudKitSyncStore.Configuration().containerIdentifier),
            makeChromiumEngine: OpenArcApp.chromiumEngineFactory
        )
        // CloudKit pushes (B65): only a build signed with the push entitlement registers; the
        // sync controller does it once the CloudKit store has started.
        if CloudKitEntitlements.allowsPush() {
            dependencies.registerForRemoteNotifications = { NSApplication.shared.registerForRemoteNotifications() }
        }
        // Sparkle updates (D7) when the bundle is configured for them; see docs/release.md.
        dependencies.updateChecker = makeUpdateChecker()
        self.dependencies = dependencies
    }

    var body: some Scene {
        // The first-launch workspace is used only when there is no usable workspace file.
        OpenArcScene(
            dependencies: dependencies,
            workspace: .firstLaunch(),
            externalOpenInbox: appDelegate.inbox,
            termination: appDelegate.termination
        )
        .commands {
            // Development build with OPENARC_DEBUG_CRASH=1 only (plan D8).
            if CrashReportLocation.isDebugCrashMenuEnabled() {
                DebugCrashCommands()
            }
        }
    }
}

extension OpenArcApp {
    /// Builds the Chromium engine (it starts Chromium's browser process when AppKit finishes
    /// launching; the quit sequence shuts it down through `BrowserEngine.shutdown`). nil when this
    /// build has no Chromium.
    static var chromiumEngineFactory: ((URL) -> any BrowserEngine)? {
        #if canImport(OpenArcChromium)
        // Crash reports (plan D8) go to the folder Settings ▸ Advanced reveals,
        // `<app data dir>/Crash Reports`, for the app process and every Chromium helper.
        return { directory in
            MainActor.assumeIsolated {
                ChromiumEngine(
                    userDataDirectory: directory,
                    crashReportsDirectory: CrashReportLocation.directory(),
                    additionalSwitches: developmentSwitches(bundleIdentifier: AppIdentity.bundleIdentifier)
                )
            }
        }
        #else
        return nil
        #endif
    }

    /// Chromium switches for the development build ("Open Arc Dev", user decision 2026-10-25): it
    /// is ad-hoc signed and rebuilt often, and the login keychain trusts one exact signature, so
    /// every rebuild asked for keychain access again. The dev build uses Chromium's mock keychain
    /// instead; its cookies and passwords are encrypted with a fixed test key. The release build
    /// keeps the real keychain item.
    static func developmentSwitches(bundleIdentifier: String) -> [String] {
        bundleIdentifier == AppIdentity.releaseBundleIdentifier ? [] : ["--use-mock-keychain"]
    }
}

#if canImport(OpenArcChromium)
// Chromium needs the process's NSApplication to be its subclass (OACBrowserApplication.h). The
// bundle's NSPrincipalClass stays NSApplication so `OPENARC_ENGINE=fake` runs never load
// Chromium code; with Chromium selected (the default), create the subclass before SwiftUI
// touches `NSApplication.shared`.
if EngineChoice.from(environment: ProcessInfo.processInfo.environment) == .chromium {
    MainActor.assumeIsolated { ChromiumEngine.installApplicationClass() }
}
#endif

OpenArcApp.main()
