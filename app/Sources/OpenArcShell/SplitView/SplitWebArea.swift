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
        // The pane at the panel's top-left corner leads with the show-sidebar button while the
        // sidebar is hidden (toolbar on). [06 §17.2] observed for the single page; inferred here.
        let topLeading = panes.min { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }?.tabID
        ZStack(alignment: .topLeading) {
            ForEach(panes, id: \.tabID) { pane in
                SplitPaneView(
                    model: model,
                    tab: sidebar.liveTab(for: pane.tabID),
                    findBar: FindBarHost(model: model.findBar, tabID: pane.tabID),
                    bar: model.paneBarState(for: pane.tabID),
                    toolbar: model.webToolbarState(for: pane.tabID),
                    items: model.webToolbarItems(role: .pane(isActive: pane.tabID == sidebar.selectedTabID),
                                                 isTopLeading: pane.tabID == topLeading),
                    layout: SplitPaneBarLayout(paneFrame: CGRect(origin: .zero, size: pane.frame.size)),
                    isFocused: showsRing && pane.tabID == sidebar.selectedTabID,
                    palette: palette,
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

/// One pane: its top bar, then the page below it, rounded like the single web panel, with a ring
/// when focused. [06 §5] observed. The bar is the web toolbar strip ([06 §17.6] observed: "the
/// pane top bar of §5"): with the toolbar off it holds back, forward, the domain group and ✕
/// ([06 §5]); with it on, the active pane adds reload, site controls and the split menu.
struct SplitPaneView: View {
    @ObservedObject var model: ShellModel
    let tab: (any BrowserTab)?
    /// The pane's find bar; it shows only over the focused pane (`FindBarModel` targets the
    /// selected tab). B25.
    let findBar: FindBarHost
    let bar: SplitPaneBarState
    let toolbar: WebToolbarState
    let items: WebToolbarItems
    let layout: SplitPaneBarLayout
    let isFocused: Bool
    let palette: ThemePalette
    /// Set while the pane's renderer is gone (C9).
    var crashed: CrashedPageState? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous)
        let colors = model.webToolbarColors(for: bar.tabID)
        ZStack(alignment: .topLeading) {
            WebToolbarView(model: model, state: toolbar, items: items, colors: colors, size: layout.barFrame.size,
                           siteControls: model.siteControls, settings: model.webToolbar)
                // An inactive pane's bar is fainter with the toolbar off. [06 §5] observed.
                .opacity(model.isWebToolbarShown ? SplitPaneBarTokens.activeOpacity : bar.opacity)
                .offset(x: layout.barFrame.minX, y: layout.barFrame.minY)
            WebPanel(tab: tab, findBar: findBar, background: palette.webPanelBackground, crashed: crashed)
                .frame(width: layout.pageFrame.width, height: layout.pageFrame.height)
                .offset(x: layout.pageFrame.minX, y: layout.pageFrame.minY)
        }
        .frame(width: layout.paneFrame.width, height: layout.paneFrame.height, alignment: .topLeading)
        // A transparent bar (empty pane) shows the panel fill. [06 §17.4] observed.
        .background(palette.webPanelBackground.swiftUI)
        .clipShape(shape)
        .webPanelEdgeShadow(palette.appearance)
        .overlay {
            if isFocused {
                shape
                    // ≈ 1 pt theme-color ring with the toolbar on ([06 §17.6] observed); the
                    // toolbar-off width stays the B18 placeholder.
                    .strokeBorder(palette.commandBarSelection.swiftUI.opacity(SplitPaneStyle.focusRingOpacity),
                                  lineWidth: model.isWebToolbarShown ? Metrics.WebToolbar.splitPaneFocusRingWidth : SplitPaneStyle.focusRingWidth)
                    .allowsHitTesting(false)
            }
        }
        .background(PointerDownObserver(onPointerDown: { model.focusPane(bar.tabID) }))
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
