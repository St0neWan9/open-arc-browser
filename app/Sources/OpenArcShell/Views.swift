import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Root view of a browser window: sidebar, web panel and the floating command bar.

extension RGBAColor {
    /// SwiftUI color for a token color.
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}

/// Root view of a browser window.
public struct MainWindowView: View {
    @ObservedObject private var model: ShellModel

    public init(model: ShellModel) {
        self.model = model
    }

    public var body: some View {
        MainWindowContent(model: model, sidebar: model.sidebar)
            .modifier(LaunchNoticeAlert(model: model))
    }
}

/// Split out so it observes the sidebar view model (the owner of workspace and selection) as well
/// as the shell model (command bar and sidebar visibility).
struct MainWindowContent: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel

    var body: some View {
        // While the Create Space view is up the window uses the default light neutral theme. [06 §1] observed.
        let palette = model.windowPalette
        GeometryReader { proxy in
            let layout = model.windowLayout(size: proxy.size)
            ZStack(alignment: .topLeading) {
                // The window background is the space theme color, with no separate title bar. [04 §window structure]
                WindowBackgroundView(palette: palette)

                if model.library.isActive {
                    // The whole window switches to the Library view. [06 §8] observed.
                    LibraryView(model: model, sidebar: sidebar, library: model.library, palette: palette, windowSize: proxy.size)
                } else {
                    browserContent(layout: layout, palette: palette)
                }

                // Hidden sidebar: it floats out over the web panel from the left edge. [06 §14] B34.
                if model.showsSidebarPeek {
                    SidebarPeekOverlay(sidebar: sidebar, siteControls: model.siteControls, windowSize: proxy.size)
                        .transition(SidebarPeekOverlay.transition(windowSize: proxy.size))
                }

                // A pane command bar is drawn inside its pane by `SplitWebArea`.
                if model.isCommandBarPresented && model.commandBarPaneTabID == nil {
                    CommandBarOverlay(model: model, commandBar: model.commandBar, windowSize: proxy.size, palette: palette)
                }

                // The selected tab's permission prompt hangs under the URL box (inferred, C7b).
                if let tabID = permissionTabUnderURLBox {
                    PermissionBubbleUnderURLBox(
                        center: model.controller.dialogs, tabID: tabID,
                        origin: PermissionPromptPlacement.originUnderURLBox(in: layout)
                    )
                }

                // First-run onboarding cards over the themed background (D9, own design).
                OnboardingLayer(model: model, onboarding: model.controller.onboarding, palette: palette)
            }
            .environment(\.dialogCenter, model.controller.dialogs)
            // The window command bar and onboarding cover the sidebar: presses go to them.
            .environment(\.sidebarAcceptsPointer, !(model.isCommandBarPresented && model.commandBarPaneTabID == nil)
                         && !model.controller.onboarding.isShown(in: model))
            .environment(\.windowDrawnPermissionTab, permissionTabUnderURLBox)
            .animation(ShellLocalTokens.sidebarToggleAnimation, value: model.isSidebarVisible)
            .animation(SidebarPeekTokens.slideAnimation, value: model.showsSidebarPeek)
            // Window-level pointer tracking for the left-edge hot zone; it sees the pointer over
            // the engine's web view too, and never takes clicks. [06 §14] B34.
            .overlay {
                if model.tracksSidebarPeek {
                    SidebarPeekTracker { [weak peek = model.sidebarPeek] point, size in
                        peek?.pointerMoved(to: point, windowSize: size)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: Motion.spaceCreateFade), value: model.spaceFlow.isCreating)
        .modifier(SpaceFlowSheets(flow: model.spaceFlow, workspace: sidebar.workspace, palette: model.windowPalette))
        .overlay(alignment: .bottomLeading) { themeEditorAnchor }
        // System-drawn floating panels (popovers, menus) follow the Space's light or dark. B21.
        .background(WindowAppearanceApplier(appearance: model.isIncognito ? nil : palette.appearance))
    }

    /// The engine tab whose permission bubble goes under the URL box: the selected tab's, while
    /// the sidebar shows and the Library is not up. inferred.
    private var permissionTabUnderURLBox: EngineTabID? {
        let visible = model.isSidebarVisible && !model.spaceFlow.isCreating && !model.library.isActive
        guard PermissionPromptPlacement.isUnderURLBox(tabID: sidebar.selectedTabID, selectedTabID: sidebar.selectedTabID, isSidebarVisible: visible) else {
            return nil
        }
        return model.selectedLiveTab?.id
    }

    /// Sidebar (or the Create Space view) and the web panel: the normal browser view.
    @ViewBuilder
    private func browserContent(layout: MainWindowLayout, palette: ThemePalette) -> some View {
        if model.spaceFlow.isCreating {
            NewSpaceView(flow: model.spaceFlow, palette: palette)
                .frame(width: layout.sidebarFrame.width, height: layout.sidebarFrame.height)
        } else if model.isSidebarVisible {
            // Slides out to the left while the web panel expands. Timing: see `ShellLocalTokens`.
            SidebarView(viewModel: sidebar)
                .environment(\.siteControlsModel, model.siteControls)
                .frame(width: layout.sidebarFrame.width, height: layout.sidebarFrame.height)
                .transition(.move(edge: .leading))
        }

        if let splitLayout = model.activeSplitLayout {
            // Each pane is clipped on its own, so the gap between panes shows the window background.
            let size = layout.webPanelFrame.size
            SplitWebArea(model: model, sidebar: sidebar, layout: splitLayout, size: size, palette: palette)
                .webPanelDropTarget(sidebar: sidebar, panes: model.splitPaneFrames(in: CGRect(origin: .zero, size: size)).map {
                    SidebarWebPanelDrop.Pane(tabID: $0.tabID, frame: $0.frame)
                })
                .offset(x: layout.webPanelFrame.minX, y: layout.webPanelFrame.minY)
        } else {
            WebPanel(tab: model.selectedLiveTab, findBar: model.findBarHost, background: palette.webPanelBackground,
                     crashed: model.crashedPageState(for: sidebar.selectedTabID))
                .frame(width: layout.webPanelFrame.width, height: layout.webPanelFrame.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous))
                .webPanelEdgeShadow(palette.appearance)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("openarc.webPanel")
                .webPanelDropTarget(sidebar: sidebar, panes: sidebar.selectedTabID.map {
                    [SidebarWebPanelDrop.Pane(tabID: $0, frame: CGRect(origin: .zero, size: layout.webPanelFrame.size))]
                } ?? [])
                .offset(x: layout.webPanelFrame.minX, y: layout.webPanelFrame.minY)
        }
    }

    /// Invisible anchor at the window's lower left for the Edit Theme bubble. [06 §2] observed:
    /// the bubble opens from the lower left. It opens to the right of the anchor, over the web panel.
    private var themeEditorAnchor: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .padding(.leading, 24)
            .padding(.bottom, 28)
            .popover(isPresented: Binding(
                get: { model.spaceFlow.themeEditorSpaceID != nil },
                set: { if !$0 { model.spaceFlow.closeThemeEditor() } }
            ), arrowEdge: .trailing) {
                if let spaceID = model.spaceFlow.themeEditorSpaceID {
                    ThemeEditorView(theme: Binding(
                        get: { model.spaceFlow.themeDraft(of: spaceID) },
                        set: { model.spaceFlow.applyThemeDraft($0, to: spaceID) }
                    ), systemAppearance: model.controller.systemAppearance)
                }
            }
            .allowsHitTesting(false)
    }
}

