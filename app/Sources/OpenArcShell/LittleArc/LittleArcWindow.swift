import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The Little Arc window. Compact: the `.littleArc` command bar fills the window ([06 §7] observed).
// Expanded: the 47 pt top bar (Profile capsule, domain, copy link, "Open in <Space> ⌘O" with a
// Spaces dropdown) above the page ([06 §21.7] observed, B60).

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
    /// Content scale: 98 % before it appears and while it closes, 100 % otherwise. [07 §11]
    /// observed on the window frame (480×323 ↔ 490×329); ours scales the content (inferred
    /// equivalent: the window frame of the compact bar is fixed by its content).
    @State private var isPresented = false

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
            .scaleEffect(isPresented && model.phase != .closed ? 1 : Motion.littleArcScale)
            .background(LittleArcWindowConfigurator(
                phase: model.phase, size: size, closeMotion: Self.closeMotion(model.closeStyle),
                onClose: { model.windowDidClose() }
            ))
            .ignoresSafeArea()
            // Open: no fade, 98 % → 100 % in ≈ 80 ms. [07 §11] observed. B40.
            .onAppear { withAnimation(ShellMotion.littleArcOpen) { isPresented = true } }
            // Close: shrinks back to 98 % while the configurator fades the window. [07 §11] observed.
            .animation(model.closeStyle == .adopt ? ShellMotion.littleArcExpandToMain : ShellMotion.littleArcClose,
                       value: model.phase == .closed)
    }

    /// Window fade of a closing Little Arc. [07 §11] observed.
    static func closeMotion(_ style: LittleArcModel.CloseStyle) -> MotionToken {
        style == .adopt ? Motion.littleArcExpandToMain : Motion.littleArcClose
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

/// The expanded state: top bar and page, with the Spaces dropdown over them. [06 §21.7] observed.
struct LittleArcBrowsingView: View {
    @ObservedObject var model: LittleArcModel
    /// "Copied Current URL" after the copy link icon ([06 §17.3] observed in the main window; the
    /// same notice here is inferred).
    @StateObject private var copyToast = WebToolbarCopyToast()
    /// See-through like the main window (B64, [07 §8.4]; for Little Arc inferred), opaque in full
    /// screen and with Reduce Transparency.
    @State private var isFullScreen = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let palette = model.palette
        let surface = WindowSurface(palette: palette, isFullScreen: isFullScreen, reduceTransparency: reduceTransparency)
        VStack(spacing: 0) {
            LittleArcTopBar(model: model, palette: palette, onCopy: { if model.copyLink() { copyToast.show() } })
                .frame(height: LittleArcTokens.topBarHeight)
            WebPanel(tab: model.liveTab, background: palette.webPanelBackground,
                     crashed: model.page.isCrashed ? CrashedPageState(reload: { model.reloadOrStop() }) : nil)
                .environment(\.dialogCenter, model.dialogs)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous))
                .webPanelEdgeShadow(palette.appearance)
                .padding([.horizontal, .bottom], LittleArcTokens.pageInset)
        }
        .overlay(alignment: .topTrailing) {
            VStack(alignment: .trailing, spacing: 8) {
                // Opens in place over the button, top-right aligned. [06 §21.7] observed.
                if model.spacePicker.isOpen {
                    LittleArcSpacePickerPanel(model: model)
                        .padding(.top, LittleArcTopBarLayout.panelTopInset)
                        .padding(.trailing, LittleArcTopBarLayout.trailingInset)
                }
                WebToolbarCopyToastView(toast: copyToast, palette: palette)
                    .padding(.trailing, LittleArcTopBarLayout.trailingInset + LittleArcTokens.pageInset)
                    .padding(.top, model.spacePicker.isOpen ? 0 : LittleArcTokens.topBarHeight + 8)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.windowSurface, surface)
        .background(WindowBackgroundView(palette: palette, surface: surface))
        .background(TranslucentWindowConfigurator { isFullScreen = $0 })
        // Traffic lights centered on the 47 pt bar: the main window's measured spot (center y 24,
        // [07 §2] observed) suits it; using it here is inferred.
        .background(MainWindowChromeConfigurator(placement: .pinned))
    }
}

/// Sizes of the expanded top bar that the spec leaves open. inferred unless noted.
enum LittleArcTopBarLayout {
    static let trailingInset: CGFloat = 10
    /// The panel covers the button: its top sits at the button's top. inferred.
    static let panelTopInset: CGFloat = (LittleArcTokens.topBarHeight - CGFloat(LittleArcSpaceTargetTokens.buttonHeight)) / 2
    /// Copy link icon. [06 §21.7] observed (16×16).
    static let copyIconSize: CGFloat = 16
    static let capsuleHeight: CGFloat = 24
}

