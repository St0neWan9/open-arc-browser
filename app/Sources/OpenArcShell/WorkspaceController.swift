import Foundation
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcDesign
import OpenArcSyncAPI
import OpenArcPersistence

// App-level owner of the workspace (plan B14). One instance per app; every browser window reads
// and mutates the same workspace through it.
//
// Owns:
// - the `WorkspaceState` value and every mutation of it (through `TreeOps`, via `mutate`/`commit`);
// - persistence (`WorkspaceStore.submit`, flush on termination, `ui-state.json`) and forwarding
//   store changes to the sync store;
// - the registry of live engine tabs (one engine tab per model tab, shared by all windows);
// - the auto-archive scheduler;
// - the list of open browser windows (for the per-window UI state and the one-window-per-tab rule).
//
// Per-window state (selected space and tab, sidebar visibility, command bar, Library mode, split
// focus, site controls) lives in `ShellModel` and its `SidebarViewModel`.

/// Values the Library keeps across launches for the whole app (B22): the Media intro dismissal
/// and the last section shown. App-level, not per window (inferred).
struct LibraryUIFlags: Equatable {
    var mediaIntroDismissed = false
    var lastSection: String?
}

/// A weak reference, for registries that must not keep windows alive.
private struct WeakRef<Object: AnyObject> {
    weak var object: Object?
}

@MainActor
public final class WorkspaceController: ObservableObject {
    public let dependencies: AppDependencies

    /// The workspace every window shows. Changed only through `mutate`, `commit` and `replaceWorkspace`.
    @Published public private(set) var workspace: WorkspaceState {
        didSet {
            workspaceGeneration &+= 1
            switch changeKind {
            case .activity:
                break
            case .tabContent(let ids):
                sidebarRowsGeneration &+= 1
                tabContentLog.append((sidebarRowsGeneration, ids))
                if tabContentLog.count > Self.tabContentLogSize { tabContentLog.removeFirst() }
            case .any:
                sidebarRowsGeneration &+= 1
                sidebarStructureGeneration &+= 1
                // The log answers only for runs of content changes (`tabsWithContentChanges`).
                tabContentLog.removeAll(keepingCapacity: true)
            }
        }
    }
    /// Bumped on every assignment of `workspace`, so derived values (the sidebar snapshot) can be
    /// cached without comparing two large workspaces.
    private(set) var workspaceGeneration = 0
    /// Like `workspaceGeneration`, but not bumped by a change that only stamps a tab's last-active
    /// time (`markTabActive`, every tab selection): nothing the sidebar list draws changes then, so
    /// a Space of thousands of rows is not walked again (B99).
    private(set) var sidebarRowsGeneration = 0
    /// Like `sidebarRowsGeneration`, but not bumped by a change that only mirrors pages' URLs,
    /// titles and favicons into their tab records (`syncContent`): the rows stay where they are, so
    /// a sidebar replaces those tabs in its rows instead of walking the Space again (B107).
    private(set) var sidebarStructureGeneration = 0
    /// What the change being assigned touches (`commit`).
    private var changeKind = ChangeKind.any
    /// The tabs of each recent tab-content change, with the `sidebarRowsGeneration` it made.
    private var tabContentLog: [(generation: Int, tabIDs: Set<UUID>)] = []
    /// Content changes remembered for `tabsWithContentChanges(afterRowsGeneration:)`. Own value: a
    /// sidebar that fell further behind walks its rows again.
    private static let tabContentLogSize = 64

    /// What a workspace change touches, for the generations above and the work `commit` does.
    enum ChangeKind: Equatable {
        /// Only tabs' last-active times.
        case activity
        /// Only these tabs' URL, title and favicon URL (`TreeOps.updateTabContent`).
        case tabContent(Set<UUID>)
        /// Anything else.
        case any
    }

    /// The tabs whose content (URL, title, favicon URL) changed since `generation` of
    /// `sidebarRowsGeneration`, when every change since then was such a content change; nil
    /// otherwise, or when the log does not reach back that far.
    func tabsWithContentChanges(afterRowsGeneration generation: Int) -> Set<UUID>? {
        guard generation <= sidebarRowsGeneration else { return nil }
        guard generation < sidebarRowsGeneration else { return [] }
        guard let oldest = tabContentLog.first, oldest.generation <= generation + 1 else { return nil }
        return tabContentLog.reduce(into: Set<UUID>()) { ids, entry in
            if entry.generation > generation { ids.formUnion(entry.tabIDs) }
        }
    }
    /// Live engine state per tab id (only for tabs that have an engine tab).
    @Published private(set) var liveStates: [UUID: SidebarTabLiveState] = [:]
    /// Library flags shared by every window (B22).
    @Published private(set) var libraryFlags = LibraryUIFlags()
    /// The system's light/dark setting, for themes set to Automatic (B21). Follows
    /// `AppDependencies.systemAppearance`.
    @Published public private(set) var systemAppearance: ResolvedAppearance

    let now: () -> Date
    let makeID: () -> UUID
    /// An incognito window's controller: an in-memory workspace, no persistence, no sync, and
    /// engine tabs created off the record. Discarded with its window. inferred (B14).
    public let isOffTheRecord: Bool
    /// The app's controller, for an incognito one (window opening goes through it).
    private weak var parent: WorkspaceController?
    /// Opens a browser window. Installed by the scene's views, where SwiftUI's `openWindow` is
    /// available; nil in tests (callers record the request as unhandled). An incognito
    /// controller uses its parent's.
    public var openBrowserWindow: ((BrowserWindowRequest) -> Void)? {
        get { parent?.openBrowserWindow ?? ownWindowOpener }
        set { ownWindowOpener = newValue }
    }
    private var ownWindowOpener: ((BrowserWindowRequest) -> Void)?
    /// Counts requests for Settings ▸ Links with the Air Traffic Control sheet open: the command
    /// bar's "Air Traffic Control" row (B61, [06 §20.1] observed row). The Settings window follows
    /// the app controller's count; an incognito controller forwards to its parent.
    @Published public private(set) var airTrafficControlRequests = 0
    /// The last request a Settings window acted on. A Settings window created by the request
    /// itself (first open) still finds it pending.
    var handledAirTrafficControlRequests = 0
    /// Asks the Settings window for the Air Traffic Control sheet (B61).
    public func requestAirTrafficControl() {
        if let parent { parent.requestAirTrafficControl() } else { airTrafficControlRequests += 1 }
    }
    /// Where links and files from other apps open (D2): the Air Traffic Control rules and their
    /// Default row, which includes the Links setting for Little Arc (B24, B52).
    public lazy var externalLinkRouter: any ExternalLinkRouting = AirTrafficControlRouter(preferences: dependencies.preferences)
    /// External URLs waiting for a browser window to register (none was open). D2.
    var pendingExternalURLs: [URL] = []
    /// Opens a Little Arc window with the given window id. Installed by the scene's views, where
    /// SwiftUI's `openWindow` is available; nil in tests. B24.
    public var openLittleArcWindow: ((UUID) -> Void)?
    /// Pages that new Little Arc windows open with, by window id (B24). See `takeLittleArcLaunchURL`.
    var littleArcLaunchURLs: [UUID: URL] = [:]
    /// Default-browser status and action, shared by Settings and the app menu (D2).
    public private(set) lazy var defaultBrowser = DefaultBrowserModel(service: dependencies.defaultBrowser)
    /// Update checks and the automatic-update settings, shared by the app menu and Settings (D7).
    /// Creating it starts the checker, so it is made on first use.
    public private(set) lazy var updates = UpdatesModel(checker: dependencies.updateChecker, preferences: dependencies.preferences)
    /// View ▸ Show Toolbar and "Show full URL when Toolbar is enabled", global for every window
    /// (B43, [06 §17.1] observed). An incognito controller uses its parent's.
    public var webToolbar: WebToolbarSettings { parent?.webToolbar ?? ownWebToolbar }
    private lazy var ownWebToolbar = WebToolbarSettings(preferences: dependencies.preferences)
    /// Settings ▸ Advanced sound, haptic and window-drag switches, global for every window (B84,
    /// [03 §Advanced] observed). An incognito controller uses its parent's.
    public var feedback: FeedbackPlayer { parent?.feedback ?? ownFeedback }
    private lazy var ownFeedback = FeedbackPlayer(
        settings: AdvancedBehaviorSettings(preferences: dependencies.preferences),
        output: dependencies.feedbackOutput
    )
    /// Settings ▸ Icon: the current app icon (B84, [03 §Icon] observed). An incognito controller
    /// uses its parent's.
    public var appIcon: AppIconSettings { parent?.appIcon ?? ownAppIcon }
    private lazy var ownAppIcon = AppIconSettings(preferences: dependencies.preferences, display: dependencies.appIconDisplay)

