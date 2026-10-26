import Foundation
import CoreGraphics
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// State of one Little Arc window. No UI framework types, so the flow is unit-testable.
//
// Spec sources (docs/arc-spec/):
//   [06 §7]  observed: a command-bar-only floating window (≈ 490×330, large radius, no title bar,
//            no sidebar); ✕ on the right of the field; the first row is selected in the theme
//            accent; Escape closes. After a page is opened the window becomes a narrow browsing
//            window with an address bar (expansion itself was not observed in detail).
//   [02]     observed: ⌥⌘N opens a Little Arc window.
//   [01 §File] observed: File ▸ New Little Arc Window.
//
// Decisions without evidence (inferred):
//   - The page lives in an engine tab only. No model tab exists until the user adopts it with
//     "Open in Open Arc", which opens a Today tab in the main window's current space.
//   - Closing the expanded window closes the engine tab; nothing is archived.
//   - Rows that act on the main window (switch to tab, app commands, restore from archive) run
//     there, and the Little Arc window closes.

/// Sizes of the Little Arc window that the spec does not give. Evidence levels as in CLAUDE.md.
enum LittleArcTokens {
    /// Size of the expanded browsing window. unknown (expansion not observed); inferred 900×700
    /// ("narrow" compared with the 1280-wide main window).
    static let expandedSize = CGSize(width: 900, height: 700)
    /// Smallest size the expanded window may be resized to. unknown; inferred.
    static let expandedMinimumSize = CGSize(width: 480, height: 360)
    /// Height of the slim top bar of the expanded window. unknown; inferred 38 pt.
    static let topBarHeight: CGFloat = 38
    /// Room left of the top bar for the traffic lights. inferred (standard buttons ≈ 70 pt).
    static let trafficLightReserve: CGFloat = 72
    /// Gap between the page and the window edges. unknown; inferred like the main web panel.
    static let pageInset: CGFloat = 6
    /// Size of the toolbar buttons in the top bar. unknown.
    static let toolbarButtonSize: CGFloat = 26
    /// Title of the "move to the main window" button. Arc's wording is not recorded in the spec;
    /// this uses our product name.
    static let adoptButtonTitle = "Open in \(AppIdentity.displayName)"
    /// Window title (hidden, used by Window menus and accessibility).
    static let windowTitle = "Little Arc"
}

@MainActor
public final class LittleArcModel: ObservableObject {
    /// Compact = command bar only; expanded = browsing window; closed = window gone.
    public enum Phase: Equatable, Sendable {
        case compact
        case expanded
        case closed
    }

    @Published public private(set) var phase: Phase = .compact
    /// The phase the window was in when it closed. A closing window keeps that phase's size, so it
    /// never shrinks back to the empty command bar on its way out (B30).
    private var phaseBeforeClose: Phase = .compact
    /// Live state of the page (URL, title, navigation). Mirrors engine events.
    @Published private(set) var page = SidebarTabLiveState()
    /// The engine tab of the page; nil while compact or while the engine is creating it.
    @Published public private(set) var liveTab: (any BrowserTab)?
    /// Last engine error (for tests and diagnostics).
    @Published public private(set) var lastError: Error?
    /// Dialog requests of the page (C7b). The page has no model tab, so it is not in the
    /// controller's center.
    public let dialogs = DialogCenter()

    /// The `.littleArc` command bar shown in the compact state. [06 §7] observed.
    public let commandBar: CommandBarViewModel

    /// Called once when the model closes (Escape, ✕, adoption). The window itself closes when its
    /// configurator sees `.closed` (B30), so this is only a notification.
    var onClose: (() -> Void)?

    private let shell: ShellModel
    private let engine: any BrowserEngine
    /// URL the user chose; shown until the engine reports its own URL.
    private var requestedURL: URL?
    private var eventTask: Task<Void, Never>?
    private var engineWork: [Task<Void, Never>] = []
    /// Color scheme last given to the page (B21).
    private var sentColorScheme: WebColorScheme?
    private var colorSchemeObservation: AnyCancellable?

