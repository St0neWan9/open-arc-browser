import SwiftUI
import OpenArcModel
import OpenArcDesign

// The drag image's content and look. [06 §15.1, §15.4, §15.5]; [04 §拖动图像(E17)];
// design-tokens.json `Metrics.SidebarDrag`.

/// What the drag image shows for the dragged item.
struct SidebarDragImageContent: Equatable {
    enum Icon: Equatable {
        /// A site icon (PNG data; nil shows the placeholder square).
        case favicon(Data?)
        /// A folder glyph.
        case folder
    }

    enum Accessory: Equatable {
        case none
        /// ✕ of a Today row. [06 §15.1] observed on the lifted row.
        case close
        /// — of a pinned row. inferred (the source row's own accessory; Arc showed ✕ on the rows it
        /// lifted).
        case unload
    }

    var title: String
    var icon: Icon
    var accessory: Accessory
}

extension SidebarViewModel {
    /// The drag image content of `item`: its icon, title and the row's trailing button.
    func dragImageContent(for item: SidebarDragItem) -> SidebarDragImageContent {
        let title = dragTitle(for: item)
        switch item {
        case .tab(let id):
            let accessory: SidebarDragImageContent.Accessory
            switch workspace.tabs[id]?.location {
            case .today?: accessory = .close
            case .pinned?: accessory = .unload
            case .favorite?, nil: accessory = .none
            }
            return SidebarDragImageContent(title: title.isEmpty ? "New Tab" : title,
                                           icon: .favicon(faviconImage(for: id)), accessory: accessory)
        case .folder:
            return SidebarDragImageContent(title: title, icon: .folder, accessory: .none)
        case .splitGroup:
            let group = snapshot.splitGroup(layoutID: item.id)
            let first = group?.members.first
            let accessory: SidebarDragImageContent.Accessory = first.map {
                if case .pinned = $0.location { return .unload } else { return .close }
            } ?? .none
            return SidebarDragImageContent(title: title, icon: .favicon(first.flatMap { faviconImage(for: $0.id) }),
                                           accessory: accessory)
        }
    }
}

/// Colors of the drag image for one theme.
struct SidebarDragImageStyle: Equatable {
    /// Row and pill fill: the theme's selected-row fill. [06 §15.1] observed (lavender #F4F5FA,
    /// pink light #F9EBF0, navy dark #9293AA).
    var rowFill: RGBAColor
    /// Text on the row and the pill: the selected row's text color. [07 §8] observed.
    var text: RGBAColor
    /// Favorite-tile fill: translucent white over the favorites block, so it reads near white /
    /// light gray whatever the theme. [06 §15.5] observed samples.
    var tileFill: RGBAColor
    /// Shadow opacity: visible on light themes, faint on dark ones. [06 §15.1] observed.
    var shadowOpacity: Double

    init(palette: ThemePalette) {
        let d = Metrics.SidebarDrag.self
        rowFill = palette.selectedTabFill
        text = palette.selectedTabText
        tileFill = RGBAColor(red: 1, green: 1, blue: 1,
                             alpha: palette.isDark ? d.favoriteTileWhiteOpacityDark : d.favoriteTileWhiteOpacity)
        shadowOpacity = palette.isDark ? d.shadowOpacityDark : d.shadowOpacityLight
    }
}

/// The drag image in one shape, with room for its shadow around it (`Metrics.SidebarDrag.shadowMargin`).
struct SidebarDragImageView: View {
    let shape: SidebarDragImageShape
    let content: SidebarDragImageContent
    let style: SidebarDragImageStyle

