import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Top bar, URL box, favorites, space name row, dock, hover card, new folder sheet.

/// Toolbar button: a 32 × 32 hit area with the glyph centered. [07 §2] observed (hit areas, glyph
/// ink sizes, icon opacity ≈ 75 % / 30 % disabled). The hover backdrop was not measured (unknown).
struct SidebarToolbarButton: View {
    let symbol: String
    /// Point size and weight that give the measured glyph ink (SF Symbols, our own icons).
    let glyphSize: CGFloat
    var glyphWeight: Font.Weight = .regular
    let label: String
    let tint: Color
    var isEnabled = true
    /// Glyph opacity when enabled / disabled: [07 §2] 75 % / 30 % for dark ink; see
    /// `ChromeInkOpacities` for light ink.
    var enabledOpacity = Metrics.IconOpacity.enabled
    var disabledOpacity = Metrics.IconOpacity.disabled
    let identifier: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let size = CGFloat(Metrics.Sidebar.toolbarButtonSize)
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .foregroundStyle(tint.opacity(isEnabled ? enabledOpacity : disabledOpacity))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: SidebarLocalTokens.toolbarHoverCornerRadius, style: .continuous)
                        .fill(Color.black.opacity(isHovering && isEnabled ? SidebarLocalTokens.rowHoverBlackOpacity : 0))
                        .padding(SidebarLocalTokens.toolbarHoverInset)
                )
                .contentShape(Rectangle())
        }
        // The plain style dims a disabled label a second time (to ≈ 60 % of the set opacity), so
        // the disabled glyph read ≈ 18 % instead of [07 §2]'s ≈ 30 % (B33 round-2 PX).
        .buttonStyle(SidebarUndimmedButtonStyle())
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

/// Top row: the window draws the traffic lights (moved to their measured spot by
/// `MainWindowChromeConfigurator`); hide sidebar, back, forward and reload sit at their measured
/// x positions, 32 × 32 each, centered on y 23.5. [07 §2] observed. Disabled back/forward are dimmed.
struct SidebarTopBarView: View, Equatable {
    /// What the top bar draws. The sidebar computes it on each of its updates; the bar is
    /// re-evaluated only when it changed (B104: a Space switch with the same tab state redraws nothing here).
    struct State: Equatable {
        var palette: ThemePalette
        var canGoBack = false
        var canGoForward = false
        var reloadMode: SidebarReloadMode = .reload
        var hasSelectedTab = false
    }

