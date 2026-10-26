import SwiftUI
import AppKit
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcDesign

// Library ▸ Spaces = Manage Spaces. [06 §8] observed: all spaces side by side as columns on a
// horizontal board; each column is the space's theme color, with a header (space icon, name,
// brush at the top right to edit the theme), the space's folders and tabs in the sidebar style,
// and at the bottom a drag handle (left) and a "…" menu (right). The row scrolls horizontally.

/// Drag payload of a board column. The type is ours and only readable in this process; the id
/// itself travels in `LibraryModel.draggingSpaceID`.
enum LibraryBoardDragPayload {
    /// `<bundle id>.library-space`, exported per build like `SidebarDragPayload.itemType`.
    static let columnType = UTType(exportedAs: "\(AppIdentity.bundleIdentifier).library-space", conformingTo: .data)

    static func makeProvider(spaceID: UUID) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(spaceID.uuidString.utf8)
        provider.registerDataRepresentation(for: columnType, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

struct LibrarySpacesBoard: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    @ObservedObject var library: LibraryModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: LibraryLocalTokens.boardColumnSpacing) {
                ForEach(library.boardColumns) { column in
                    LibraryBoardColumnView(model: model, sidebar: sidebar, library: library, column: column)
                        .frame(width: LibraryLocalTokens.boardColumnWidth)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.spacesBoard")
    }
}

struct LibraryBoardColumnView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    @ObservedObject var library: LibraryModel
    let column: LibraryBoardColumn

    var body: some View {
        let palette = column.palette
        let text = palette.primaryText.swiftUI
        VStack(spacing: 0) {
            header(text: text)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SidebarLayout().rowSpacing) {
                    ForEach(column.pinned) { LibraryBoardRow(item: $0, palette: palette) }
                    if !column.pinned.isEmpty || !column.today.isEmpty {
                        Rectangle().fill(text.opacity(0.15)).frame(height: SidebarLocalTokens.separatorThickness)
                    }
                    ForEach(column.today) { LibraryBoardRow(item: $0, palette: palette) }
                }
                .padding(.horizontal, CGFloat(Metrics.Sidebar.addressFieldHorizontalInset))
            }
            .frame(maxHeight: .infinity)
            footer(text: text)
        }
        .background(
            RoundedRectangle(cornerRadius: LibraryLocalTokens.boardColumnCornerRadius, style: .continuous)
                .fill(palette.windowBackground.swiftUI)
        )
        .opacity(library.draggingSpaceID == column.id ? SidebarLocalTokens.draggedRowOpacity : 1)
        .onDrop(of: [LibraryBoardDragPayload.columnType], delegate: LibraryBoardDropDelegate(library: library, target: column.id))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.space.\(column.id.uuidString)")
    }

    private func header(text: Color) -> some View {
        HStack(spacing: 6) {
            SidebarSpaceIconView(icon: column.space.icon, size: LibraryLocalTokens.boardIconSize, tint: text)
            Text(column.space.name)
                .font(Typography.spaceName.font)
                .foregroundStyle(text)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button { model.spaceFlow.beginEditTheme(spaceID: column.id) } label: {
                Image(systemName: "paintbrush").foregroundStyle(text.opacity(0.8)).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit Theme")
            .accessibilityIdentifier("openarc.library.space.editTheme")
        }
        .padding(.horizontal, 12)
        .frame(height: LibraryLocalTokens.boardHeaderHeight)
    }

    private func footer(text: Color) -> some View {
        HStack {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .foregroundStyle(text.opacity(0.7))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .onDrag {
                    library.draggingSpaceID = column.id
                    return LibraryBoardDragPayload.makeProvider(spaceID: column.id)
                }
                .accessibilityLabel("Reorder Space")
                .accessibilityIdentifier("openarc.library.space.dragHandle")
            Spacer()
            Menu {
                Button("Rename Space") { model.spaceFlow.beginRename(spaceID: column.id) }
                Button("Change Space Icon…") { model.spaceFlow.beginChangeIcon(spaceID: column.id) }
                Button("Edit Theme…") { model.spaceFlow.beginEditTheme(spaceID: column.id) }
                Divider()
                Button("Delete Space", role: .destructive) { sidebar.requestDeleteSpace(column.id) }
                    .disabled(!sidebar.canDeleteSpace)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(text.opacity(0.8))
            .accessibilityIdentifier("openarc.library.space.menu")
        }
        .padding(.horizontal, 10)
        .frame(height: LibraryLocalTokens.boardFooterHeight)
    }
}

/// Drop of a dragged column on another column: left half = before, right half = after. inferred.
struct LibraryBoardDropDelegate: DropDelegate {
    let library: LibraryModel
    let target: UUID

    func validateDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { library.draggingSpaceID != nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        let x = info.location.x
        return MainActor.assumeIsolated {
            library.dropDraggedSpace(on: target, locationX: x, columnWidth: LibraryLocalTokens.boardColumnWidth)
        }
    }
}

/// A read-only row of a board column, drawn like a sidebar row (same height, icon and title
/// offsets, fonts; folders bold). [06 §8] observed "same style as the sidebar".
struct LibraryBoardRow: View {
    let item: SidebarItemModel
    let palette: ThemePalette

    private let layout = SidebarLayout()

    var body: some View {
        let text = palette.primaryText.swiftUI
        let iconSize = SidebarLocalTokens.rowIconSize
        HStack(spacing: layout.rowTitleLeading - layout.rowIconLeading - iconSize) {
            icon(text: text).frame(width: iconSize, height: iconSize)
            Text(title)
                .font((isFolder ? Typography.folderRowTitle : Typography.tabRowTitle).font)
                .foregroundStyle(text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.leading, layout.rowIconLeading + CGFloat(item.depth) * SidebarLocalTokens.folderIndent)
        .frame(height: layout.rowHeight)
        .accessibilityElement(children: .combine)
    }

    private var isFolder: Bool {
        if case .folder = item.kind { return true }
        return false
    }

    private var title: String {
        switch item.kind {
        case .folder(let folder): return folder.title
        case .tab(let tab): return tab.displayTitle.isEmpty ? "New Tab" : tab.displayTitle
        case .splitGroup(let group): return group.members.map { $0.displayTitle.isEmpty ? "New Tab" : $0.displayTitle }.joined(separator: " | ")
        }
    }

    @ViewBuilder
    private func icon(text: Color) -> some View {
        switch item.kind {
        case .folder(let folder):
            Image(systemName: folder.isExpanded ? "folder" : "folder.fill")
                .resizable().scaledToFit().foregroundStyle(text.opacity(0.8))
        case .tab, .splitGroup:
            SidebarFaviconView(live: nil, size: SidebarLocalTokens.rowIconSize, tint: text.opacity(0.7))
        }
    }
}