/// The command bar floating over the window. There is no dimming scrim [04 §command bar] observed;
/// a click outside the panel dismisses it (inferred).
struct CommandBarOverlay: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var commandBar: CommandBarViewModel
    let windowSize: CGSize
    let palette: ThemePalette

    var body: some View {
        let layout = CommandBarLayout(presentation: .window, resultCount: commandBar.results.count)
        let frame = layout.panelFrame(in: windowSize)
        // Keep the top edge where the five-row panel puts it, so the panel grows downward as
        // results arrive instead of jumping. inferred.
        let top = CommandBarLayout(presentation: .window, resultCount: 5).panelFrame(in: windowSize).minY
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.dismissCommandBar() }
            CommandBarView(viewModel: commandBar, palette: palette)
                .offset(x: frame.minX, y: top)
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
    }
}

/// The web panel: hosts the selected tab's engine surface, with its find bar (B25) and that
/// tab's dialogs over it (tab-modal, C7b).
struct WebPanel: View {
    let tab: (any BrowserTab)?
    /// The find bar of the tab shown here; nil where there is none (Little Arc).
    var findBar: FindBarHost? = nil
    /// Content-area color behind the page (`ThemePalette.webPanelBackground`): the theme tint of
    /// [07 §8.1] (E12) in light and dark. With no tab the panel is just this color, with no text
    /// (B32 round 1 observed: Arc's empty panel is blank).
    var background: RGBAColor = RGBAColor(hex: 0xFFFFFF)
    /// Set while the tab's renderer is gone: the crash page covers the surface (C9).
    var crashed: CrashedPageState? = nil
    @Environment(\.dialogCenter) private var dialogCenter
    @Environment(\.windowDrawnPermissionTab) private var windowDrawnPermissionTab