    /// For actions only: the bar does not observe the view model (see `State`).
    let viewModel: SidebarViewModel
    let state: State
    let layout: SidebarLayout
    /// "Hide sidebar" when pinned, "Lock sidebar" in the floating peek. [06 §14] observed.
    @Environment(\.sidebarPresentation) private var presentation

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state && lhs.layout == rhs.layout }

    var body: some View {
        let tint = state.palette.primaryText.swiftUI
        let ink = state.palette.inkOpacity
        let isStop = state.reloadMode == .stop
        ZStack(alignment: .topLeading) {
            // Glyph sizes and weight chosen so the SF Symbol ink matches [07 §2] (sidebar 18 × 14.5
            // for 18.5 × 14.5, arrows 15 × 12 for 14.5 × 12, reload 14 × 17) and the stroke weight
            // of the round-2 capture (B33).
            place(layout.hideSidebarButtonFrame) {
                SidebarToolbarButton(symbol: "sidebar.left", glyphSize: SidebarLocalTokens.toolbarSidebarGlyphSize,
                                     glyphWeight: SidebarLocalTokens.toolbarGlyphWeight, label: presentation.sidebarButtonLabel, tint: tint,
                                     enabledOpacity: ink.toolbarEnabled, disabledOpacity: ink.toolbarDisabled, identifier: "openarc.sidebar.hideButton") {
                    viewModel.toggleSidebar()
                }
            }
            // With the web toolbar on, back / forward / reload live there instead. [06 §17.1] observed.
            if layout.showsAddressControls {
                navigationButtons(tint: tint, ink: ink, isStop: isStop)
            }
        }
    }

    @ViewBuilder
    private func navigationButtons(tint: Color, ink: ChromeInkOpacities, isStop: Bool) -> some View {
            place(layout.backButtonFrame) {
                SidebarToolbarButton(symbol: "arrow.left", glyphSize: SidebarLocalTokens.toolbarArrowGlyphSize,
                                     glyphWeight: SidebarLocalTokens.toolbarGlyphWeight, label: "Back", tint: tint, isEnabled: state.canGoBack,
                                     enabledOpacity: ink.toolbarEnabled, disabledOpacity: ink.toolbarDisabled, identifier: "openarc.sidebar.backButton") {
                    viewModel.goBack()
                }
            }
            place(layout.forwardButtonFrame) {
                SidebarToolbarButton(symbol: "arrow.right", glyphSize: SidebarLocalTokens.toolbarArrowGlyphSize,
                                     glyphWeight: SidebarLocalTokens.toolbarGlyphWeight, label: "Forward", tint: tint, isEnabled: state.canGoForward,
                                     enabledOpacity: ink.toolbarEnabled, disabledOpacity: ink.toolbarDisabled, identifier: "openarc.sidebar.forwardButton") {
                    viewModel.goForward()
                }
            }
            // While loading the button turns into ✕ (stop). [06 §13] observed.
            place(layout.reloadButtonFrame) {
                SidebarToolbarButton(
                    symbol: isStop ? "xmark" : "arrow.clockwise",
                    glyphSize: isStop ? 14 : SidebarLocalTokens.toolbarReloadGlyphSize,
                    glyphWeight: SidebarLocalTokens.toolbarGlyphWeight,
                    label: isStop ? "Stop loading" : "Reload",
                    tint: tint,
                    isEnabled: state.hasSelectedTab,
                    enabledOpacity: ink.toolbarEnabled,
                    disabledOpacity: ink.toolbarDisabled,
                    identifier: "openarc.sidebar.reloadButton"
                ) {
                    viewModel.reloadOrStop()
                }
            }
    }

    private func place<Content: View>(_ frame: CGRect, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// Search / address box: x 8–268, y 46–82, radius ≈ 12, control fill. A domain is SF Regular 13
/// in black 60 %, left-aligned from x 20 [07 §3, §4] observed. The "Search or Enter URL…"
/// placeholder has a magnifier in a 24 pt cell at (14, 52) (ink ≈ 12 × 12 at x 20–32, y 58–70)
/// and starts at x 41 (ink 42.5): round-1 comparison (B32) observed, AX + PX. Clicking it opens the command bar (it is not an in-place editor) [05];
/// hovering a loaded page shows copy-link and site-controls icons [06 §12] observed. On plain http
/// pages the red struck-through lock (the toolbar's) takes the same 24 pt cell at x 14 and the
/// domain starts at x 41; a click opens the Site Control Center [06 §17.7, §17.3] observed.
struct SidebarURLBoxView: View, Equatable {
    /// What the URL box draws. The sidebar computes it on each of its updates; the box is
    /// re-evaluated only when it changed (B104).
    struct State: Equatable {
        var palette: ThemePalette
        var content: SidebarURLBoxContent
        var showsInsecureLock = false
        var selectedTabID: UUID?
        /// The selected page's translation entry label (`TranslationEntryLabel`), nil without one.
        var translationLabel: TranslationEntryLabel?
    }

    /// For actions only: the box does not observe the view model (see `State`).
    let viewModel: SidebarViewModel
    let state: State
    @Environment(\.siteControlsModel) private var siteControls
    @Environment(\.translationModel) private var translation
    @Environment(\.windowSurface) private var surface
    @SwiftUI.State private var isHovering = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state }

    var body: some View {
        let palette = state.palette
        let content = state.content
        // B47: "Translation Available" / "Translated" as a second line; the domain moves to the
        // box's top half. [06 §19.1] observed.
        let translationShift = translationLineShift(content)
        let s = Metrics.Sidebar.self
        let showsMagnifier = content == .placeholder
        let showsLock = state.showsInsecureLock
        let textStart = showsMagnifier || showsLock ? s.addressFieldTextLeadingAfterIcon : s.addressFieldTextLeading
        let textLeading = CGFloat(textStart - s.addressFieldHorizontalInset)
        let textWidth = CGFloat(s.addressFieldTextTrailing - textStart)
        let style = showsMagnifier ? Typography.addressPlaceholder : Typography.addressField
        let icon = s.addressFieldIconFrame
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: CGFloat(s.addressFieldCornerRadius), style: .continuous)
                .fill(palette.windowFills(on: surface).controlFill.swiftUI)
                // The box itself: a 260 × 36 button that opens the command bar.
                .accessibilityElement()
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Search or Enter URL")
                .accessibilityAction { viewModel.openCommandBar(.currentTab) }
                .accessibilityIdentifier("openarc.sidebar.urlBox.field")
            if showsMagnifier {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: SidebarLocalTokens.addressIconGlyphSize, weight: .medium))
                    .foregroundStyle(palette.ink(\.addressIcon).swiftUI)
                    .frame(width: CGFloat(icon.width), height: CGFloat(icon.height))
                    .accessibilityBox(label: "Search", identifier: "openarc.sidebar.urlBox.pageIcon", traits: .isButton)
                    .offset(x: CGFloat(icon.x - s.addressFieldHorizontalInset))
            }
            if showsLock {
                insecureLock(frame: icon)
                    .offset(x: CGFloat(icon.x - s.addressFieldHorizontalInset))
            }
            Text(urlText(content))
                .font(style.font)
                .foregroundStyle(palette.ink(\.addressText).swiftUI)
                .lineLimit(1)
                // Ink 1 pt inside the text frame, like the reference ([07 §4], B33).
                .padding(.leading, SidebarLocalTokens.textInkInset)
                .frame(width: textWidth, height: CGFloat(style.lineHeight), alignment: .leading)
                // One accessibility element for the 18 pt text line (y 55–73), like the reference.
                .accessibilityBox(label: urlText(content), identifier: "openarc.sidebar.urlBox.text")
                .padding(.leading, textLeading)
                .offset(y: -translationShift)
            if translationShift > 0, let translation {
                TranslationURLBoxLine(model: translation, tabID: state.selectedTabID,
                                      ink: palette.ink(\.addressText).swiftUI, palette: palette)
                    .padding(.leading, textLeading + SidebarLocalTokens.textInkInset)
                    .offset(y: TranslationLocalTokens.entryLineHeight - translationShift)
            }
            if case .domain = content {
                // Site Control Center anchor (B13, B90; SiteControls/): one 30 × 30 icon at
                // x 234–264, y 49–79. [06 §12], [07 §12] observed.
                SiteControlsURLBoxAccessories(model: siteControls, isHovering: isHovering, tint: palette.primaryText.swiftUI,
                                              chrome: palette) {
                    if let url = viewModel.selectedURL { SidebarPasteboard.copy(url) }
                } openSiteControls: {
                    viewModel.requestFromMenu(.showSiteControls)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { viewModel.openCommandBar(.currentTab) }
        // With a page: the URL menu; without one: the current Space's menu. [06 §28] observed (E33).
        .contextMenu {
            if let tabID = state.selectedTabID, viewModel.selectedURL != nil {
                SidebarURLBoxMenu(viewModel: viewModel, tabID: tabID)
            } else {
                SidebarSpaceMenu(viewModel: viewModel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction { viewModel.openCommandBar(.currentTab) }
        .accessibilityIdentifier("openarc.sidebar.urlBox")
    }

    /// The red struck-through lock of insecure pages: the toolbar's glyph and red
    /// (`ThemeDerivation.webToolbarInsecureLock`), opening the same Site Control Center.
    /// [06 §17.7, §17.3] observed.
    private func insecureLock(frame: Rect2D) -> some View {
        Button {
            viewModel.requestFromMenu(.showSiteControls)
        } label: {
            Image(systemName: "lock.slash")
                .font(.system(size: WebToolbarLocalTokens.centerGlyphSize, weight: WebToolbarLocalTokens.glyphWeight))
                .foregroundStyle(ThemeDerivation.webToolbarInsecureLock.swiftUI)
                .frame(width: CGFloat(frame.width), height: CGFloat(frame.height))
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarUndimmedButtonStyle())
        .help("Not Secure")
        .accessibilityLabel("Not Secure")
        .accessibilityIdentifier("openarc.sidebar.urlBox.insecureLock")
    }

    /// How far the domain moves up for the translation line: the two 17 pt lines fill the 36 pt box
    /// from its top ([06 §19.1] observed: domain row at the box top, the line 17 below). 0 without
    /// the line.
    private func translationLineShift(_ content: SidebarURLBoxContent) -> CGFloat {
        guard translation != nil, case .domain = content, state.translationLabel != nil else { return 0 }
        return CGFloat(Metrics.Sidebar.addressFieldHeight) / 2 - TranslationLocalTokens.entryLineHeight / 2
    }

    private func urlText(_ content: SidebarURLBoxContent) -> String {
        switch content {
        case .placeholder: return SidebarURLBoxContent.placeholderText
        case .domain(let host, _): return host
        }
    }
}

/// Favorites: a grid of filled tiles (47 pt tall, radius ≈ 12, control fill) over x 8–268 with
/// 8 pt gaps both ways; rows = ⌈n / 4⌉, columns = ⌈n / rows⌉, the last row left-aligned; the
/// favicon (18 × 18) is centered and there is no title. [06 §21.3] observed (B55), [07 §4]
/// observed. With no favorites the empty-state card shows ([06 §21.2] observed); after it was
/// dismissed an empty block keeps the drop target (inferred). The gaps between tiles open the
/// Space menu ([06 §21.5] observed).
struct SidebarFavoritesView: View, Equatable {
    /// What the favorites block draws. The sidebar computes it on each of its updates; the block
    /// is re-evaluated only when it changed (B104: favorites belong to the profile, so a switch
    /// between Spaces of one profile with the same theme leaves them as they were).
    struct State: Equatable {
        var palette: ThemePalette
        var cells: [SidebarFavoriteCell.State]
        var showsEmptyCard = false
        /// The gap a dragged tab hovers (`SidebarDropTarget.favoriteGap`), and the dragged
        /// favorite's index when it is one of these.
        var dropGap: Int?
        var draggedIndex: Int?
        /// The favorite whose hover card shows, and the card's second line.
        var tooltipTabID: UUID?
        var tooltipDetail: String?
        var favorites: [TabNode] { cells.map(\.tab) }
    }

    /// For actions only: the block does not observe the view model (see `State`).
    let viewModel: SidebarViewModel
    let state: State
    let layout: SidebarLayout
    @Environment(\.windowSurface) private var surface

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.state == rhs.state && lhs.layout == rhs.layout }

    private var favorites: [TabNode] { state.favorites }

    /// Tile frames, relative to the block. While a tab hovers the block the other tiles give way
    /// live: a new tile opens an empty slot at the gap (no line, no placeholder fill, [06 §15.5]
    /// observed with one favorite); a reordered favorite already sits in its new place while the
    /// others shift ([06 §21.4] observed).
    private var slots: [CGRect] {
        let block = layout.favoritesTilesFrame
        let width = block.width
        guard let gap = state.dropGap, !favorites.isEmpty else {
            return SidebarFavoritesGrid.slotFrames(count: favorites.count, width: width)
        }
        if let dragged = state.draggedIndex {
            var order = Array(favorites.indices)
            order.remove(at: dragged)
            order.insert(dragged, at: min(SidebarFavoritesGrid.targetIndex(gap: gap, draggedIndex: dragged), order.count))
            let frames = SidebarFavoritesGrid.slotFrames(count: favorites.count, width: width)
            var result = frames
            for (slot, index) in order.enumerated() { result[index] = frames[slot] }
            return result
        }
        var frames = SidebarFavoritesGrid.slotFrames(count: favorites.count + 1, width: width)
        frames.remove(at: min(max(gap, 0), favorites.count))
        return frames
    }

    /// The hovered favorite's card, right of its block. [07 §12] observed (B89).
    private var tooltip: some View {
        let id = state.tooltipTabID
        let index = id.flatMap { id in favorites.firstIndex { $0.id == id } }
        let slots = self.slots
        let tab = index.map { favorites[$0] }
        return SidebarFavoritesTooltipPresenter(block: index.flatMap { slots.indices.contains($0) ? slots[$0] : nil },
                                                title: tab?.displayTitle ?? "",
                                                detail: state.tooltipDetail)
            .frame(width: layout.favoritesTilesFrame.width, height: layout.favoritesTilesFrame.height)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    var body: some View {
        let palette = state.palette
        let block = layout.favoritesTilesFrame
        let radius = CGFloat(Metrics.Sidebar.favoritesCornerRadius)
        ZStack(alignment: .topLeading) {
            // The gaps between tiles belong to the Space background. [06 §21.5] observed.
            Color.clear
                .contentShape(Rectangle())
                .contextMenu { SidebarSpaceMenu(viewModel: viewModel) }
            if favorites.isEmpty {
                if state.showsEmptyCard {
                    SidebarFavoritesEmptyCard(viewModel: viewModel, palette: palette)
                } else {
                    RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.windowFills(on: surface).controlFill.swiftUI)
                }
            }
            ForEach(Array(zip(state.cells, slots)), id: \.0.tab.id) { cell, slot in
                SidebarFavoriteCell(viewModel: viewModel, state: cell)
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.minX, y: slot.minY)
            }
            tooltip
        }
        .frame(width: block.width, height: block.height, alignment: .topLeading)
        .animation(ShellMotion.favoriteMakeRoom, value: state.dropGap)
        .sidebarDropRegion(.favorites)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.favorites")
    }
}

/// The empty-state card: dashed rounded border in a light tint of the theme, a 16 pt filled star
/// badge, bold "Drag to add Favorites", two secondary lines "Favorites keep your most used sites
/// and apps close", and a 14 pt ✕ ("Dismiss") 8 pt from the top-right corner. [06 §21.2] observed;
/// font sizes and the dash pattern are inferred.
struct SidebarFavoritesEmptyCard: View {
    /// For the dismiss action only.
    let viewModel: SidebarViewModel
    let palette: ThemePalette

    static let title = "Drag to add Favorites"
    static let detail = "Favorites keep your most used sites and apps close"

    var body: some View {
        let g = Metrics.FavoritesGrid.self
        let ink = palette.primaryText.swiftUI
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: CGFloat(g.emptyStateCornerRadius), style: .continuous)
                .strokeBorder(ink.opacity(g.emptyStateBorderOpacity),
                              style: StrokeStyle(lineWidth: CGFloat(g.emptyStateBorderWidth), dash: g.emptyStateDash.map { CGFloat($0) }))
            VStack(spacing: CGFloat(g.emptyStateLineSpacing)) {
                Image(systemName: "star.circle.fill")
                    .resizable()
                    .frame(width: CGFloat(g.emptyStateStarSize), height: CGFloat(g.emptyStateStarSize))
                    .foregroundStyle(ink.opacity(g.emptyStateStarOpacity))
                Text(Self.title)
                    .textStyle(Typography.favoritesEmptyTitle, ink: palette.primaryText)
                Text(Self.detail)
                    .textStyle(Typography.favoritesEmptyDetail, ink: palette.primaryText)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, CGFloat(g.emptyStateDetailPadding))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { viewModel.dismissFavoritesEmptyCard() } label: {
                Image(systemName: "xmark")
                    .textStyle(Typography.favoritesEmptyDismiss, ink: palette.primaryText)
                    .frame(width: CGFloat(g.emptyStateDismissSize), height: CGFloat(g.emptyStateDismissSize))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("openarc.sidebar.favorites.emptyDismiss")
            .padding(.top, CGFloat(g.emptyStateDismissInset))
            .padding(.trailing, CGFloat(g.emptyStateDismissInset))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.favorites.empty")
    }
}

struct SidebarFavoriteCell: View {
    /// What one favorite tile draws (B104, see `SidebarFavoritesView.State`).
    struct State: Equatable {
        var tab: TabNode
        var palette: ThemePalette
        var isSelected = false
        /// PNG bytes of the favicon (when the tab has no custom icon), nil for the placeholder.
        var favicon: Data?
        /// The favorite whose Peek is open. [06 §22.2] observed (B49).
        var isPeekSource = false
        var unreadCount: Int?
    }

    /// For actions only.
    let viewModel: SidebarViewModel
    let state: State
    @Environment(\.windowSurface) private var surface
    private var tab: TabNode { state.tab }

    var body: some View {
        let palette = state.palette
        let isSelected = state.isSelected
        let radius = CGFloat(Metrics.Sidebar.favoritesCornerRadius)
        Group {
            if let icon = tab.icon {
                // Change Icon… replaces the favicon. [06 §21.5] observed item (B77).
                SidebarCustomIconView(icon: icon, size: SidebarLocalTokens.favoriteIconSize, tint: palette.primaryText.swiftUI)
            } else {
                SidebarFaviconView(pngData: state.favicon, size: SidebarLocalTokens.favoriteIconSize,
                                   tint: palette.ink(\.faviconPlaceholder).swiftUI, placeholder: .roundedSquare)
            }
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Self.fill(palette: palette, isSelected: isSelected, surface: surface).swiftUI))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [palette.commandBarSelection.swiftUI, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2
                        )
                }
            }
            // The favorite whose Peek is open carries a small corner badge. [06 §22.2] observed (B49).
            .overlay(alignment: .topTrailing) {
                if state.isPeekSource {
                    LinkPeekSourceBadge()
                } else if let count = state.unreadCount, count > 0 {
                    // Show Unread Badge. [05 §context menus] observed item; look inferred (B77).
                    FavoriteUnreadBadge(count: count)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.selectTab(tab.id) }
            .contextMenu { SidebarTabMenu(viewModel: viewModel, tab: tab, kind: .favorite) }
            // Hovering shows the favorites card (title, plus the unread tip when the badge is on:
            // "No unread emails, you can exhale! 🌿", [06 §12] observed) right of the block instead
            // of a system tooltip. [07 §12] observed (B89).
            .onHover { hovering in
                if hovering { viewModel.favoriteHoverBegan(tab.id) } else { viewModel.favoriteHoverEnded(tab.id) }
            }
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("openarc.sidebar.favorite.\(tab.id.uuidString)")
    }

    /// Tile fill: the control fill; selected in the dark appearance a clearly lighter gray (window
    /// + ≈ 47 % white, ≈ #8F9099 on the default dark theme). [06 §21.3] observed (dark only; the
    /// light appearance keeps the control fill, inferred).
    /// On a see-through window both are layers over the window (B64, [07 §8.4]).
    static func fill(palette: ThemePalette, isSelected: Bool, surface: WindowSurface = .opaque) -> RGBAColor {
        guard isSelected, palette.isDark else { return palette.windowFills(on: surface).controlFill }
        if surface.isTranslucent { return RGBAColor(hex: 0xFFFFFF, alpha: Metrics.FavoritesGrid.selectedTileWhiteDark) }
        return ThemeDerivation.overlayWhite(palette.windowBackground, amount: Metrics.FavoritesGrid.selectedTileWhiteDark)
    }
}