    private var liveTabs: [UUID: any BrowserTab] = [:]
    /// Back/forward lists saved at the last quit (plan C20, `TabHistoryFile`), by model tab id.
    /// Loaded only while "restore windows from previous session" is on; each is used by the
    /// engine tabs made for its model tab (`ensureLive`) until one of them is attached.
    private var savedTabHistories: [UUID: TabHistorySnapshot.Entry] = [:]
    private var eventTasks: [UUID: Task<Void, Never>] = [:]
    /// Dialog requests of every live tab of this controller, queued per tab (C7b).
    public let dialogs = DialogCenter()
    /// Favicon images seen from the engine (C9, WorkspaceController+Favicons.swift). On disk next to
    /// the workspace file; memory only for an incognito controller or without persistence.
    public let favicons: FaviconCache
    /// State of page-initiated tabs and engine-event observation (C7b, WorkspaceController+PageRequests.swift).
    let pageRequests = PageRequestState()
    /// Link preview triggers sent to live tabs (B49, LinkPeek/WorkspaceController+LinkPeek.swift).
    let linkPeekRouting = LinkPeekRouting()
    /// Open Little Arc windows and their idle-archive timer (B82, LittleArc/LittleArcArchive.swift).
    let littleArcArchive = LittleArcArchiveState()
    /// The windows the engine's extensions see (plan B126). One per app: an incognito controller
    /// uses its parent's.
    var engineWindows: EngineWindowReporter { parent?.engineWindows ?? ownEngineWindows }
    private lazy var ownEngineWindows = EngineWindowReporter(engine: dependencies.engine)
    private var engineWork: [Task<Void, Never>] = []
    /// Tabs whose live content waits to be mirrored into their records (`scheduleContentSync`).
    private var pendingContentSyncs: Set<UUID> = []
    /// Engine tabs `ensureLive` is making, by model tab id: a second call waits for the first.
    private var makingLive: [UUID: Task<Void, any Error>] = [:]
    /// Last queued command per engine tab: the next one waits for it, so commands reach each
    /// engine tab in the order they were issued (`enqueueTabCommand`).
    private var tabCommandTails: [EngineTabID: Task<Void, Never>] = [:]
    /// Color scheme last sent to each live tab (B21, WorkspaceController+Appearance.swift).
    var sentColorSchemes: [UUID: WebColorScheme] = [:]
    private var systemAppearanceObservation: AnyCancellable?
    /// Fires after anything that may change a page's color scheme (B21). For pages that have no
    /// model tab (Little Arc).
    let colorSchemeInputsChanged = PassthroughSubject<Void, Never>()
    /// Incognito controllers made from this one: they follow its View ▸ Appearance changes.
    private var incognitoChildren: [WeakRef<WorkspaceController>] = []

    /// Sidebars of every open window, in creation order.
    private var sidebars: [WeakRef<SidebarViewModel>] = []
    /// Browser windows whose state is saved in `ui-state.json`, in creation order.
    private var windows: [WeakRef<ShellModel>] = []
    /// The browser window that was used last (key window, or the last one created).
    public private(set) weak var activeWindow: ShellModel?

    /// Windows from the last session not yet reopened (consumed by `.restore` windows).
    private var pendingRestores: [WindowUIState] = []
    private var didRequestAdditionalRestores = false
    private var launchNotice: LaunchNotice?
    /// First-run onboarding is finished or skipped on this device (D9, own design). Saved in
    /// `ui-state.json`; see `OnboardingLaunch` for the launch rule.
    var onboardingCompleted = true
    /// The first-pin "Double-click to rename" line was shown on this device. [06 §4] observed
    /// (once); saved in `ui-state.json` (B76).
    private(set) var pinRenameHintShown = false
    /// The first-run onboarding flow (D9).
    public private(set) lazy var onboarding = OnboardingModel(controller: self)

    let autoArchiveTicker: any AutoArchiveTicker
    private var autoArchiveScheduler: AutoArchiveScheduler?
    /// Forwards store changes to the sync store and merges applied remote changes back in.
    private var syncForwarding: Task<Void, Never>?
    /// Starts, stops and observes the sync store (D5). Incognito controllers get one around
    /// `DisabledSyncStore` with no database, so it never starts.
    public private(set) lazy var sidebarSync = SidebarSyncController(
        store: dependencies.sync,
        database: dependencies.persistence.flatMap { $0.isReadOnly ? nil : $0 },
        preferences: dependencies.preferences,
        allRecordIDs: { [weak self] in self?.workspace.allSyncedRecordIDs ?? [] },
        now: now,
        notificationCenter: syncNotificationCenter,
        registerForRemoteNotifications: dependencies.registerForRemoteNotifications,
        hold: firstLaunchSpaceHold
    )
    /// Where `sidebarSync` observes app activation and forwarded pushes (B65).
    private var syncNotificationCenter: NotificationCenter = .default
    /// Flushes the store and the UI state and shuts the engine down on
    /// `NSApplication.willTerminateNotification`.
    private var terminationObserver: TerminationObserver?
    private(set) var isStopped = false
    /// Set once the termination flush ran; later UI state saves are skipped.
    private var isTerminating = false
    /// The quit sequence (`prepareForTermination` or the `willTerminate` fallback) is running or
    /// has run: neither runs twice.
    private var isTerminationRunning = false
    private(set) var isTerminationPrepared = false

    /// - Parameters:
    ///   - workspace: used when the persistence store has no usable file (first launch).
    ///   - notificationCenter: where `willTerminate`, app activation and forwarded remote
    ///     notifications (sync, B65) are observed (tests pass their own).
    public init(
        dependencies: AppDependencies,
        workspace: WorkspaceState,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init,
        notificationCenter: NotificationCenter = .default,
        autoArchiveTicker: any AutoArchiveTicker = SystemAutoArchiveTicker()
    ) {
        self.dependencies = dependencies
        self.now = now
        self.makeID = makeID
        self.autoArchiveTicker = autoArchiveTicker
        self.syncNotificationCenter = notificationCenter
        self.isOffTheRecord = false
        self.systemAppearance = dependencies.systemAppearance.current
        self.favicons = dependencies.persistence.map { FaviconCache(dataDirectory: $0.directory) } ?? FaviconCache(directory: nil)
        // With a persistence store, a workspace read from disk replaces the caller's default. First
        // launch, a recovered corrupt file or a refused file keep the default. [B2]
        let persistence = dependencies.persistence
        if let persistence, persistence.loadResult.outcome == .loaded {
            self.workspace = persistence.loadResult.workspace
        } else {
            self.workspace = workspace
        }
        // Per-device UI state from the last quit (not for a read-only store: its workspace is not
        // the one the ids refer to).
        if let persistence, !persistence.isReadOnly, let saved = UIStateFile.load(from: persistence.directory) {
            pendingRestores = saved.restorableWindows
            libraryFlags = LibraryUIFlags(mediaIntroDismissed: saved.mediaIntroDismissed, lastSection: saved.lastLibrarySection)
            pinRenameHintShown = saved.pinRenameHintShown
        }
        if let persistence, !persistence.isReadOnly, dependencies.preferences.restoresWindowsFromPreviousSession {
            savedTabHistories = TabHistoryFile.load(from: persistence.directory)?.entries ?? [:]
        }
        onboardingCompleted = OnboardingLaunch.isCompleted(persistence: persistence)
        if let persistence {
            if persistence.loadResult.outcome != .loaded {
                persistence.submit(self.workspace)
                // A new install's first-launch workspace: its Space waits for the account's (see
                // `FirstLaunchSpaceAdoption`). Only without any workspace file: after a recovered
                // corrupt file the sync state may already be past the account's records.
                if persistence.loadResult.outcome == .noFile {
                    let spaces = self.workspace.allLiveSpaces
                    dependencies.preferences.firstLaunchSpaceID = spaces.count == 1 ? spaces.first?.id : nil
                    dependencies.preferences.droppedFirstLaunchSpaceID = nil
                }
            }
            if persistence.isReadOnly {
                launchNotice = .dataNotLoaded(persistence.loadResult.outcome)
            } else {
                syncForwarding = makeSyncForwarding(persistence, baseline: persistence.loadResult.workspace)
            }
        }
        // Quit: flush the store, then shut the engine down (B25). Also without persistence, so
        // the engine always gets its shutdown.
        terminationObserver = TerminationObserver(center: notificationCenter) { [weak self] in
            self?.flushForTermination()
        }
        // Profile settings from older per-device preferences, before the first auto-archive run. [A18]
        migrateLegacyProfileSettings()
        // Spaces made with the old blue placeholder get Arc's default look (B98).
        migratePlaceholderThemes()
        // New tabs the pages ask for (window.open, ⌘-click). C7b.
        observeEngineEvents()
        // "Sync Sidebar" decides whether the sync store starts. [03 §账号卡] observed toggle (D5).
        // Off for new installs (plan Q14); an install from before B73 keeps the "on" it had.
        dependencies.preferences.pinLegacySidebarSyncDefault(isExistingInstall: persistence?.loadResult.outcome == .loaded)
        sidebarSync.launch()
        observeSystemAppearance()
        // The app icon chosen in Settings ▸ Icon shows in the Dock again after a relaunch (B84).
        appIcon.applyStored()
        // ⌥⌘N in any app, while the app runs (B82, [03 §Links] observed switch).
        syncLittleArcHotKey()
    }

