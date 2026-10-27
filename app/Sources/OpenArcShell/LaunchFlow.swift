import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence

// Launch flow: real dependencies, the first-launch workspace, restoring per-device UI state,
// forwarding local changes to the sync store, and flushing (then engine shutdown) on termination.

// MARK: - Dependencies

/// Where the app keeps its data and how to override it.
public enum AppDataLocation {
    /// Environment variable that overrides the data directory (development only). A relative path
    /// is resolved against the current directory; `~` is expanded.
    public static let environmentKey = "OPENARC_DATA_DIR"

    /// `OPENARC_DATA_DIR` if set and not empty, else `~/Library/Application Support/<bundle id>/`.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return PersistenceDefaults.defaultDirectory
        }
        let expanded = (raw as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        return URL(fileURLWithPath: expanded, isDirectory: true, relativeTo: base).standardizedFileURL
    }
}

/// Which sync backend the app runs with. Sync stays off unless a launch switch asks for CloudKit:
/// the iCloud container and entitlements do not exist yet (plan D4).
public enum SyncBackendChoice: Hashable, Sendable {
    case disabled
    case cloudKit

    /// Environment variable that selects the backend (development only).
    public static let environmentKey = "OPENARC_SYNC"

    /// `OPENARC_SYNC=cloudkit` (any case) selects CloudKit; anything else keeps sync disabled.
    public static func from(environment: [String: String]) -> SyncBackendChoice {
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "cloudkit" ? .cloudKit : .disabled
    }
}

/// Which web engine the app runs with. Chromium is the default (decided by the user, 2026-10-25);
/// `OPENARC_ENGINE=fake` selects FakeEngine for development and UI tests.
public enum EngineChoice: Hashable, Sendable {
    case fake
    case chromium

    /// Environment variable that selects the engine (development only).
    public static let environmentKey = "OPENARC_ENGINE"

    /// `OPENARC_ENGINE=fake` (any case) selects FakeEngine; anything else, including no value,
    /// selects Chromium.
    public static func from(environment: [String: String]) -> EngineChoice {
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return raw == "fake" ? .fake : .chromium
    }
}

extension AppDependencies {
    /// What the app runs with: Chromium when the app passes `makeChromiumEngine` (the shell does
    /// not link the Chromium target; the app does, when the build has it), FakeEngine when the
    /// build has no Chromium or `OPENARC_ENGINE=fake` is set, the on-disk workspace store, and sync disabled unless
    /// `OPENARC_SYNC=cloudkit` is set and the app passes `makeCloudKitStore` (the shell does not
    /// link the CloudKit target; the app does). A build without the iCloud entitlement still
    /// starts: the CloudKit store reports `.unavailable(.notConfigured)` and the account card shows
    /// it. Creating the dependencies loads the workspace file synchronously, so build them once (in
    /// `App.init`), not in a `body`.
    ///
    /// `makeChromiumEngine` gets the engine's user data directory, `<data dir>/Chromium`
    /// (chromium-bridge/include/OpenArcCore/OACApplication.h), so `OPENARC_DATA_DIR` isolates
    /// engine data too.
    public static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        makeCloudKitStore: (() -> any SyncStore)? = nil,
        makeChromiumEngine: ((URL) -> any BrowserEngine)? = nil
    ) -> AppDependencies {
        let dataDirectory = AppDataLocation.directory(environment: environment)
        return AppDependencies(
            engine: engine(environment: environment, dataDirectory: dataDirectory, makeChromiumEngine: makeChromiumEngine),
            sync: syncStore(environment: environment, makeCloudKitStore: makeCloudKitStore),
            persistence: WorkspaceStore(directory: dataDirectory),
            preferences: .standard,
            defaultBrowser: SystemDefaultBrowserService(),
            systemAppearance: ApplicationSystemAppearance(),
            mediaFolders: .live(environment: environment)
        )
    }

    /// The engine for `environment`: Chromium when selected (the default) and a constructor is
    /// given, otherwise FakeEngine.
    static func engine(
        environment: [String: String], dataDirectory: URL, makeChromiumEngine: ((URL) -> any BrowserEngine)?
    ) -> any BrowserEngine {
        switch EngineChoice.from(environment: environment) {
        case .chromium:
            let engineDirectory = dataDirectory.appendingPathComponent("Chromium", isDirectory: true)
            return makeChromiumEngine?(engineDirectory) ?? FakeEngine()
        case .fake:
            return FakeEngine()
        }
    }

    /// The sync store for `environment`: `DisabledSyncStore` unless CloudKit is selected and a
    /// constructor is given.
    static func syncStore(environment: [String: String], makeCloudKitStore: (() -> any SyncStore)?) -> any SyncStore {
        switch SyncBackendChoice.from(environment: environment) {
        case .cloudKit: return makeCloudKitStore?() ?? DisabledSyncStore()
        case .disabled: return DisabledSyncStore()
        }
    }
}

// MARK: - First launch

