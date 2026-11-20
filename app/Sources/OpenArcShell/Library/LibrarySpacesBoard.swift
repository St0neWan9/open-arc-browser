import SwiftUI
import AppKit
import OpenArcModel
import OpenArcDesign

// Library ▸ Spaces = Manage Spaces. [06 §8] observed: all spaces side by side as columns on a
// horizontal board; each column is the space's theme color, with a header (space icon, name,
// brush at the top right to edit the theme), the space's folders and tabs in the sidebar style,
// and at the bottom a drag handle (left) and a "…" menu (right). The row scrolls horizontally.

/// A column being moved by its drag handle: which one, and how far the pointer went (B228).
struct LibraryBoardDrag: Equatable {
    var id: UUID
    /// Pointer travel since the press.
    var translation: CGFloat
    /// Where the pointer is, in window coordinates (for scrolling at the board's edges).
    var pointerX: CGFloat = 0
    /// How far the board scrolled since the press (B232): the column moves with the content, so
    /// this adds to the pointer's travel.
    var scrolled: CGFloat = 0

    /// The column's travel along the board.
    var travel: CGFloat { translation + scrolled }
}

/// Scrolls the board's AppKit scroll view while a column is held near an edge (B232). The board is a
/// SwiftUI ScrollView; macOS 14 has no offset-based scroll position, so this reaches the
/// NSScrollView under it.
@MainActor
final class LibraryBoardScroller {
    weak var scrollView: NSScrollView?

    /// Scrolls by `delta` points (clamped to the content); returns how far it actually moved.
    func scroll(by delta: CGFloat) -> CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView
        let maxX = max(0, document.frame.width - clip.bounds.width)
        let old = clip.bounds.origin.x
        let new = min(max(old + delta, 0), maxX)
        guard new != old else { return 0 }
        clip.scroll(to: NSPoint(x: new, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
        return new - old
    }
}

/// Finds the NSScrollView that hosts it.
private struct LibraryBoardScrollViewProbe: NSViewRepresentable {
    let scroller: LibraryBoardScroller

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            MainActor.assumeIsolated { if let found = nsView?.enclosingScrollView { scroller.scrollView = found } }
        }
    }
}

struct LibrarySpacesBoard: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    @ObservedObject var library: LibraryModel

    /// The column following the pointer while its handle is dragged; nil otherwise.
    @State private var drag: LibraryBoardDrag?
    @State private var scroller = LibraryBoardScroller()
    /// The board's visible frame in window coordinates.
    @State private var visibleFrame: CGRect = .zero
    @State private var edgeScroll: Task<Void, Never>?

    var body: some View {
        let t = LibraryLocalTokens.self
        let columns = library.boardColumns
        let pitch = t.boardColumnWidth + t.boardColumnSpacing
        let from = drag.flatMap { d in columns.firstIndex { $0.id == d.id } }
        let travel = drag?.travel ?? 0
        let to = from.map { LibraryBoard.reorderIndex(from: $0, translation: travel, pitch: pitch, count: columns.count) }
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: t.boardColumnSpacing) {
                ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                    let isLifted = drag?.id == column.id
                    LibraryBoardColumnView(model: model, sidebar: sidebar, library: library, column: column, isLifted: isLifted,
                                           onHandleDrag: { translation, pointerX in
                                               var next = drag?.id == column.id ? drag! : LibraryBoardDrag(id: column.id, translation: 0)
                                               next.translation = translation
                                               next.pointerX = pointerX
                                               drag = next
                                               startEdgeScrollIfNeeded()
                                           },
                                           onHandleDrop: { _ in drop(column.id, columns: columns, pitch: pitch) })
                        .frame(width: t.boardColumnWidth)
                        // The dragged column follows the pointer; the ones it passes make room.
                        .offset(x: from.flatMap { f in to.map { LibraryBoard.dragOffset(index: index, from: f, to: $0, translation: travel, pitch: pitch) } } ?? 0)
                        .animation(isLifted ? nil : ShellMotion.favoriteMakeRoom, value: to)
                        .zIndex(isLifted ? 1 : 0)
                }
            }
            .padding(.leading, t.boardLeading)
            // The last column can scroll clear of the page panel at the right edge (B227).
            .padding(.trailing, t.boardLeading + t.pagePeekVisibleWidth)
            .padding(.top, t.boardTop)
            .padding(.bottom, t.boardBottom)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(LibraryBoardScrollViewProbe(scroller: scroller))
        }
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { visibleFrame = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in visibleFrame = frame }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.library.spacesBoard")
    }

    /// While the pointer holds a column near the board's left or right edge, the board scrolls
    /// that way, faster the closer it gets (B232, user 2026-11-15; speeds inferred). The page
    /// panel's strip at the right edge counts as outside.
    private func startEdgeScrollIfNeeded() {
        guard edgeScroll == nil else { return }
        edgeScroll = Task { @MainActor in
            while !Task.isCancelled, let current = drag {
                let right = visibleFrame.maxX - LibraryLocalTokens.pagePeekVisibleWidth
                let step = LibraryBoard.edgeScrollStep(pointerX: current.pointerX, minX: visibleFrame.minX, maxX: right)
                if step == 0 { break }
                let moved = scroller.scroll(by: step)
                if moved == 0 { break }
                drag?.scrolled += moved
                try? await Task.sleep(nanoseconds: 16_000_000)
            }
            edgeScroll = nil
        }
    }

    /// The handle was let go: the column takes the slot nearest the pointer and settles there.
    private func drop(_ id: UUID, columns: [LibraryBoardColumn], pitch: CGFloat) {
        edgeScroll?.cancel()
        edgeScroll = nil
        let travel = drag?.travel ?? 0
        guard let from = columns.firstIndex(where: { $0.id == id }) else { drag = nil; return }
        let to = LibraryBoard.reorderIndex(from: from, translation: travel, pitch: pitch, count: columns.count)
        withAnimation(ShellMotion.favoriteMakeRoom) {
            library.moveColumn(from: from, to: to)
            drag = nil
        }
    }
}