/// Space header: icon 26 × 26 at (13, 150) when the Space has one; the name (SF Semibold 13,
/// black 45 %) from x 41 (13 without an icon) to 259, its 18 pt text line at y 154; the "More"
/// button is an invisible 2 × 26 strip at (261, 150) that is always in the accessibility tree and
/// widens to show "…" while the header is hovered. [07 §3, §4] observed; the hovered look unknown.
/// What a Space page's header draws for its Space: name, icon and colors. B106 compares it to
/// tell whether a hidden page still draws its Space's current state.
struct SidebarSpaceHeaderLook: Equatable {
    var name: String
    var icon: String?
    var palette: ThemePalette
}

extension SidebarViewModel {
    /// What the header of Space `spaceID`'s page draws now.
    func spaceHeaderLook(for spaceID: UUID?) -> SidebarSpaceHeaderLook {
        let space = liveSpace(spaceID)
        return SidebarSpaceHeaderLook(name: space?.name ?? "", icon: space?.icon, palette: palette(forSpace: spaceID))
    }
}

struct SidebarSpaceNameRowView: View {
    /// Read, not observed: its page's `changes` relay says when to update (B104).
    let viewModel: SidebarViewModel
    @ObservedObject var changes: SidebarSpacePageChanges
    /// The Space of the page this header heads (B101).
    let spaceID: UUID?
    let layout: SidebarLayout
    @State private var isHovering = false