    /// An incognito window's controller: one off-the-record Space (dark theme, no favorites) in
    /// memory only. Nothing reaches `WorkspaceStore` or the sync store: there is neither. The
    /// profile id is the parent's current profile, so the engine can derive the off-the-record
    /// context from it (inferred).
    private init(incognitoOf parent: WorkspaceController) {
        self.dependencies = AppDependencies(
            engine: parent.dependencies.engine,
            sync: DisabledSyncStore(),
            persistence: nil,
            preferences: parent.dependencies.preferences,
            systemAppearance: parent.dependencies.systemAppearance,
            mediaFolders: parent.dependencies.mediaFolders
        )
        self.systemAppearance = parent.systemAppearance
        self.now = parent.now
        self.makeID = parent.makeID
        self.autoArchiveTicker = parent.autoArchiveTicker
        self.isOffTheRecord = true
        self.parent = parent
        self.favicons = FaviconCache(directory: nil)
        let stamp = parent.now()
        let profileID = parent.currentProfileID ?? parent.makeID()
        let themeID = parent.makeID(), spaceID = parent.makeID()
        var ws = TreeOps.createProfile(WorkspaceState(), id: profileID, name: IncognitoLocalTokens.profileName, now: stamp)
        ws = TreeOps.createTheme(ws, id: themeID, style: ThemeStyle(appearance: IncognitoLocalTokens.themeAppearance, colors: [IncognitoLocalTokens.themeColor]), now: stamp)
        do {
            ws = try TreeOps.createSpace(
                ws, id: spaceID, profileID: profileID, name: IncognitoLocalTokens.spaceName,
                icon: IncognitoLocalTokens.spaceIcon, themeID: themeID, now: stamp
            )
        } catch {
            assertionFailure("incognito workspace is invalid: \(error)")
        }
        self.workspace = ws
        observeEngineEvents()
        observeSystemAppearance()
    }

    /// A new controller for one incognito window. inferred (B14): [01 §File] observed the item.
    public func makeIncognito() -> WorkspaceController {
        let child = WorkspaceController(incognitoOf: self)
        incognitoChildren.removeAll { $0.object == nil }
        incognitoChildren.append(WeakRef(object: child))
        return child
    }

    /// The Spaces the Spaces menu lists, in dock order. An incognito controller lists the app's
    /// Spaces (its parent's), which the menu shows greyed. [06 §20.2] observed (F5-4).
    var menuSpaces: [Space] { (parent ?? self).workspace.allLiveSpaces }

    /// Live incognito controllers made from this one.
    var liveIncognitoChildren: [WorkspaceController] {
        incognitoChildren.removeAll { $0.object == nil }
        return incognitoChildren.compactMap(\.object)
    }

    /// Follows the system light/dark setting: palettes of Automatic themes and the pages' color
    /// scheme update at once. [04 §dark mode] observed: automatic follows the system appearance.
    private func observeSystemAppearance() {
        systemAppearanceObservation = dependencies.systemAppearance.observe { [weak self] appearance in
            guard let self, self.systemAppearance != appearance else { return }
            self.systemAppearance = appearance
            self.syncWebColorSchemes()
        }
    }

    /// Cancels background work: the scheduler, sync forwarding, the termination observer and
    /// engine observation. Call when the app (or a test's world) goes away. An incognito
    /// controller also closes every engine tab it made: closing the window discards them.
    public func stop() {
        isStopped = true
        selectionLoads.stop()
        autoArchiveScheduler?.stop()
        autoArchiveScheduler = nil
        littleArcArchive.stop()
        if parent == nil { ownEngineWindows.stop() }
        if !isOffTheRecord { dependencies.globalHotKeys.unregisterLittleArcHotKey() }
        syncForwarding?.cancel()
        syncForwarding = nil
        if !isOffTheRecord { sidebarSync.stopWatching() }
        terminationObserver?.invalidate()
        terminationObserver = nil
        pageRequests.stop()
        if isOffTheRecord { Array(liveTabs.keys).forEach(closeLive) }
        eventTasks.values.forEach { $0.cancel() }
        eventTasks.removeAll()
        systemAppearanceObservation = nil
    }

    // MARK: - Workspace mutations

    /// Applies `body` to the workspace and commits the result. Throws what `body` throws; the
    /// workspace is unchanged then. `origin` is the sidebar that made the change: it handles its own
    /// selection, every other window repairs its selection.
    func mutate(origin: SidebarViewModel?, _ body: (WorkspaceState) throws -> WorkspaceState) throws {
        let new = try body(workspace)
        commit(new, origin: origin)
    }

    /// Stamps tab `id` as active now (`TreeOps.markTabActive`) and commits it like `mutate`. The
    /// sidebar rows do not show the time, so their snapshot is kept (`sidebarRowsGeneration`).
    func markTabActive(_ id: UUID, origin: SidebarViewModel?) throws {
        commit(try TreeOps.markTabActive(workspace, id: id, now: now()), origin: origin, kind: .activity)
    }

    /// Stores a new workspace value made by the app: persists it and lets every window except
    /// `origin` repair its selection.
    func commit(_ new: WorkspaceState, origin: SidebarViewModel?) {
        commit(new, origin: origin, kind: .any)
    }

    private func commit(_ new: WorkspaceState, origin: SidebarViewModel?, kind: ChangeKind) {
        let old = workspace
        changeKind = kind
        workspace = new
        changeKind = .any
        // Only the records this change touched: a remote batch the store applied after `old` was
        // read (and not yet merged here, see `mergeRemote`) must not be reverted or purged. [A19]
        dependencies.persistence?.submit(changesFrom: old, to: new)
        for sidebar in liveSidebars where sidebar !== origin { sidebar.workspaceDidChange() }
        // A page's color scheme, its link preview triggers and its engine profile follow from the
        // tab's place and its Space, which last-active times and page content never change. These
        // walk every live tab, so the commits of each selection and each page load skip them (B107).
        guard kind == .any else { return }
        syncWebColorSchemes()
        syncLinkPreviewTriggers()
        reconcileLiveTabProfiles()
    }

    /// Replaces the workspace without persisting it (a value that is already stored elsewhere,
    /// e.g. merged from sync, or set up by a test). Every window repairs its selection.
    public func replaceWorkspace(_ new: WorkspaceState) {
        workspace = new
        for sidebar in liveSidebars { sidebar.workspaceDidChange() }
        syncWebColorSchemes()
        syncLinkPreviewTriggers()
        reconcileLiveTabProfiles()
    }

    // MARK: - Profiles

    /// The profile the app-level surfaces (Settings) act on: the active window's, else Default.
    public var currentProfileID: UUID? {
        activeWindow?.sidebar.currentProfileID ?? workspace.defaultProfileID
    }

    /// New Profile… Returns the new profile id. [01, 05 §context menus] observed menu items.
    @discardableResult
    public func createProfile(name: String, icon: String? = nil) -> UUID {
        let id = makeID()
        commit(TreeOps.createProfile(workspace, id: id, name: name, icon: icon, now: now()), origin: nil)
        return id
    }

