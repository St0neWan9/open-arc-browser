import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Views of the web toolbar (plan B43): the 32 pt strip at the top of the web panel (toolbar on),
// and the same strip on each split pane. Geometry from `WebToolbarLayout`, colors from
// `ThemeDerivation.webToolbarColors`.
//
// Spec sources (docs/arc-spec/): [06 §17.2] layout, [06 §17.3] clicks, [06 §17.4] colors,
// [06 §17.5] hover, [06 §17.6] split panes, all observed unless noted.

private struct IsWebToolbarShownKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// View ▸ Show Toolbar is on: the sidebar drops its URL box and navigation buttons. [06 §17.1]
    var isWebToolbarShown: Bool {
        get { self[IsWebToolbarShownKey.self] }
        set { self[IsWebToolbarShownKey.self] = newValue }
    }
}

/// Local look tokens of the toolbar that the capture does not give.
enum WebToolbarLocalTokens {
    /// Glyph point sizes. unknown (SF Symbols sized to sit like the sidebar's toolbar glyphs, B33).
    static let arrowGlyphSize: CGFloat = 15
    static let reloadGlyphSize: CGFloat = 14.5
    static let stopGlyphSize: CGFloat = 13
    static let sidebarGlyphSize: CGFloat = 15
    static let siteControlsGlyphSize: CGFloat = 14
    static let splitMenuGlyphSize: CGFloat = 14
    static let closeGlyphSize: CGFloat = 12.5
    static let centerGlyphSize: CGFloat = 12.5
    static let glyphWeight: Font.Weight = .medium
    /// "Copied Current URL" stays this long. unknown.
    static let copiedToastDuration: Double = 2
    /// The toast's distance from the panel's top-right corner, below the strip. unknown ([06 §17.3]
    /// observed only "top right of the window").
    static let copiedToastInset: CGFloat = 10
}

/// One bar: the single page's toolbar or a split pane's top bar in toolbar mode.
struct WebToolbarView: View {
    @ObservedObject var model: ShellModel
    let state: WebToolbarState
    let items: WebToolbarItems
    let colors: WebToolbarColors
    let size: CGSize
    @ObservedObject var siteControls: SiteControlsModel
    @ObservedObject var settings: WebToolbarSettings
    @Environment(\.webToolbarCopyToast) private var copyToast
    @State private var isDomainHovered = false

    var body: some View {
        let text = state.displayText(showsFullURL: settings.showsFullURL)
        let font = Font.system(size: CGFloat(Metrics.WebToolbar.domainFontSize), weight: .medium)
        let textWidth = Self.textWidth(text)
        let layout = WebToolbarLayout(barFrame: CGRect(origin: .zero, size: size), items: items,
                                      domainTextWidth: textWidth, showsInsecureLock: state.showsInsecureLock)
        ZStack(alignment: .topLeading) {
            colors.background.swiftUI
            // ≈ 0.5 pt line between the strip and the page. [06 §17.2] observed.
            Rectangle()
                .fill(colors.separator.swiftUI)
                .frame(width: size.width, height: CGFloat(Metrics.WebToolbar.bottomSeparatorThickness))
                .offset(y: size.height - CGFloat(Metrics.WebToolbar.bottomSeparatorThickness))
                .allowsHitTesting(false)

            ForEach(items.leading + items.trailing, id: \.self) { item in
                if let frame = layout.frame(of: item) {
                    button(item).frame(width: frame.width, height: frame.height).offset(x: frame.minX, y: frame.minY)
                }
            }

            // Center group: copy link · (http) lock · domain. [06 §17.2] observed.
            centerButton("link", label: "Copy Link", id: "openarc.webToolbar.copyLink", tint: colors.icon) {
                if model.webToolbarCopyLink(state.tabID) { copyToast?.show() }
            }
            .frame(width: layout.copyLinkFrame.width, height: layout.copyLinkFrame.height)
            .offset(x: layout.copyLinkFrame.minX, y: layout.copyLinkFrame.minY)
            .disabled(state.url == nil)
            if let lock = layout.lockFrame {
                centerButton("lock.slash", label: "Not Secure", id: "openarc.webToolbar.insecureLock", tint: colors.insecureLock) {
                    model.webToolbarShowSiteControls(state.tabID)
                }
                .frame(width: lock.width, height: lock.height)
                .offset(x: lock.minX, y: lock.minY)
            }
            domain(text: text, font: font, layout: layout)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.webToolbar")
    }

    /// Natural width of the domain text in the toolbar font.
    static func textWidth(_ text: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: CGFloat(Metrics.WebToolbar.domainFontSize), weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The domain: grey text with a hover pill around the text only; a click opens the command bar
    /// with the full URL selected. [06 §17.2, §17.3, §17.5] observed.
    private func domain(text: String, font: Font, layout: WebToolbarLayout) -> some View {
        let pill = layout.domainHoverFrame
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: pill.height / 2, style: .continuous)
                .fill(isDomainHovered ? colors.domainHoverFill.swiftUI : Color.clear)
                .frame(width: pill.width, height: pill.height)
            Text(text)
                .font(font)
                .foregroundStyle(colors.domainText.swiftUI)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: layout.domainFrame.width, height: layout.domainFrame.height)
                .offset(x: layout.domainFrame.minX - pill.minX, y: layout.domainFrame.minY - pill.minY)
        }
        .frame(width: pill.width, height: pill.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onHover { isDomainHovered = $0 }
        .onTapGesture { model.webToolbarOpenAddress(state.tabID) }
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(text)
        .accessibilityAction { model.webToolbarOpenAddress(state.tabID) }
        .accessibilityIdentifier("openarc.webToolbar.domain")
        .offset(x: pill.minX, y: pill.minY)
    }

