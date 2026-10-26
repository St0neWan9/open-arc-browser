import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

/// The sidebar. Fixed width (`Metrics.Sidebar.width`), full window height. Every block sits at
/// its measured window position [07 §1, §2, §4] observed: toolbar buttons (y 7.5–39.5), URL box
/// (46–82), favorites (90–137), Space header (145–181), the scrolling list (181 to H − 50) and
/// the dock (H − 50 to H).
public struct SidebarView: View {
    @ObservedObject private var viewModel: SidebarViewModel
    @State private var isSidebarHovered = false
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var regions: [SidebarDropRegion: CGRect] = [:]
    /// The floating peek panel's deeper fill instead of the window color. [06 §14] B34.
    @Environment(\.sidebarFillOverride) private var fillOverride

    public init(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            content(layout: SidebarLayout(windowSize: CGSize(width: proxy.size.width, height: proxy.size.height)))
        }
        .frame(width: CGFloat(Metrics.Sidebar.width))
    }

    private func content(layout: SidebarLayout) -> some View {
        let palette = viewModel.palette
        let snapshot = viewModel.snapshot
        let url = layout.urlBoxFrame, favorites = layout.favoritesFrame
        let listHeight = max(0, layout.dockFrame.minY - layout.listTop)

        return ZStack(alignment: .topLeading) {
            (fillOverride ?? palette.windowBackground).swiftUI

            SidebarTopBarView(viewModel: viewModel, layout: layout)

            ZStack(alignment: .topLeading) {
                SidebarURLBoxView(viewModel: viewModel)
                    .frame(width: url.width, height: url.height)
                    .offset(x: url.minX, y: url.minY)

                // An incognito window has no favorites: the block keeps its place empty. inferred (B14).
                if !viewModel.isIncognito {
                    SidebarFavoritesView(viewModel: viewModel, favorites: snapshot.favorites, layout: layout)
                        .frame(width: favorites.width, height: favorites.height)
                        .offset(x: favorites.minX, y: favorites.minY)
                }

                SidebarSpaceNameRowView(viewModel: viewModel, layout: layout)

                SidebarListView(viewModel: viewModel, snapshot: snapshot, isSidebarHovered: isSidebarHovered, layout: layout)
                    .frame(width: layout.width, height: listHeight)
                    .offset(y: layout.listTop)

                // No Space dock in an incognito window (one in-memory Space). inferred (B14).
                if !viewModel.isIncognito {
                    SidebarDockView(viewModel: viewModel, layout: layout)
                        .frame(width: layout.width, height: layout.dockFrame.height)
                        .offset(y: layout.dockFrame.minY)
                }
            }
            .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
            .id(viewModel.selectedSpaceID)
            .transition(.opacity)

            hoverCard(layout: layout)
        }
        .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
        .coordinateSpace(name: SidebarCoordinateSpace.root)
        .onPreferenceChange(SidebarRowFramesKey.self) { rowFrames = $0 }
        .onPreferenceChange(SidebarDropRegionsKey.self) { regions = $0 }
        // Auto-scroll moves rows under a pointer that may not move: re-hit-test with the new frames
        // so the indicator stays on the row actually under the pointer. inferred (B20).
        .onChange(of: rowFrames) { viewModel.refreshDropTarget(in: dropGeometry(viewModel.snapshot, layout: layout)) }
        .onDrop(of: [SidebarDragPayload.itemType, .url], delegate: SidebarRootDropDelegate(viewModel: viewModel, geometry: dropGeometry(snapshot, layout: layout)))
        .onHover { isSidebarHovered = $0 }
        .animation(.easeInOut(duration: Motion.spaceCreateFade), value: viewModel.selectedSpaceID)
        .sheet(isPresented: $viewModel.isNewFolderSheetPresented) {
            SidebarNewFolderSheet(viewModel: viewModel)
        }
        .sheet(isPresented: deleteBinding) {
            DeleteSpaceSheet(spaceName: deleteSpaceName, palette: palette) {
                viewModel.cancelDeleteSpace()
            } onDelete: {
                viewModel.confirmDeleteSpace()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar")
    }

    private func dropGeometry(_ snapshot: SidebarSnapshot, layout: SidebarLayout) -> SidebarDropGeometry {
        SidebarDropGeometry.make(
            snapshot: snapshot,
            dockSpaceIDs: viewModel.dockSpaces.map(\.id),
            rowFrames: rowFrames,
            regions: regions,
            rowSpacing: layout.rowSpacing
        )
    }

    @ViewBuilder
    private func hoverCard(layout: SidebarLayout) -> some View {
        if let id = viewModel.hoverCardTabID, let row = rowFrames[id], let tab = viewModel.workspace.tabs[id] {
            let frame = SidebarHoverCardPlacement.frame(rowFrame: row, containerWidth: layout.width)
            SidebarHoverCardView(title: tab.displayTitle)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .transition(.opacity)
        }
    }

    private var deleteSpaceName: String {
        viewModel.pendingSpaceDeletionID.flatMap { viewModel.workspace.spaces[$0]?.name } ?? ""
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { viewModel.pendingSpaceDeletionID != nil },
            set: { if !$0 { viewModel.cancelDeleteSpace() } }
        )
    }
}

