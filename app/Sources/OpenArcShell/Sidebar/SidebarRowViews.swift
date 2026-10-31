import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// Tab row and folder row.

/// Geometry shared by the list rows: each row is the full sidebar width and one pitch (41) tall;
/// the 40 pt row button is at its top; the selected / hovered fill spans x 8–268, y 2–38 with
/// radius ≈ 11; the 18 pt icon is at x 17, vertically centered in the button; the title starts at
/// x 43. [07 §1, §4] observed.
struct SidebarRowFrame<Content: View>: View {
    let fill: Color
    /// Soft shadow under the fill: set on the selected row only. [07 §4, §7] observed.
    var shadow: Metrics.PanelShadow? = nil
    var depth: Int = 0
    /// Split preview while a tab is dragged over the row's middle band: a gray-violet block on the
    /// pointer's side, the row content moved to the other side. [06 §15.2] observed.
    var splitPreview: SplitSide? = nil
    /// Color of the split preview block: follows the theme. [06 §15.4] observed (E17).
    var splitPreviewFill: Color = RGBAColor(hex: SidebarLocalTokens.splitPreviewRGB).swiftUI
    @ViewBuilder let content: () -> Content
    /// The window's sidebar width (B144): the row and its fill span it.
    @Environment(\.sidebarWidth) private var sidebarWidth

    var body: some View {
        let layout = SidebarLayout(width: sidebarWidth)
        let fillFrame = layout.rowFillFrame
        let radius = CGFloat(Metrics.Sidebar.selectedRowCornerRadius)
        let block = (fillFrame.width * CGFloat(Metrics.SidebarDrag.splitPreviewWidthFraction)).rounded()
        // A fixed-size row: `SidebarFixedFrameLayout` gives it its size without measuring the
        // content and reports no alignment guides, so SwiftUI's hover and scroll geometry queries
        // stop at the row instead of walking into its text (B99 profile: that walk was most of a
        // scroll frame).
        SidebarFixedFrameLayout(size: CGSize(width: layout.width, height: layout.rowHeight)) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .frame(width: fillFrame.width, height: fillFrame.height)
                    .panelShadow(shadow)
                    .offset(x: fillFrame.minX, y: fillFrame.minY)
                if let splitPreview {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(splitPreviewFill)
                        .frame(width: block, height: fillFrame.height)
                        .offset(x: splitPreview == .leading ? fillFrame.minX : fillFrame.maxX - block, y: fillFrame.minY)
                        .accessibilityHidden(true)
                }
                HStack(spacing: 0) { content() }
                    .padding(.leading, layout.rowIconLeading + CGFloat(depth) * SidebarLocalTokens.folderIndent
                             + (splitPreview == .leading ? block : 0))
                    .padding(.trailing, layout.width - fillFrame.maxX + SidebarLocalTokens.rowAccessoryTrailingPadding
                             + (splitPreview == .trailing ? block : 0))
                    .frame(width: layout.width, height: layout.rowButtonHeight, alignment: .leading)
            }
            .frame(width: layout.width, height: layout.rowHeight, alignment: .topLeading)
        }
        .contentShape(Rectangle())
    }

    /// Fill of a selected row: the theme's selected-row fill, ≈ 1 % darker while the mouse holds
    /// it (no scale). [07 §7] observed (#F0EDF0 → #EEECED).
    static func selectedFill(_ base: RGBAColor, isPressed: Bool) -> RGBAColor {
        isPressed ? ThemeDerivation.shade(base, by: Metrics.Sidebar.pressedRowShade) : base
    }
}

extension View {
    /// A black drop shadow from a `Metrics.PanelShadow` token; nil draws none.
    @ViewBuilder
    func panelShadow(_ shadow: Metrics.PanelShadow?) -> some View {
        if let shadow {
            self.shadow(color: .black.opacity(shadow.opacity), radius: CGFloat(shadow.radius),
                        x: CGFloat(shadow.offsetX), y: CGFloat(shadow.offsetY))
        } else {
            self
        }
    }
}

