import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The Little Arc window. Compact: the `.littleArc` command bar fills the window. Expanded: a slim
// top bar (domain, back/forward/reload, "Open in Open Arc") above the page. [06 §7] observed for
// the compact state; the expanded layout is not in the spec, so its sizes are `LittleArcTokens`.

/// Scene id of the Little Arc window group.
public enum LittleArcScene {
    public static let id = "little-arc"
}

/// Root view of one Little Arc window. Owns its `LittleArcModel`.
///
/// The window closes itself once the model is `.closed` (Escape, ✕, adoption, `window.close()`):
/// the configurator closes the `NSWindow`. B30: SwiftUI's `dismiss`, used before, left the window
/// open after "Open in Open Arc" opened a new browser window, and the closed model then drew the
/// window as an empty compact command bar.
struct LittleArcWindowView: View {
    @StateObject private var model: LittleArcModel

    /// The window SwiftUI opened with `windowID` (the scene's value). Its model is made once; a
    /// window this run did not open starts closed (see `LittleArcModel.window(_:on:)`).
    init(windowID: UUID?, controller: WorkspaceController) {
        _model = StateObject(wrappedValue: LittleArcModel.window(windowID, on: controller))
    }

    /// A window on an existing model (tests drive the phase through it).
    init(model: LittleArcModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        let size = model.windowSize
        let expanded = model.displayedPhase == .expanded
        let minimum = expanded ? LittleArcTokens.expandedMinimumSize : size
        // Compact is a fixed size; expanded starts at `size` (set by the configurator) and can be resized.
        content
            .frame(
                minWidth: minimum.width, idealWidth: size.width, maxWidth: expanded ? .infinity : size.width,
                minHeight: minimum.height, idealHeight: size.height, maxHeight: expanded ? .infinity : size.height
            )
            .background(LittleArcWindowConfigurator(phase: model.phase, size: size, onClose: { model.windowDidClose() }))
            .ignoresSafeArea()
    }

    @ViewBuilder
    private var content: some View {
        // A closing window keeps the layout it closed in (never the empty command bar, B30).
        switch model.displayedPhase {
        case .compact, .closed:
            CommandBarView(viewModel: model.commandBar, palette: model.palette)
        case .expanded:
            LittleArcBrowsingView(model: model)
        }
    }
}

/// The expanded state: top bar and page.
struct LittleArcBrowsingView: View {
    @ObservedObject var model: LittleArcModel

    var body: some View {
        let palette = model.palette
        VStack(spacing: 0) {
            LittleArcTopBar(model: model, palette: palette)
                .frame(height: LittleArcTokens.topBarHeight)
            WebPanel(tab: model.liveTab, background: palette.webPanelBackground,
                     crashed: model.page.isCrashed ? CrashedPageState(reload: { model.reloadOrStop() }) : nil)
                .environment(\.dialogCenter, model.dialogs)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous))
                .padding([.horizontal, .bottom], LittleArcTokens.pageInset)
        }
        .background(palette.windowBackground.swiftUI)
    }
}

/// Slim bar above the page. Layout unknown (expansion not observed); the controls follow the
/// task: domain, back/forward/reload and the adopt button.
struct LittleArcTopBar: View {
    @ObservedObject var model: LittleArcModel
    let palette: ThemePalette

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: LittleArcTokens.trafficLightReserve)
            toolbarButton("chevron.left", label: "Back", enabled: model.canGoBack) { model.goBack() }
            toolbarButton("chevron.right", label: "Forward", enabled: model.canGoForward) { model.goForward() }
            toolbarButton(model.reloadMode == .stop ? "xmark" : "arrow.clockwise",
                          label: model.reloadMode == .stop ? "Stop" : "Reload",
                          enabled: model.liveTab != nil) { model.reloadOrStop() }
            Spacer(minLength: 8)
            address
            Spacer(minLength: 8)
            Button(LittleArcTokens.adoptButtonTitle) { model.adopt() }
                .buttonStyle(.plain)
                .font(Typography.dialogButton.font.weight(.medium))
                .foregroundStyle(palette.primaryText.swiftUI)
                .padding(.horizontal, 10)
                .frame(height: LittleArcTokens.toolbarButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.controlFill.swiftUI)
                )
                .disabled(model.currentURL == nil)
                .accessibilityIdentifier("openarc.littlearc.adopt")
        }
        .padding(.trailing, 8)
    }

    @ViewBuilder
    private var address: some View {
        switch model.addressContent {
        case .placeholder:
            Text(SidebarURLBoxContent.placeholderText)
                .textStyle(Typography.addressField, ink: palette.chromeInk)
        case .domain(let host, let isSecure):
            HStack(spacing: 4) {
                if isSecure {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                }
                Text(host).lineLimit(1).truncationMode(.middle)
            }
            .textStyle(Typography.addressField, ink: palette.chromeInk)
        }
    }

    private func toolbarButton(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: LittleArcTokens.toolbarButtonSize, height: LittleArcTokens.toolbarButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.primaryText.swiftUI.opacity(enabled ? Metrics.IconOpacity.enabled : Metrics.IconOpacity.disabled))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Window configuration (AppKit)

