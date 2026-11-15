import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// The Library mode of the main window. [06 §8] observed: an icon rail on the left, a list column,
// and the web panel on the right (the page that was open stays); [07 §6] observed: the left part
// is 417 wide, rail buttons 97 × 80 at a 100 pitch. The Spaces section replaces the list column
// and web panel with a horizontal board of all spaces.

struct LibraryView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    @ObservedObject var library: LibraryModel
    let palette: ThemePalette
    let windowSize: CGSize

    var body: some View {
        let layout = LibraryLayout(windowSize: windowSize)
        let section = library.section ?? .media
        ZStack(alignment: .topLeading) {
            // Everything right of the rail sits on a deeper shade of the window color, in every
            // section (B224 observed on Spaces; B226 user 2026-11-15: the other sections too,
            // inferred for them).
            LibraryContentArea(palette: palette)
                .frame(width: layout.boardFrame.width, height: layout.boardFrame.height)
                .offset(x: layout.boardFrame.minX, y: layout.boardFrame.minY)
            if section == .spaces {
                LibrarySpacesBoard(model: model, sidebar: sidebar, library: library)
                    .frame(width: layout.boardFrame.width, height: layout.boardFrame.height)
                    .offset(x: layout.boardFrame.minX, y: layout.boardFrame.minY)
            }
            LibraryRail(model: model, library: library, palette: palette, itemsTop: layout.railItemsTop)
                .frame(width: layout.railFrame.width, height: layout.railFrame.height)
            if section == .spaces {
                LibraryPagePeek(palette: palette) { model.exitLibrary() }
                    .frame(width: layout.pagePeekFrame.width, height: layout.pagePeekFrame.height)
                    .offset(x: layout.pagePeekFrame.minX, y: layout.pagePeekFrame.minY)
            }

            if section != .spaces {
                LibraryListColumn(library: library, section: section, palette: palette)
                    .frame(width: layout.listFrame.width, height: layout.listFrame.height)
                    .offset(x: layout.listFrame.minX, y: layout.listFrame.minY)
                webPanel(layout.webPanelFrame)
            }
        }
        .frame(width: windowSize.width, height: windowSize.height, alignment: .topLeading)
        // Delete Space from the Spaces board shows the window card (`SidebarWindowModals`, B91).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library")
    }

    @ViewBuilder
    private func webPanel(_ frame: CGRect) -> some View {
        if let splitLayout = model.activeSplitLayout {
            SplitWebArea(model: model, sidebar: sidebar, layout: splitLayout, size: frame.size, palette: palette)
                .offset(x: frame.minX, y: frame.minY)
        } else {
            EaselOrWebPanel(model: model, sidebar: sidebar, size: frame.size, palette: palette)
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous))
                .webPanelEdgeShadow(palette.appearance)
                .offset(x: frame.minX, y: frame.minY)
        }
    }

}

// MARK: - Content area

/// The area right of the rail: a deeper shade of the window color, a faint shadow cast by the rail
/// along its edge, and a 1 pt light line on the rail's own edge (drawn just left of the area).
/// B224 / B226 observed (user's Arc screenshot): rail #5E69FB, line #666FFB, area #515DF0 at the
/// edge fading to #535FF7 over ≈ 20 pt.
struct LibraryContentArea: View {
    let palette: ThemePalette