/// What a tab row draws. The list computes it for each row it builds (`SidebarListRows`), so a row
/// is re-evaluated only when its own state changes, not on every change of the sidebar's view
/// model (a selection, a page title or a loading flag used to re-evaluate every built row, B99).
struct SidebarTabRowState: Equatable {
    var tab: TabNode
    var depth: Int
    var area: SidebarArea
    var palette: ThemePalette
    var isSelected = false
    /// The mouse holds this (selected) row. [07 §7] observed.
    var isPressed = false
    var isLoading = false
    var audio: SidebarAudioIndicator?
    var isEasel = false
    /// PNG bytes of the favicon, nil for the placeholder.
    var favicon: Data?
    var splitPreview: SplitSide?
    var isRenaming = false
    var showsRenameHint = false
    /// The row is the "drop into" target of a drag (`SidebarRowInteraction`).
    var isDropInto = false
    var isIncognito = false
}

/// A tab row in the pinned area or in Today. States: normal, hover (darker fill + ✕ / —),
/// selected (near-white rounded fill), loading (spinner instead of icon), audible or muted (speaker
/// between icon and title, [05 §tab audio indicator] observed), renaming (inline text field). [06 §4, §12] observed; title SF Regular 14 in the theme's row
/// text color, unchanged when selected [07 §3, §8] observed.
struct SidebarTabRowView: View, Equatable {
    /// For actions only: the row does not observe the view model (see `SidebarTabRowState`).
    let viewModel: SidebarViewModel
    let row: SidebarTabRowState
    private var tab: TabNode { row.tab }
    private var area: SidebarArea { row.area }

    @Environment(\.windowSurface) private var surface
    @State private var isHovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        let palette = row.palette
        let isSelected = row.isSelected
        let textColor = isSelected ? palette.selectedTabText.swiftUI : palette.rowTitleText.swiftUI
        let iconSize = SidebarLocalTokens.rowIconSize
        let style = Typography.tabRowTitle

        SidebarRowFrame(fill: fill(isSelected: isSelected, palette: palette), shadow: isSelected ? Metrics.Sidebar.selectedRowShadow : nil,
                        depth: row.depth, splitPreview: row.splitPreview, splitPreviewFill: palette.splitPreviewFill.swiftUI) {
            // Favicon, then the speaker while the tab is audible or muted, then the title.
            // [05 §tab audio indicator] observed.
            ForEach(SidebarTabRowPart.leadingParts(audio: row.audio), id: \.self) { part in
                switch part {
                case .icon:
                    Group {
                        if row.isEasel {
                            // An Easel row has the Easel icon. [06 §4] observed. B56.
                            Image(systemName: EaselIcon.symbol)
                                .font(.system(size: iconSize * 0.8, weight: .medium))
                                .foregroundStyle(textColor)
                        } else if row.isLoading {
                            ProgressView().controlSize(.small).scaleEffect(0.6)
                        } else if let icon = tab.icon {
                            // Change Icon… replaces the favicon. [06 §21.5] observed item (B77).
                            SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor)
                        } else {
                            SidebarFaviconView(pngData: row.favicon, size: iconSize, tint: placeholderTint(isSelected: isSelected, palette: palette), placeholder: .roundedSquare)
                        }
                    }
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityBox(label: "Icon", identifier: "openarc.sidebar.row.icon", traits: .isImage)
                    .padding(.trailing, SidebarLayout().rowTitleGap)
                case .audio(let audio):
                    SidebarAudioGlyphButton(viewModel: viewModel, tabID: tab.id, indicator: audio, textColor: textColor)
                case .title:
                    if row.isRenaming {
                        TextField("", text: $renameText)
                            .textFieldStyle(.plain)
                            .font(style.font)
                            .foregroundStyle(textColor)
                            .focused($renameFocused)
                            .onSubmit { viewModel.commitRename(tab.id, text: renameText) }
                            .onExitCommand { viewModel.cancelRename() }
                            .onChange(of: renameFocused) { _, focused in
                                if !focused, viewModel.renamingItemID == tab.id { viewModel.commitRename(tab.id, text: renameText) }
                            }
                            .onAppear {
                                renameText = tab.displayTitle
                                renameFocused = true
                            }
                            // The rename never outlives its field (F5-1).
                            .onDisappear { viewModel.renameFieldClosed(tab.id, text: renameText) }
                            .accessibilityIdentifier("openarc.sidebar.row.renameField")
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tab.displayTitle.isEmpty ? "New Tab" : tab.displayTitle)
                                .font(style.font)
                                .foregroundStyle(textColor)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                // Ink 1 pt inside the 43 pt text frame ([07 §4] ink at 45, B33).
                                .padding(.leading, SidebarLocalTokens.textInkInset)
                                .frame(height: CGFloat(style.lineHeight))
                                .accessibilityBox(label: tab.displayTitle.isEmpty ? "New Tab" : tab.displayTitle, identifier: "openarc.sidebar.row.title")
                            if row.showsRenameHint {
                                // The first pin's faint hint under the title. [06 §4] observed; the hover
                                // card's hint style (11 pt, 50 %) is reused, inferred. B76.
                                Text(SidebarLocalTokens.hoverCardHint)
                                    .font(Typography.hoverCardHint.font)
                                    .foregroundStyle(textColor.opacity(Typography.hoverCardHint.opacity))
                                    .lineLimit(1)
                                    .padding(.leading, SidebarLocalTokens.textInkInset)
                                    .frame(height: CGFloat(Typography.hoverCardHint.lineHeight))
                                    .accessibilityIdentifier("openarc.sidebar.row.renameHint")
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 4)
            accessory(textColor: textColor)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { viewModel.hoverBegan(tab.id) } else { viewModel.hoverEnded(tab.id) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { viewModel.beginRename(tab.id) })
        .onTapGesture { viewModel.selectTab(tab.id) }
        .contextMenu {
            // An incognito window has its own tab menu (no Pin / Move / Favorites). [06 §20.2] observed (B48).
            if row.isIncognito {
                IncognitoTabMenu(viewModel: viewModel, tab: tab)
            } else {
                SidebarTabMenu(viewModel: viewModel, tab: tab, kind: area == .pinned ? .pinned : .today)
            }
        }
        .sidebarRowInteraction(isDropInto: row.isDropInto)
        // Like the reference's outline row: a 41 pt row holding the icon cell and the title line.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tab.displayTitle.isEmpty ? "New Tab" : tab.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { viewModel.selectTab(tab.id) }
        .accessibilityIdentifier("openarc.sidebar.row.\(tab.id.uuidString)")
    }

    private func fill(isSelected: Bool, palette: ThemePalette) -> Color {
        if isSelected {
            return SidebarRowFrame<EmptyView>.selectedFill(palette.windowFills(on: surface).selectedRowFill,
                                                           isPressed: row.isPressed).swiftUI
        }
        if isHovering { return Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) }
        return .clear
    }

