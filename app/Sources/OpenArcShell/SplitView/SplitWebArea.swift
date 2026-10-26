import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The web panel area while the selected tab belongs to a split layout: 2–4 panes side by side,
// each with its tab's surface, separated by the pane gap. [06 §5] observed.

struct SplitWebArea: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    let layout: SplitLayout
    let size: CGSize
    let palette: ThemePalette

    var body: some View {
        let container = CGRect(origin: .zero, size: size)
        let panes = model.splitPaneFrames(in: container)
        let showsRing = panes.count > 1
        ZStack(alignment: .topLeading) {
            ForEach(panes, id: \.tabID) { pane in
                SplitPaneView(
                    tab: sidebar.liveTab(for: pane.tabID),
                    findBar: FindBarHost(model: model.findBar, tabID: pane.tabID),
                    bar: model.paneBarState(for: pane.tabID),
                    layout: SplitPaneBarLayout(paneFrame: CGRect(origin: .zero, size: pane.frame.size)),
                    isFocused: showsRing && pane.tabID == sidebar.selectedTabID,
                    palette: palette,
                    actions: SplitPaneBarActions(model: model, tabID: pane.tabID),
                    crashed: model.crashedPageState(for: pane.tabID)
                )
                .frame(width: pane.frame.width, height: pane.frame.height)
                .offset(x: pane.frame.minX, y: pane.frame.minY)
            }
            // The command bar sits inside its pane, outside the pane's rounded clip.
            if let barTab = model.commandBarPaneTabID, let pane = panes.first(where: { $0.tabID == barTab }) {
                PaneCommandBarOverlay(commandBar: model.paneCommandBar, palette: palette, paneFrame: pane.frame)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        // Panes other than the selected tab may not have an engine tab yet.
        .task(id: layout.root.tabIDs) {
            for id in layout.root.tabIDs { await sidebar.ensureLive(id) }
        }
    }
}

/// What the buttons of one pane's top bar do; every action names its pane's tab, so the right
/// tab is affected even when another pane is focused.
@MainActor
struct SplitPaneBarActions {
    let model: ShellModel
    let tabID: UUID

    func focus() { model.focusPane(tabID) }
    func back() { model.paneGoBack(tabID) }
    func forward() { model.paneGoForward(tabID) }
    func openAddress() { model.paneOpenAddressBar(tabID) }
    func close() { model.paneClose(tabID) }
}

/// One pane: its top bar, then the page below it, rounded like the single web panel, with a ring
/// when focused. [06 §5] observed.
struct SplitPaneView: View {
    let tab: (any BrowserTab)?
    /// The pane's find bar; it shows only over the focused pane (`FindBarModel` targets the
    /// selected tab). B25.
    let findBar: FindBarHost
    let bar: SplitPaneBarState
    let layout: SplitPaneBarLayout
    let isFocused: Bool
    let palette: ThemePalette
    let actions: SplitPaneBarActions
    /// Set while the pane's renderer is gone (C9).
    var crashed: CrashedPageState? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            SplitPaneBarView(bar: bar, layout: layout, palette: palette, actions: actions)
                .frame(width: layout.barFrame.width, height: layout.barFrame.height)
                .offset(x: layout.barFrame.minX, y: layout.barFrame.minY)
            WebPanel(tab: tab, findBar: findBar, background: palette.webPanelBackground, crashed: crashed)
                .frame(width: layout.pageFrame.width, height: layout.pageFrame.height)
                .offset(x: layout.pageFrame.minX, y: layout.pageFrame.minY)
        }
        .frame(width: layout.paneFrame.width, height: layout.paneFrame.height, alignment: .topLeading)
        .background(palette.controlFill.swiftUI)
        .clipShape(shape)
        .overlay {
            if isFocused {
                shape
                    .strokeBorder(palette.commandBarSelection.swiftUI.opacity(SplitPaneStyle.focusRingOpacity), lineWidth: SplitPaneStyle.focusRingWidth)
                    .allowsHitTesting(false)
            }
        }
        .background(PointerDownObserver(onPointerDown: actions.focus))
    }
}

