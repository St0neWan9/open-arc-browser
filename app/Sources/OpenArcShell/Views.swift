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
        MainWindowContent(model: model, sidebar: model.sidebar, webToolbar: model.webToolbar)
            .modifier(LaunchNoticeAlert(model: model))
    }
}

/// Split out so it observes the sidebar view model (the owner of workspace and selection) as well
/// as the shell model (command bar and sidebar visibility).
struct MainWindowContent: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    /// View ▸ Show Toolbar, shared by every window (B43, [06 §17.1]).
    @ObservedObject var webToolbar: WebToolbarSettings
    /// "Copied Current URL" after the toolbar's copy link button (B43, [06 §17.3]).
    @StateObject private var copyToast = WebToolbarCopyToast()

    init(model: ShellModel, sidebar: SidebarViewModel, webToolbar: WebToolbarSettings? = nil) {
        self.model = model
        self.sidebar = sidebar
        self.webToolbar = webToolbar ?? model.webToolbar
    }

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

                // "Translated back to …! Use ⌘Z to undo." at the web panel's top right. [06 §19.5] observed. B47.
                TranslationRevertNoticeView(model: model.translation, palette: palette)
                    .frame(width: max(0, layout.webPanelFrame.maxX - TranslationLocalTokens.noticeInset), alignment: .trailing)
                    .offset(y: layout.pageFrame.minY + TranslationLocalTokens.noticeInset)

                // Copy link notice at the panel's top right, under the toolbar. [06 §17.3] observed. B43.
                if layout.isWebToolbarShown {
                    WebToolbarCopyToastView(toast: copyToast, palette: palette)
                        .frame(width: layout.webPanelFrame.maxX - WebToolbarLocalTokens.copiedToastInset, alignment: .trailing)
                        .offset(y: layout.pageFrame.minY + WebToolbarLocalTokens.copiedToastInset)
                        .allowsHitTesting(false)
                }
            }
            .environment(\.dialogCenter, model.controller.dialogs)
            .environment(\.translationModel, model.translation)
            .environment(\.isWebToolbarShown, layout.isWebToolbarShown)
            .environment(\.webToolbarCopyToast, copyToast)
            // The window command bar and onboarding cover the sidebar: presses go to them.
            .environment(\.sidebarAcceptsPointer, !(model.isCommandBarPresented && model.commandBarPaneTabID == nil)
                         && !model.controller.onboarding.isShown(in: model))
            .environment(\.windowDrawnPermissionTab, permissionTabUnderURLBox)
            // ⌘S: web panel resize and sidebar slide on one fast ease-out. [07 §11] B40.
            .animation(ShellMotion.sidebarToggle, value: model.isSidebarVisible)
            // Peek slide: curve unknown, within the observed 0.3 s bound. [07 §11] B40.
            .animation(ShellMotion.sidebarPeekSlide, value: model.showsSidebarPeek)
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
        .animation(ShellMotion.spaceCreateFade, value: model.spaceFlow.isCreating)
        .modifier(SpaceFlowSheets(flow: model.spaceFlow, workspace: sidebar.workspace, palette: model.windowPalette))
        .overlay(alignment: .topLeading) { themeEditorAnchor }
        // System-drawn floating panels (popovers, menus) follow the Space's light or dark. B21.
        .background(WindowAppearanceApplier(appearance: palette.appearance))
    }

    /// The engine tab whose permission bubble goes under the URL box: the selected tab's, while
    /// the sidebar shows and the Library is not up. inferred.
    private var permissionTabUnderURLBox: EngineTabID? {
        // With the web toolbar on the sidebar has no URL box: the tab's own panel draws the prompt. inferred (B43).
        let visible = model.isSidebarVisible && !model.spaceFlow.isCreating && !model.library.isActive && !model.isWebToolbarShown
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
            // Slides out to the left while the web panel expands. Timing: `ShellMotion.sidebarToggle`.
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
            singlePanel(layout: layout, palette: palette)
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

    /// The single web panel: the page, under the toolbar strip while View ▸ Show Toolbar is on
    /// (the panel's rounded corners and shadow wrap both). [06 §17.2] observed. B43.
    @ViewBuilder
    private func singlePanel(layout: MainWindowLayout, palette: ThemePalette) -> some View {
        let page = EaselOrWebPanel(model: model, sidebar: sidebar, size: layout.webPanelFrame.size, palette: palette)
        if layout.isWebToolbarShown {
            WebPanelWithToolbar(model: model, sidebar: sidebar, size: layout.webPanelFrame.size) { page }
        } else {
            page
        }
    }

    /// The Edit Theme bubble (Spaces ▸ Edit Theme…, Space menu ▸ Edit Theme Color…). [07 §12]
    /// observed: no arrow; left edge 13 pt right of the web panel's left edge, vertically centered
    /// on the pointer, kept 13 pt inside the window. The anchor only gives the bubble its window.
    private var themeEditorAnchor: some View {
        let systemAppearance = model.controller.systemAppearance
        return Color.clear
            .frame(width: 1, height: 1)
            .floatingBubble(isPresented: model.spaceFlow.themeEditorSpaceID != nil) {
                let spaceID = model.spaceFlow.themeEditorSpaceID
                let draft = spaceID.map { model.spaceFlow.themeDraft(of: $0) } ?? SpaceThemeDraft()
                // The panel's left edge does not depend on the window size (any size wider than the sidebar).
                let webPanelMinX = model.windowLayout(size: CGSize(width: 4096, height: 4096)).webPanelFrame.minX
                return FloatingBubbleRequest(
                    placement: .editTheme(webPanelMinX: webPanelMinX),
                    style: ThemeEditorView.bubbleStyle(for: draft, systemAppearance: systemAppearance),
                    content: AnyView(ThemeEditorView(theme: Binding(
                        get: { spaceID.map { model.spaceFlow.themeDraft(of: $0) } ?? draft },
                        set: { if let spaceID { model.spaceFlow.applyThemeDraft($0, to: spaceID) } }
                    ), systemAppearance: systemAppearance, drawsBackground: false)),
                    onDismiss: { _ in model.spaceFlow.closeThemeEditor() }
                )
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