    /// The favicon placeholder square: the chrome ink at its placeholder opacity; on the near-white
    /// selected fill the row text color at the dark-ink opacity ("the icon placeholder gets
    /// lighter" when selected, [07 §7] observed).
    private func placeholderTint(isSelected: Bool, palette: ThemePalette) -> Color {
        if isSelected { return palette.selectedTabText.swiftUI.opacity(ChromeInkOpacities.darkInk.faviconPlaceholder) }
        return palette.ink(\.faviconPlaceholder).swiftUI
    }

    /// Whether the row shows its ✕ / —: while hovered or selected, not while renaming. [06 §12]
    /// observed (hover), [06 §20.2] observed ("hover / selected", same as Today rows). F5-13.
    static func showsAccessory(isHovering: Bool, isSelected: Bool, isRenaming: Bool) -> Bool {
        (isHovering || isSelected) && !isRenaming
    }

    @ViewBuilder
    private func accessory(textColor: Color) -> some View {
        if Self.showsAccessory(isHovering: isHovering, isSelected: row.isSelected, isRenaming: row.isRenaming) {
            // ✕ archives a Today tab; — on a pinned row unloads the page and keeps the pin
            // (`SidebarViewModel.unloadPinnedTab`). [06 §12], [06 §16.1] observed.
            Button {
                if area == .pinned { viewModel.unloadPinnedTab(tab.id) } else { viewModel.closeTab(tab.id) }
            } label: {
                Image(systemName: area == .pinned ? "minus" : "xmark")
                    .font(.system(size: SidebarLocalTokens.rowAccessoryGlyphSize, weight: SidebarLocalTokens.rowAccessoryGlyphWeight))
                    .foregroundStyle(textColor.opacity(SidebarLocalTokens.rowAccessoryInkOpacity))
                    .frame(width: SidebarLocalTokens.rowAccessoryButtonSize, height: SidebarLocalTokens.rowAccessoryButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(area == .pinned ? "Unload pinned tab" : "Archive tab")
            .accessibilityIdentifier("openarc.sidebar.row.accessory")
        }
    }
}

/// The speaker glyph between a row's favicon and title, in the row's ink: sound waves while the
/// tab plays, crossed out while it is muted; a click mutes / unmutes without selecting the row.
/// [05 §tab audio indicator] observed. Its frame is reported to the sidebar's scroll state
/// (`SidebarListScrollState.audioGlyphFrames`) so the sidebar's press-to-select monitor leaves it
/// alone. Reported directly, not as a preference: a preference key is combined through every row
/// view of the list on each update, glyph or not (B99 profile).
struct SidebarAudioGlyphButton: View {
    /// Used by the action only: the row passes everything it draws (B104).
    let viewModel: SidebarViewModel
    let tabID: UUID
    let indicator: SidebarAudioIndicator
    let textColor: Color
    @Environment(\.sidebarAudioGlyphSink) private var sink

    var body: some View {
        Button {
            viewModel.audioIndicatorClicked(tabID)
        } label: {
            Image(systemName: indicator.symbol)
                .font(.system(size: SidebarLocalTokens.rowAccessoryGlyphSize))
                .foregroundStyle(textColor.opacity(SidebarLocalTokens.rowAccessoryInkOpacity))
                .frame(width: SidebarLocalTokens.rowAudioGlyphCellWidth, height: SidebarLocalTokens.rowAccessoryButtonSize)
                .padding(.trailing, SidebarLocalTokens.rowAudioGlyphTitleGap)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(SidebarCoordinateSpace.root)) }) { [sink, tabID] frame in
            sink?.audioGlyphFrames[tabID] = frame
        }
        .onDisappear { [sink, tabID] in sink?.audioGlyphFrames[tabID] = nil }
        .accessibilityLabel(indicator.accessibilityLabel)
        .accessibilityIdentifier(SidebarAudioIndicator.accessibilityIdentifier)
    }
}