/// The slim bar: back and forward on the left, the "🔗 domain" pill centered, ✕ on the right.
/// An inactive pane's bar is fainter. [06 §5] observed.
struct SplitPaneBarView: View {
    let bar: SplitPaneBarState
    let layout: SplitPaneBarLayout
    let palette: ThemePalette
    let actions: SplitPaneBarActions

    var body: some View {
        let tint = palette.primaryText.swiftUI
        let origin = layout.barFrame.origin
        ZStack(alignment: .topLeading) {
            button("chevron.left", label: "Back", enabled: bar.canGoBack, frame: layout.backButtonFrame, origin: origin, tint: tint, action: actions.back)
            button("chevron.right", label: "Forward", enabled: bar.canGoForward, frame: layout.forwardButtonFrame, origin: origin, tint: tint, action: actions.forward)
            Button(action: actions.openAddress) {
                HStack(spacing: 4) {
                    Image(systemName: "link").font(.system(size: 11, weight: .medium))
                    Text(bar.domain ?? SidebarURLBoxContent.placeholderText)
                        .font(Typography.paneBarPill.font)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(tint.opacity(0.8))
                .padding(.horizontal, SplitPaneBarTokens.pillHorizontalPadding)
                .frame(width: layout.pillFrame.width, height: layout.pillFrame.height)
                .background(Capsule().fill(Color.black.opacity(SplitPaneBarTokens.pillFillOpacity)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Address")
            .offset(x: layout.pillFrame.minX - origin.x, y: layout.pillFrame.minY - origin.y)
            button("xmark", label: "Close split pane", enabled: true, frame: layout.closeButtonFrame, origin: origin, tint: tint, action: actions.close)
        }
        .frame(width: layout.barFrame.width, height: layout.barFrame.height, alignment: .topLeading)
        .opacity(bar.opacity)
    }

    private func button(
        _ symbol: String, label: String, enabled: Bool, frame: CGRect, origin: CGPoint, tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: SplitPaneBarTokens.symbolFontSize, weight: .medium))
                .foregroundStyle(tint.opacity(enabled ? 0.8 : 0.3))
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
        .offset(x: frame.minX - origin.x, y: frame.minY - origin.y)
    }
}

/// The command bar in the lower right of the pane it belongs to. [06 §5] observed.
struct PaneCommandBarOverlay: View {
    @ObservedObject var commandBar: CommandBarViewModel
    let palette: ThemePalette
    let paneFrame: CGRect

    var body: some View {
        let layout = CommandBarLayout(presentation: .pane, resultCount: commandBar.results.count)
        let frame = layout.panelFrame(in: paneFrame.size)
        CommandBarView(viewModel: commandBar, palette: palette)
            .offset(x: paneFrame.minX + frame.minX, y: paneFrame.minY + frame.minY)
    }
}

// MARK: - Pointer observation (AppKit)

/// Reports left mouse-downs inside its bounds without consuming them, so a click on a web view
/// still reaches the web view while the pane gets focused.
struct PointerDownObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> PointerDownObserverView {
        let view = PointerDownObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: PointerDownObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class PointerDownObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var monitor: EventMonitorToken?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard window != nil else { return }
        let token = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        monitor = token.map(EventMonitorToken.init)
    }

    /// Never takes part in hit-testing; clicks fall through to the pane content.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func handle(_ event: NSEvent) {
        guard let window, event.window === window else { return }
        handle(locationInWindow: event.locationInWindow)
    }

    func handle(locationInWindow point: NSPoint) {
        if bounds.contains(convert(point, from: nil)) { onPointerDown?() }
    }

    private func removeMonitor() { monitor = nil }
}

/// Removes its event monitor when released, so the observer view needs no `deinit`.
private final class EventMonitorToken {
    private let monitor: Any

    init(_ monitor: Any) { self.monitor = monitor }

    deinit { NSEvent.removeMonitor(monitor) }
}
