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
struct SidebarTopBarView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout
    /// "Hide sidebar" when pinned, "Lock sidebar" in the floating peek. [06 §14] observed.
    @Environment(\.sidebarPresentation) private var presentation

    var body: some View {
        let tint = viewModel.palette.primaryText.swiftUI
        let ink = viewModel.palette.inkOpacity
        let isStop = viewModel.reloadMode == .stop
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
            place(layout.backButtonFrame) {
                SidebarToolbarButton(symbol: "arrow.left", glyphSize: SidebarLocalTokens.toolbarArrowGlyphSize,
                                     glyphWeight: SidebarLocalTokens.toolbarGlyphWeight, label: "Back", tint: tint, isEnabled: viewModel.canGoBack,
                                     enabledOpacity: ink.toolbarEnabled, disabledOpacity: ink.toolbarDisabled, identifier: "openarc.sidebar.backButton") {
                    viewModel.goBack()
                }
            }
            place(layout.forwardButtonFrame) {
                SidebarToolbarButton(symbol: "arrow.right", glyphSize: SidebarLocalTokens.toolbarArrowGlyphSize,
                                     glyphWeight: SidebarLocalTokens.toolbarGlyphWeight, label: "Forward", tint: tint, isEnabled: viewModel.canGoForward,
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
                    isEnabled: viewModel.selectedTabID != nil,
                    enabledOpacity: ink.toolbarEnabled,
                    disabledOpacity: ink.toolbarDisabled,
                    identifier: "openarc.sidebar.reloadButton"
                ) {
                    viewModel.reloadOrStop()
                }
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
/// hovering a loaded page shows copy-link and site-controls icons [06 §12] observed.
struct SidebarURLBoxView: View {
    @ObservedObject var viewModel: SidebarViewModel
    @Environment(\.siteControlsModel) private var siteControls
    @State private var isHovering = false

    var body: some View {
        let palette = viewModel.palette
        let content = viewModel.urlBoxContent
        let s = Metrics.Sidebar.self
        let showsMagnifier = content == .placeholder
        let textStart = showsMagnifier ? s.addressFieldTextLeadingAfterIcon : s.addressFieldTextLeading
        let textLeading = CGFloat(textStart - s.addressFieldHorizontalInset)
        let textWidth = CGFloat(s.addressFieldTextTrailing - textStart)
        let style = showsMagnifier ? Typography.addressPlaceholder : Typography.addressField
        let icon = s.addressFieldIconFrame
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: CGFloat(s.addressFieldCornerRadius), style: .continuous)
                .fill(palette.controlFill.swiftUI)
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
            if case .domain = content, let siteControls {
                // Site Control Center anchor (B13, SiteControls/). [06 §12] observed.
                SiteControlsURLBoxAccessories(model: siteControls, isHovering: isHovering, tint: palette.primaryText.swiftUI, chrome: palette) {
                    viewModel.requestFromMenu(.showSiteControls)
                }
            } else if isHovering, case .domain = content {
                HStack(spacing: 2) {
                    Spacer()
                    affordance("link", label: "Copy link", id: "openarc.sidebar.copyLinkButton") {
                        if let url = viewModel.selectedURL { SidebarPasteboard.copy(url) }
                    }
                    affordance("slider.horizontal.3", label: "Site controls", id: "openarc.sidebar.siteControlsButton") {
                        viewModel.requestFromMenu(.showSiteControls)
                    }
                }
                .padding(.trailing, 6)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { viewModel.openCommandBar(.currentTab) }
        .accessibilityElement(children: .contain)
        .accessibilityAction { viewModel.openCommandBar(.currentTab) }
        .accessibilityIdentifier("openarc.sidebar.urlBox")
    }

    private func urlText(_ content: SidebarURLBoxContent) -> String {
        switch content {
        case .placeholder: return SidebarURLBoxContent.placeholderText
        case .domain(let host, _): return host
        }
    }

    private func affordance(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(viewModel.palette.primaryText.swiftUI.opacity(Metrics.IconOpacity.enabled))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// Favorites: one filled block per favorite (47 pt tall, radius ≈ 12, control fill), sharing
/// x 8–268 with 8 pt gaps (one = 260 wide, two = 126 each); the favicon (18 × 18) is centered.
/// The selected favorite gets a colored gradient outline. [07 §4] observed, [06 §12] observed.
/// With no favorites an empty block keeps the drop target (inferred).
struct SidebarFavoritesView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let favorites: [TabNode]
    let layout: SidebarLayout

    /// While a tab hovers the block, the tiles move aside to open an empty slot at the drop gap
    /// (no line, no placeholder fill). [06 §15.5] observed with one favorite; the slot follows the
    /// hit-tested gap (inferred for several favorites).
    private var slots: [CGRect] {
        guard case .favoriteGap(let gap) = viewModel.dropTarget, !favorites.isEmpty else {
            return layout.favoriteSlotFrames(count: favorites.count)
        }
        // The dragged favorite itself keeps its tile (the source does not move, [06 §15.1]).
        var frames = layout.favoriteSlotFrames(count: favorites.count + 1)
        frames.remove(at: min(max(gap, 0), favorites.count))
        return frames
    }

    var body: some View {
        let palette = viewModel.palette
        let block = layout.favoritesFrame
        let radius = CGFloat(Metrics.Sidebar.favoritesCornerRadius)
        ZStack(alignment: .topLeading) {
            if favorites.isEmpty {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.controlFill.swiftUI)
            }
            ForEach(Array(zip(favorites, slots)), id: \.0.id) { fav, slot in
                SidebarFavoriteCell(viewModel: viewModel, tab: fav)
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.minX - block.minX)
            }
        }
        .frame(width: block.width, height: block.height, alignment: .topLeading)
        .animation(ShellMotion.favoriteMakeRoom, value: viewModel.dropTarget)
        .sidebarDropRegion(.favorites)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.favorites")
    }
}

struct SidebarFavoriteCell: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode

    var body: some View {
        let palette = viewModel.palette
        let isSelected = viewModel.isSelected(tab.id)
        let radius = CGFloat(Metrics.Sidebar.favoritesCornerRadius)
        SidebarFaviconView(pngData: viewModel.faviconImage(for: tab.id), size: SidebarLocalTokens.favoriteIconSize,
                           tint: palette.ink(\.faviconPlaceholder).swiftUI, placeholder: .roundedSquare)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(palette.controlFill.swiftUI))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [palette.commandBarSelection.swiftUI, .pink, .orange], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 2
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { viewModel.selectTab(tab.id) }
            .contextMenu { SidebarTabMenu(viewModel: viewModel, tab: tab, kind: .favorite) }
            .help(tab.displayTitle)
            .accessibilityLabel(tab.displayTitle)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("openarc.sidebar.favorite.\(tab.id.uuidString)")
    }
}