/// Defaults for the workspace created on first launch.
enum FirstLaunchDefaults {
    /// [03 §Profiles] observed: the built-in profile is named "Default" and cannot be deleted.
    static let profileName = "Default"
    /// unknown: the spec does not record the name of the first Space. Our own choice.
    static let spaceName = "Home"
    /// unknown: same placeholder color a new Space gets when no theme is picked.
    static var themeColor: RGBAColor { SpaceFlowLocalTokens.defaultThemeColor }
}

extension WorkspaceState {
    /// The workspace of a first launch (or of a launch whose file could not be used): the
    /// "Default" profile and one Space with a default theme, no tabs. Built with `TreeOps`.
    public static func firstLaunch(now: Date = Date(), makeID: () -> UUID = UUID.init) -> WorkspaceState {
        let profileID = makeID(), themeID = makeID(), spaceID = makeID()
        var s = TreeOps.createProfile(WorkspaceState(), id: profileID, name: FirstLaunchDefaults.profileName, now: now)
        s = TreeOps.createTheme(s, id: themeID, style: ThemeStyle(colors: [FirstLaunchDefaults.themeColor]), now: now)
        do {
            s = try TreeOps.createSpace(s, id: spaceID, profileID: profileID, name: FirstLaunchDefaults.spaceName, themeID: themeID, now: now)
        } catch {
            assertionFailure("first-launch workspace is invalid: \(error)")
        }
        return s
    }
}

// MARK: - Launch notice

/// A one-time alert shown after launch. Our wording (the spec has no such surface).
public struct LaunchNotice: Hashable, Sendable {
    public var title: String
    public var message: String

    /// The workspace file was refused (read-only store): nothing was loaded and nothing is saved.
    static func dataNotLoaded(_ outcome: WorkspaceLoadOutcome) -> LaunchNotice {
        let reason: String
        if case .refused(.unsupportedSchemaVersion) = outcome {
            reason = "Your data was saved by a newer version of \(AppIdentity.displayName), so it was not loaded."
        } else {
            reason = "Your saved data could not be read safely, so it was not loaded."
        }
        return LaunchNotice(
            title: "Your Data Was Not Loaded",
            message: reason + " Changes you make now will not be saved."
        )
    }
}

/// Shows `ShellModel.launchNotice` once; dismissing it clears the notice.
struct LaunchNoticeAlert: ViewModifier {
    @ObservedObject var model: ShellModel

    func body(content: Content) -> some View {
        let isPresented = Binding(
            get: { model.launchNotice != nil },
            set: { if !$0 { model.dismissLaunchNotice() } }
        )
        content.alert(model.launchNotice?.title ?? "", isPresented: isPresented) {
            Button("OK", role: .cancel) { model.dismissLaunchNotice() }
        } message: {
            Text(model.launchNotice?.message ?? "")
        }
    }
}

// MARK: - Termination

/// Runs an action when the app is about to terminate (`NSApplication.willTerminateNotification`).
/// The center is injectable so tests can post the notification without an app.
final class TerminationObserver {
    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    init(center: NotificationCenter, action: @escaping @MainActor @Sendable () -> Void) {
        self.center = center
        // AppKit posts this notification on the main thread.
        token = center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { action() }
        }
    }

    func invalidate() {
        if let token { center.removeObserver(token) }
        token = nil
    }

    deinit { invalidate() }
}

/// The app's quit sequence, run from `applicationShouldTerminate` (B27).
///
/// Quitting used to take a minute with the UI frozen: after the app said yes, AppKit asked the
/// process for promised data still on the drag pasteboard (left there by the last sidebar drag,
/// whose item provider answers asynchronously) and waited for its 60 s timeout. Now the quit
/// first drops that drag data, then answers `.terminateLater`, runs the store flush and the engine
/// shutdown as async work (the main thread keeps running, so work that needs the main actor
/// finishes), and replies once they are done or the overall deadline passed.
@MainActor
public final class AppTermination {
    private weak var controller: WorkspaceController?
    private let deadline: TimeInterval
    private let releaseDragData: @MainActor () -> Void
    private let confirmQuit: @MainActor () -> QuitConfirmation
    private let isSystemQuit: @MainActor () -> Bool
    private var isRunning = false
    /// An update is about to relaunch the app: its quit is never questioned.
    private var isUpdateRelaunch = false
    private var updateObserver: QuitNotificationObservation?

    /// - Parameters:
    ///   - deadline: the latest the app replies, whatever is still running.
    ///   - releaseDragData: drops drag-pasteboard data this process still promises. Tests pass
    ///     their own, so they never touch the system pasteboard.
    ///   - confirmQuit: asks the user whether to quit ("Warn before quitting", B68). Tests pass
    ///     their own, so no alert runs.
    ///   - isSystemQuit: whether the quit comes from logout, restart or shut down, which are never
    ///     questioned.
    public init(
        deadline: TimeInterval = TerminationTiming.quitDeadline,
        releaseDragData: @escaping @MainActor () -> Void = AppTermination.releaseDragPasteboard,
        confirmQuit: @escaping @MainActor () -> QuitConfirmation = QuitConfirmationAlert.run,
        isSystemQuit: @escaping @MainActor () -> Bool = AppTermination.currentQuitIsFromSystem,
        notificationCenter: NotificationCenter = .default
    ) {
        self.deadline = deadline
        self.releaseDragData = releaseDragData
        self.confirmQuit = confirmQuit
        self.isSystemQuit = isSystemQuit
        // Posted on the main thread by the updater just before it quits the app to install.
        updateObserver = QuitNotificationObservation(center: notificationCenter, name: QuitConfirmationAlert.updateRelaunchNotification) { [weak self] in
            self?.isUpdateRelaunch = true
        }
    }

