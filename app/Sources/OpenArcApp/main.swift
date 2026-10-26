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
// disabled unless `OPENARC_SYNC=cloudkit` is set (D5); without the iCloud entitlement (D4) the
// CloudKit store then reports itself as not configured instead of starting. Updates use Sparkle
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
            makeChromiumEngine: OpenArcApp.chromiumEngineFactory
        )
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
                ChromiumEngine(userDataDirectory: directory, crashReportsDirectory: CrashReportLocation.directory())
            }
        }
        #else
        return nil
        #endif
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