    /// Replaces a profile's synced settings through `TreeOps.updateProfileSettings`.
    /// [03 §Profiles] observed. Returns false if refused.
    @discardableResult
    public func updateProfileSettings(_ profileID: UUID, _ settings: ProfileSettings) -> Bool {
        (try? mutate(origin: nil) { try TreeOps.updateProfileSettings($0, id: profileID, settings: settings, now: now()) }) != nil
    }

    /// Deletes a profile through `TreeOps.deleteProfile` (refused for the Default profile and while
    /// Spaces use it, [06 §16.3] observed). Archived favorites lose their live engine tabs, then the
    /// profile's engine data is removed ([06 §16.3] observed: "permanently remove any cookies,
    /// history, preferences, and logins"). Returns false if refused.
    @discardableResult
    public func deleteProfile(_ profileID: UUID) -> Bool {
        let favorites = workspace.favorites(profileID: profileID).map(\.id)
        guard (try? mutate(origin: nil) { try TreeOps.deleteProfile($0, id: profileID, now: now()) }) != nil else { return false }
        favorites.forEach(closeLive)
        // Incognito windows opened on a Space of this profile (before the Space changed profile)
        // still have tabs in its off-the-record context: they go too. inferred (C11).
        let incognito = liveIncognitoChildren.filter { child in child.workspace.profiles[profileID] != nil }
        for child in incognito { Array(child.liveTabs.keys).forEach(child.closeLive) }
        // The engine needs every tab of the profile closed first: wait for the queued closes.
        let earlier = engineWork
        let engine = dependencies.engine
        enqueueEngineWork {
            for task in earlier { await task.value }
            for child in incognito { await child.settleEngineWork() }
            do {
                try await engine.deleteProfileData(profileID)
            } catch {
                NSLog("Open Arc: removing the engine data of profile %@ failed: %@", profileID.uuidString, String(describing: error))
            }
        }
        return true
    }

    /// One-time migration of the per-device values B12 stored in `AppPreferences` into the synced
    /// `Profile.settings`. For each live profile with legacy keys, the stored values replace the
    /// matching settings and the keys are removed, so it never runs twice. Skipped for a read-only
    /// store: nothing would be saved, and the keys must survive until a build that can save runs.
    /// Moves themes that still carry the pre-B98 placeholder color (never picked by the user) to
    /// Arc's no-color default ([07 §8.5]). Keeps grain and brightness. The pending first-launch
    /// Space's theme is left alone until `FirstLaunchSpaceAdoption` decides, because an edit would
    /// count as the user touching it; a later launch migrates it.
    func migratePlaceholderThemes() {
        if dependencies.persistence?.isReadOnly == true { return }
        let pendingThemeID = dependencies.preferences.firstLaunchSpaceID.flatMap { workspace.spaces[$0]?.themeID }
        let legacy = [SpaceFlowLocalTokens.legacyPlaceholderColor]
        let stale = workspace.themes.values.filter { !$0.meta.isTombstone && $0.colors == legacy && $0.id != pendingThemeID }
        guard !stale.isEmpty else { return }
        let stamp = now()
        try? mutate(origin: nil) { state in
            try stale.reduce(state) { s, theme in
                var style = theme.style
                style.colors = []
                if style.appearance == .automatic { style.appearance = SpaceFlowLocalTokens.defaultThemeStyle.appearance }
                return try TreeOps.editTheme(s, id: theme.id, style: style, now: stamp)
            }
        }
    }

    func migrateLegacyProfileSettings() {
        if dependencies.persistence?.isReadOnly == true { return }
        let preferences = dependencies.preferences
        for profile in workspace.liveProfilesOldestFirst where preferences.hasLegacyProfileSettings(for: profile.id) {
            let legacy = preferences.legacyProfileSettings(for: profile.id)
            var settings = profile.settings
            if let engine = legacy.searchEngine { settings.searchEngine = engine }
            if let lifetime = legacy.archiveLifetime { settings.todayLifetime = lifetime.interval }
            if settings == profile.settings || updateProfileSettings(profile.id, settings) {
                preferences.removeLegacyProfileSettings(for: profile.id)
            }
        }
    }

    // MARK: - Live engine tabs

    func liveTab(for id: UUID) -> (any BrowserTab)? { liveTabs[id] }

    /// Every live engine tab with its model tab id.
    var liveTabEntries: [(id: UUID, tab: any BrowserTab)] { liveTabs.map { ($0.key, $0.value) } }

    /// The model tab whose engine tab is `engineID`, if this controller owns it.
    func modelTabID(forEngineTab engineID: EngineTabID) -> UUID? {
        liveTabs.first { $0.value.id == engineID }?.key
    }

    func liveState(for id: UUID) -> SidebarTabLiveState? { liveStates[id] }

    /// Forgets the find result shown for `id` (the find bar closed or its text was cleared; the
    /// engine reports no result for a stopped search). B25.
    func clearFindResult(_ id: UUID) {
        guard liveStates[id]?.findResult != nil else { return }
        liveStates[id]?.findResult = nil
    }

    /// Queues engine work (tab creation, navigation, closing) so tests can wait for it.
    func enqueueEngineWork(_ work: @escaping @MainActor () async -> Void) {
        engineWork.append(Task { await work() })
    }

    /// Queues a command for one engine tab. Commands for the same tab run one after another in the
    /// order issued (View ▸ Developer ▸ items pressed in a row reach DevTools in that order); other
    /// engine work and other tabs are not held up.
    func enqueueTabCommand(_ tab: any BrowserTab, _ work: @escaping @MainActor (any BrowserTab) async -> Void) {
        let previous = tabCommandTails[tab.id]
        let task = Task { @MainActor in
            await previous?.value
            await work(tab)
        }
        tabCommandTails[tab.id] = task
        engineWork.append(task)
    }

    /// Waits until queued engine work has finished. For tests.
    func settleEngineWork() async {
        while !engineWork.isEmpty {
            let pending = engineWork
            engineWork.removeAll()
            for task in pending { await task.value }
        }
    }

    /// The engine profile a model tab's page belongs to: the favorite's profile, else its Space's
    /// profile. nil when the Space is unknown (the caller's fallback applies). C11: "Profiles help
    /// keep your data separate across Spaces — like history, logins, cookies" ([03 §Profiles]
    /// observed), so a Space's Profile decides where its tabs' data lives. A profile reference
    /// unknown on this device (profiles do not sync, B73) resolves to the Default profile.
    func engineProfileID(forTab tab: TabNode) -> UUID? {
        switch tab.location {
        case .favorite(let favoriteProfile): return workspace.localProfileID(for: favoriteProfile)
        case .pinned(let spaceID, _), .today(let spaceID): return workspace.profileID(ofSpace: spaceID)
        }
    }

    /// Creates the engine tab for `id` if needed and starts observing it. The profile is the tab's
    /// Space's profile (or the favorite's profile), else `fallbackProfileID`.
    ///
    /// The engine tab is made in a later pass of the main run loop than the call: the pass that
    /// selected the tab draws the selection and the empty panel in the theme color first ([07
    /// §8.1]), and making the engine tab (most of a frame for Chromium), attaching its page and
    /// mirroring its content each get a pass of their own (B103). Nothing is made ahead of a
    /// selection.
    func ensureLive(_ id: UUID, fallbackProfileID: UUID?) async throws {
        guard liveTabs[id] == nil else { return }
        if let making = makingLive[id] {
            try await making.value
            return
        }
        let making = Task { try await self.makeLive(id, fallbackProfileID: fallbackProfileID) }
        makingLive[id] = making
        defer { if makingLive[id] == making { makingLive[id] = nil } }
        try await making.value
    }

    /// Paces the engine tabs of quick successive selections (B107).
    private(set) lazy var selectionLoads: SelectionLoadGate = {
        let gate = SelectionLoadGate()
        gate.isOnScreen = { [weak self] id in
            self?.liveSidebars.contains { $0.onScreenTabIDs.contains(id) } ?? false
        }
        return gate
    }()

    /// Notes a tab selection made now; returns whether it is part of a burst of quick selections
    /// (`SelectionLoadGate`). Called in the selection's own pass.
    func noteTabSelection() -> Bool {
        selectionLoads.noteSelection()
    }