/// Scrolling list: pinned area (folders and tabs), the divider, "+ New Tab" right under it at the
/// top of Today, then the Today tabs. [07 §1, §4] observed (row pitch 41, a 3 pt spacer on top,
/// a 17 pt divider; B31 found New Tab directly below the divider). An empty Space shows only
/// "+ New Tab", without the divider. [06 §4] observed.
struct SidebarListView: View {
    @ObservedObject var viewModel: SidebarViewModel
    let snapshot: SidebarSnapshot
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    @State private var edges = SidebarScrollEdges()

    var body: some View {
        GeometryReader { viewport in
            list
                .onPreferenceChange(SidebarListContentFrameKey.self) { frame in
                    edges = SidebarScrollEdges(contentFrame: frame, viewportHeight: viewport.size.height)
                }
                .overlay(alignment: .top) { edgeLine(visible: edges.top) }
                .overlay(alignment: .bottom) { edgeLine(visible: edges.bottom) }
        }
    }

    /// Full-width 1 pt line at the list's top or bottom edge while rows are scrolled under it.
    /// Round-1 comparison (B32) observed: lines at y 181 and 934 across the sidebar, window + 5 %
    /// white on a light-ink window, in a scrolled list; shown only while scrolled (inferred).
    @ViewBuilder
    private func edgeLine(visible: Bool) -> some View {
        if visible {
            Rectangle()
                .fill(viewModel.palette.scrollEdgeLine.swiftUI)
                .frame(width: layout.width, height: SidebarLocalTokens.scrollEdgeLineThickness)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var list: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: layout.rowSpacing) {
                ForEach(snapshot.pinned) { item in row(item) }
                if snapshot.showsDivider {
                    SidebarDividerRowView(viewModel: viewModel, canClear: snapshot.canClear, isSidebarHovered: isSidebarHovered)
                }
                SidebarNewTabRowView(viewModel: viewModel, isEmptySpace: snapshot.isEmptySpace)
                ForEach(snapshot.today) { item in row(item) }
                // Empty area below the list: dropping here appends to Today (the root drop delegate
                // maps every point below the last row to the end of Today). Its height follows the
                // reference's scroller (B33, `SidebarLocalTokens.listTrailingSpace`).
                Color.clear.frame(height: SidebarLocalTokens.listTrailingSpace)
            }
            .padding(.top, CGFloat(Metrics.Sidebar.listTopSpacer))
            .frame(width: layout.width, alignment: .topLeading)
            .background(GeometryReader { content in
                Color.clear.preference(
                    key: SidebarListContentFrameKey.self,
                    value: content.frame(in: .named(SidebarListContentFrameKey.viewportSpace))
                )
            })
            // Gives the view model a handle on the backing scroll view for drag auto-scroll (B20).
            .background(SidebarListScrollProbe(viewModel: viewModel))
        }
        .scrollIndicators(.never)
        .coordinateSpace(name: SidebarListContentFrameKey.viewportSpace)
        .sidebarDropRegion(.list)
        .contentShape(Rectangle())
        .contextMenu { SidebarSpaceMenu(viewModel: viewModel) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.tabList")
    }