    @ViewBuilder
    private func button(_ item: WebToolbarItem) -> some View {
        let t = WebToolbarLocalTokens.self
        switch item {
        case .showSidebar:
            WebToolbarButton(symbol: "sidebar.left", glyphSize: t.sidebarGlyphSize, label: "Show Sidebar",
                             identifier: "openarc.webToolbar.showSidebar", colors: colors) { model.webToolbarShowSidebar() }
        case .back:
            WebToolbarButton(symbol: "arrow.left", glyphSize: t.arrowGlyphSize, label: "Go Back", help: "Go Back ⌘[",
                             identifier: "openarc.webToolbar.back", colors: colors, isEnabled: state.canGoBack) {
                model.webToolbarGoBack(state.tabID)
            }
        case .forward:
            WebToolbarButton(symbol: "arrow.right", glyphSize: t.arrowGlyphSize, label: "Go Forward", help: "Go Forward ⌘]",
                             identifier: "openarc.webToolbar.forward", colors: colors, isEnabled: state.canGoForward) {
                model.webToolbarGoForward(state.tabID)
            }
        case .reload:
            // While loading the button turns into ✕ (stop). [06 §17.2] observed.
            WebToolbarButton(symbol: state.isLoading ? "xmark" : "arrow.clockwise",
                             glyphSize: state.isLoading ? t.stopGlyphSize : t.reloadGlyphSize,
                             label: state.isLoading ? "Stop Loading" : "Refresh the Page",
                             help: state.isLoading ? "Stop Loading" : "Refresh the Page ⌘R",
                             identifier: "openarc.webToolbar.reload", colors: colors, isEnabled: state.tabID != nil) {
                model.webToolbarReload(state.tabID)
            }
        case .siteControls:
            WebToolbarButton(symbol: "slider.horizontal.3", glyphSize: t.siteControlsGlyphSize, label: "Site Controls",
                             identifier: "openarc.webToolbar.siteControls", colors: colors, isEnabled: state.url != nil) {
                model.webToolbarShowSiteControls(state.tabID)
            }
            .siteControlsBubble(siteControls, isPresented: siteControls.isPresented && siteControls.tabID == state.tabID,
                                palette: model.windowPalette)
        case .splitMenu:
            WebToolbarSplitMenu(colors: colors) { placement in model.addSplit(placement, beside: state.tabID) }
        case .closePane:
            WebToolbarButton(symbol: "xmark", glyphSize: t.closeGlyphSize, label: "Close Split Pane",
                             identifier: "openarc.webToolbar.closePane", colors: colors) { model.webToolbarClosePane(state.tabID) }
        }
    }

