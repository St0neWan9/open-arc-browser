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

    var body: some View {
        let layout = SidebarLayout()
        let fillFrame = layout.rowFillFrame
        let radius = CGFloat(Metrics.Sidebar.selectedRowCornerRadius)
        let block = (fillFrame.width * CGFloat(Metrics.SidebarDrag.splitPreviewWidthFraction)).rounded()
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

/// A tab row in the pinned area or in Today. States: normal, hover (darker fill + ✕ / —),
/// selected (near-white rounded fill), loading (spinner instead of icon), audible (speaker),
/// renaming (inline text field). [06 §4, §12] observed; title SF Regular 14 in the theme's row
/// text color, unchanged when selected [07 §3, §8] observed.
struct SidebarTabRowView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let tab: TabNode
    let depth: Int
    let area: SidebarArea

    @Environment(\.windowSurface) private var surface
    @State private var isHovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let palette = viewModel.palette
        let isSelected = viewModel.isSelected(tab.id)
        let live = viewModel.liveState(for: tab.id)
        let textColor = isSelected ? palette.selectedTabText.swiftUI : palette.rowTitleText.swiftUI
        let iconSize = SidebarLocalTokens.rowIconSize
        let style = Typography.tabRowTitle

        SidebarRowFrame(fill: fill(isSelected: isSelected, palette: palette), shadow: isSelected ? Metrics.Sidebar.selectedRowShadow : nil,
                        depth: depth, splitPreview: viewModel.splitPreviewSide(for: tab.id), splitPreviewFill: palette.splitPreviewFill.swiftUI) {
            Group {
                if viewModel.isEaselRow(tab.id) {
                    // An Easel row has the Easel icon. [06 §4] observed. B56.
                    Image(systemName: EaselIcon.symbol)
                        .font(.system(size: iconSize * 0.8, weight: .medium))
                        .foregroundStyle(textColor)
                } else if live?.isLoading == true {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if let icon = tab.icon {
                    // Change Icon… replaces the favicon. [06 §21.5] observed item (B77).
                    SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor)
                } else {
                    SidebarFaviconView(pngData: viewModel.faviconImage(for: tab.id), size: iconSize, tint: placeholderTint(isSelected: isSelected, palette: palette), placeholder: .roundedSquare)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .accessibilityBox(label: "Icon", identifier: "openarc.sidebar.row.icon", traits: .isImage)
            .padding(.trailing, SidebarLayout().rowTitleGap)

            if viewModel.renamingItemID == tab.id {
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
                    if viewModel.showsPinRenameHint(tab.id) {
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

            Spacer(minLength: 4)
            accessory(live: live, textColor: textColor)
        }
        .onHover { hovering in
            isHovering = hovering
            if hovering { viewModel.hoverBegan(tab.id) } else { viewModel.hoverEnded(tab.id) }
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded { viewModel.beginRename(tab.id) })
        .onTapGesture { viewModel.selectTab(tab.id) }
        .contextMenu {
            // An incognito window has its own tab menu (no Pin / Move / Favorites). [06 §20.2] observed (B48).
            if viewModel.isIncognito {
                IncognitoTabMenu(viewModel: viewModel, tab: tab)
            } else {
                SidebarTabMenu(viewModel: viewModel, tab: tab, kind: area == .pinned ? .pinned : .today)
            }
        }
        .sidebarRowInteraction(viewModel: viewModel, id: tab.id)
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
                                                           isPressed: viewModel.pressedItemID == tab.id).swiftUI
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

    @ViewBuilder
    private func accessory(live: SidebarTabLiveState?, textColor: Color) -> some View {
        if isHovering && viewModel.renamingItemID != tab.id {
            // ✕ archives a Today tab; — on a pinned row unloads it (ambiguous in the spec, see
            // `SidebarViewModel.unloadPinnedTab`). [06 §12] observed.
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
        } else if live?.isAudible == true {
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: SidebarLocalTokens.rowAccessoryGlyphSize))
                .foregroundStyle(textColor.opacity(SidebarLocalTokens.rowAccessoryInkOpacity))
                .frame(width: SidebarLocalTokens.rowAccessoryButtonSize, height: SidebarLocalTokens.rowAccessoryButtonSize)
                .accessibilityLabel("Playing audio")
        }
    }
}

/// One row for the tabs of a split view. [06 §5] observed: "the two split tabs are treated as one
/// group in the sidebar". Nothing else is specified, so the look is local: the row has the geometry
/// and selected fill of a tab row and shows each member's favicon and title side by side. A click
/// selects the focused pane tab; ✕ (— in the pinned area) acts on the whole group; the row drags as
/// a unit. Per-member clicks, rename and the hover card are not part of the group row.
struct SidebarSplitGroupRowView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let group: SidebarSplitGroup
    let depth: Int
    let area: SidebarArea

    @Environment(\.windowSurface) private var surface
    @State private var isHovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let palette = viewModel.palette
        let isSelected = viewModel.isGroupSelected(group)
        let textColor = isSelected ? palette.selectedTabText.swiftUI : palette.rowTitleText.swiftUI
        let layout = viewModel.splitLayout(group.layoutID)

        SidebarRowFrame(fill: fill(isSelected: isSelected, palette: palette), shadow: isSelected ? Metrics.Sidebar.selectedRowShadow : nil, depth: depth) {
            if viewModel.renamingItemID == group.layoutID {
                // Split row ▸ Rename…: inline, like a tab row. [06 §21.5] observed item (B77).
                renameField(layout: layout, textColor: textColor)
            } else if layout?.title != nil || layout?.icon != nil {
                // A named split row shows its own icon and title instead of the members'. inferred (B77).
                namedCell(layout: layout, textColor: textColor)
            } else {
                ForEach(Array(group.members.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        Rectangle()
                            .fill(textColor.opacity(SidebarLocalTokens.splitGroupDividerOpacity))
                            .frame(width: SidebarLocalTokens.separatorThickness, height: SidebarLocalTokens.splitGroupDividerHeight)
                    }
                    memberCell(member, textColor: textColor, isFirst: index == 0)
                }
            }
            accessory(textColor: textColor)
        }
        .onHover { isHovering = $0 }
        .onTapGesture { viewModel.selectSplitGroup(group.layoutID) }
        // The split row's own menu. [06 §21.5] observed (B55).
        .contextMenu { SidebarSplitGroupMenu(viewModel: viewModel, group: group) }
        .sidebarRowInteraction(viewModel: viewModel, id: group.layoutID)
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
                } else if let first = group.members.first {
                    SidebarFaviconView(pngData: viewModel.faviconImage(for: first.id), size: iconSize, tint: textColor.opacity(0.3), placeholder: .roundedSquare)
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
            .accessibilityIdentifier("openarc.sidebar.splitGroup.renameField")
    }

    private func memberCell(_ member: TabNode, textColor: Color, isFirst: Bool) -> some View {
        let live = viewModel.liveState(for: member.id)
        let iconSize = SidebarLocalTokens.rowIconSize
        return HStack(spacing: SidebarLocalTokens.splitGroupMemberIconGap) {
            Group {
                if live?.isLoading == true {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                } else if let icon = member.icon {
                    SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor)
                } else {
                    SidebarFaviconView(pngData: viewModel.faviconImage(for: member.id), size: iconSize, tint: textColor.opacity(0.3), placeholder: .roundedSquare)
                }
            }
            .frame(width: iconSize, height: iconSize)
            Text(member.displayTitle.isEmpty ? "New Tab" : member.displayTitle)
                .font(Typography.tabRowTitle.font)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // The first member's icon stays at the row icon position (x 17).
        .padding(.leading, isFirst ? 0 : SidebarLocalTokens.splitGroupMemberPadding)
        .padding(.trailing, SidebarLocalTokens.splitGroupMemberPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fill(isSelected: Bool, palette: ThemePalette) -> Color {
        if isSelected {
            return SidebarRowFrame<EmptyView>.selectedFill(palette.windowFills(on: surface).selectedRowFill,
                                                           isPressed: viewModel.pressedItemID == group.layoutID).swiftUI
        }
        if isHovering { return Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) }
        return .clear
    }

    @ViewBuilder
    private func accessory(textColor: Color) -> some View {
        if isHovering {
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

/// A folder row: SF Semibold 14 title, folder icon (open when expanded) whose ink (≈ 22.5 × 16.5)
/// is centered on the 18 pt icon cell. [07 §3, §4] observed; [06 §3] observed.
struct SidebarFolderRowView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let folder: Folder
    let depth: Int

    @State private var isHovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        let palette = viewModel.palette
        let iconSize = SidebarLocalTokens.rowIconSize
        let textColor = palette.rowTitleText.swiftUI
        let style = Typography.folderRowTitle

        SidebarRowFrame(fill: isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear, depth: depth) {
            // 18 pt symbol ≈ 21 × 16 ink; drawn in the 18 pt cell, overflowing it symmetrically
            // like the measured 22.5 pt ink (x 16–38.5).
            Group {
                if let icon = folder.icon {
                    // Change Icon… replaces the folder glyph. [06 §21.5] observed item (B77).
                    SidebarCustomIconView(icon: icon, size: iconSize, tint: textColor.opacity(0.8))
                } else {
                    Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(textColor.opacity(0.8))
                }
            }
                .frame(width: iconSize, height: iconSize)
                .padding(.trailing, SidebarLayout().rowTitleGap)

            if viewModel.renamingItemID == folder.id {
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
        .sidebarRowInteraction(viewModel: viewModel, id: folder.id)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openarc.sidebar.folder.\(folder.id.uuidString)")
    }
}

/// Divider between the pinned area and Today: a 17 pt row with a 0.5 pt hairline (window × 0.87)
/// across x 18.5–257.5. [07 §1, §4] observed. "Clear" shows at the right end only while the sidebar
/// is hovered ([07 §3] inferred: not visible in E11; [06 §12] observed "gray → darker while hovering").
struct SidebarDividerRowView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let canClear: Bool
    let isSidebarHovered: Bool
    @Environment(\.windowSurface) private var surface

    var body: some View {
        let palette = viewModel.palette
        let s = Metrics.Sidebar.self
        let layout = SidebarLayout()
        let lineWidth = CGFloat(s.dividerLineTrailing - s.dividerLineLeading)
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
                .offset(x: CGFloat(s.dividerLineTrailing) - SidebarLocalTokens.clearButtonWidth)
                .accessibilityIdentifier("openarc.sidebar.clearButton")
            }
        }
        .frame(width: layout.width, height: CGFloat(s.dividerRowHeight), alignment: .leading)
        .contentShape(Rectangle())
        .sidebarDropRegion(.divider)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.divider")
    }
}

/// "+ New Tab" row at the top of Today, right under the divider: tab-row geometry, no fill, a "+"
/// (ink ≈ 11.5 × 12 at x 20) in the icon cell, SF Regular 14 in black 30 % [07 §3, §4] observed;
/// white ≈ 50 % with light ink (B32 round-1 PX, inferred).
struct SidebarNewTabRowView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let isEmptySpace: Bool
    @State private var isHovering = false

    var body: some View {
        let palette = viewModel.palette
        let ink = palette.ink(\.newTabRow).swiftUI
        let style = Typography.newTabRow
        SidebarRowFrame(fill: isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear) {
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
        .sidebarDropRegion(.newTabRow)
        // Like the reference row: an element holding the icon and the title.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { viewModel.newTabRowClicked() }
        .accessibilityIdentifier("openarc.sidebar.newTabRow")
    }
}