/// The 47 pt bar: traffic lights · Profile capsule · centered domain · copy link · "Open in <Space>
/// ⌘O" | dropdown arrow. [06 §21.7] observed.
struct LittleArcTopBar: View {
    @ObservedObject var model: LittleArcModel
    let palette: ThemePalette
    var onCopy: () -> Void = {}
    @Environment(\.windowSurface) private var surface

    var body: some View {
        ZStack {
            address
                .padding(.horizontal, 220)
            HStack(spacing: 10) {
                Color.clear.frame(width: LittleArcTokens.trafficLightReserve)
                if let name = model.profileCapsuleName { profileCapsule(name) }
                Spacer(minLength: 8)
                copyButton
                openInButton
            }
            .padding(.trailing, LittleArcTopBarLayout.trailingInset)
        }
    }

    /// Smiley icon + profile name. [06 §21.7] observed (non-Default profile).
    private func profileCapsule(_ name: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "face.smiling").font(.system(size: 12, weight: .medium))
            Text(name).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.primaryText.swiftUI)
        .padding(.horizontal, 9)
        .frame(height: LittleArcTopBarLayout.capsuleHeight)
        .background(Capsule().fill(palette.windowFills(on: surface).controlFill.swiftUI))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openarc.littlearc.profile")
    }

    /// Centered domain, ≈ 13 pt. [06 §21.7] observed.
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
            .accessibilityIdentifier("openarc.littlearc.domain")
        }
    }

    private var copyButton: some View {
        Button(action: onCopy) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .frame(width: LittleArcTopBarLayout.copyIconSize, height: LittleArcTopBarLayout.copyIconSize)
                .padding(5)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.primaryText.swiftUI.opacity(Metrics.IconOpacity.enabled))
        .disabled(model.currentURL == nil)
        .accessibilityLabel("Copy Link")
        .accessibilityIdentifier("openarc.littlearc.copyLink")
    }

    /// Dark split button: "Open in **Space** ⌘O" · divider · dropdown arrow. [06 §21.7] observed.
    private var openInButton: some View {
        let ink = Color.white
        let height = CGFloat(LittleArcSpaceTargetTokens.buttonHeight)
        return HStack(spacing: 0) {
            Button { model.adopt() } label: {
                HStack(spacing: 6) {
                    openInTitle
                    Text(LittleArcSpaceTargetTokens.keyCap)
                        .font(Typography.dialogKeyCap.font)
                        .foregroundStyle(ink.opacity(0.7))
                        .padding(.horizontal, 4)
                        .frame(minHeight: 16)
                        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(ink.opacity(0.14)))
                }
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .frame(height: height)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // ⌘O: open in the target Space. [06 §21.7], [02] observed.
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityIdentifier("openarc.littlearc.adopt")
            Rectangle().fill(ink.opacity(0.2)).frame(width: 1, height: height - 10)
            Button { model.toggleSpacePicker() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 26, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Choose Space")
            .accessibilityIdentifier("openarc.littlearc.spaceMenu")
        }
        .foregroundStyle(ink)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(LittleArcSpaceTargetTokens.darkFill.swiftUI))
        .disabled(model.currentURL == nil)
    }

    /// "Open in " + bold Space name. [06 §21.7] observed.
    private var openInTitle: some View {
        Group {
            if let name = model.targetSpaceName {
                Text(LittleArcSpaceTargetTokens.openInPrefix) + Text(name).fontWeight(.bold)
            } else {
                Text(LittleArcTokens.adoptButtonTitle)
            }
        }
        .font(.system(size: 13, weight: .regular))
        .lineLimit(1)
    }
}

