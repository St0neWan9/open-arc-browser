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
            LibraryRail(model: model, library: library, palette: palette)
                .frame(width: layout.railFrame.width, height: layout.railFrame.height)

            if section == .spaces {
                LibrarySpacesBoard(model: model, sidebar: sidebar, library: library)
                    .frame(width: layout.boardFrame.width, height: layout.boardFrame.height)
                    .offset(x: layout.boardFrame.minX, y: layout.boardFrame.minY)
            } else {
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

// MARK: - Rail

/// Icon rail: the six sections, the selected one on a gray rounded block; "←" at the bottom left
/// goes back, a gift icon sits at the bottom right. [06 §8] observed.
struct LibraryRail: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var library: LibraryModel
    let palette: ThemePalette
    @Environment(\.windowSurface) private var surface

    /// Selected section block: window × 0.90; on a see-through window the same as a 10 % black
    /// layer (B64, [07 §8.4]).
    private var railSelectedFill: RGBAColor {
        surface.isTranslucent ? RGBAColor(hex: 0x000000, alpha: 1 - LibraryLocalTokens.railSelectedShade)
            : ThemeDerivation.shade(palette.windowBackground, by: LibraryLocalTokens.railSelectedShade)
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
                        .foregroundStyle(text.opacity(0.8))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("openarc.library.back")
                Spacer(minLength: 0)
                // Gift (sharing the app) is out of scope: shown, no action.
                Image(systemName: "gift")
                    .font(.system(size: LibraryLocalTokens.railFooterIconSize))
                    .foregroundStyle(text.opacity(0.6))
                    .accessibilityLabel("Gift")
            }
            .padding(.horizontal, LibraryLocalTokens.railFooterPadding)
            .padding(.bottom, LibraryLocalTokens.railFooterPadding)
        }
        .padding(.top, LibraryLocalTokens.topInset)
        .padding(.leading, CGFloat(Metrics.Library.railButtonLeading))
        .frame(width: LibraryLocalTokens.railWidth, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.rail")
    }

    private func item(_ section: LibrarySection, text: Color) -> some View {
        let isSelected = library.section == section
        return VStack(spacing: 6) {
            Image(systemName: section.symbolName)
                .font(.system(size: LibraryLocalTokens.railIconSize))
            Text(section.title)
                .font(Typography.libraryRailLabel.font)
                .lineLimit(1)
        }
        .foregroundStyle(text)
        .frame(width: LibraryLocalTokens.railItemSize.width, height: LibraryLocalTokens.railItemSize.height)
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
        VStack(alignment: .leading, spacing: 8) {
            if section.hasFilterButton, library.isFilterPanelOpen, let title = LibraryFilter.title(for: section) {
                LibraryFilterPanel(library: library, title: title, palette: palette)
            } else if let placeholder = section.searchPlaceholder {
                searchRow(placeholder, text: text)
            }
            content(text: text)
            Spacer(minLength: 0)
        }
        .padding(.top, LibraryLocalTokens.topInset)
        .padding(.horizontal, LibraryLocalTokens.listHorizontalPadding)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.list.\(section.rawValue)")
    }

    private func searchRow(_ placeholder: String, text: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(placeholder, text: Binding(
                get: { library.searchText[section] ?? "" },
                set: { library.searchText[section] = $0 }
            ))
            .textFieldStyle(.plain)
            .font(Typography.librarySearch.font)
            .padding(.horizontal, 12)
            .frame(height: LibraryLocalTokens.searchFieldHeight)
            .background(
                RoundedRectangle(cornerRadius: LibraryLocalTokens.searchFieldCornerRadius)
                    .fill(palette.windowFills(on: surface).controlFill.swiftUI)
            )
            .accessibilityIdentifier("openarc.library.search")
            if section.hasFilterButton {
                // Opens the Filter panel (B94). [06 §8] Filter, observed.
                Button(LibraryTexts.filterButton) { library.openFilterPanel() }
                    .buttonStyle(.plain)
                    .font(Typography.libraryRowDetail.font)
                    .foregroundStyle(text.opacity(0.8))
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
        let text = palette.primaryText.swiftUI
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(library.archiveGroups, id: \.group) { group in
                    Text(group.group.title)
                        .textStyle(Typography.libraryGroupHeader, ink: palette.chromeInk)
                        .padding(.top, 6)
                    ForEach(group.items, id: \.id) { item in
                        LibraryArchiveRow(item: item, iconData: library.faviconImage(for: item), textColor: text, secondary: palette.secondaryText.swiftUI) {
                            library.restore(item.id)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("openarc.library.archive")
    }
}

struct LibraryArchiveRow: View {
    let item: ArchiveItem
    /// Cached favicon of the archived page (C9); nil draws the globe.
    var iconData: Data?
    let textColor: Color
    let secondary: Color
    let onRestore: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            SidebarFaviconView(pngData: iconData, size: LibraryLocalTokens.archiveRowIconSize, tint: textColor.opacity(0.7))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(Typography.libraryRowTitle.font)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
                Text(LibraryArchive.displayURL(item.url))
                    .font(Typography.libraryRowDetail.font)
                    .foregroundStyle(secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .frame(height: LibraryLocalTokens.archiveRowHeight)
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