    var body: some View {
        let t = LibraryLocalTokens.self
        ZStack(alignment: .leading) {
            t.boardAreaFill(for: palette.windowBackground).swiftUI
            LinearGradient(colors: [Color.black.opacity(t.boardEdgeShadowBlack), Color.black.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: t.boardEdgeShadowWidth)
            Color.white.opacity(t.railEdgeHighlightWhite)
                .frame(width: t.railEdgeHighlightWidth)
                .offset(x: -t.railEdgeHighlightWidth)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Page panel at the right edge (Spaces)

/// The page panel slid out to the right in the Spaces section, ≈ 56 pt still on screen: the
/// content-area color, its top bar with the Show Sidebar button and the back arrow, no page.
/// B227 observed (user's Arc screenshot); the click back to the page is inferred.
struct LibraryPagePeek: View {
    let palette: ThemePalette
    let onTap: () -> Void

    var body: some View {
        let t = LibraryLocalTokens.self
        let ink = Color.black.opacity(t.pagePeekIconBlack)
        let shape = RoundedRectangle(cornerRadius: Metrics.WebPanel.cornerRadius, style: .continuous)
        ZStack(alignment: .topLeading) {
            palette.webPanelBackground.swiftUI
            Rectangle().fill(Color.black.opacity(t.pagePeekLineBlack))
                .frame(height: t.pagePeekLineWidth)
                .offset(y: t.pagePeekBarHeight)
            Image(systemName: "sidebar.left")
                .font(.system(size: WebToolbarLocalTokens.sidebarGlyphSize, weight: WebToolbarLocalTokens.glyphWeight))
                .foregroundStyle(ink)
                .position(t.pagePeekSidebarIconCenter)
            Image(systemName: "arrow.left")
                .font(.system(size: WebToolbarLocalTokens.arrowGlyphSize, weight: WebToolbarLocalTokens.glyphWeight))
                .foregroundStyle(ink)
                .position(x: t.pagePeekBackIconCenterX, y: t.pagePeekSidebarIconCenter.y)
        }
        .clipShape(shape)
        .webPanelEdgeShadow(palette.appearance)
        .contentShape(shape)
        .onTapGesture(perform: onTap)
        .accessibilityElement()
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Back to Page")
        .accessibilityAction { onTap() }
        .accessibilityIdentifier("openarc.library.pagePeek")
    }
}

// MARK: - Rail

/// Icon rail: the six sections, the selected one on a gray rounded block; "←" at the bottom left
/// goes back, a gift icon sits at the bottom right. [06 §8] observed.
struct LibraryRail: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var library: LibraryModel
    let palette: ThemePalette
    /// Top of the first button (`LibraryLayout.railItemsTop`).
    var itemsTop: CGFloat = LibraryLocalTokens.topInset
    @Environment(\.windowSurface) private var surface

    /// Selected section block (`LibraryLocalTokens.railSelectedFill`).
    private var railSelectedFill: RGBAColor {
        LibraryLocalTokens.railSelectedFill(palette: palette, translucent: surface.isTranslucent)
    }

    var body: some View {
        let text = palette.primaryText.swiftUI
        VStack(spacing: LibraryLocalTokens.railItemSpacing) {
            ForEach(LibrarySection.allCases) { section in
                item(section, text: text)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                Button { model.exitLibrary() } label: {
                    Image(systemName: "arrow.left")
                        .font(.system(size: LibraryLocalTokens.railFooterIconSize, weight: .semibold))
                        .foregroundStyle(text.opacity(LibraryLocalTokens.railUnselectedInkOpacity))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("openarc.library.back")
                Spacer(minLength: 0)
                // Gift (sharing the app) is out of scope: shown, no action.
                Image(systemName: "gift")
                    .font(.system(size: LibraryLocalTokens.railFooterIconSize))
                    .foregroundStyle(text.opacity(LibraryLocalTokens.railUnselectedInkOpacity))
                    .accessibilityLabel("Gift")
            }
            .padding(.horizontal, LibraryLocalTokens.railFooterPadding)
            .padding(.bottom, LibraryLocalTokens.railFooterBottomPadding)
        }
        .padding(.top, itemsTop)
        // The buttons sit in the middle of the rail, 8 pt from both edges (B225, Arc observed);
        // the footer row spans the rail.
        .frame(width: LibraryLocalTokens.railWidth)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.rail")
    }

    private func item(_ section: LibrarySection, text: Color) -> some View {
        let isSelected = library.section == section
        let t = LibraryLocalTokens.self
        // Icon centered 31.5 pt and label 56 pt below the button's top; the selected button in
        // full ink, the others dimmed. B225 observed (user's Arc screenshot).
        return VStack(spacing: t.railLabelCenterY - t.railIconCenterY - t.railIconBoxHeight / 2 - t.railLabelBoxHeight / 2) {
            Image(systemName: section.symbolName)
                .font(.system(size: t.railIconSize))
                .frame(height: t.railIconBoxHeight)
            Text(section.title)
                .font(Typography.libraryRailLabel.font)
                .lineLimit(1)
                .frame(height: t.railLabelBoxHeight)
        }
        .padding(.top, t.railIconCenterY - t.railIconBoxHeight / 2)
        .foregroundStyle(isSelected ? text : text.opacity(t.railUnselectedInkOpacity))
        .frame(width: t.railItemSize.width, height: t.railItemSize.height, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: LibraryLocalTokens.railItemCornerRadius, style: .continuous)
                .fill(isSelected ? railSelectedFill.swiftUI : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { library.open(section) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("openarc.library.rail.\(section.rawValue)")
    }
}

// MARK: - List column

/// The list column (≈ 304 pt, [07 §6]): search field (+ Filter), then the section's list or empty state. [06 §8] observed.
struct LibraryListColumn: View {
    @ObservedObject var library: LibraryModel
    let section: LibrarySection
    let palette: ThemePalette
    @Environment(\.windowSurface) private var surface

    var body: some View {
        let text = palette.primaryText.swiftUI
        VStack(alignment: .leading, spacing: LibraryLocalTokens.listHeaderGapAboveFirst) {
            if section.hasFilterButton, library.isFilterPanelOpen, let title = LibraryFilter.title(for: section) {
                LibraryFilterPanel(library: library, title: title, palette: palette)
            } else if let placeholder = section.searchPlaceholder {
                searchRow(placeholder, text: text)
            }
            content(text: text)
            Spacer(minLength: 0)
        }
        // Level with the page panel's top, as in Arc (B229 observed); the traffic lights stay in
        // the rail.
        .padding(.top, LibraryLocalTokens.listTop)
        .padding(.horizontal, LibraryLocalTokens.listHorizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.list.\(section.rawValue)")
    }

    /// The search field, with the Filter button on its right in Downloads and Archived Tabs (B229,
    /// Arc observed): both in the window color over the deeper area.
    private func searchRow(_ placeholder: String, text: Color) -> some View {
        let t = LibraryLocalTokens.self
        let fill = palette.windowBackground.swiftUI
        let shape = RoundedRectangle(cornerRadius: t.searchFieldCornerRadius, style: .continuous)
        return HStack(spacing: t.searchFilterGap) {
            ZStack(alignment: .leading) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: t.searchIconSize, weight: .medium))
                    .foregroundStyle(text.opacity(Typography.libraryListDetail.opacity))
                    .position(x: t.searchIconCenterX, y: t.searchFieldHeight / 2)
                TextField("", text: Binding(
                    get: { library.searchText[section] ?? "" },
                    set: { library.searchText[section] = $0 }
                ), prompt: Text(placeholder).foregroundColor(text.opacity(Typography.libraryListTitle.opacity)))
                .textFieldStyle(.plain)
                .font(Typography.librarySearch.font)
                .foregroundStyle(text)
                .padding(.leading, t.searchTextX)
                .padding(.trailing, 8)
                .accessibilityIdentifier("openarc.library.search")
            }
            .frame(maxWidth: .infinity)
            .frame(height: t.searchFieldHeight)
            .background(shape.fill(fill))
            if section.hasFilterButton {
                // Opens the Filter panel (B94). [06 §8] Filter, observed; beside the field, B229.
                Button { library.openFilterPanel() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: t.searchIconSize, weight: .medium))
                        Text(LibraryTexts.filterButton)
                            .font(Typography.librarySearch.font)
                    }
                    .foregroundStyle(text.opacity(Typography.libraryListTitle.opacity))
                    .padding(.horizontal, t.filterButtonPadding)
                    .frame(height: t.searchFieldHeight)
                    .background(shape.fill(fill))
                    .contentShape(shape)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityIdentifier("openarc.library.filter")
            }
        }
    }

    @ViewBuilder
    private func content(text: Color) -> some View {
        switch section {
        case .archivedTabs:
            LibraryArchiveList(library: library, palette: palette)
        case .media:
            if library.isMediaIntroVisible {
                LibraryMediaIntroCard(library: library, palette: palette)
            } else {
                LibraryMediaList(library: library, media: library.media, palette: palette)
            }
        case .downloads:
            LibraryDownloadsList(library: library, downloads: library.downloads, palette: palette)
        case .easels:
            // B56: the Easels list (empty state included).
            LibraryEaselsList(library: library, palette: palette)
        case .boosts:
            if let empty = section.emptyState {
                LibraryEmptyStateView(state: empty, isBoosts: section == .boosts, palette: palette)
            }
        case .spaces:
            EmptyView()
        }
    }
}

/// Archived Tabs: date groups, each row favicon + title + gray URL; a click restores. [06 §8] observed.
struct LibraryArchiveList: View {
    @ObservedObject var library: LibraryModel
    let palette: ThemePalette

    var body: some View {
        let groups = library.archiveGroups
        if groups.isEmpty {
            Text(library.hasArchivedItems ? LibraryTexts.archiveNoMatches : LibraryTexts.archiveEmpty)
                .font(Typography.libraryEmptyDetail.font)
                .foregroundStyle(Typography.libraryEmptyDetail.color(palette.chromeInk))
                .frame(maxWidth: .infinity)
                .padding(.top, 24)
                .accessibilityIdentifier("openarc.library.archive.empty")
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.group) { group in
                        LibraryListHeader(title: group.group.title, palette: palette)
                        ForEach(group.items, id: \.id) { item in
                            LibraryArchiveRow(item: item, iconData: library.faviconImage(for: item), palette: palette) {
                                library.restore(item.id)
                            }
                            // Row menu: ours (inferred), the spec records only the click.
                            .contextMenu {
                                Button("Restore Tab") { library.restore(item.id) }
                                if let url = item.url {
                                    Button("Copy Link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                }
                                Divider()
                                Button("Delete from Archive") { library.deleteArchived(item.id) }
                            }
                        }
                    }
                }
            }
            .accessibilityIdentifier("openarc.library.archive")
        }
    }
}

/// A date header of the Downloads and Archived Tabs lists: "2 days ago", 27 pt tall. B229 observed.
struct LibraryListHeader: View {
    let title: String
    let palette: ThemePalette

