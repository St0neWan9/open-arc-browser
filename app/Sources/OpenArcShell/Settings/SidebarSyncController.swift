import Foundation
import AppKit
import OpenArcSyncAPI

/// Runs the sync store for the app (plan D5): starts it at launch when "Sync Sidebar" is on,
/// stops and restarts it when the toggle changes, forwards local changes, and keeps the status
/// the account card shows. [03 §账号卡] observed: the "Sync Sidebar" toggle and the
/// "Last synced: <time>" line.
///
/// Every call into the store runs on one serial chain, so a start always comes before the
/// enqueues that follow it and a quick off/on cannot reorder `stop` and `start`.
///
/// Changes made while sync is off (or before a start that failed) are not queued anywhere: a
/// stopped store keeps no queue the app could add to. So turning sync off marks the workspace
/// for a full upload (persisted in `AppPreferences`), and the next successful start announces
/// every record once. The backend merges each record under `ConflictPolicy`, so records the
/// server already has cost an upload but change nothing.
///
/// Live updates (B65): while the store runs, a CloudKit push (forwarded by the app delegate as
/// `remoteChangeNotification`) and the app becoming active (at most once per
/// `SyncFetchThrottle.activationInterval`) fetch remote changes, so another device's edits show
/// without a relaunch or Sync Now. The first successful start registers the app for remote
/// notifications (`registerForRemoteNotifications`). Our own design; inferred.
@MainActor
public final class SidebarSyncController: ObservableObject {
    /// Latest status from `SyncStore.statusUpdates()`.
    @Published public private(set) var status: SyncStatus
    /// Why the last "Sync Now" (or resume) failed, when the store threw instead of reporting a
    /// status. Cleared by the next attempt.
    @Published public private(set) var actionError: String?

    public let store: any SyncStore
    private let database: (any SyncLocalDatabase)?
    private let preferences: AppPreferences
    /// Every record id of the current workspace, for a full upload.
    private let allRecordIDs: @MainActor () -> [SyncRecordID]
    let now: () -> Date

    /// True between a successful `start` and the next `stop`.
    public private(set) var isRunning = false
    /// Tail of the serial chain of store calls.
    private var tail: Task<Void, Never>?
    /// Spaces out the fetches the app's activation asks for (B65).
    private(set) var fetchThrottle: SyncFetchThrottle
    /// The trigger of the automatic fetch waiting in the chain. Later requests join it; a push
    /// upgrades a waiting activation fetch so the throttle cannot skip it.
    private var queuedFetchTrigger: SyncFetchThrottle.Trigger?
    /// Registers the app for remote notifications (CloudKit pushes). nil: never (tests, builds
    /// without the push entitlement).
    private let registerForRemoteNotifications: (@MainActor @Sendable () -> Void)?
    private var didRegisterForRemoteNotifications = false
    private var observers: SyncNotificationObservers?

    /// - Parameters:
    ///   - database: the on-disk workspace store. nil (tests, previews, a read-only store) never
    ///     starts the sync store.
    ///   - allRecordIDs: every record id of the workspace (`WorkspaceState.allRecordIDs`).
    ///   - now: clock for the relative "Last synced" time and the activation fetch spacing.
    ///   - notificationCenter: where `NSApplication.didBecomeActiveNotification` and
    ///     `remoteChangeNotification` are observed (tests pass their own).
    ///   - registerForRemoteNotifications: called once, after the first successful start.
    ///   - activationFetchInterval: minimum time between fetches on activation.
    public init(
        store: any SyncStore,
        database: (any SyncLocalDatabase)?,
        preferences: AppPreferences,
        allRecordIDs: @escaping @MainActor () -> [SyncRecordID],
        now: @escaping () -> Date = Date.init,
        notificationCenter: NotificationCenter = .default,
        registerForRemoteNotifications: (@MainActor @Sendable () -> Void)? = nil,
        activationFetchInterval: TimeInterval = SyncFetchThrottle.activationInterval
    ) {
        self.store = store
        self.database = database
        self.preferences = preferences
        self.allRecordIDs = allRecordIDs
        self.now = now
        self.registerForRemoteNotifications = registerForRemoteNotifications
        fetchThrottle = SyncFetchThrottle(minimumInterval: activationFetchInterval)
        status = .disabled
        // Only a store that can run listens; `DisabledSyncStore` (incognito, no backend) never does.
        if isBackendAvailable {
            observers = SyncNotificationObservers(
                center: notificationCenter,
                onActivation: { [weak self] in self?.appDidBecomeActive() },
                onRemoteChange: { [weak self] in self?.remoteChangeReceived() }
            )
        }
    }

