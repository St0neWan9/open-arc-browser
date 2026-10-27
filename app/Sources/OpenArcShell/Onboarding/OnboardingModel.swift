import Foundation
import Combine
import OpenArcModel
import OpenArcDesign
import OpenArcPersistence

// First-run onboarding (plan D9, restyled in B53). The steps and their wording are our own (D9);
// the look follows the captured onboarding ([06 §27.1–27.4]): a full-window welcome screen, then a
// split layout with one D9 step per screen in the white left column. Each step is optional and the
// whole flow can be skipped at any point. No network, no AI.
//
// The flow is app-level (one per `WorkspaceController`) and shown in one browser window at a time
// (the host). Workspace changes go through `TreeOps` and are committed by the controller.

/// Whether onboarding is already done at launch. Own design (D9):
/// - no persistence store (tests, previews) or a read-only store: done, never shown;
/// - the saved per-device flag wins when present (false: the first run was quit midway, so it
///   shows again; true: finished or skipped);
/// - no flag (no `ui-state.json`, or one written before D9): pending only when there was no
///   workspace file, i.e. on first launch.
enum OnboardingLaunch {
    static func isCompleted(persistence: WorkspaceStore?) -> Bool {
        guard let persistence, !persistence.isReadOnly else { return true }
        let saved = UIStateFile.load(from: persistence.directory)?.onboardingCompleted
        return saved ?? (persistence.loadResult.outcome != .noFile)
    }
}

/// State and actions of the onboarding card flow.
@MainActor
public final class OnboardingModel: ObservableObject {
    /// The steps in order. Own design (D9).
    public enum Step: Int, CaseIterable, Sendable {
        case welcome, space, importBookmarks, defaultBrowser, sync, done
    }

    /// The two screens of the flow. [06 §27.1] observed: a full-window welcome screen first;
    /// [06 §27.2] observed: then a split layout. [06 §27.4] inferred: our D9 steps after the
    /// welcome go into the split layout's left column, one step per screen.
    public enum Screen: Sendable {
        /// Full-window gradient, headline and the arrow button. [06 §27.1]
        case welcome
        /// White left column with the step, gradient right column with the demo. [06 §27.2]
        case split
    }

    /// The flow wants to be on screen (first launch, or Help ▸ Show Welcome Again).
    @Published public private(set) var isPresented: Bool
    @Published public private(set) var step: Step = .welcome
    /// Text of the Space name field (step 2). Applied when the step is left with Continue.
    @Published public var spaceName = ""
    /// The "Sync Sidebar" choice as shown on step 5.
    @Published public private(set) var syncEnabled: Bool
    /// The import step opened the import flow at least once (for tests and the button label).
    @Published public private(set) var didOpenImport = false

    /// The browser window that shows the flow. Weak: a closed window hands the flow to the next
    /// window that appears.
    public private(set) weak var hostWindow: ShellModel?
    /// The Space step 2 names and colors: the host window's Space when the flow attached.
    public private(set) var spaceID: UUID?

    /// Opens the bookmark import flow (D3). Tests replace it.
    var presentImport: @MainActor (WorkspaceController) -> Void = { BookmarkImportPresenter.present(controller: $0) }

    private weak var controller: WorkspaceController?

    init(controller: WorkspaceController) {
        self.controller = controller
        isPresented = !controller.onboardingCompleted && !controller.isOffTheRecord
        syncEnabled = controller.dependencies.preferences.isSidebarSyncEnabled
    }

    /// Whether the flow is on screen in `window`.
    public func isShown(in window: ShellModel) -> Bool {
        isPresented && hostWindow === window
    }

    /// A browser window appeared: it hosts the pending flow unless another open window already
    /// does. Incognito windows never host it.
    public func attach(_ window: ShellModel) {
        guard isPresented, !window.isIncognito, let controller, window.controller === controller else { return }
        if let host = hostWindow, host !== window, controller.browserWindows.contains(where: { $0 === host }) { return }
        host(in: window)
    }

    /// Help ▸ Show Welcome Again: runs the flow again from the first step in `window`. The saved
    /// completion flag stays set, so quitting midway does not bring it back at launch. inferred.
    public func showAgain(in window: ShellModel) {
        guard !window.isIncognito, let controller, window.controller === controller else { return }
        step = .welcome
        didOpenImport = false
        syncEnabled = controller.dependencies.preferences.isSidebarSyncEnabled
        isPresented = true
        host(in: window)
    }

    private func host(in window: ShellModel) {
        objectWillChange.send()
        hostWindow = window
        spaceID = window.selectedSpaceID ?? controller?.workspace.allLiveSpaces.first?.id
        spaceName = spaceID.flatMap { controller?.workspace.spaces[$0]?.name } ?? ""
    }

    // MARK: Navigation

    public var canGoBack: Bool { step != .welcome && step != .done }

    /// The screen that shows `step`. [06 §27.4] inferred.
    public static func screen(for step: Step) -> Screen { step == .welcome ? .welcome : .split }

    /// The screen of the current step.
    public var screen: Screen { Self.screen(for: step) }