    /// Fill of the Space-name row while a tab is dragged over it: the theme color, slightly darker,
    /// full width; the name keeps its dark theme ink. [06 §15.4] observed 2026-10-26.
    static func dropBandFill(palette: ThemePalette) -> RGBAColor {
        palette.dropTargetFill
    }

    var body: some View {
        let look = viewModel.spaceHeaderLook(for: spaceID)
        // What this page drew, so a hidden page can tell whether it is still current (B106).
        // A plain record: never published.
        let _ = changes.noteDrawn(header: look)
        let palette = look.palette
        let s = Metrics.Sidebar.self
        let icon = look.icon
        let style = Typography.spaceName
        let nameLeading = CGFloat(icon == nil ? s.spaceNameLeadingWithoutIcon : s.spaceNameLeadingWithIcon)
        let more = s.spaceMoreButtonFrame
        let moreWidth = isHovering ? SidebarLocalTokens.spaceMoreHoverWidth : CGFloat(more.width)
        let isDropTarget = viewModel.dropTarget == .pinnedAreaTop && spaceID == viewModel.selectedSpaceID
        ZStack(alignment: .topLeading) {
            // Hover / context menu area: the whole header (y 145–181). It is also a drop target
            // that pins the dragged tab first, shown as a full-width saturated blue band.
            // [06 §15.4] observed.
            (isDropTarget ? Self.dropBandFill(palette: palette).swiftUI : Color.clear)
                .frame(width: layout.width, height: CGFloat(s.spaceHeaderHeight))
                .contentShape(Rectangle())
                .sidebarDropRegion(.spaceName)
                .offset(y: CGFloat(s.spaceHeaderTop) - layout.contentShift)
            if let icon {
                // A ≈ 14 pt glyph centered in the 26 pt cell (B33 round-2 PX), not a 26 pt glyph.
                SidebarSpaceIconView(icon: icon, size: CGFloat(s.spaceIconFrame.width),
                                     glyphSize: SidebarLocalTokens.spaceIconGlyphSize, tint: palette.ink(\.spaceIcon).swiftUI)
                    .frame(width: CGFloat(s.spaceIconFrame.width), height: CGFloat(s.spaceIconFrame.height))
                    .accessibilityBox(label: "Space icon", identifier: "openarc.sidebar.spaceIcon", traits: .isImage)
                    .offset(x: CGFloat(s.spaceIconFrame.x), y: CGFloat(s.spaceIconFrame.y) - layout.contentShift)
            }
            Text(look.name)
                .font(style.font)
                .foregroundStyle(palette.ink(\.spaceName).swiftUI)
                .lineLimit(1)
                .padding(.leading, SidebarLocalTokens.textInkInset)
                .frame(width: CGFloat(s.spaceNameTrailing) - nameLeading, height: CGFloat(style.lineHeight), alignment: .leading)
                // The element spans the name line (x to 259, 18 tall), like the reference.
                .accessibilityBox(label: look.name, identifier: "openarc.sidebar.spaceName")
                .offset(x: nameLeading, y: CGFloat(s.spaceNameTop) - layout.contentShift)
            Menu {
                SidebarSpaceMenu(viewModel: viewModel)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.ink(\.spaceName).swiftUI.opacity(isHovering ? 1 : 0))
                    .frame(width: moreWidth, height: CGFloat(more.height))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(width: moreWidth, height: CGFloat(more.height))
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("More")
            .accessibilityIdentifier("openarc.sidebar.spaceMoreButton")
            .offset(x: CGFloat(more.maxX) - moreWidth, y: CGFloat(more.y) - layout.contentShift)
        }
        .onHover { isHovering = $0 }
    }
}