    /// False with `DisabledSyncStore`: this build has no sync backend.
    public var isBackendAvailable: Bool { !(store is DisabledSyncStore) }

    /// The "Sync Sidebar" toggle as shown: off when there is no backend.
    public var isEnabled: Bool { isBackendAvailable && preferences.isSidebarSyncEnabled }

    /// The account card for the current status, with "Last synced" relative to `now()`.
    public var card: SyncCardState {
        let reference = now()
        return SyncCardState.make(
            status: status,
            backendAvailable: isBackendAvailable,
            isSyncOn: preferences.isSidebarSyncEnabled,
            actionError: actionError,
            formatDate: { SyncTimeFormat.relative($0, now: reference) }
        )
    }

    // MARK: Lifecycle

    /// At launch: starts the store when the backend exists, there is a database and "Sync
    /// Sidebar" is on. With the toggle off nothing is started. inferred (D5).
    public func launch() {
        guard isEnabled, database != nil else { return }
        perform { await self.startStore() }
    }

    /// The "Sync Sidebar" toggle. Stores the choice, then starts or stops the store.
    public func setEnabled(_ isOn: Bool) {
        guard isBackendAvailable else { return }
        objectWillChange.send()
        preferences.isSidebarSyncEnabled = isOn
        actionError = nil
        if isOn {
            guard database != nil else { return }
            perform { await self.startStore() }
        } else {
            // Edits from now on are not queued; the next start uploads everything once.
            preferences.needsFullSyncUpload = true
            // `stop` is safe on a store that is not running.
            perform {
                self.isRunning = false
                await self.store.stop()
            }
        }
    }

    /// Hands local changes to the store while it runs. Dropped otherwise: the full upload after
    /// the next start covers them (see the type comment).
    public func forward(_ changes: [PendingChange]) {
        guard !changes.isEmpty else { return }
        perform {
            // When not running, `needsFullSyncUpload` is already set: it starts true and is set
            // again whenever sync is turned off; only a successful start clears it.
            guard self.isRunning else { return }
            await self.store.enqueue(changes)
        }
    }

    /// "Sync Now" on the account card (shown when the last sync failed).
    public func syncNow() {
        perform {
            self.actionError = nil
            self.fetchThrottle.noteFetch(at: self.now())
            do {
                try await self.store.syncNow()
            } catch {
                self.actionError = Self.describe(error)
            }
        }
    }

    /// After the iCloud account changed the store pauses until the app decides. The user chose to
    /// sync this Mac's sidebar with the new account: drop the old account's sync state and upload
    /// every record. inferred (D5; the decision itself is ours, not observed).
    public func resumeAfterAccountChange() {
        perform {
            self.actionError = nil
            await self.store.resetLocalSyncState()
            await self.store.enqueue(self.allRecordIDs().map(PendingChange.save))
        }
    }

    // MARK: Live updates (B65)

    /// Posted by the app delegate when a remote notification arrives. The app has no push source
    /// of its own, so every remote notification is a CloudKit one (the database subscription
    /// CKSyncEngine keeps).
    public nonisolated static let remoteChangeNotification = Notification.Name("org.openarc.sync.remoteChange")

    /// The app became active: fetch, unless the last fetch is younger than the throttle interval.
    /// A pushed change can be delayed or dropped by APNs; this catches up when the user comes back.
    public func appDidBecomeActive() {
        requestAutomaticFetch(.activation)
    }

    /// A CloudKit push arrived: fetch now. CKSyncEngine also schedules its own fetch for the push;
    /// a manual one runs at once instead of waiting for the engine's scheduler.
    public func remoteChangeReceived() {
        requestAutomaticFetch(.remoteNotification)
    }

    /// Queues one fetch (`SyncStore.syncNow`) on the store chain. Skipped while the store is not
    /// running or has no usable account. Its errors are not shown as `actionError`: the store
    /// reports them through its status and retries on its own.
    private func requestAutomaticFetch(_ trigger: SyncFetchThrottle.Trigger) {
        guard isEnabled else { return }
        if let queued = queuedFetchTrigger {
            if queued == .activation, trigger == .remoteNotification { queuedFetchTrigger = trigger }
            return
        }
        queuedFetchTrigger = trigger
        perform {
            let trigger = self.queuedFetchTrigger ?? trigger
            self.queuedFetchTrigger = nil
            guard self.isRunning else { return }
            let reference = self.now()
            guard self.fetchThrottle.allows(trigger, at: reference) else { return }
            switch await self.store.currentStatus().phase {
            case .disabled, .unavailable: return
            case .idle, .syncing, .failed: break
            }
            self.fetchThrottle.noteFetch(at: reference)
            try? await self.store.syncNow()
        }
    }