/// Applies window properties SwiftUI does not expose on macOS 14: floating level, hidden traffic
/// lights while compact, transparent background so the bar's rounded corners show, resizing and
/// re-centering when the phase changes.
///
/// B28: never write the window from inside `updateNSView`. Several of these properties (style
/// mask, title bar, opacity, background, button visibility) are observed by the hosting view, and
/// AppKit notifies observers even when the new value equals the old one. Writing them on every
/// update invalidated the hosting view, which ran another update; and `contentMinSize`, which the
/// hosting view itself sets from the view's minimum frame, was written back to a different value
/// each time: an endless loop that pinned the main thread when the window expanded. So the update only records what it wants and schedules
/// one pass on the next run-loop turn (coalesced); that pass writes a property only when its value
/// differs, and the per-phase changes (size, centering) run once per phase change.
struct LittleArcWindowConfigurator: NSViewRepresentable {
    let phase: LittleArcModel.Phase
    let size: CGSize
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        let coordinator = context.coordinator
        coordinator.view = view
        // The view is usually not in its window yet: ask again once it is.
        view.onMoveToWindow = { [weak coordinator] in coordinator?.requestAgain() }
        coordinator.request(phase: phase, size: size, onClose: onClose)
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.request(phase: phase, size: size, onClose: onClose)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: NSView?
        /// The phase whose size and position were applied last; nil before the first pass.
        private(set) var appliedPhase: LittleArcModel.Phase?
        private var wanted: (phase: LittleArcModel.Phase, size: CGSize)?
        private var isPassScheduled = false
        private var didCloseWindow = false
        private var onClose: (() -> Void)?
        private weak var window: NSWindow?

        /// Records the wanted state and schedules one pass for the next run-loop turn. Calls made
        /// before that turn share the pass.
        func request(phase: LittleArcModel.Phase, size: CGSize, onClose: @escaping () -> Void) {
            wanted = (phase, size)
            if self.onClose == nil, window == nil { self.onClose = onClose }
            schedulePass()
        }

        /// The view moved to a window: run a pass with the state last asked for.
        func requestAgain() {
            guard wanted != nil else { return }
            schedulePass()
        }