/// One row for the tabs of a split view: the geometry and selected fill of a tab row, holding one
/// capsule per member side by side, each with the member's icon and truncated title. [06 §5]
/// observed (one group in the sidebar), [06 §21.6] observed ("one row with two capsules side by
/// side", row fill as a selected row); the capsule metrics are ours (`SidebarLocalTokens`). A click
/// selects the focused pane tab; ✕ (— in the pinned area) acts on the whole group; the row drags as
/// a unit. Per-member clicks and the hover card are not part of the group row.
struct SidebarSplitGroupRowView: View, Equatable {
    /// What the row draws; the row does not observe the view model (see `SidebarTabRowState`).
    struct State: Equatable {
        /// Live state of one member, in `group.members` order.
        struct Member: Equatable {
            var isLoading = false
            var audio: SidebarAudioIndicator?
            var favicon: Data?
        }
        var group: SidebarSplitGroup
        var depth: Int
        var area: SidebarArea
        var palette: ThemePalette
        var layout: SplitLayout?
        var members: [Member] = []
        var isSelected = false
        var isPressed = false
        var isRenaming = false
        var isDropInto = false
    }

    /// For actions only.
    let viewModel: SidebarViewModel
    let row: State
    private var group: SidebarSplitGroup { row.group }
    private var area: SidebarArea { row.area }

    @Environment(\.windowSurface) private var surface
    @SwiftUI.State private var isHovering = false
    @SwiftUI.State private var renameText = ""
    @FocusState private var renameFocused: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        let palette = row.palette
        let isSelected = row.isSelected
        let textColor = isSelected ? palette.selectedTabText.swiftUI : palette.rowTitleText.swiftUI
        let layout = row.layout