    /// `ensureLive` for a tab just selected. A selection that is part of a burst (`inBurst`) gets
    /// its engine tab once selections are quiet, so a quick run of clicks or Next Tab presses does
    /// not carry the previous tabs' engine work in each click's frame (B107).
    func ensureLiveForSelection(_ id: UUID, inBurst: Bool, fallbackProfileID: UUID?) async throws {
        guard liveTabs[id] == nil else { return }
        if inBurst, makingLive[id] == nil, !isStopped {
            await selectionLoads.admit(id, inBurst: true)
        }
        defer { selectionLoads.finished(id) }
        try await ensureLive(id, fallbackProfileID: fallbackProfileID)
    }

    /// `ensureLive`'s work, once per model tab at a time.
    private func makeLive(_ id: UUID, fallbackProfileID: UUID?) async throws {
        await MainRunLoopTurn.next()
        // The workspace may have changed while the selection was drawn: read the tab again.
        guard liveTabs[id] == nil, !isStopped, !pageRequests.adopting.contains(id), let tab = workspace.tabs[id], !tab.meta.isTombstone else { return }
        // An Easel's row shows the canvas, never an engine page (B56).
        guard workspace.easelID(ofTab: id) == nil else { return }
        guard let profileID = engineProfileID(forTab: tab) ?? fallbackProfileID else { return }
        let engine = dependencies.engine
        let scheme = webColorScheme(forTab: id)
        let initialURL = tab.url ?? tab.pinnedURL
        let configuration = TabConfiguration(
            profileID: profileID,
            initialURL: initialURL,
            opener: pageRequests.openers.removeValue(forKey: id),
            isOffTheRecord: isOffTheRecord,
            preferredColorScheme: scheme,
            sessionHistory: savedHistory(of: id, url: initialURL)
        )
        let live = try await engine.makeTab(configuration)
        // Making a Chromium tab takes most of a frame on the main thread; the new page goes on
        // screen in a frame of its own (B103).
        await MainRunLoopTurn.next()
        await attachLive(id, live, initialColorScheme: scheme)
    }