    /// - Parameter initialURL: a page to open right away (a link from another app, B24): the window
    ///   starts expanded on it and skips the command bar. nil: the compact command bar. inferred.
    public init(shell: ShellModel, initialURL: URL? = nil) {
        self.shell = shell
        self.engine = shell.dependencies.engine
        let sidebar = shell.sidebar
        self.commandBar = CommandBarViewModel(
            sources: commandBarDefaultSources(
                workspace: { @MainActor in sidebar.workspace },
                commandState: { @MainActor [weak shell] in shell?.littleArcCommandBarState ?? .everything }
            ),
            mode: .newTab,
            presentation: .littleArc
        )
        commandBar.onAction = { [weak self] action in self?.handle(action) }
        commandBar.faviconProvider = { [weak shell] result in shell?.controller.commandBarFavicon(for: result) }
        commandBar.onDismiss = { [weak self] in self?.close() }
        colorSchemeObservation = shell.controller.colorSchemeInputsChanged.sink { [weak self] in
            MainActor.assumeIsolated { self?.syncColorScheme() }
        }
        if let initialURL, shell.sidebar.currentProfileID != nil {
            open(initialURL)
        } else {
            commandBar.open(mode: .newTab, currentSpaceID: shell.selectedSpaceID)
        }
    }

    // MARK: Derived state

    /// Window content size for the current phase. Compact: [06 §7] observed ≈ 490×330.
    /// Expanded: `LittleArcTokens.expandedSize` (unknown). Closed: the size of the phase it closed from.
    public var windowSize: CGSize {
        switch displayedPhase {
        case .compact, .closed:
            let size = Metrics.LittleArc.initialSize
            return CGSize(width: size.width, height: size.height)
        case .expanded:
            return LittleArcTokens.expandedSize
        }
    }

    /// The phase whose layout the window shows: a closed window keeps the one it closed in.
    var displayedPhase: Phase { phase == .closed ? phaseBeforeClose : phase }

    /// The page's URL: the engine's once known, else the one the user chose.
    public var currentURL: URL? { page.url ?? requestedURL }

    /// What the top bar shows: the domain only, like the sidebar URL box. [06 §4] observed there;
    /// the same treatment in Little Arc is inferred.
    var addressContent: SidebarURLBoxContent { SidebarURLBoxContent.make(url: currentURL) }

    var canGoBack: Bool { page.canGoBack }
    var canGoForward: Bool { page.canGoForward }
    var reloadMode: SidebarReloadMode { SidebarReloadMode.make(isLoading: page.isLoading) }

    /// Theme palette of the main window's current space: the first row uses its accent. [06 §7] observed.
    var palette: ThemePalette { shell.sidebar.palette }

    /// The page's color scheme: that of a page in the main window's current Space (B21, inferred).
    var colorScheme: WebColorScheme { shell.controller.webColorScheme(forSpace: shell.selectedSpaceID) }

    /// Sends the page its scheme when it changed (system appearance, the Space's theme, View ▸ Appearance).
    private func syncColorScheme() {
        guard let liveTab, phase == .expanded else { return }
        let scheme = colorScheme
        guard scheme != sentColorScheme else { return }
        sentColorScheme = scheme
        engineWork.append(Task { await liveTab.setPreferredColorScheme(scheme) })
    }

    // MARK: Command bar

    /// Runs what the command bar returned.
    func handle(_ action: CommandBarAction) {
        guard phase != .closed else { return }
        switch action {
        case .openURL(let url, _):
            open(url)
        case .searchWeb(let query, _):
            if let url = shell.searchURL(for: query) { open(url) }
        case .switchToTab, .runCommand, .restoreArchived, .goToSpace, .moveTab:
            // These act on the main window. inferred.
            close()
            shell.perform(action)
        }
    }