    /// The app's workspace controller. Its quit work runs on termination.
    public func attach(_ controller: WorkspaceController) {
        self.controller = controller
    }

    /// For `NSApplicationDelegate.applicationShouldTerminate`.
    public func shouldTerminate(_ application: NSApplication) -> NSApplication.TerminateReply {
        request { application.reply(toApplicationShouldTerminate: true) }
    }

    /// A quit request (⌘Q, Open Arc ▸ Quit, the Dock): first asks the user when "Warn before
    /// quitting" is on ([03 §General] observed, default on), then runs the quit sequence.
    /// `.terminateCancel` when the user keeps the app open. Logout, restart, shut down and an
    /// update relaunch quit without asking (inferred: the system and the updater cannot wait for an
    /// answer).
    @discardableResult
    public func request(reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        if !isRunning, let preferences = controller?.dependencies.preferences, preferences.warnsBeforeQuitting,
           !isUpdateRelaunch, !isSystemQuit() {
            switch confirmQuit() {
            case .cancel: return .terminateCancel
            case .quit: break
            case .quitAndStopWarning: preferences.warnsBeforeQuitting = false
            }
        }
        return begin(reply: reply)
    }

    /// Whether the quit Apple event being handled carries a reason (logout, restart, shut down).
    /// ⌘Q, the menu and the Dock send none.
    public static func currentQuitIsFromSystem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else { return false }
        return event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
            || event.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
    }

    /// Starts the quit sequence and calls `reply` once it finished or `deadline` passed. Returns
    /// `.terminateNow` when there is nothing to wait for. A second request while one runs is
    /// answered by the first one's reply.
    @discardableResult
    public func begin(reply: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        releaseDragData()
        guard let controller else { return .terminateNow }
        guard !isRunning else { return .terminateLater }
        isRunning = true
        let deadline = self.deadline
        Task { @MainActor in
            _ = await TerminationDeadline.run(timeout: deadline) { await controller.prepareForTermination() }
            reply()
        }
        return .terminateLater
    }

    /// Clears the drag pasteboard unless a drag is in progress (a mouse button is down). Its
    /// contents only matter during a drag session; left there, lazily provided data makes AppKit
    /// wait for this process while it exits. Our own decision (the spec says nothing about it).
    public static func releaseDragPasteboard() {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        NSPasteboard(name: .drag).clearContents()
    }
}

/// Waits for async work at most `timeout` seconds without blocking the thread. The work runs in
/// its own task, so work that never finishes (or ignores cancellation) cannot hold the caller.
@MainActor
enum TerminationDeadline {
    /// Returns true when `operation` finished in time. The operation is cancelled at the deadline.
    static func run(timeout: TimeInterval, _ operation: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = ResumeOnce(continuation)
            let work = Task.detached {
                await operation()
                await gate.resume(true)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0) * 1_000_000_000))
                if gate.resume(false) { work.cancel() }
            }
        }
    }

    /// Resumes a continuation once; later calls do nothing.
    @MainActor
    private final class ResumeOnce {
        private var continuation: CheckedContinuation<Bool, Never>?

        init(_ continuation: CheckedContinuation<Bool, Never>) {
            self.continuation = continuation
        }

        /// Returns whether this call resumed it.
        @discardableResult
        func resume(_ value: Bool) -> Bool {
            guard let continuation else { return false }
            self.continuation = nil
            continuation.resume(returning: value)
            return true
        }
    }
}

// MARK: - ShellModel launch helpers

extension ShellModel {
    /// Restores the tab selected at the last quit. Ignored when the tab no longer exists, was
    /// archived, belongs to another Space or profile than the restored selection, or another window
    /// already shows it. inferred.
    func restoreSelectedTab(_ id: UUID) {
        guard let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        switch tab.location {
        case .favorite(let profileID):
            guard workspace.localProfileID(for: profileID) == sidebar.currentProfileID else { return }
        case .pinned(let spaceID, _), .today(let spaceID):
            guard spaceID == selectedSpaceID else { return }
        }
        sidebar.selectTab(id, focusingOtherWindow: false)
    }

    /// Saves the UI state, writes pending workspace changes and then shuts the engine down before
    /// the process exits (see `WorkspaceController.flushForTermination`).
    public func flushForTermination(timeout: TimeInterval = TerminationTiming.storeFlushTimeout, engineShutdownTimeout: TimeInterval = TerminationTiming.engineShutdownTimeout) {
        controller.flushForTermination(timeout: timeout, engineShutdownTimeout: engineShutdownTimeout)
    }

    public func dismissLaunchNotice() { launchNotice = nil }
}