/// The dark Spaces panel: "Search Spaces…" + collapse arrow, then one row per Space (theme-colored
/// square + name, ≈ 39 pt), the default target first and highlighted, scrollable. [06 §21.7] observed.
struct LittleArcSpacePickerPanel: View {
    @ObservedObject var model: LittleArcModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let options = model.spaceOptions
        let rowHeight = CGFloat(LittleArcSpaceTargetTokens.rowHeight)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField(LittleArcSpaceTargetTokens.searchPlaceholder, text: Binding(
                    get: { model.spacePicker.query },
                    set: { model.setSpaceQuery($0) }
                ))
                .textFieldStyle(.plain)
                // The dark panel: a dark field appearance, so the prompt and caret are light.
                .environment(\.colorScheme, .dark)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit { model.chooseHighlightedSpace() }
                .onKeyPress(.downArrow) { model.moveSpaceHighlight(by: 1); return .handled }
                .onKeyPress(.upArrow) { model.moveSpaceHighlight(by: -1); return .handled }
                .onKeyPress(.escape) { model.closeSpacePicker(); return .handled }
                .accessibilityIdentifier("openarc.littlearc.spaceSearch")
                Button { model.closeSpacePicker() } label: {
                    Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Collapse")
            }
            .padding(.horizontal, 12)
            .frame(height: CGFloat(LittleArcSpaceTargetTokens.buttonHeight) + 6)
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                        row(option, highlighted: index == model.spacePicker.highlightedIndex)
                            .frame(height: rowHeight)
                    }
                }
                .padding(4)
            }
            .frame(height: rowHeight * CGFloat(min(max(options.count, 1), LittleArcSpaceTargetTokens.visibleRows)) + 8)
        }
        .foregroundStyle(Color.white)
        .frame(width: CGFloat(LittleArcSpaceTargetTokens.panelWidth))
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LittleArcSpaceTargetTokens.darkFill.swiftUI))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .onAppear { fieldFocused = true }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.littlearc.spacePicker")
    }

    private func row(_ option: LittleArcSpaceOption, highlighted: Bool) -> some View {
        Button { model.chooseSpace(option.id) } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(option.swatch.swiftUI)
                    .frame(width: 22, height: 22)
                    .overlay {
                        if let icon = option.icon {
                            SidebarSpaceIconView(icon: icon, size: 22, glyphSize: 12, tint: .black.opacity(0.6))
                        }
                    }
                Text(option.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(highlighted ? 0.14 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("openarc.littlearc.space.\(option.name)")
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
    /// Fade of the window once the model closed. [07 §11] observed.
    var closeMotion: MotionToken = Motion.littleArcClose
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowProbeView {
        let view = WindowProbeView()
        let coordinator = context.coordinator
        coordinator.view = view
        // The view is usually not in its window yet: ask again once it is.
        view.onMoveToWindow = { [weak coordinator] in coordinator?.requestAgain() }
        coordinator.request(phase: phase, size: size, closeMotion: closeMotion, onClose: onClose)
        return view
    }

    func updateNSView(_ nsView: WindowProbeView, context: Context) {
        context.coordinator.request(phase: phase, size: size, closeMotion: closeMotion, onClose: onClose)
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var view: NSView?
        /// The phase whose size and position were applied last; nil before the first pass.
        private(set) var appliedPhase: LittleArcModel.Phase?
        private var wanted: (phase: LittleArcModel.Phase, size: CGSize)?
        private var closeMotion: MotionToken = Motion.littleArcClose
        private var isPassScheduled = false
        private var didCloseWindow = false
        private var onClose: (() -> Void)?
        private weak var window: NSWindow?

        /// Records the wanted state and schedules one pass for the next run-loop turn. Calls made
        /// before that turn share the pass.
        func request(phase: LittleArcModel.Phase, size: CGSize, closeMotion: MotionToken, onClose: @escaping () -> Void) {
            wanted = (phase, size)
            self.closeMotion = closeMotion
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
                fadeOutAndClose(window)
                return
            }
            let isFirstPass = appliedPhase == nil
            if apply(phase: wanted.phase, size: wanted.size, to: window) {
                LittleArcWindowConfigurator.diagnostics.writeCount += 1
            }
            if isFirstPass { show(window, focusingField: wanted.phase == .compact) }
        }

        /// Fades the window out on `closeMotion`, then closes it. [07 §11] observed: alpha 1 → 0
        /// over ≈ 0.2 s (Escape) or ≈ 0.19 s ("Open in <Space>"). A window not on screen yet (a
        /// restored one, B30) closes at once.
        private func fadeOutAndClose(_ window: NSWindow) {
            let curve = closeMotion.curve
            guard window.isVisible, curve.nominalDuration > 0 else {
                window.close()
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = curve.nominalDuration
                context.timingFunction = curve.mediaTimingFunction
                window.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { window.close() }
            }
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
            // No system open/close animation: Little Arc appears without a fade and closes with
            // its own fade ([07 §11] observed). B40.
            window.animationBehavior = .none
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
            // Expanded: clear too, the view draws the see-through window background (B64).
            set(\.isOpaque, false)
            let background: NSColor = .clear
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
            // First opening: top right of the screen's visible area, 20 pt in from its right and
            // top edges. [07 §12] observed. Later phase changes keep the window's center. inferred.
            let oldFrame = window.frame
            window.setContentSize(size)
            if isFirst {
                if let screen = window.screen ?? NSScreen.main {
                    let height = screen.frame.maxY
                    let visible = FloatingBubbleLayout.flip(screen.visibleFrame, height: height)
                    let origin = FloatingBubbleLayout.littleArcOrigin(size: window.frame.size, visible: visible)
                    window.setFrameOrigin(NSPoint(x: origin.x, y: height - origin.y - window.frame.height))
                } else {
                    window.center()
                }
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