    var body: some View {
        let d = Metrics.SidebarDrag.self
        let size = shape.size
        image
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(style.shadowOpacity), radius: CGFloat(d.shadowRadius), x: 0, y: CGFloat(d.shadowOffsetY))
            .padding(CGFloat(d.shadowMargin))
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var image: some View {
        let d = Metrics.SidebarDrag.self
        switch shape {
        case .row:
            // The lifted row: selected fill, icon at the row's icon position, title, accessory;
            // ≈ 0.85 opaque as a whole. [06 §15.1] observed / inferred (opacity, radius).
            HStack(spacing: 0) {
                icon(size: SidebarLocalTokens.rowIconSize)
                    .padding(.trailing, SidebarLayout().rowTitleGap)
                title(size: CGFloat(Typography.tabRowTitle.size))
                Spacer(minLength: 4)
                accessory(glyph: SidebarLocalTokens.rowAccessoryGlyphSize, box: SidebarLocalTokens.rowAccessoryButtonSize)
            }
            .padding(.leading, SidebarLayout().rowIconLeading - CGFloat(Metrics.Sidebar.selectedRowHorizontalInset) - 1)
            .padding(.trailing, SidebarLocalTokens.rowAccessoryTrailingPadding - 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: CGFloat(d.rowImageCornerRadius), style: .continuous).fill(style.rowFill.swiftUI))
            .compositingGroup()
            .opacity(d.rowImageOpacity)
        case .pill:
            // Compact pill: icon + smaller title + accessory, near white, translucent. [06 §15.4] observed.
            HStack(spacing: 0) {
                icon(size: CGFloat(d.pillIconSize))
                    .padding(.trailing, CGFloat(d.pillTitleGap))
                title(size: CGFloat(d.pillTitleSize))
                Spacer(minLength: 2)
                accessory(glyph: CGFloat(d.pillAccessorySize), box: CGFloat(d.pillIconSize))
            }
            .padding(.leading, CGFloat(d.pillIconLeading))
            .padding(.trailing, CGFloat(d.pillTrailing))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: CGFloat(d.pillCornerRadius), style: .continuous).fill(style.rowFill.swiftUI))
            .compositingGroup()
            .opacity(d.rowImageOpacity)
        case .favoriteTile:
            // Favorite tile: near-white translucent block with only the centered icon (blank when the
            // tab has no icon). [06 §15.5] observed.
            // A clear base keeps the block when there is no icon (modifiers on an empty view draw nothing).
            Color.clear
                .overlay { tileIcon }
                .background(RoundedRectangle(cornerRadius: CGFloat(d.favoriteTileCornerRadius), style: .continuous).fill(style.tileFill.swiftUI))
        }
    }

    @ViewBuilder
    private var tileIcon: some View {
        if case .favicon(let data) = content.icon, let image = SidebarFaviconView.image(data) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: SidebarLocalTokens.favoriteIconSize, height: SidebarLocalTokens.favoriteIconSize)
        }
    }

    @ViewBuilder
    private func icon(size: CGFloat) -> some View {
        let ink = style.text.swiftUI
        switch content.icon {
        case .favicon(let data):
            SidebarFaviconView(pngData: data, size: size,
                               tint: ink.opacity(ChromeInkOpacities.darkInk.faviconPlaceholder), placeholder: .roundedSquare)
                .frame(width: size, height: size)
        case .folder:
            Image(systemName: "folder.fill")
                .font(.system(size: size * 0.9, weight: .regular))
                .foregroundStyle(ink.opacity(0.8))
                .frame(width: size, height: size)
        }
    }

    private func title(size: CGFloat) -> some View {
        Text(content.title)
            .font(.system(size: size, weight: content.icon == .folder ? .semibold : .regular))
            .foregroundStyle(style.text.swiftUI)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    private func accessory(glyph: CGFloat, box: CGFloat) -> some View {
        switch content.accessory {
        case .none:
            EmptyView()
        case .close, .unload:
            Image(systemName: content.accessory == .close ? "xmark" : "minus")
                .font(.system(size: glyph, weight: SidebarLocalTokens.rowAccessoryGlyphWeight))
                .foregroundStyle(style.text.swiftUI.opacity(SidebarLocalTokens.rowAccessoryInkOpacity))
                .frame(width: box, height: box)
        }
    }
}