        SidebarRowFrame(fill: fill(isSelected: isSelected, palette: palette), shadow: isSelected ? Metrics.Sidebar.selectedRowShadow : nil, depth: row.depth) {
            if row.isRenaming {
                // Split row ▸ Rename…: inline, like a tab row. [06 §21.5] observed item (B77).
                renameField(layout: layout, textColor: textColor)
            } else if layout?.title != nil || layout?.icon != nil {
                // A named split row shows its own icon and title instead of the members'. inferred (B77).
                namedCell(layout: layout, textColor: textColor)
            } else {
                HStack(spacing: SidebarLocalTokens.splitGroupCapsuleGap) {
                    ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                        memberCapsule(member, state: index < row.members.count ? row.members[index] : State.Member(),
                                      textColor: textColor)
                    }
                }
                // The first icon stays at the row icon position (x 17).
                .padding(.leading, -SidebarLocalTokens.splitGroupCapsuleLeading)
                .padding(.trailing, SidebarLocalTokens.splitGroupCapsuleGap)
            }
            accessory(textColor: textColor)
        }
        .onHover { isHovering = $0 }
        .onTapGesture { viewModel.selectSplitGroup(group.layoutID) }
        // The split row's own menu. [06 §21.5] observed (B55).
        .contextMenu { SidebarSplitGroupMenu(viewModel: viewModel, group: group) }
        .sidebarRowInteraction(isDropInto: row.isDropInto)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("openarc.sidebar.splitGroup.\(group.layoutID.uuidString)")
    }

    /// The members' titles joined, the row's title when it has none of its own.
    private var membersTitle: String {
        group.members.map { $0.displayTitle.isEmpty ? "New Tab" : $0.displayTitle }.joined(separator: " | ")
    }

    private func namedCell(layout: SplitLayout?, textColor: Color) -> some View {
        let iconSize = SidebarLocalTokens.rowIconSize
        return HStack(spacing: SidebarLayout().rowTitleGap) {
            Group {
                if let icon = layout?.icon {
                    SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor)
                } else if !group.members.isEmpty {
                    SidebarFaviconView(pngData: row.members.first?.favicon, size: iconSize, tint: textColor.opacity(0.3), placeholder: .roundedSquare)
                }
            }
            .frame(width: iconSize, height: iconSize)
            Text(layout?.title ?? membersTitle)
                .font(Typography.tabRowTitle.font)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func renameField(layout: SplitLayout?, textColor: Color) -> some View {
        TextField("", text: $renameText)
            .textFieldStyle(.plain)
            .font(Typography.tabRowTitle.font)
            .foregroundStyle(textColor)
            .focused($renameFocused)
            .onSubmit { viewModel.commitRename(group.layoutID, text: renameText) }
            .onExitCommand { viewModel.cancelRename() }
            .onChange(of: renameFocused) { _, focused in
                if !focused, viewModel.renamingItemID == group.layoutID { viewModel.commitRename(group.layoutID, text: renameText) }
            }
            .onAppear {
                renameText = layout?.title ?? membersTitle
                renameFocused = true
            }
            .onDisappear { viewModel.renameFieldClosed(group.layoutID, text: renameText) }
            .accessibilityIdentifier("openarc.sidebar.splitGroup.renameField")
    }

    private func memberCapsule(_ member: TabNode, state: State.Member, textColor: Color) -> some View {
        let iconSize = SidebarLocalTokens.rowIconSize
        return HStack(spacing: SidebarLocalTokens.splitGroupMemberIconGap) {
            Group {
                if state.isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if let icon = member.icon {
                    SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor)
                } else {
                    SidebarFaviconView(pngData: state.favicon, size: iconSize, tint: textColor.opacity(0.3), placeholder: .roundedSquare)
                }
            }
            .frame(width: iconSize, height: iconSize)
            // Each member's speaker sits between its favicon and title. [05 §tab audio indicator] observed.
            if let audio = state.audio {
                SidebarAudioGlyphButton(viewModel: viewModel, tabID: member.id, indicator: audio, textColor: textColor)
                    .padding(.trailing, -SidebarLocalTokens.splitGroupMemberIconGap)
            }
            Text(member.displayTitle.isEmpty ? "New Tab" : member.displayTitle)
                .font(Typography.tabRowTitle.font)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, SidebarLocalTokens.splitGroupCapsuleLeading)
        .padding(.trailing, SidebarLocalTokens.splitGroupCapsuleTrailing)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: SidebarLocalTokens.splitGroupCapsuleHeight)
        .background(Capsule(style: .continuous).fill(textColor.opacity(SidebarLocalTokens.splitGroupCapsuleInkOpacity)))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openarc.sidebar.splitGroup.member")
    }

    private func fill(isSelected: Bool, palette: ThemePalette) -> Color {
        if isSelected {
            return SidebarRowFrame<EmptyView>.selectedFill(palette.windowFills(on: surface).selectedRowFill,
                                                           isPressed: row.isPressed).swiftUI
        }
        if isHovering { return Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) }
        return .clear
    }

    @ViewBuilder
    private func accessory(textColor: Color) -> some View {
        // Hovered or selected, like a tab row. [06 §12], [06 §20.2] observed. F5-13.
        if SidebarTabRowView.showsAccessory(isHovering: isHovering, isSelected: row.isSelected, isRenaming: row.isRenaming) {
            Button {
                if area == .pinned { viewModel.unloadPinnedSplitGroup(group.layoutID) } else { viewModel.closeSplitGroup(group.layoutID) }
            } label: {
                Image(systemName: area == .pinned ? "minus" : "xmark")
                    .font(.system(size: SidebarLocalTokens.rowAccessoryGlyphSize, weight: SidebarLocalTokens.rowAccessoryGlyphWeight))
                    .foregroundStyle(textColor.opacity(SidebarLocalTokens.rowAccessoryInkOpacity))
                    .frame(width: SidebarLocalTokens.rowAccessoryButtonSize, height: SidebarLocalTokens.rowAccessoryButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(area == .pinned ? "Unload split tabs" : "Archive split tabs")
            .accessibilityIdentifier("openarc.sidebar.splitGroup.accessory")
        }
    }
}

/// A folder row: SF Semibold 14 title, folder icon (open when expanded) vertically centered on the
/// row: closed in the 18 pt icon cell (B149 observed), open at 22.5 × 16.5 across x 16–38.5
/// ([07 §4] observed). [07 §3] observed; [06 §3] observed.
struct SidebarFolderRowView: View, Equatable {
    /// What the row draws; the row does not observe the view model (see `SidebarTabRowState`).
    struct State: Equatable {
        var folder: Folder
        var depth: Int
        var palette: ThemePalette
        var isRenaming = false
        var isDropInto = false
    }

    /// For actions only.
    let viewModel: SidebarViewModel
    let row: State
    private var folder: Folder { row.folder }

    @SwiftUI.State private var isHovering = false
    @SwiftUI.State private var renameText = ""
    @FocusState private var renameFocused: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.row == rhs.row }

    var body: some View {
        let palette = row.palette
        let iconSize = SidebarLocalTokens.rowIconSize
        let textColor = palette.rowTitleText.swiftUI
        let style = Typography.folderRowTitle

        SidebarRowFrame(fill: isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear, depth: row.depth) {
            // Closed: ink fills the 18 pt cell (B149). Open: the measured 22.5 × 16.5, overflowing
            // the cell and shifted so it spans x 16–38.5 (`SidebarFolderGlyph`). F5-32/49/59.
            Group {
                if let icon = folder.icon {
                    // Change Icon… replaces the folder glyph. [06 §21.5] observed item (B77).
                    SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor.opacity(SidebarLocalTokens.folderGlyphInkOpacity))
                } else {
                    SidebarFolderGlyph(isExpanded: folder.isExpanded, ink: textColor.opacity(SidebarLocalTokens.folderGlyphInkOpacity))
                }
            }
                .frame(width: iconSize, height: iconSize)
                .padding(.trailing, SidebarLayout().rowTitleGap)

            if row.isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(style.font)
                    .foregroundStyle(textColor)
                    .focused($renameFocused)
                    .onSubmit { viewModel.commitRename(folder.id, text: renameText) }
                    .onExitCommand { viewModel.cancelRename() }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused, viewModel.renamingItemID == folder.id { viewModel.commitRename(folder.id, text: renameText) }
                    }
                    .onAppear {
                        renameText = folder.title
                        renameFocused = true
                    }
                    .onDisappear { viewModel.renameFieldClosed(folder.id, text: renameText) }
            } else {
                Text(folder.title)
                    .font(style.font)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
        }
        .onHover { hovering in
            isHovering = hovering
            // Hovering a folder opens its quick list. [06 §14] observed. B76.
            if hovering { viewModel.folderHoverBegan(folder.id) } else { viewModel.folderHoverEnded(folder.id) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { viewModel.beginRename(folder.id) })
        .onTapGesture { viewModel.toggleFolder(folder.id) }
        .contextMenu { SidebarFolderMenu(viewModel: viewModel, folder: folder) }
        .sidebarRowInteraction(isDropInto: row.isDropInto)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openarc.sidebar.folder.\(folder.id.uuidString)")
    }
}