/// Dock values the spec does not pin down.
enum SidebarDockLocalTokens {
    /// Diameter of the "Create Space" placeholder's dashed circle. unknown (its look was not
    /// recorded); about the ink of a Space glyph ([07 §4] observed ≈ 11 × 15).
    static let createSpacePlaceholderSize: CGFloat = 13
}

/// One item between Home and "+" in the dock: a Space, or the "Create Space" placeholder shown
/// while the creation view is up. [06 §1] observed ("底部 Dock 先插入一个「Create Space」占位项").
enum SidebarDockEntry: Equatable {
    case space(Space)
    case createSpacePlaceholder

    var id: String {
        switch self {
        case .space(let space): space.id.uuidString
        case .createSpacePlaceholder: "createSpacePlaceholder"
        }
    }

    /// The dock items in order. While a Space is being created the placeholder sits right after
    /// the current Space, where the new Space will be inserted ([06 §1] observed: the new Space
    /// goes after the current one; the placeholder's position is inferred from that). Without a
    /// current Space it goes last.
    static func entries(spaces: [Space], selectedSpaceID: UUID?, isCreatingSpace: Bool) -> [SidebarDockEntry] {
        var entries = spaces.map(SidebarDockEntry.space)
        guard isCreatingSpace else { return entries }
        let index = spaces.firstIndex { $0.id == selectedSpaceID }.map { $0 + 1 } ?? entries.count
        entries.insert(.createSpacePlaceholder, at: index)
        return entries
    }
}