/// Space header: icon 26 × 26 at (13, 150) when the Space has one; the name (SF Semibold 13,
/// black 45 %) from x 41 (13 without an icon) to 259, its 18 pt text line at y 154; the "More"
/// button is an invisible 2 × 26 strip at (261, 150) that is always in the accessibility tree and
/// widens to show "…" while the header is hovered. [07 §3, §4] observed; the hovered look unknown.
struct SidebarSpaceNameRowView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout
    @State private var isHovering = false

    /// Fill of the Space-name row while a tab is dragged over it: the theme color, slightly darker,
    /// full width; the name keeps its dark theme ink. [06 §15.4] observed 2026-10-26.
    static func dropBandFill(palette: ThemePalette) -> RGBAColor {
        palette.dropTargetFill
    }

    var body: some View {
        let palette = viewModel.palette
        let s = Metrics.Sidebar.self
        let icon = viewModel.selectedSpace?.icon
        let style = Typography.spaceName
        let nameLeading = CGFloat(icon == nil ? s.spaceNameLeadingWithoutIcon : s.spaceNameLeadingWithIcon)
        let more = s.spaceMoreButtonFrame
        let moreWidth = isHovering ? SidebarLocalTokens.spaceMoreHoverWidth : CGFloat(more.width)
        let isDropTarget = viewModel.dropTarget == .pinnedAreaTop
        ZStack(alignment: .topLeading) {
            // Hover / context menu area: the whole header (y 145–181). It is also a drop target
            // that pins the dragged tab first, shown as a full-width saturated blue band.
            // [06 §15.4] observed.
            (isDropTarget ? Self.dropBandFill(palette: palette).swiftUI : Color.clear)
                .frame(width: layout.width, height: CGFloat(s.spaceHeaderHeight))
                .contentShape(Rectangle())
                .sidebarDropRegion(.spaceName)
                .offset(y: CGFloat(s.spaceHeaderTop))
            if let icon {
                // A ≈ 14 pt glyph centered in the 26 pt cell (B33 round-2 PX), not a 26 pt glyph.
                SidebarSpaceIconView(icon: icon, size: CGFloat(s.spaceIconFrame.width),
                                     glyphSize: SidebarLocalTokens.spaceIconGlyphSize, tint: palette.ink(\.spaceIcon).swiftUI)
                    .frame(width: CGFloat(s.spaceIconFrame.width), height: CGFloat(s.spaceIconFrame.height))
                    .accessibilityBox(label: "Space icon", identifier: "openarc.sidebar.spaceIcon", traits: .isImage)
                    .offset(x: CGFloat(s.spaceIconFrame.x), y: CGFloat(s.spaceIconFrame.y))
            }
            Text(viewModel.selectedSpace?.name ?? "")
                .font(style.font)
                .foregroundStyle(palette.ink(\.spaceName).swiftUI)
                .lineLimit(1)
                .padding(.leading, SidebarLocalTokens.textInkInset)
                .frame(width: CGFloat(s.spaceNameTrailing) - nameLeading, height: CGFloat(style.lineHeight), alignment: .leading)
                // The element spans the name line (x to 259, 18 tall), like the reference.
                .accessibilityBox(label: viewModel.selectedSpace?.name ?? "", identifier: "openarc.sidebar.spaceName")
                .offset(x: nameLeading, y: CGFloat(s.spaceNameTop))
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
            .offset(x: CGFloat(more.maxX) - moreWidth, y: CGFloat(more.y))
        }
        .onHover { isHovering = $0 }
    }
}