    @ViewBuilder
    private func row(_ item: SidebarItemModel) -> some View {
        switch item.kind {
        case .folder(let folder):
            SidebarFolderRowView(viewModel: viewModel, folder: folder, depth: item.depth)
        case .tab(let tab):
            SidebarTabRowView(viewModel: viewModel, tab: tab, depth: item.depth, area: item.area)
        case .splitGroup(let group):
            SidebarSplitGroupRowView(viewModel: viewModel, group: group, depth: item.depth, area: item.area)
        }
    }
}

/// Frame of the list content in the scroll viewport's coordinate space.
struct SidebarListContentFrameKey: PreferenceKey {
    static let viewportSpace = "openarc.sidebar.listViewport"
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// Which scroll-edge lines show: top while the content is scrolled up under the list's top,
/// bottom while content continues below the viewport. Pure, for tests.
struct SidebarScrollEdges: Equatable {
    var top = false
    var bottom = false

    init(top: Bool = false, bottom: Bool = false) {
        self.top = top
        self.bottom = bottom
    }

    /// Half a point of slack absorbs rounding of the scroll offset.
    init(contentFrame: CGRect, viewportHeight: CGFloat) {
        top = contentFrame.minY < -0.5
        bottom = contentFrame.maxY > viewportHeight + 0.5
    }
}

// MARK: - Scroll hook (drag auto-scroll)

/// Finds the `NSScrollView` behind the SwiftUI `ScrollView` and hands the view model a
/// `SidebarListScrolling` for it. `ScrollPosition` / `onScrollGeometryChange` would do this in
/// SwiftUI, but they need macOS 15 and the minimum is macOS 14.
private struct SidebarListScrollProbe: NSViewRepresentable {
    let viewModel: SidebarViewModel

    func makeCoordinator() -> SidebarNSScrollHook { SidebarNSScrollHook() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        let hook = context.coordinator
        view.onMoveToWindow = { [weak hook] probe in hook?.scrollView = probe.enclosingScrollView }
        viewModel.listScroller = hook
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        let hook = context.coordinator
        if hook.scrollView == nil { hook.scrollView = nsView.enclosingScrollView }
        // The list is rebuilt per Space (`.id`): the probe on screen is the one that counts.
        viewModel.listScroller = hook
    }

    final class ProbeView: NSView {
        var onMoveToWindow: ((ProbeView) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onMoveToWindow?(self)
        }
        // Transparent to the mouse: rows and drags must keep working.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// `SidebarListScrolling` over an AppKit scroll view. Offsets are measured from the content top,
/// whatever the flippedness of the document view.
@MainActor
final class SidebarNSScrollHook: SidebarListScrolling {
    weak var scrollView: NSScrollView?

    var metrics: SidebarScrollMetrics? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let contentHeight = document.frame.height
        let viewportHeight = clip.bounds.height
        let offset = document.isFlipped ? clip.bounds.minY : contentHeight - clip.bounds.maxY
        return SidebarScrollMetrics(offset: offset, contentHeight: contentHeight, viewportHeight: viewportHeight)
    }

    func scroll(toOffset offset: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let y = document.isFlipped ? offset : document.frame.height - clip.bounds.height - offset
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scrollView.reflectScrolledClipView(clip)
    }
}
