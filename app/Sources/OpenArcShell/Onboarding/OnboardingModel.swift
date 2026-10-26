import Foundation
import Combine
import OpenArcModel
import OpenArcDesign
import OpenArcPersistence

// First-run onboarding (plan D9). OWN DESIGN: Arc's onboarding was never captured (plan E6), so
// nothing here copies it. Steps, wording, sizes and timing are ours; each step is optional and the
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