struct LibraryBoardColumnView: View {
    @ObservedObject var model: ShellModel
    @ObservedObject var sidebar: SidebarViewModel
    @ObservedObject var library: LibraryModel
    let column: LibraryBoardColumn
    /// Being dragged by its handle: lifted above the others with a deeper shadow (inferred).
    var isLifted = false
    /// The handle moved by this much (pointer travel along the board), the pointer at this x in
    /// window coordinates.
    var onHandleDrag: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// The handle was let go after moving this much.
    var onHandleDrop: (CGFloat) -> Void = { _ in }

    /// A tab row's favicon; split groups show their first member's. C9.
    private func iconData(_ item: SidebarItemModel) -> Data? {
        switch item.kind {
        case .tab(let tab): return library.faviconImage(forTab: tab.id)
        case .splitGroup(let group): return group.members.first.flatMap { library.faviconImage(forTab: $0.id) }
        case .folder: return nil
        }
    }

    var body: some View {
        let palette = column.palette
        let text = palette.primaryText.swiftUI
        VStack(spacing: 0) {
            header(text: text)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: SidebarLayout().rowSpacing) {
                    ForEach(column.pinned) { LibraryBoardRow(item: $0, palette: palette, iconData: iconData($0)) }
                    if !column.pinned.isEmpty || !column.today.isEmpty {
                        Rectangle().fill(text.opacity(0.15)).frame(height: SidebarLocalTokens.separatorThickness)
                    }
                    ForEach(column.today) { LibraryBoardRow(item: $0, palette: palette, iconData: iconData($0)) }
                }
                .padding(.horizontal, CGFloat(Metrics.Sidebar.addressFieldHorizontalInset))
            }
            .frame(maxHeight: .infinity)
            footer(text: text)
        }
        .background(
            // Each column in its own Space's theme, laid over the board like a window of that
            // Space (B224, user 2026-11-15; Arc observed).
            RoundedRectangle(cornerRadius: LibraryLocalTokens.boardColumnCornerRadius, style: .continuous)
                .fill(LibraryLocalTokens.boardColumnFill(for: palette).swiftUI)
                .shadow(color: .black.opacity(isLifted ? LibraryLocalTokens.boardColumnLiftedShadowOpacity
                                                       : LibraryLocalTokens.boardColumnShadowOpacity),
                        radius: isLifted ? LibraryLocalTokens.boardColumnLiftedShadowRadius : LibraryLocalTokens.boardColumnShadowRadius,
                        y: isLifted ? LibraryLocalTokens.boardColumnLiftedShadowRadius / 2 : 0)
        )
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
                .frame(width: LibraryLocalTokens.boardHandleSize, height: LibraryLocalTokens.boardHandleSize)
                .contentShape(Rectangle())
                // Press and drag: the column follows the pointer, a plain mouse drag (B228; the
                // system drag and drop only moved a small icon and needed a drop on a column).
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { onHandleDrag($0.translation.width, $0.location.x) }
                        .onEnded { onHandleDrop($0.translation.width) }
                )
                .onHover { inside in
                    if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
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

/// A read-only row of a board column, drawn like a sidebar row (same height, icon and title
/// offsets, fonts; folders bold). [06 §8] observed "same style as the sidebar".
struct LibraryBoardRow: View {
    let item: SidebarItemModel
    let palette: ThemePalette
    /// The tab's favicon (C9); nil draws the globe.
    var iconData: Data?

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
            SidebarFaviconView(pngData: iconData, size: SidebarLocalTokens.rowIconSize, tint: text.opacity(0.7))
        }
    }
}