        private func schedulePass() {
            guard !isPassScheduled else { return }
            isPassScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.runPass() }
            }
        }

        private func runPass() {
            isPassScheduled = false
            guard let wanted, let window = view?.window else { return }
            attach(to: window)
            LittleArcWindowConfigurator.diagnostics.passCount += 1
            // The model closed: so does its window, as it is (no resize, never made key), also when
            // SwiftUI has not ordered it in yet (a restored window). Once. B30.
            if wanted.phase == .closed {
                guard !didCloseWindow else { return }
                didCloseWindow = true
                LittleArcWindowConfigurator.diagnostics.closeCount += 1
                window.close()
                return
            }
            let isFirstPass = appliedPhase == nil
            if apply(phase: wanted.phase, size: wanted.size, to: window) {
                LittleArcWindowConfigurator.diagnostics.writeCount += 1
            }
            if isFirstPass { show(window, focusingField: wanted.phase == .compact) }
        }

        /// Once, when the window is first configured: make it key (keys typed right after ⌥⌘N
        /// must reach it, B29) and give the command bar field the keyboard. Only inside an active
        /// app, so a link from another app never steals focus from it; `makeKeyAndOrderFront`
        /// is called only when the window is not key yet.
        private func show(_ window: NSWindow, focusingField: Bool) {
            if LittleArcWindowConfigurator.appIsActive(), !window.isKeyWindow, window.canBecomeKey {
                window.makeKeyAndOrderFront(nil)
                LittleArcWindowConfigurator.diagnostics.keyRequestCount += 1
            }
            guard focusingField, let field = Self.commandBarField(in: window.contentView) else { return }
            field.takeFocus?()
        }

        /// The command bar field in `view`'s subtree.
        static func commandBarField(in view: NSView?) -> CommandBarNSTextField? {
            guard let view else { return nil }
            if let field = view as? CommandBarNSTextField { return field }
            for subview in view.subviews {
                if let field = commandBarField(in: subview) { return field }
            }
            return nil
        }

        private func attach(to window: NSWindow) {
            guard self.window == nil else { return }
            self.window = window
            // A Little Arc page lives in an engine tab only, which does not survive a relaunch:
            // the window is never brought back by AppKit's window restoration. inferred (B30).
            window.isRestorable = false
            // Closing the window by any means closes the engine tab. inferred. Selector-based
            // observers are removed automatically when the coordinator goes away.
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification, object: window
            )
        }

        /// Writes what differs. Returns whether anything was written.
        private func apply(phase: LittleArcModel.Phase, size: CGSize, to window: NSWindow) -> Bool {
            var changed = false
            func set<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NSWindow, Value>, _ value: Value) {
                guard window[keyPath: keyPath] != value else { return }
                window[keyPath: keyPath] = value
                changed = true
            }
            // Floating level: inferred (a Little Arc stays above other apps' windows).
            set(\.level, .floating)
            set(\.titleVisibility, .hidden)
            set(\.titlebarAppearsTransparent, true)
            set(\.isMovableByWindowBackground, true)
            set(\.title, LittleArcTokens.windowTitle)
            let compact = phase != .expanded
            // Compact: no title bar controls at all. [06 §7] observed ("no title bar").
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                if let button = window.standardWindowButton(kind), button.isHidden != compact {
                    button.isHidden = compact
                    changed = true
                }
            }
            // Compact: the command bar draws its own rounded panel; the window itself is clear.
            set(\.isOpaque, !compact)
            let background: NSColor = compact ? .clear : .windowBackgroundColor
            if !window.backgroundColor.isEqual(background) {
                window.backgroundColor = background
                changed = true
            }
            if compact {
                if window.styleMask.contains(.resizable) {
                    window.styleMask.remove(.resizable)
                    changed = true
                }
            } else {
                if !window.styleMask.contains(.resizable) {
                    window.styleMask.insert(.resizable)
                    changed = true
                }
                // No `contentMinSize` here: the hosting view keeps it in step with the view's
                // minimum frame (`LittleArcTokens.expandedMinimumSize` plus the title bar inset).
                // Writing our own value made the two fight, one SwiftUI update per write (B28).
            }

            // Size and position: once per phase change, so a window the user resized keeps its size.
            guard appliedPhase != phase else { return changed }
            let isFirst = appliedPhase == nil
            appliedPhase = phase
            changed = true
            // Keep the window's center when it grows. Centered on screen when it first opens. inferred.
            let oldFrame = window.frame
            window.setContentSize(size)
            if isFirst {
                window.center()
            } else {
                var frame = window.frame
                frame.origin.x = oldFrame.midX - frame.width / 2
                frame.origin.y = oldFrame.maxY - frame.height
                if let visible = window.screen?.visibleFrame {
                    frame.origin.x = min(max(frame.origin.x, visible.minX), max(visible.minX, visible.maxX - frame.width))
                    frame.origin.y = min(max(frame.origin.y, visible.minY), max(visible.minY, visible.maxY - frame.height))
                }
                window.setFrame(frame, display: true, animate: false)
            }
            return changed
        }

        @objc private func windowWillClose(_ notification: Notification) {
            // Closed by other means (close button, ⇧⌘W): the pass for `.closed` has nothing to do.
            didCloseWindow = true
            onClose?()
            onClose = nil
        }
    }

    /// Tells the coordinator when it lands in a window.
    final class WindowProbeView: NSView {
        var onMoveToWindow: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { onMoveToWindow?() }
        }
        // Transparent to the mouse: the window background stays draggable.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// Process-wide counters of configurator passes (all passes, and passes that wrote at least
    /// one property), for the B28 regression test, and of key requests (B29).
    @MainActor
    struct Diagnostics {
        var passCount = 0
        var writeCount = 0
        /// How often a shown window was made key (B29).
        var keyRequestCount = 0
        /// How often a window was closed because its model closed (B30).
        var closeCount = 0
    }

    @MainActor static var diagnostics = Diagnostics()

    /// Whether the app is active (the window may then take the keyboard). Tests replace it: a test
    /// runner is never the active app.
    @MainActor static var appIsActive: () -> Bool = { NSApp?.isActive ?? false }
}

// MARK: - Opening

/// Gives the shell a way to open a Little Arc window (for the command bar's "New Little Arc
/// Window" row). Apply it to a view inside a scene, where `openWindow` is available.
struct LittleArcOpenerInstaller: ViewModifier {
    let shell: ShellModel
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let open = openWindow
            shell.openLittleArcWindow = { [weak controller = shell.controller] in
                guard let controller else { return }
                // Keys typed before the new window has the keyboard wait for it (B29).
                NewWindowTypeAhead.shared.begin(.littleArc)
                // An id this run issued: only those windows show a command bar (B30).
                open(id: LittleArcScene.id, value: controller.issueLittleArcWindowID())
            }
        }
    }
}

extension View {
    func installsLittleArcOpener(_ shell: ShellModel) -> some View {
        modifier(LittleArcOpenerInstaller(shell: shell))
    }
}