    private func centerButton(_ symbol: String, label: String, id: String, tint: RGBAColor, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: WebToolbarLocalTokens.centerGlyphSize, weight: WebToolbarLocalTokens.glyphWeight))
                .foregroundStyle(tint.swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarUndimmedButtonStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// A toolbar button: the glyph centered in its frame, a ≈ 32 × 21 rounded block ≈ 4 % darker
/// behind it while hovered, the help tag after a moment. [06 §17.5] observed.
struct WebToolbarButton: View {
    let symbol: String
    let glyphSize: CGFloat
    let label: String
    var help: String? = nil
    let identifier: String
    let colors: WebToolbarColors
    var isEnabled = true
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let hover = Metrics.WebToolbar.buttonHoverSize
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: WebToolbarLocalTokens.glyphWeight))
                .foregroundStyle((isEnabled ? colors.icon : colors.iconDisabled).swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat(Metrics.WebToolbar.buttonHoverCornerRadius), style: .continuous)
                        .fill(isHovering && isEnabled ? colors.buttonHoverFill.swiftUI : Color.clear)
                        .frame(width: CGFloat(hover.width), height: CGFloat(hover.height))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarUndimmedButtonStyle())
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .help(help ?? label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// The split view menu: a native menu with Add Right / Left Split, a separator, Add Top / Bottom
/// Split, each with a small icon. [06 §17.3] observed.
struct WebToolbarSplitMenu: View {
    let colors: WebToolbarColors
    let add: (WebToolbarSplitPlacement) -> Void
    @State private var isHovering = false

    var body: some View {
        let hover = Metrics.WebToolbar.buttonHoverSize
        Menu {
            ForEach([WebToolbarSplitPlacement.right, .left], id: \.self) { item(for: $0) }
            Divider()
            ForEach([WebToolbarSplitPlacement.top, .bottom], id: \.self) { item(for: $0) }
        } label: {
            Image(systemName: "rectangle.split.2x1")
                .font(.system(size: WebToolbarLocalTokens.splitMenuGlyphSize, weight: WebToolbarLocalTokens.glyphWeight))
                .foregroundStyle(colors.icon.swiftUI)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: CGFloat(Metrics.WebToolbar.buttonHoverCornerRadius), style: .continuous)
                        .fill(isHovering ? colors.buttonHoverFill.swiftUI : Color.clear)
                        .frame(width: CGFloat(hover.width), height: CGFloat(hover.height))
                )
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovering = $0 }
        .help("Split View")
        .accessibilityLabel("Split View")
        .accessibilityIdentifier("openarc.webToolbar.splitMenu")
    }

    private func item(for placement: WebToolbarSplitPlacement) -> some View {
        Button { add(placement) } label: { Label(placement.title, systemImage: placement.symbol) }
    }
}

extension View {
    /// Anchors the Site Control Center bubble to this view: below it, centered, arrow up.
    /// [07 §12] observed (12 pt gap, centered on the anchor); [06 §17.3] observed that in the
    /// toolbar it points at the site controls button.
    func siteControlsBubble(_ model: SiteControlsModel, isPresented: Bool, palette: ThemePalette) -> some View {
        floatingBubble(isPresented: isPresented) {
            FloatingBubbleRequest(
                placement: .attached(.below),
                style: FloatingBubbleStyle(width: SiteControlsLocalTokens.width, height: nil,
                                           cornerRadius: SiteControlsLocalTokens.cornerRadius,
                                           tint: palette.floatingPanelBackground, isDark: palette.isDark),
                content: AnyView(SiteControlsView(model: model).environment(\.colorScheme, palette.isDark ? .dark : .light)),
                onDismiss: { reason in model.close(reason == .escape ? .escape : .clickOutside) }
            )
        }
    }
}

// MARK: - Single page

/// The web panel with the toolbar on: the strip on top, the page below, both inside the panel's
/// rounded corners and edge shadow. [06 §17.2] observed.
struct WebPanelWithToolbar<Page: View>: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    let size: CGSize
    @ViewBuilder let page: () -> Page

    var body: some View {
        let height = min(CGFloat(Metrics.WebToolbar.height), size.height)
        let colors = model.webToolbarColors(isSplitPane: false)
        VStack(spacing: 0) {
            WebToolbarView(model: model, state: model.webToolbarState(for: sidebar.selectedTabID),
                           items: model.webToolbarItems(role: .page), colors: colors,
                           size: CGSize(width: size.width, height: height),
                           siteControls: model.siteControls, settings: model.webToolbar)
            page().frame(width: size.width, height: max(0, size.height - height))
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .background(colors.background.swiftUI)
    }
}

// MARK: - Copied Current URL

/// The "Copied Current URL" notice of the copy link button. [06 §17.3] observed: a small pill at
/// the window's top right with the text and a share icon on the theme color. Size, timing and
/// the share action are unknown (the share icon is drawn but does nothing yet).
@MainActor
final class WebToolbarCopyToast: ObservableObject {
    @Published private(set) var isShown = false
    private var hideTask: Task<Void, Never>?

    func show() {
        isShown = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(WebToolbarLocalTokens.copiedToastDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.isShown = false
        }
    }
}

private struct WebToolbarCopyToastKey: EnvironmentKey {
    static let defaultValue: WebToolbarCopyToast? = nil
}

extension EnvironmentValues {
    var webToolbarCopyToast: WebToolbarCopyToast? {
        get { self[WebToolbarCopyToastKey.self] }
        set { self[WebToolbarCopyToastKey.self] = newValue }
    }
}

struct WebToolbarCopyToastView: View {
    @ObservedObject var toast: WebToolbarCopyToast
    let palette: ThemePalette

    var body: some View {
        if toast.isShown {
            HStack(spacing: 8) {
                Text("Copied Current URL")
                    .font(.system(size: 13, weight: .medium))
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(palette.commandBarSelection.swiftUI))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("openarc.webToolbar.copiedToast")
        }
    }
}