    /// Registers `live` as the engine tab of model tab `id` and starts observing its events and
    /// dialog requests. Closes it instead when the model tab went away (archived, or made live by
    /// another window) while the engine worked.
    /// `initialColorScheme`: the scheme `live` was created with; nil (an adopted tab) makes the
    /// shell send the tab's scheme right away.
    func attachLive(_ id: UUID, _ live: any BrowserTab, initialColorScheme: WebColorScheme? = nil) async {
        guard workspace.tabs[id].map({ !$0.meta.isTombstone }) == true, liveTabs[id] == nil, !isStopped else {
            await dependencies.engine.closeTab(live.id)
            return
        }
        liveTabs[id] = live
        engineWindows.setNeedsReport()
        // Its saved back/forward list (plan C20) was used or is out of date now.
        savedTabHistories.removeValue(forKey: id)
        // The tab moved to a Space of another Profile while the engine made it (C11).
        if reconcileProfile(of: id) { return }
        sentColorSchemes[id] = initialColorScheme
        syncWebColorScheme(of: id)
        syncLinkPreviewTriggers(of: id)
        dialogs.observe(live)
        liveStates[id] = SidebarTabLiveState(snapshot: await live.currentState())
        rememberFavicon(of: id)
        // The record follows in a later frame: the new page and its row go on screen first (B103).
        scheduleContentSync(id)
        let stream = live.events()
        eventTasks[id] = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.apply(event, to: id)
            }
        }
    }

    /// Applies an engine event to the live state and mirrors content changes into the workspace.
    func apply(_ event: TabEvent, to id: UUID) {
        var state = liveStates[id] ?? SidebarTabLiveState()
        state.apply(event)
        // An event that changes nothing shown (a repeated URL, the same security level) does not
        // publish: every publish updates each window's views (B103).
        if liveStates[id] != state { liveStates[id] = state }
        switch event {
        case .faviconChanged, .snapshot:
            rememberFavicon(of: id)
            scheduleContentSync(id)
        case .urlChanged, .titleChanged: scheduleContentSync(id)
        case .closeRequested: pageRequestedClose(id)
        case .activationRequested: pageRequestedActivation(id)
        case .linkPreviewRequested(let request): linkPreviewRequested(request, from: id)
        case .contextMenuRequested(let menu): pageContextMenuRequested(menu, from: id)
        default: break
        }
    }

    /// Mirrors `id`'s live URL, title and favicon into its record (`syncContent`) once the current
    /// pass of the main run loop has drawn. A page load reports its URL, title and favicon as
    /// separate events, often in one burst; each record change makes every window's sidebar
    /// derive its rows again (a few milliseconds with thousands of tabs), so a burst costs one
    /// change, outside the frame that shows the page (B103). Queued as engine work, so
    /// `settleEngineWork` waits for it.
    func scheduleContentSync(_ id: UUID) {
        guard pendingContentSyncs.insert(id).inserted, pendingContentSyncs.count == 1 else { return }
        enqueueEngineWork { [weak self] in
            await MainRunLoopTurn.next()
            guard let self else { return }
            let ids = self.pendingContentSyncs
            self.pendingContentSyncs.removeAll()
            self.syncContent(ids)
        }
    }

    /// Mirrors the live page's URL, title and favicon into the tab record (`TreeOps.updateTabContent`).
    func syncContent(_ id: UUID) {
        syncContent([id])
    }

    /// Loads `url` in tab `id`'s engine tab (queued after its earlier commands), then writes the
    /// page the engine now shows into the record. The page's events bring the same values later,
    /// on the tab's event stream; reading the engine's state here means the record follows the load
    /// as soon as the load call returns, so engine work that waits for this command (and
    /// `settleEngineWork`) sees it. B107.
    func load(_ url: URL, inLiveTab id: UUID) {
        guard let live = liveTabs[id] else { return }
        enqueueTabCommand(live) { [weak self] tab in
            do { try await tab.load(url) } catch { return }
            let state = await tab.currentState()
            guard let self, self.liveTabs[id]?.id == tab.id else { return }
            self.syncContent([id], sources: [id: SidebarTabLiveState(snapshot: state)])
        }
    }

    /// Runs `body` once tab `id`'s record holds the page its engine tab shows: after the tab's
    /// queued commands (a load just issued), with the engine's own state written into the record.
    /// The cached live state can lag behind the engine (its events are still on the tab's event
    /// stream after `load(_:inLiveTab:)` wrote the new URL), so a command about "the current page"
    /// must not read it (B129). Without an engine tab the record is the page and `body` runs now.
    func afterContentSettles(of id: UUID, _ body: @escaping @MainActor () -> Void) {
        guard let live = liveTabs[id] else { return body() }
        enqueueTabCommand(live) { [weak self] tab in
            let state = await tab.currentState()
            guard let self else { return }
            if self.liveTabs[id]?.id == tab.id {
                self.syncContent([id], sources: [id: SidebarTabLiveState(snapshot: state)])
            }
            body()
        }
    }

    /// `syncContent` for several tabs, as one change. It touches only those records' content, so
    /// every sidebar updates just their rows (`ChangeKind.tabContent`, B107). `sources` replaces
    /// the live state a tab's values are read from (the engine's own state, read after a load).
    private func syncContent(_ ids: Set<UUID>, sources: [UUID: SidebarTabLiveState] = [:]) {
        var next = workspace
        var changed: Set<UUID> = []
        let stamp = now()
        for id in ids {
            guard let live = sources[id] ?? liveStates[id], let node = next.tabs[id], !node.meta.isTombstone else { continue }
            let title = live.title.isEmpty ? node.title : live.title
            let url = live.url ?? node.url
            let favicon = Self.faviconURLToStore(live: live, storedURL: node.url, storedFaviconURL: node.faviconURL)
            guard url != node.url || title != node.title || favicon != node.faviconURL else { continue }
            guard let updated = try? TreeOps.updateTabContent(next, id: id, url: url, title: title, faviconURL: favicon, now: stamp) else { continue }
            next = updated
            changed.insert(id)
        }
        guard !changed.isEmpty else { return }
        commit(next, origin: nil, kind: .tabContent(changed))
    }

    /// A live engine tab belongs to one engine profile for good: its cookies, storage and history
    /// live there, and a web contents cannot move to another profile. When a model tab now belongs
    /// to another Profile (moved to a Space of another Profile, its Space's Profile changed, or a
    /// favorite moved), its engine tab is closed and a new one is made in the right profile, which
    /// loads the tab's URL again (back/forward history, form state and the page's scripts state
    /// are lost; inferred, the spec records no detail). C11.
    func reconcileLiveTabProfiles() {
        for id in Array(liveTabs.keys) { reconcileProfile(of: id) }
    }

    /// See `reconcileLiveTabProfiles`. Returns whether the engine tab of `id` was replaced.
    @discardableResult
    private func reconcileProfile(of id: UUID) -> Bool {
        guard let live = liveTabs[id], let tab = workspace.tabs[id], !tab.meta.isTombstone,
              let expected = engineProfileID(forTab: tab), expected != live.profileID else { return false }
        closeLive(id)
        enqueueEngineWork { [weak self] in
            try? await self?.ensureLive(id, fallbackProfileID: expected)
        }
        return true
    }

    /// Closes the engine tab of `id`, if any, and forgets its live state.
    func closeLive(_ id: UUID) {
        eventTasks.removeValue(forKey: id)?.cancel()
        liveStates.removeValue(forKey: id)
        sentColorSchemes.removeValue(forKey: id)
        guard let live = liveTabs.removeValue(forKey: id) else { return }
        engineWindows.setNeedsReport()
        tabCommandTails.removeValue(forKey: live.id)
        // The page goes away: its queued dialogs get their default answers.
        dialogs.stopObserving(live.id)
        let engine = dependencies.engine
        enqueueEngineWork { await engine.closeTab(live.id) }
    }

    // MARK: - Auto-archive

    /// Auto-archive: archives Today tabs idle for their profile's "Archive tabs after" setting
    /// (`lifetimeOverride` replaces it for every tab), closes their live engine tabs and repairs
    /// every window's selection. [05 §window and app entry points] observed (12 h default).
    /// Tabs on screen in any window (selected tab and its split partners), and the tabs of windows
    /// of the last session that are still being reopened, are kept: inferred.
    /// Returns the archived ids.
    @discardableResult
    func runAutoArchive(lifetimeOverride: TimeInterval? = nil) -> [UUID] {
        let base = workspace
        // Windows of the last session that are not open yet keep their tab too.
        var onScreen = liveSidebars.filter(\.countsAsVisibleWindow).reduce(into: Set<UUID>()) { $0.formUnion($1.onScreenTabIDs) }
        for pending in pendingRestores {
            guard let tabID = pending.selectedTabID else { continue }
            onScreen.insert(tabID)
            if let layout = SplitPaneLayout.activeLayout(in: base, containing: tabID) { onScreen.formUnion(layout.root.tabIDs) }
        }
        let after = TreeOps.autoArchive(base, lifetimeOverride: lifetimeOverride, excluding: onScreen, now: now())
        guard after != base else { return [] }
        let archived = base.tabs.values
            .filter { !$0.meta.isTombstone && after.tabs[$0.id]?.meta.isTombstone == true }
            .map(\.id)
        commit(after, origin: nil)
        archived.forEach(closeLive)
        return archived
    }

    /// Starts the auto-archive scheduler (first run now, then hourly). [B3] Idempotent. Not for an
    /// incognito window: its tabs go away with the window.
    func startAutoArchive() {
        guard autoArchiveScheduler == nil, !isStopped, !isOffTheRecord else { return }
        autoArchiveScheduler = AutoArchiveScheduler(ticker: autoArchiveTicker) { [weak self] in self?.runAutoArchive() }
        autoArchiveScheduler?.start()
    }

    var isAutoArchiveRunning: Bool { autoArchiveScheduler?.isRunning ?? false }

    // MARK: - Windows

    /// Sidebars of windows that are still open.
    var liveSidebars: [SidebarViewModel] {
        sidebars.removeAll { $0.object == nil }
        return sidebars.compactMap(\.object)
    }

    /// Browser windows whose state is saved, in creation order.
    var browserWindows: [ShellModel] {
        windows.removeAll { $0.object == nil }
        return windows.compactMap(\.object)
    }

    func register(_ sidebar: SidebarViewModel) {
        guard !liveSidebars.contains(where: { $0 === sidebar }) else { return }
        sidebars.append(WeakRef(object: sidebar))
    }

    func unregister(_ sidebar: SidebarViewModel) {
        sidebars.removeAll { $0.object == nil || $0.object === sidebar }
    }

    /// The window (other than `except`) that shows `tabID` on screen, if any. A tab's engine
    /// surface can be hosted in one window only. inferred.
    func sidebar(showing tabID: UUID, except: SidebarViewModel) -> SidebarViewModel? {
        liveSidebars.first { $0 !== except && $0.countsAsVisibleWindow && $0.onScreenTabIDs.contains(tabID) }
    }

    /// Adds a browser window to the saved UI state and makes it the active window. The first one
    /// starts the auto-archive scheduler, after its selection was restored. [B3, B14]
    func registerWindow(_ window: ShellModel) {
        if !browserWindows.contains(where: { $0 === window }) { windows.append(WeakRef(object: window)) }
        activeWindow = window
        startAutoArchive()
        // Links from other apps that arrived while no window was open. D2.
        deliverPendingExternalURLs(to: window)
        // A Little Arc page adopted while no window was open. B29.
        deliverPendingReveal(to: window)
        // First-run onboarding shows in the first window that opens (D9).
        onboarding.attach(window)
    }

    /// A browser window closed (`save` true: its state leaves `ui-state.json` right away) or was
    /// stopped. The last window closing does not quit the app (macOS convention, inferred); its
    /// state is kept, so the next launch opens it again.
    func unregisterWindow(_ window: ShellModel, save: Bool) {
        guard browserWindows.contains(where: { $0 === window }) else { return }
        windows.removeAll { $0.object == nil || $0.object === window }
        if browserWindows.isEmpty { lastClosedWindow = window.windowUIState }
        if activeWindow === window { activeWindow = browserWindows.last }
        if save { saveUIState() }
    }

    /// The state of the last window that closed while no other was open.
    private var lastClosedWindow: WindowUIState?

    /// The model Little Arc acts on: the active browser window, else a hidden host on this
    /// workspace (made once). The host is not a window: it holds no tab away from real windows.
    func littleArcHost() -> ShellModel {
        if let activeWindow { return activeWindow }
        if let host = hiddenHost { return host }
        let host = ShellModel(controller: self, window: WindowUIState(selectedSpaceID: activeSpaceID), isBrowserWindow: false)
        hiddenHost = host
        return host
    }

    private var hiddenHost: ShellModel?

    /// The window became key.
    func windowDidBecomeActive(_ window: ShellModel) {
        guard browserWindows.contains(where: { $0 === window }) else { return }
        activeWindow = window
        // Favorites take the color scheme of the active window's Space (B21).
        syncWebColorSchemes()
    }

    /// The Space a new window opens on: the active window's. inferred.
    var activeSpaceID: UUID? { activeWindow?.selectedSpaceID ?? workspace.allLiveSpaces.first?.id }

    /// The tab a New Window shows: the most recently active pinned or Today tab of `spaceID` that
    /// no open window has on screen. inferred (B14).
    func mostRecentTabNotOnScreen(inSpace spaceID: UUID) -> UUID? {
        let onScreen = liveSidebars.filter(\.countsAsVisibleWindow).reduce(into: Set<UUID>()) { $0.formUnion($1.onScreenTabIDs) }
        return workspace.allTabs(inSpace: spaceID)
            .filter { !onScreen.contains($0.id) }
            .max { ($0.lastActiveAt, $0.id.uuidString) < ($1.lastActiveAt, $1.id.uuidString) }?
            .id
    }

    /// A model for the app-level surfaces that are not a browser window (the Settings window): it
    /// reads and writes this workspace and never holds a tab on screen. Made once.
    public func appHost() -> ShellModel {
        if let host = settingsHost { return host }
        let host = ShellModel(controller: self, window: WindowUIState(selectedSpaceID: activeSpaceID), isBrowserWindow: false)
        settingsHost = host
        return host
    }

    private var settingsHost: ShellModel?

    /// The next window from the last session, or nil when all are back.
    func takePendingRestore() -> WindowUIState? {
        guard !pendingRestores.isEmpty else { return nil }
        return pendingRestores.removeFirst()
    }

    /// What a window the app opens by itself shows when nothing is left to restore (e.g. a Dock
    /// click after the last window closed): the last closed window's Space and sidebar, and its tab
    /// unless another window shows it; else the active Space. inferred.
    func reopenState() -> WindowUIState {
        guard var state = lastClosedWindow else { return WindowUIState(selectedSpaceID: activeSpaceID) }
        if let tab = state.selectedTabID, liveSidebars.contains(where: { $0.countsAsVisibleWindow && $0.onScreenTabIDs.contains(tab) }) {
            state.selectedTabID = nil
        }
        return state
    }

    /// A tab ("Open in Open Arc", B29) that must show in the next browser window that registers.
    private(set) var pendingRevealTabID: UUID?

    /// Shows `tabID` in a browser window and brings that window to the front: the active window if
    /// one is open (it may be behind or minimized), else a new window opens for it. Until that
    /// window registers the tab waits, like links from other apps do (D2). inferred (B29).
    func revealInBrowserWindow(_ tabID: UUID, spaceID: UUID?) {
        if let window = activeWindow {
            window.revealTab(tabID)
            return
        }
        pendingRevealTabID = tabID
        guard !isRevealWindowRequested, let open = openBrowserWindow else { return }
        isRevealWindowRequested = true
        open(BrowserWindowRequest(kind: .newWindow, spaceID: spaceID, tabID: tabID))
    }

    /// A window was requested for `pendingRevealTabID` and has not registered yet.
    private var isRevealWindowRequested = false

    private func deliverPendingReveal(to window: ShellModel) {
        isRevealWindowRequested = false
        guard let tabID = pendingRevealTabID else { return }
        pendingRevealTabID = nil
        guard workspace.tabs[tabID].map({ !$0.meta.isTombstone }) == true else { return }
        window.revealTab(tabID)
    }

    /// Ids of the window requests this run handed to SwiftUI (see `BrowserWindowRoot`).
    private var issuedRequestIDs: Set<UUID> = []
    /// The opener came from the scene's commands, which work with no window open. A browser
    /// window's own `openWindow` does not replace it: that window may close, and an opener taken
    /// from a closed window's view opened nothing (B29).
    private var hasSceneWindowOpener = false

    /// Installs the scene's window opener (SwiftUI's `openWindow`). Every request it opens is
    /// recorded first (`noteIssued`). The closure holds this controller weakly: an incognito
    /// controller stores it on itself, and a strong capture would keep the closed window's
    /// in-memory workspace alive. [A19]
    /// - Parameter sceneLevel: the opener comes from the scene's commands (always usable), not
    ///   from one window's view. A scene-level opener is never replaced by a window's.
    func installWindowOpener(sceneLevel: Bool = false, _ open: @escaping (BrowserWindowRequest) -> Void) {
        if hasSceneWindowOpener, !sceneLevel { return }
        if sceneLevel { hasSceneWindowOpener = true }
        openBrowserWindow = { [weak self] request in
            self?.noteIssued(request)
            open(request)
        }
    }

    /// Records a request about to be handed to SwiftUI. Kept by the app's controller (the one the
    /// scene's windows check), also when an incognito window's controller issues it. [A19]
    func noteIssued(_ request: BrowserWindowRequest) {
        if let parent { parent.noteIssued(request) } else { issuedRequestIDs.insert(request.id) }
    }

    /// A fresh Little Arc window id, recorded as issued by this run. Every Little Arc window is
    /// opened with one (⌥⌘N, the command bar, links from other apps). B30.
    func issueLittleArcWindowID() -> UUID {
        if let parent { return parent.issueLittleArcWindowID() }
        let id = makeID()
        issuedLittleArcWindowIDs.insert(id)
        return id
    }

    /// Whether this run opened the Little Arc window `id`. nil (the group's default window) and ids
    /// from an earlier run (window restoration) do not count. B30.
    func wasIssuedLittleArcWindow(_ id: UUID?) -> Bool {
        if let parent { return parent.wasIssuedLittleArcWindow(id) }
        return id.map { issuedLittleArcWindowIDs.contains($0) } ?? false
    }

    private var issuedLittleArcWindowIDs: Set<UUID> = []

    /// Whether this run made `request`. `.restore` requests always count (the scene's default).
    func wasIssued(_ request: BrowserWindowRequest) -> Bool {
        if let parent { return parent.wasIssued(request) }
        return request.kind == .restore || issuedRequestIDs.contains(request.id)
    }

    /// Profile settings for a window of this controller. An incognito window follows its parent
    /// profile's stored settings (its in-memory profile has the same id but default settings).
    /// [03 §Profiles] observed per-profile settings; following them in incognito is inferred. [A19]
    func profileSettings(for profileID: UUID?) -> ProfileSettings {
        if let parent { return parent.profileSettings(for: profileID) }
        guard let profileID, let profile = workspace.profiles[profileID], !profile.meta.isTombstone else { return .default }
        return profile.settings
    }

    var pendingRestoreCount: Int { pendingRestores.count }

    /// Forgets the windows of the last session that were not reopened (single-window hosts).
    func discardPendingRestores() { pendingRestores.removeAll() }

    /// How many more windows the scene must open to bring back the last session (all but the one
    /// the app opens by itself). Asked once, by the first window; later calls return 0.
    ///
    /// [03 §Advanced] observed: "When opening Arc, restore windows from previous session", off by
    /// default. Off: only the first window comes back (its Space, tab and sidebar, as before B14;
    /// inferred). On: every window of the last session.
    func takeAdditionalRestoreCount() -> Int {
        guard !didRequestAdditionalRestores else { return 0 }
        didRequestAdditionalRestores = true
        guard dependencies.preferences.restoresWindowsFromPreviousSession else {
            pendingRestores.removeAll()
            return 0
        }
        return pendingRestores.count
    }

    /// The one-time launch notice, handed to the first window that asks.
    func takeLaunchNotice() -> LaunchNotice? {
        defer { launchNotice = nil }
        return launchNotice
    }

    // MARK: - Library flags

    /// Stores new Library flags and saves the UI state. Other windows pick them up through
    /// `libraryFlags`.
    func setLibraryFlags(_ flags: LibraryUIFlags) {
        guard flags != libraryFlags else { return }
        libraryFlags = flags
        saveUIState()
    }

    // MARK: - UI state and persistence

    /// The per-device UI state to save now: every open browser window and the Library flags.
    var currentUIState: UIState {
        let open = browserWindows.map(\.windowUIState)
        return UIState(
            windows: open.isEmpty ? lastClosedWindow.map { [$0] } ?? [] : open,
            mediaIntroDismissed: libraryFlags.mediaIntroDismissed,
            lastLibrarySection: libraryFlags.lastSection,
            onboardingCompleted: onboardingCompleted,
            pinRenameHintShown: pinRenameHintShown
        )
    }

    /// Records that the first-pin rename hint was shown and saves the UI state. B76.
    func markPinRenameHintShown() {
        guard !pinRenameHintShown else { return }
        pinRenameHintShown = true
        saveUIState()
    }

    /// Writes `ui-state.json` next to the workspace file. Skipped without persistence and when the
    /// store is read-only (its ids would point into a workspace that is never saved).
    func saveUIState() {
        guard let store = dependencies.persistence, !store.isReadOnly, !isTerminating else { return }
        try? UIStateFile.save(currentUIState, to: store.directory)
    }

    /// Writes pending workspace changes, the UI state and the tabs' back/forward lists to disk now.
    public func flushPersistence() async throws {
        saveUIState()
        await saveTabHistories()
        try await dependencies.persistence?.flush()
    }

    // MARK: - Back/forward lists across relaunch (plan C20)

    /// The saved list for model tab `id`, only when it was saved for the URL the tab loads now
    /// (the URL changed elsewhere since: the list would show another page). [03 §Advanced]
    /// inferred (analysis). Kept until an engine tab for `id` is attached (`attachLive`): two
    /// engine tabs can be in the making for one model tab, and either may be the one kept.
    private func savedHistory(of id: UUID, url: URL?) -> TabSessionHistory? {
        guard let entry = savedTabHistories[id], entry.url == url else { return nil }
        return TabSessionHistory(data: entry.data)
    }

    /// The lists to keep for the next launch: every live engine tab's current list, plus the
    /// saved lists of tabs that were not opened this run and still show the same URL.
    func currentTabHistories() async -> TabHistorySnapshot {
        var entries: [UUID: TabHistorySnapshot.Entry] = [:]
        for (id, entry) in savedTabHistories {
            guard let tab = workspace.tabs[id], !tab.meta.isTombstone, (tab.url ?? tab.pinnedURL) == entry.url else { continue }
            entries[id] = entry
        }
        for (id, live) in liveTabs {
            guard let tab = workspace.tabs[id], !tab.meta.isTombstone,
                  let history = await live.sessionHistory() else { continue }
            // The page's own URL: the tab record follows it (`syncContent`), but may not have yet.
            let url = await live.currentState().url ?? tab.url ?? tab.pinnedURL
            entries[id] = TabHistorySnapshot.Entry(url: url, data: history.data)
        }
        return TabHistorySnapshot(entries: entries)
    }

    /// Writes `tab-history.plist` next to the workspace file while "restore windows from previous
    /// session" is on, and removes it while the setting is off (nothing of the pages is kept that
    /// the user did not ask for). Per device; never synced. Skipped for an incognito controller,
    /// without persistence and for a read-only store.
    func saveTabHistories() async {
        guard !isOffTheRecord, let store = dependencies.persistence, !store.isReadOnly else { return }
        let directory = store.directory
        guard dependencies.preferences.restoresWindowsFromPreviousSession else {
            try? TabHistoryFile.remove(from: directory)
            return
        }
        let snapshot = await currentTabHistories()
        try? TabHistoryFile.save(snapshot, to: directory)
    }

    /// The quit path for `applicationShouldTerminate` (B27): saves the UI state, writes pending
    /// workspace changes, then shuts the engine down, without blocking the main thread. Each step
    /// is bounded (`TerminationTiming`), so a stuck store or engine cannot hold up quitting; the
    /// store is flushed before the engine shuts down, so the user's data is on disk first. Runs
    /// once: later calls, and the `willTerminate` fallback, return at once.
    public func prepareForTermination(
        storeFlushTimeout: TimeInterval = TerminationTiming.storeFlushTimeout,
        engineShutdownTimeout: TimeInterval = TerminationTiming.engineShutdownTimeout
    ) async {
        guard !isTerminationPrepared, !isTerminationRunning else { return }
        isTerminationRunning = true
        defer {
            isTerminationRunning = false
            isTerminationPrepared = true
        }
        saveUIState()
        // Windows closing while the app quits must not drop themselves from the saved state.
        isTerminating = true
        // The tabs' back/forward lists, read while the engine still runs (plan C20).
        _ = await TerminationDeadline.run(timeout: storeFlushTimeout) { [weak self] in await self?.saveTabHistories() }
        if let store = dependencies.persistence, !store.isReadOnly {
            _ = await TerminationDeadline.run(timeout: storeFlushTimeout) { try? await store.flush() }
        }
        guard !isOffTheRecord else { return }
        let engine = dependencies.engine
        _ = await TerminationDeadline.run(timeout: engineShutdownTimeout) { await engine.shutdown() }
    }

    /// The synchronous fallback on `willTerminate`, for a quit that did not go through
    /// `prepareForTermination` (no app delegate, tests). Does nothing when that already ran.
    ///
    /// Saves the UI state and writes pending workspace changes before the process exits. Blocks
    /// the main thread until the store has written (at most `timeout` seconds): after
    /// `willTerminate` returns the process ends, so an async flush would be lost. The store is an
    /// actor off the main thread, so waiting here cannot deadlock.
    ///
    /// After the flush the engine is shut down (`BrowserEngine.shutdown`, B25), waiting at most
    /// `engineShutdownTimeout` seconds so quitting never hangs on the engine. The workspace is on
    /// disk first, so a slow or stuck engine cannot cost the user's data.
    public func flushForTermination(
        timeout: TimeInterval = TerminationTiming.storeFlushTimeout,
        engineShutdownTimeout: TimeInterval = TerminationTiming.engineShutdownTimeout
    ) {
        guard !isTerminationPrepared, !isTerminationRunning else { return }
        isTerminationPrepared = true
        saveUIState()
        isTerminating = true
        saveTabHistoriesBlocking(timeout: timeout)
        if let store = dependencies.persistence, !store.isReadOnly {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                try? await store.flush()
                done.signal()
            }
            _ = done.wait(timeout: .now() + timeout)
        }
        shutDownEngine(timeout: engineShutdownTimeout)
    }

    /// `saveTabHistories` for the `willTerminate` fallback (plan C20): the engine answers on the
    /// main actor, so the run loop keeps turning while it waits, at most `timeout` seconds.
    private func saveTabHistoriesBlocking(timeout: TimeInterval) {
        guard !isOffTheRecord, dependencies.persistence?.isReadOnly == false else { return }
        var finished = false
        Task { @MainActor [weak self] in
            await self?.saveTabHistories()
            finished = true
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !finished, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
        }
    }

    /// Runs `engine.shutdown()` and waits for it, at most `timeout` seconds. The main run loop
    /// keeps turning while it waits (unlike the store flush, which is off the main thread): an
    /// engine may hop to the main actor to shut down (decision Q11), and blocking the thread would
    /// make it wait for the full timeout. Only an incognito controller's parent shuts the engine
    /// down; the two share it.
    private func shutDownEngine(timeout: TimeInterval) {
        guard !isOffTheRecord else { return }
        let engine = dependencies.engine
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await engine.shutdown()
            done.signal()
        }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.01)))
        }
    }

    /// Forwards every store change to the sync store (through `sidebarSync`, which drops them
    /// while sync is off). Changes made before the subscription (e.g. the first-launch workspace)
    /// are caught up by diffing against `baseline`, the workspace as loaded from disk. Remote
    /// batches the store applied are merged into the shown workspace.
    private func makeSyncForwarding(_ store: WorkspaceStore, baseline: WorkspaceState) -> Task<Void, Never> {
        let sync = sidebarSync
        return Task.detached { [weak self] in
            let (current, events) = await store.subscribe()
            let catchUp = WorkspaceDiff.pendingChanges(from: baseline, to: current)
            await sync.forward(catchUp)
            for await event in events {
                if Task.isCancelled { return }
                if event.origin == .remote { await self?.mergeRemote(event) }
                await sync.forward(event.pendingChanges)
            }
        }
    }

    /// Brings records the sync store applied to the persistence store into the shown workspace.
    /// Each changed record is merged with the shown copy under `ConflictPolicy` (`RecordMerge`), so
    /// a local edit committed after the remote batch was applied keeps its newer field groups. The
    /// result is committed like any change: saved, and every window repairs its selection.
    ///
    /// A record where the shown copy wins nothing (`needsUpload` false) is taken exactly as the
    /// store holds it, version included: any difference would look like a local change to the
    /// store, which would upload the record again, and the other device would echo that upload
    /// back: an endless sync loop. [A19, A20]
    /// Engine tabs of tabs that were deleted remotely are closed.
    func mergeRemote(_ event: WorkspaceStoreEvent) {
        mergeStored(event.workspace, changes: event.changes)
    }

    /// `mergeRemote` for the records `changes` names in `stored`, the persistence store's workspace.
    func mergeStored(_ stored: WorkspaceState, changes: WorkspaceDiff.Changes) {
        guard !isStopped else { return }
        var next = workspace
        for id in changes.saved {
            guard let server = stored.record(for: id) else { continue }
            if let local = next.record(for: id), let outcome = RecordMerge.merge(local: local, server: server) {
                next.setRecord(outcome.needsUpload ? outcome.merged : server)
            } else {
                next.setRecord(server)
            }
        }
        for id in changes.removed { next.removeRecord(id) }
        // Splits left naming tabs another device deleted or archived lose those panes; a split
        // with one live pane left ends (delete wins). The repair is a local change, so it is saved
        // and uploaded like any edit. [B67, 06 §5 / §21.6]
        next = TreeOps.repairSplits(next, now: now())
        guard next != workspace else { return }
        let gone = liveTabs.keys.filter { next.tabs[$0].map(\.meta.isTombstone) ?? true }
        commit(next, origin: nil)
        gone.forEach(closeLive)
    }
}

/// Timing of the quit path. Our own values (the spec records nothing about quitting).
public enum TerminationTiming {
    /// How long quitting waits for the workspace store to write. Own value; a normal flush takes
    /// milliseconds.
    public static let storeFlushTimeout: TimeInterval = 2
    /// How long quitting waits for `BrowserEngine.shutdown()` after the store flush. Own value.
    public static let engineShutdownTimeout: TimeInterval = 3
    /// Hard limit for the whole quit sequence: the app replies to `applicationShouldTerminate`
    /// by then even if a step is still running. Own value (store + engine limits, plus margin).
    public static let quitDeadline: TimeInterval = 6
}