    /// Follows the store's status until the stream ends or the calling task is cancelled. The
    /// Settings window runs this in `.task`.
    public func observeStatus() async {
        for await next in store.statusUpdates() {
            status = next
        }
    }

    /// Waits until every store call queued so far has finished (tests).
    func settle() async {
        while let current = tail {
            await current.value
            if tail == current { return }
        }
    }

    // MARK: Internals

    private func startStore() async {
        guard let database, preferences.isSidebarSyncEnabled else { return }
        do {
            try await store.start(database: database)
        } catch {
            isRunning = false
            actionError = Self.describe(error)
            // Changes made until the next start are not queued anywhere.
            preferences.needsFullSyncUpload = true
            return
        }
        isRunning = true
        // The engine fetches on its own when it starts: activation right after launch adds nothing.
        fetchThrottle.noteFetch(at: now())
        if !didRegisterForRemoteNotifications, let registerForRemoteNotifications {
            didRegisterForRemoteNotifications = true
            registerForRemoteNotifications()
        }
        if preferences.needsFullSyncUpload {
            await store.enqueue(allRecordIDs().map(PendingChange.save))
            preferences.needsFullSyncUpload = false
        }
    }

    private func perform(_ operation: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// When an automatic fetch may run (B65). A push always fetches; the app's activation fetches only
/// when the last fetch (start, push, activation or Sync Now) is at least `minimumInterval` old.
/// Our own values; inferred.
public struct SyncFetchThrottle: Hashable, Sendable {
    public enum Trigger: Hashable, Sendable {
        case activation
        case remoteNotification
    }

    /// Default spacing of activation fetches. Our own value: often enough that switching back to
    /// the app shows another device's edits, rare enough that ⌘-Tab does not hit CloudKit each time.
    public static let activationInterval: TimeInterval = 60

    public let minimumInterval: TimeInterval
    public private(set) var lastFetch: Date?

    public init(minimumInterval: TimeInterval = SyncFetchThrottle.activationInterval) {
        self.minimumInterval = minimumInterval
    }

    public func allows(_ trigger: Trigger, at now: Date) -> Bool {
        switch trigger {
        case .remoteNotification:
            return true
        case .activation:
            guard let lastFetch else { return true }
            // A clock set back (now before the last fetch) must not block fetches for that long.
            return now < lastFetch || now.timeIntervalSince(lastFetch) >= minimumInterval
        }
    }

    public mutating func noteFetch(at now: Date) {
        lastFetch = now
    }
}

/// Observes app activation and forwarded remote notifications; removes the observers when released.
private final class SyncNotificationObservers {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(
        center: NotificationCenter,
        onActivation: @escaping @MainActor @Sendable () -> Void,
        onRemoteChange: @escaping @MainActor @Sendable () -> Void
    ) {
        self.center = center
        // AppKit posts didBecomeActive on the main thread; the app delegate posts the remote
        // change from its main-thread callback.
        tokens = [
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { onActivation() }
            },
            center.addObserver(forName: SidebarSyncController.remoteChangeNotification, object: nil, queue: nil) { _ in
                MainActor.assumeIsolated { onRemoteChange() }
            },
        ]
    }

    deinit { tokens.forEach(center.removeObserver) }
}

/// "Last synced: <time>" as a relative time. [03 §账号卡] observed the line; the time format was
/// not recorded, so the relative wording is ours (inferred).
public enum SyncTimeFormat {
    /// "just now", "5 minutes ago", "1 hour ago", "3 days ago"; a week or more shows the date.
    /// A time in the future (clock skew between devices) reads "just now".
    public static func relative(
        _ date: Date,
        now: Date,
        absolute: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    ) -> String {
        let seconds = now.timeIntervalSince(date)
        let minute: TimeInterval = 60, hour = 60 * minute, day = 24 * hour
        switch seconds {
        case ..<minute: return "just now"
        case ..<hour: return count(Int(seconds / minute), "minute")
        case ..<day: return count(Int(seconds / hour), "hour")
        case ..<(7 * day): return count(Int(seconds / day), "day")
        default: return absolute(date)
        }
    }

    private static func count(_ n: Int, _ unit: String) -> String {
        n == 1 ? "1 \(unit) ago" : "\(n) \(unit)s ago"
    }
}