/// Divider between the pinned area and Today: a 17 pt row with a 0.5 pt hairline (window × 0.87)
/// across x 18.5–257.5. [07 §1, §4] observed. "Clear" shows at the right end only while the sidebar
/// is hovered ([07 §3] inferred: not visible in E11; [06 §12] observed "gray → darker while hovering").
struct SidebarDividerRowView: View {
    /// Used by the action only: the list passes everything it draws (B104).
    let viewModel: SidebarViewModel
    /// Its page's Space colors (B101).
    let palette: ThemePalette
    let canClear: Bool
    let isSidebarHovered: Bool
    @Environment(\.windowSurface) private var surface
    @Environment(\.sidebarWidth) private var sidebarWidth

    var body: some View {
        let s = Metrics.Sidebar.self
        let layout = SidebarLayout(width: sidebarWidth)
        // The hairline and "Clear" keep their distance to the sidebar's right edge. B144.
        let lineTrailing = layout.trailingX(s.dividerLineTrailing)
        let lineWidth = lineTrailing - CGFloat(s.dividerLineLeading)
        let showsClear = isSidebarHovered && canClear
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(palette.windowFills(on: surface).separator.swiftUI)
                .frame(width: showsClear ? lineWidth - SidebarLocalTokens.clearButtonWidth : lineWidth, height: CGFloat(s.dividerLineThickness))
                .offset(x: CGFloat(s.dividerLineLeading))
            if showsClear {
                Button {
                    viewModel.clearToday()
                } label: {
                    Text("↓ Clear")
                        .font(Typography.dividerClear.font)
                        .foregroundStyle(palette.ink(\.spaceName).swiftUI)
                        .frame(width: SidebarLocalTokens.clearButtonWidth, height: CGFloat(s.dividerRowHeight), alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: lineTrailing - SidebarLocalTokens.clearButtonWidth)
                .accessibilityIdentifier("openarc.sidebar.clearButton")
            }
        }
        .frame(width: layout.width, height: CGFloat(s.dividerRowHeight), alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.divider")
    }
}

/// "+ New Tab" row at the top of Today, right under the divider: tab-row geometry, no fill while
/// unselected, a "+" (ink ≈ 11.5 × 12 at x 20) in the icon cell, SF Regular 14 in black 30 %
/// [07 §3, §4] observed; white ≈ 50 % with light ink (B32 round-1 PX, inferred). Selected (the
/// window's new-tab command bar is open, inferred) it takes `selectedFill`.
struct SidebarNewTabRowView: View {
    /// Used by the action only: the list passes everything it draws (B104).
    let viewModel: SidebarViewModel
    /// Its page's Space colors (B101).
    let palette: ThemePalette
    let isEmptySpace: Bool
    var isSelected = false
    var isIncognito = false
    @Environment(\.windowSurface) private var surface
    @State private var isHovering = false