    var body: some View {
        ZStack {
            background.swiftUI
            if let tab {
                SurfaceHostRepresentable(surface: tab.surface, panelColor: background)
                    .id(tab.id)
                if let crashed { CrashedPageView(state: crashed, panelColor: background) }
                if let findBar { FindBarOverlay(host: findBar) }
                if let dialogCenter {
                    TabDialogOverlay(center: dialogCenter, tabID: tab.id, windowDrawnPermissionTab: windowDrawnPermissionTab)
                }
            }
        }
    }
}

// MARK: - Surface hosting (AppKit)

/// AppKit container implementing `SurfaceHost`: shows the engine's native view, or a SwiftUI
/// placeholder for FakeEngine.
final class SurfaceContainerView: NSView, SurfaceHost {
    private(set) var lastPlaceholder: SurfacePlaceholder?
    /// The content-area color the placeholder sits on, so its text keeps contrast. Changing it
    /// redraws a shown placeholder.
    var panelColor: RGBAColor = RGBAColor(hex: 0xFFFFFF) {
        didSet {
            guard panelColor != oldValue, let placeholder = lastPlaceholder, !subviews.isEmpty else { return }
            show(.placeholder(placeholder))
        }
    }

    func show(_ content: SurfaceContent) {
        clear()
        let child: NSView
        switch content {
        case .native(let object):
            guard let view = object as? NSView else { return }
            lastPlaceholder = nil
            child = view
        case .placeholder(let placeholder):
            lastPlaceholder = placeholder
            child = NSHostingView(rootView: PlaceholderPage(placeholder: placeholder, panelColor: panelColor))
        }
        child.frame = bounds
        child.autoresizingMask = [.width, .height]
        addSubview(child)
    }

    func clear() {
        subviews.forEach { $0.removeFromSuperview() }
    }
}

struct SurfaceHostRepresentable: NSViewRepresentable {
    let surface: any TabSurface
    var panelColor: RGBAColor = RGBAColor(hex: 0xFFFFFF)

    func makeNSView(context: Context) -> SurfaceContainerView {
        let view = SurfaceContainerView()
        view.panelColor = panelColor
        surface.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: SurfaceContainerView, context: Context) {
        nsView.panelColor = panelColor
    }

    static func dismantleNSView(_ nsView: SurfaceContainerView, coordinator: ()) {
        nsView.clear()
    }
}

/// FakeEngine's stand-in for a page. It paints no page background of its own, so the content-area
/// color of [07 §8.1] (E12) shows through as it does in Arc wherever no page paints; a real engine
/// draws the page (Arc's about:blank is #FFFFFF light / #121212 dark, [07 §8.1] observed).
struct PlaceholderPage: View {
    let placeholder: SurfacePlaceholder
    /// The content-area color underneath; picks black or white text for contrast.
    var panelColor: RGBAColor = RGBAColor(hex: 0xFFFFFF)

    /// Text ink on `panelColor`: white where it has more contrast than black.
    static func usesWhiteText(on panelColor: RGBAColor) -> Bool {
        ThemeDerivation.contrast(panelColor, RGBAColor(hex: 0xFFFFFF)) > ThemeDerivation.contrast(panelColor, RGBAColor(hex: 0x000000))
    }

    var body: some View {
        // The page still learns its `prefers-color-scheme` (B21) through the environment.
        let isDark = placeholder.colorScheme == .dark
        let whiteText = Self.usesWhiteText(on: panelColor)
        VStack(spacing: 8) {
            Text(placeholder.title.isEmpty ? "New Tab" : placeholder.title)
                .font(.title2.weight(.semibold))
            if let url = placeholder.url {
                Text(url.absoluteString).foregroundStyle(.secondary)
            }
            Text("FakeEngine placeholder").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(whiteText ? Color.white : Color.black)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }
}