/// Bottom dock, centered on y = H − 25 [07 §4] observed: a Home button at x 8 (32 × 32), the Space
/// icons sharing x 42–234 (current opaque, others ≈ 33 % with dark ink; ≈ 50 % / ≈ 12 % with light
/// ink, B32 round-1 PX), and "+" at x 236, which opens the New menu ([06 §23] observed, B75; an
/// incognito window's "+" opens the command bar, [06 §20.2] observed).
/// While a Space is being created the dock stays under the creation view with a "Create Space"
/// placeholder as the current item ([06 §1] observed); it ignores clicks then (inferred).
struct SidebarDockView: View, Equatable {
    /// What the dock draws. The sidebar computes it on each of its updates; the dock is
    /// re-evaluated only when it changed (B104).
    struct State: Equatable {
        var palette: ThemePalette
        var spaces: [Space]
        var selectedSpaceID: UUID?
        var isIncognito = false
        /// The dock Space a drag hovers (`SidebarDropTarget.dockSpace`).
        var dropSpaceID: UUID?
    }

    /// For actions only: the dock does not observe the view model (see `State`).
    let viewModel: SidebarViewModel
    let state: State
    let layout: SidebarLayout
    /// The creation view is up: show the placeholder item. [06 §1] observed.
    var isCreatingSpace = false
    /// The window palette when it is not the Space's (the creation view's light neutral theme).
    var paletteOverride: ThemePalette? = nil
    /// The window whose New menu rows run. nil (previews) draws them disabled.
    @Environment(\.sidebarNewMenuTarget) private var newMenuTarget
    @SwiftUI.State private var isNewMenuShown = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state && lhs.layout == rhs.layout && lhs.isCreatingSpace == rhs.isCreatingSpace
            && lhs.paletteOverride == rhs.paletteOverride
    }

    var body: some View {
        let palette = paletteOverride ?? state.palette
        let tint = palette.primaryText.swiftUI.opacity(palette.inkOpacity.dockButton)
        let top = layout.dockFrame.minY
        let entries = SidebarDockEntry.entries(spaces: state.spaces, selectedSpaceID: state.selectedSpaceID,
                                               isCreatingSpace: isCreatingSpace)
        ZStack(alignment: .topLeading) {
            dockButton(layout.dockHomeFrame, top: top, symbol: SidebarLocalTokens.dockHomeSymbol,
                       glyphSize: SidebarLocalTokens.dockHomeGlyphSize, tint: tint,
                       label: SidebarLocalTokens.dockHomeAccessibilityLabel, id: "openarc.sidebar.dock.home") {
                viewModel.requestFromMenu(.openLibrary)
            }
            ForEach(Array(zip(entries, layout.dockItemFrames(count: entries.count))), id: \.0.id) { entry, frame in
                switch entry {
                case .space(let space): dockItem(space, frame: frame, top: top, palette: palette)
                case .createSpacePlaceholder: createSpacePlaceholder(frame: frame, top: top, palette: palette)
                }
            }
            dockButton(layout.dockPlusFrame, top: top, symbol: "plus", glyphSize: SidebarLocalTokens.dockPlusGlyphSize,
                       glyphWeight: SidebarLocalTokens.dockPlusGlyphWeight, tint: tint,
                       label: state.isIncognito ? "New Tab" : "New", id: "openarc.sidebar.dock.plus",
                       presenter: AnyView(newMenuPresenter(palette: palette))) {
                if viewModel.dockPlusClicked() == .toggleNewMenu { isNewMenuShown.toggle() }
            }
        }
        .frame(width: layout.width, height: layout.dockFrame.height, alignment: .topLeading)
        .disabled(isCreatingSpace)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.dock")
    }

    /// The New menu above the "+" button while it is open. [06 §23] observed.
    private func newMenuPresenter(palette: ThemePalette) -> some View {
        let target = newMenuTarget
        let menu = SidebarNewMenuView(
            palette: palette,
            isEnabled: { target?.canPerformNewMenuItem($0) ?? false },
            onSelect: { item in
                isNewMenuShown = false
                target?.performNewMenuItem(item)
            }
        )
        return SidebarNewMenuPresenter(content: isNewMenuShown && !isCreatingSpace ? AnyView(menu) : nil, palette: palette) {
            isNewMenuShown = false
        }
    }

    /// Home and "+": 32 × 32 hit areas; glyph sizes give the measured ink (+ 14 × 15 for 14 × 14,
    /// stack 13.5 × 16 for 13.5 × 16.5). [07 §4] observed ink; the Home glyph's shape is our own.
    private func dockButton(_ frame: CGRect, top: CGFloat, symbol: String, glyphSize: CGFloat,
                            glyphWeight: Font.Weight = .regular, tint: Color,
                            label: String, id: String, presenter: AnyView? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .foregroundStyle(tint)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .background { if let presenter { presenter } }
        .offset(x: frame.minX, y: frame.minY - top)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// The "Create Space" placeholder: the current item while the creation view is up. [06 §1]
    /// observed (the item exists); its look is unknown: a dashed circle, our own.
    private func createSpacePlaceholder(frame: CGRect, top: CGFloat, palette: ThemePalette) -> some View {
        let size = SidebarDockLocalTokens.createSpacePlaceholderSize
        return Circle()
            .strokeBorder(palette.primaryText.swiftUI, style: StrokeStyle(lineWidth: 1.2, dash: [2.5, 2]))
            .frame(width: size, height: size)
            .opacity(palette.inkOpacity.dockCurrentSpace)
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY - top)
            .help("Create Space")
            .accessibilityElement()
            .accessibilityLabel("Create Space")
            .accessibilityAddTraits(.isSelected)
            .accessibilityIdentifier("openarc.sidebar.dock.createSpace")
    }

    private func dockItem(_ space: Space, frame: CGRect, top: CGFloat, palette: ThemePalette) -> some View {
        // The placeholder is the current item while a Space is being created. inferred.
        let isCurrent = space.id == state.selectedSpaceID && !isCreatingSpace
        let radius = CGFloat(Metrics.Sidebar.addressFieldCornerRadius)
        return Button {
            viewModel.selectSpace(space.id)
        } label: {
            Group {
                if let icon = space.icon {
                    SidebarSpaceIconView(icon: icon, size: SidebarLocalTokens.dockSpaceGlyphSize,
                                         glyphSize: SidebarLocalTokens.dockSpaceGlyphSize, tint: palette.primaryText.swiftUI)
                } else {
                    // A Space without an icon shows a dot. [07 §4] unknown: every Space in the
                    // captures had an icon, so the reference's no-icon look is not documented.
                    Circle().fill(palette.primaryText.swiftUI).frame(width: 6, height: 6)
                }
            }
            .opacity(isCurrent ? palette.inkOpacity.dockCurrentSpace : palette.inkOpacity.dockOtherSpace)
            .frame(width: frame.width, height: frame.height)
            .overlay {
                // Hovering a dot only switches the Space after a moment ([06 §15.6] observed); the
                // hover look is unknown, so the dot gets the light "drop into" fill of folders.
                if state.dropSpaceID == space.id {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(RGBAColor(hex: SidebarLocalTokens.dropIntoRGB).swiftUI.opacity(SidebarLocalTokens.dockDropFillOpacity))
                }
            }
            .sidebarDropRegion(.dock(space.id))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY - top)
        .help(space.name)
        .accessibilityLabel(space.name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("openarc.sidebar.dock.\(space.name)")
    }
}