    /// Fill of the selected row: the address box's fill ([04 §侧边栏] observed "填充与搜索框同色",
    /// [07 §4] observed "无底色(未选中)"); the incognito window's observed ≈ #46494D
    /// ([06 §20.1] observed). F5-66.
    static func selectedFill(palette: ThemePalette, isIncognito: Bool, surface: WindowSurface = .opaque) -> RGBAColor {
        isIncognito ? IncognitoTokens.newTabRowSelectedFill : palette.windowFills(on: surface).controlFill
    }

    var body: some View {
        let ink = palette.ink(\.newTabRow).swiftUI
        let style = Typography.newTabRow
        let fill: Color = isSelected ? Self.selectedFill(palette: palette, isIncognito: isIncognito, surface: surface).swiftUI
            : isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear
        SidebarRowFrame(fill: fill) {
            Image(systemName: "plus")
                .font(.system(size: SidebarLocalTokens.newTabPlusGlyphSize, weight: SidebarLocalTokens.newTabPlusGlyphWeight))
                .frame(width: SidebarLocalTokens.rowIconSize, height: SidebarLocalTokens.rowIconSize)
                .accessibilityBox(label: "New Tab", identifier: "openarc.sidebar.newTabRow.icon", traits: .isImage)
                .padding(.trailing, SidebarLayout().rowTitleGap)
            Text("New Tab").font(style.font)
                .padding(.leading, SidebarLocalTokens.textInkInset)
                .frame(height: CGFloat(style.lineHeight))
                .accessibilityBox(label: "New Tab", identifier: "openarc.sidebar.newTabRow.title")
            Spacer()
        }
        .foregroundStyle(ink)
        .onHover { isHovering = $0 }
        .onTapGesture { viewModel.newTabRowClicked() }
        // Like the reference row: an element holding the icon and the title.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { viewModel.newTabRowClicked() }
        .accessibilityIdentifier("openarc.sidebar.newTabRow")
    }
}

/// The folder glyph of a folder row.
/// - Closed: our outlined folder (`SidebarClosedFolderShape`) whose ink fills the 18 pt icon cell
///   (x 17–35), 1.5 pt stroke, the tab band lightly filled. B149 observed on a 2× Arc capture.
/// - Expanded: the open folder symbol stretched to `Metrics.Sidebar.folderGlyph` (22.5 × 16.5),
///   spanning x 16–38.5 ([07 §4] observed), so it overflows the cell by `inkOffsetX`.
/// The drawings are ours (icons may differ); only the ink boxes and weights follow Arc.
struct SidebarFolderGlyph: View {
    let isExpanded: Bool
    let ink: Color