    var body: some View {
        Text(title)
            .font(Typography.libraryListHeader.font)
            .foregroundStyle(palette.primaryText.swiftUI.opacity(Typography.libraryListHeader.opacity))
            .lineLimit(1)
            .padding(.leading, LibraryLocalTokens.listHeaderLeading)
            .frame(maxWidth: .infinity, minHeight: LibraryLocalTokens.listHeaderHeight, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A Downloads or Archived Tabs row: icon centered 28.5 pt from the column's left, title and a
/// gray second line from 51.5 pt, 56 pt tall. B229 observed (user's Arc screenshots).
struct LibraryListRowLayout<Icon: View, Accessory: View>: View {
    let title: String
    let detail: String
    let palette: ThemePalette
    @ViewBuilder let icon: () -> Icon
    /// Controls at the row's end (a running download's buttons); the text gives them room.
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let t = LibraryLocalTokens.self
        let ink = palette.primaryText.swiftUI
        HStack(spacing: t.listIconTitleGap) {
            icon().frame(width: t.listIconColumnWidth)
            VStack(alignment: .leading, spacing: t.listTitleDetailSpacing) {
                Text(title)
                    .font(Typography.libraryListTitle.font)
                    .foregroundStyle(ink.opacity(Typography.libraryListTitle.opacity))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !detail.isEmpty {
                    Text(detail)
                        .font(Typography.libraryListDetail.font)
                        .foregroundStyle(ink.opacity(Typography.libraryListDetail.opacity))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            accessory()
        }
        .frame(height: t.listRowHeight)
    }
}

extension LibraryListRowLayout where Accessory == EmptyView {
    init(title: String, detail: String, palette: ThemePalette, @ViewBuilder icon: @escaping () -> Icon) {
        self.init(title: title, detail: detail, palette: palette, icon: icon, accessory: { EmptyView() })
    }
}

struct LibraryArchiveRow: View {
    let item: ArchiveItem
    /// Cached favicon of the archived page (C9); nil draws the globe.
    var iconData: Data?
    let palette: ThemePalette
    let onRestore: () -> Void

    @State private var isHovering = false

    var body: some View {
        LibraryListRowLayout(title: item.title.isEmpty ? "Untitled" : item.title,
                             detail: LibraryArchive.displayURL(item.url), palette: palette) {
            SidebarFaviconView(pngData: iconData, size: LibraryLocalTokens.archiveRowIconSize,
                               tint: palette.primaryText.swiftUI.opacity(0.7))
        }
        .background(
            RoundedRectangle(cornerRadius: CGFloat(Metrics.Sidebar.selectedRowCornerRadius), style: .continuous)
                .fill(isHovering ? Color.black.opacity(SidebarLocalTokens.rowHoverBlackOpacity) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onRestore)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("openarc.library.archive.\(item.id.uuidString)")
    }
}

/// Media first-visit card. [06 §8] observed texts; our app name replaces the product name.
struct LibraryMediaIntroCard: View {
    @ObservedObject var library: LibraryModel
    let palette: ThemePalette

    var body: some View {
        let text = RGBAColor(hex: SidebarLocalTokens.cardTextRGB).swiftUI
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(LibraryTexts.mediaIntroTitle).font(Typography.panelRowTitle.font.weight(.semibold))
                Spacer(minLength: 4)
                Button { library.dismissMediaIntro() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .accessibilityIdentifier("openarc.library.media.close")
            }
            Text(LibraryTexts.mediaIntroDetail).font(Typography.panelRowDetail.font)
            Button(LibraryTexts.mediaIntroButton) { library.dismissMediaIntro() }
                .controlSize(.small)
            Text(LibraryTexts.mediaPrivacyNote)
                .font(Typography.panelRowDetail.font)
                .foregroundStyle(text.opacity(0.6))
        }
        .foregroundStyle(text)
        .fixedSize(horizontal: false, vertical: true)
        .padding(LibraryLocalTokens.mediaCardPadding)
        .background(RoundedRectangle(cornerRadius: LibraryLocalTokens.mediaCardCornerRadius).fill(Color.white))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.media.intro")
    }
}

/// Icon + title + detail of an empty section. [06 §8] observed texts.
struct LibraryEmptyStateView: View {
    let state: LibraryEmptyState
    let isBoosts: Bool
    let palette: ThemePalette

    var body: some View {
        let text = palette.primaryText.swiftUI
        VStack(spacing: 6) {
            if let symbol = state.symbolName {
                Image(systemName: symbol)
                    .font(.system(size: LibraryLocalTokens.emptyStateIconSize))
                    .foregroundStyle(text.opacity(0.6))
            }
            Text(state.title)
                .font(Typography.libraryEmptyTitle.font)
                .foregroundStyle(text)
            detail
                .font(Typography.libraryEmptyDetail.font)
                .foregroundStyle(Typography.libraryEmptyDetail.color(palette.chromeInk))
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("openarc.library.empty")
    }

    /// The Boosts detail has a brush icon inline and "Boost Gallery" drawn as a link (no action:
    /// there is no gallery). [06 §8] observed.
    private var detail: Text {
        guard isBoosts else { return Text(state.detail) }
        return Text(LibraryTexts.boostsDetailPrefix)
            + Text(Image(systemName: "paintbrush"))
            + Text(LibraryTexts.boostsDetailMiddle)
            + Text(LibraryTexts.boostsGalleryLink).underline().foregroundColor(palette.commandBarSelection.swiftUI)
            + Text(LibraryTexts.boostsDetailSuffix)
    }
}