// MARK: - Update pill (B111)

/// "New Open Arc Version Available": a full-width capsule right above the dock while a downloaded
/// update waits. [07 §8.6] observed (E27, re-measured 2026-10-31): x 8–268, 24 pt tall, fully
/// rounded; on a dark sidebar the sidebar color lightened with white text, on a light one darkened
/// slightly with black text; 11.5 pt medium text centered; no border or shadow. A click installs
/// the update and relaunches (Arc's click behavior unknown; ours inferred).
struct SidebarUpdatePill: View {
    /// The sidebar uses light ink (a dark theme color): white text on a lighter pill; otherwise
    /// black text on a slightly darker pill. [07 §8.6] observed.
    let lightInk: Bool
    let action: @MainActor () -> Void

    var body: some View {
        let t = UpdatePillTokens.self
        Button(action: action) {
            Text(SidebarUpdatePill.title)
                .font(t.titleStyle.font)
                .foregroundStyle(t.titleColor(lightInk: lightInk).swiftUI)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A white (or black) layer over whatever the sidebar shows, so a see-through window
                // changes the same way as an opaque one.
                .background(Capsule(style: .continuous).fill(
                    lightInk ? Color.white.opacity(t.whiteOverlay) : Color.black.opacity(t.blackOverlay)
                ))
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(SidebarUpdatePill.title)
        .accessibilityHint("Installs the update and relaunches")
        .accessibilityIdentifier("openarc.sidebar.updatePill")
    }

    /// [07 §8.6] observed "New Arc Version Available", with our app's name.
    static let title = "New \(AppIdentity.displayName) Version Available"
}