    /// Loads `url`: expands the window and creates the engine tab on first use. [06 §7] observed
    /// that the window expands after a page is opened.
    public func open(_ url: URL) {
        guard phase != .closed else { return }
        requestedURL = url
        if let liveTab {
            engineWork.append(Task { [weak self] in
                do { try await liveTab.load(url) } catch { self?.lastError = error }
            })
            return
        }
        guard let profileID = shell.sidebar.currentProfileID else { return }
        phase = .expanded
        commandBar.dismiss()
        engineWork.append(Task { [weak self] in await self?.makeLiveTab(profileID: profileID, url: url) })
    }

    private func makeLiveTab(profileID: UUID, url: URL) async {
        do {
            let scheme = colorScheme
            let tab = try await engine.makeTab(TabConfiguration(profileID: profileID, initialURL: url, preferredColorScheme: scheme))
            // The window may have closed while the engine was working.
            guard phase == .expanded, liveTab == nil else {
                await engine.closeTab(tab.id)
                return
            }
            liveTab = tab
            sentColorScheme = scheme
            syncColorScheme()
            dialogs.observe(tab)
            page = SidebarTabLiveState(snapshot: await tab.currentState())
            let stream = tab.events()
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard let self else { return }
                    self.page.apply(event)
                    // window.close(): the window closes with its page (inferred, C7b).
                    if event == .closeRequested { self.close() }
                }
            }
        } catch {
            lastError = error
        }
    }

    // MARK: Toolbar

    func goBack() { runOnTab { try await $0.goBack() } }
    func goForward() { runOnTab { try await $0.goForward() } }

    /// Reload, or stop while loading (same rule as the sidebar). [06 §13] observed there.
    func reloadOrStop() {
        let stop = reloadMode == .stop
        runOnTab { tab in if stop { try await tab.stopLoading() } else { try await tab.reload() } }
    }

    private func runOnTab(_ body: @escaping @Sendable (any BrowserTab) async throws -> Void) {
        guard let liveTab else { return }
        engineWork.append(Task { [weak self] in
            do { try await body(liveTab) } catch { self?.lastError = error }
        })
    }

    // MARK: Adoption and closing

    /// "Open in Open Arc": opens the page as a Today tab in the main window's current space,
    /// selects it and closes this window. Returns the new model tab id. inferred.
    @discardableResult
    public func adopt() -> UUID? {
        guard phase == .expanded, let url = currentURL else { return nil }
        let title = page.title.isEmpty ? (url.host ?? url.absoluteString) : page.title
        let id = shell.adoptLittleArcTab(url: url, title: title)
        close()
        return id
    }

    /// Closes the window and its engine tab (not archived; inferred). Idempotent.
    public func close() {
        guard phase != .closed else { return }
        phaseBeforeClose = phase
        phase = .closed
        eventTask?.cancel()
        eventTask = nil
        if let liveTab {
            dialogs.stopObserving(liveTab.id)
            engineWork.append(Task { [engine] in await engine.closeTab(liveTab.id) })
        }
        liveTab = nil
        commandBar.dismiss()
        onClose?()
    }

    /// The window went away by other means (close button, ⌘W): it is already closing, so it is
    /// not asked to close again.
    func windowDidClose() {
        onClose = nil
        close()
    }

    /// The model of a Little Arc window SwiftUI shows with `windowID` (the scene's value). A window
    /// this run did not ask for (one macOS or SwiftUI brought back from the last session, or the
    /// group's default window) gets a closed model, so the window closes as soon as it appears
    /// instead of showing an empty command bar (B30). [A19] did the same for browser windows.
    /// inferred.
    static func window(_ windowID: UUID?, on controller: WorkspaceController) -> LittleArcModel {
        let issued = controller.wasIssuedLittleArcWindow(windowID)
        // A link from another app gives its window a page to open right away (B24).
        let launchURL = issued ? windowID.flatMap { controller.takeLittleArcLaunchURL(for: $0) } : nil
        let model = LittleArcModel(shell: controller.littleArcHost(), initialURL: launchURL)
        if !issued { model.close() }
        return model
    }

    /// Waits for queued engine work (tab creation, navigation, closing). For tests.
    func settleEngineWork() async {
        while !engineWork.isEmpty {
            let pending = engineWork
            engineWork.removeAll()
            for task in pending { await task.value }
        }
    }
}