    /// Ink box of the expanded glyph. [07 §4] observed.
    static var inkSize: CGSize {
        CGSize(width: Metrics.Sidebar.folderGlyph.width, height: Metrics.Sidebar.folderGlyph.height)
    }
    /// Ink box of the closed glyph: the icon cell. B149 observed.
    static var closedInkSize: CGSize {
        CGSize(width: Metrics.Sidebar.closedFolderGlyph.width, height: Metrics.Sidebar.closedFolderGlyph.height)
    }
    /// Left edge of the expanded ink in the row (window x). [07 §4] observed (x 16–38.5).
    static let inkLeading: CGFloat = 16
    /// Shift of the expanded ink's center from the icon cell's center: (16 + 38.5) / 2 − (17 + 35) / 2.
    static var inkOffsetX: CGFloat {
        let cellCenter = CGFloat(Metrics.Sidebar.rowIconLeading + Metrics.Sidebar.rowIconSize / 2)
        return inkLeading + inkSize.width / 2 - cellCenter
    }

    /// Ink box of the glyph for a folder state.
    static func inkBox(isExpanded: Bool) -> CGSize { isExpanded ? inkSize : closedInkSize }

    var body: some View {
        if isExpanded {
            let size = Self.inkSize
            Image(systemName: "folder")
                .resizable()
                .frame(width: size.width, height: size.height)
                .foregroundStyle(ink)
                .offset(x: Self.inkOffsetX)
                .accessibilityHidden(true)
        } else {
            let size = Self.closedInkSize
            let line = CGFloat(Metrics.Sidebar.closedFolderStroke)
            ZStack {
                SidebarClosedFolderShape(part: .tabBand).fill(ink.opacity(SidebarLocalTokens.closedFolderTabFillOpacity))
                SidebarClosedFolderShape(part: .outline).stroke(ink, style: StrokeStyle(lineWidth: line, lineJoin: .round))
            }
            .frame(width: size.width, height: size.height)
            .accessibilityHidden(true)
        }
    }
}

/// Our closed folder drawing in a square box: a rounded body with a tab on the upper left, a flap
/// line across under the tab, and the band between the top outline and the flap. Stroke centers sit
/// half a stroke inside the box, so a 1.5 pt stroke inks the whole box. Proportions follow the
/// B149 capture (tab top over the left ≈ 45 % of the width, shelf ≈ 2 pt lower, flap ≈ 4 pt below
/// the top), in our own geometry.
struct SidebarClosedFolderShape: Shape {
    enum Part { case outline, tabBand }
    var part: Part

    func path(in rect: CGRect) -> Path {
        let u = rect.width / 18, v = rect.height / 18
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * u, y: rect.minY + y * v) }
        let edge: CGFloat = 0.75, far: CGFloat = 17.25, radius: CGFloat = 2.25
        let tabTop = edge, shelf: CGFloat = 2.75, flap: CGFloat = 4.75
        let tabEnd: CGFloat = 8, slopeEnd: CGFloat = 10.5
        var top = Path()
        top.move(to: p(edge, flap))
        top.addLine(to: p(edge, tabTop + radius))
        top.addQuadCurve(to: p(edge + radius, tabTop), control: p(edge, tabTop))
        top.addLine(to: p(tabEnd, tabTop))
        top.addLine(to: p(slopeEnd, shelf))
        top.addLine(to: p(far - radius, shelf))
        top.addQuadCurve(to: p(far, shelf + radius), control: p(far, shelf))
        top.addLine(to: p(far, flap))
        switch part {
        case .tabBand:
            top.closeSubpath()
            return top
        case .outline:
            var path = top
            path.addLine(to: p(far, far - radius))
            path.addQuadCurve(to: p(far - radius, far), control: p(far, far))
            path.addLine(to: p(edge + radius, far))
            path.addQuadCurve(to: p(edge, far - radius), control: p(edge, far))
            path.closeSubpath()
            path.move(to: p(edge, flap))
            path.addLine(to: p(far, flap))
            return path
        }
    }
}