    /// Whether the primary button is enabled. On the Space step it needs a name (the button's
    /// disabled state is [06 §27.3] observed; requiring a name is our own rule). `next()` itself
    /// still accepts an empty name and keeps the old one.
    public var isContinueEnabled: Bool {
        step != .space || !spaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The right column's demo shows the Space being named, with its live theme, instead of
    /// cycling through the sample Spaces. Our own choice: the window background is covered by
    /// the split layout ([06 §27.2] observed), so this is where the theme pick shows. inferred.
    public var showsLiveSpaceDemo: Bool { step == .space }

    /// Continue: applies the current step's pending input, then moves on. Continue on the last
    /// step finishes the flow.
    public func next() {
        guard isPresented else { return }
        if step == .space { applySpaceName() }
        guard let following = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        step = following
    }

    public func back() {
        guard canGoBack, let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    /// "Skip" / Escape on any step: ends the flow and records it as completed. Input not yet
    /// applied (an edited Space name) is dropped; theme edits were applied live and stay.
    public func skip() { finish() }

    /// Ends the flow and saves the per-device flag.
    public func finish() {
        guard isPresented else { return }
        isPresented = false
        objectWillChange.send()
        hostWindow = nil
        guard let controller else { return }
        controller.onboardingCompleted = true
        controller.saveUIState()
    }

    // MARK: Step 2: name and theme of the first Space

    /// Renames the Space through `TreeOps.renameSpace` (stamps only `naming`). An empty or
    /// unchanged name changes nothing.
    func applySpaceName() {
        guard let controller, let spaceID else { return }
        let name = spaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let space = controller.workspace.spaces[spaceID], !space.meta.isTombstone, space.name != name else { return }
        let stamp = controller.now()
        try? controller.mutate(origin: nil) { try TreeOps.renameSpace($0, id: spaceID, name: name, now: stamp) }
    }

    /// The system light/dark setting, for a theme draft set to Automatic (B21).
    var systemAppearance: ResolvedAppearance { controller?.systemAppearance ?? .light }

    /// The theme editor's view of the Space's theme (shared with Edit Theme…).
    var themeDraft: SpaceThemeDraft {
        get {
            guard let spaceID, let host = hostWindow else { return SpaceThemeDraft() }
            return host.spaceFlow.themeDraft(of: spaceID)
        }
        set {
            guard let spaceID, let host = hostWindow else { return }
            objectWillChange.send()
            // `TreeOps.editSpaceTheme`, applied live like Edit Theme… so the background follows.
            host.spaceFlow.applyThemeDraft(newValue, to: spaceID)
        }
    }

    // MARK: Step 3: import bookmarks

    /// Opens the D3 import sheet. The step stays; Continue moves on.
    public func openImport() {
        guard let controller else { return }
        didOpenImport = true
        presentImport(controller)
    }

    // MARK: Step 4: default browser

    /// Whether Open Arc already is the default browser (D2 service).
    public var isDefaultBrowser: Bool { controller?.defaultBrowser.isDefault ?? false }

    /// "Make Default": asks the system through the D2 default-browser model.
    public func makeDefaultBrowser() async {
        guard let controller else { return }
        objectWillChange.send()
        await controller.defaultBrowser.makeDefault()
        objectWillChange.send()
    }

    // MARK: Step 5: iCloud sync

    /// False when this build has no sync backend: the choice is stored for later.
    public var isSyncBackendAvailable: Bool { controller?.sidebarSync.isBackendAvailable ?? false }

    /// The "Sync Sidebar" choice (D5 preference). With a backend it goes through the sync
    /// controller (which starts or stops the store); without one only the preference is stored,
    /// with the same full-upload mark the toggle sets when turned off.
    public func setSyncEnabled(_ isOn: Bool) {
        guard let controller else { return }
        syncEnabled = isOn
        if controller.sidebarSync.isBackendAvailable {
            controller.sidebarSync.setEnabled(isOn)
        } else {
            let preferences = controller.dependencies.preferences
            preferences.isSidebarSyncEnabled = isOn
            if !isOn { preferences.needsFullSyncUpload = true }
        }
    }
}

/// The demo card in the split layout's right column cycles through sample Spaces. [06 §27.2]
/// observed: about every 3 s, with a crossfade. Pure: the view passes the dates of its timeline,
/// tests pass their own.
enum OnboardingCarousel {
    /// Time each sample stays up. [06 §27.2] observed ≈ 3 s.
    static let interval: TimeInterval = 3
    /// Crossfade between two samples. unknown (our choice, shorter than the interval).
    static let crossfade: TimeInterval = 0.6
    /// Slack for timeline dates that land a hair before a tick (floating point).
    private static let tolerance: TimeInterval = 0.001

    /// Index of the sample on screen at `now` for a carousel started at `start`: one step per
    /// `interval`, wrapping after the last of `count` samples; 0 before `start` or when empty.
    static func index(start: Date, now: Date, count: Int, interval: TimeInterval = interval) -> Int {
        guard count > 0, interval > 0 else { return 0 }
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 0 else { return 0 }
        let ticks = Int((elapsed + tolerance) / interval)
        return ticks % count
    }
}