/// Bottom dock, centered on y = H − 25 [07 §4] observed: a Home button at x 8 (32 × 32), the Space
/// icons sharing x 42–234 (current opaque, others ≈ 33 % with dark ink; ≈ 50 % / ≈ 12 % with light
/// ink, B32 round-1 PX), and "+" (New Space) at x 236.
struct SidebarDockView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout

    var body: some View {
        let palette = viewModel.palette
        let tint = palette.primaryText.swiftUI.opacity(palette.inkOpacity.dockButton)
        let top = layout.dockFrame.minY
        let spaces = viewModel.dockSpaces
        ZStack(alignment: .topLeading) {
            dockButton(layout.dockHomeFrame, top: top, symbol: SidebarLocalTokens.dockHomeSymbol,
                       glyphSize: SidebarLocalTokens.dockHomeGlyphSize, tint: tint,
                       label: "Library", id: "openarc.sidebar.dock.home") {
                viewModel.requestFromMenu(.openLibrary)
            }
            ForEach(Array(zip(spaces, layout.dockItemFrames(count: spaces.count))), id: \.0.id) { space, frame in
                dockItem(space, frame: frame, top: top, palette: palette)
            }
            dockButton(layout.dockPlusFrame, top: top, symbol: "plus", glyphSize: SidebarLocalTokens.dockPlusGlyphSize,
                       glyphWeight: SidebarLocalTokens.dockPlusGlyphWeight, tint: tint,
                       label: "New Space", id: "openarc.sidebar.dock.plus") {
                viewModel.requestFromMenu(.newSpace)
            }
        }
        .frame(width: layout.width, height: layout.dockFrame.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.dock")
    }

    /// Home and "+": 32 × 32 hit areas; glyph sizes give the measured ink (+ 14 × 15 for 14 × 14,
    /// stack 13.5 × 16 for 13.5 × 16.5). [07 §4] observed ink; the Home glyph's shape is our own.
    private func dockButton(_ frame: CGRect, top: CGFloat, symbol: String, glyphSize: CGFloat,
                            glyphWeight: Font.Weight = .regular, tint: Color,
                            label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyphSize, weight: glyphWeight))
                .foregroundStyle(tint)
                .frame(width: frame.width, height: frame.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: frame.width, height: frame.height)
        .offset(x: frame.minX, y: frame.minY - top)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func dockItem(_ space: Space, frame: CGRect, top: CGFloat, palette: ThemePalette) -> some View {
        let isCurrent = space.id == viewModel.selectedSpaceID
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
                if viewModel.dropTarget == .dockSpace(space.id) {
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

