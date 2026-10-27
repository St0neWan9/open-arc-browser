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
    /// See-through window: no own background, controls as layers. [07 §8.4] B64.
    @Environment(\.windowSurface) private var surface
    /// View ▸ Show Toolbar: no URL box or navigation buttons here, content 46 pt higher. [06 §17.1] B43.
    @Environment(\.isWebToolbarShown) private var isWebToolbarShown

    public init(viewModel: SidebarViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        GeometryReader { proxy in
            content(layout: SidebarLayout(windowSize: CGSize(width: proxy.size.width, height: proxy.size.height),
                                          isWebToolbarShown: isWebToolbarShown, hidesFavorites: viewModel.isIncognito,
                                          favoritesTilesHeight: viewModel.favoritesTilesHeight))
        }
        .frame(width: CGFloat(Metrics.Sidebar.width))
    }

    private func content(layout: SidebarLayout) -> some View {
        let palette = viewModel.palette
        let snapshot = viewModel.snapshot
        let url = layout.urlBoxFrame, favorites = layout.favoritesTilesFrame
        let listHeight = max(0, layout.dockFrame.minY - layout.listTop)

        return ZStack(alignment: .topLeading) {
            fillOverride.map(\.swiftUI) ?? palette.sidebarBackground(on: surface)

            // Right-click anywhere on the sidebar top (traffic-light row, URL box) opens the current
            // Space's menu, the same as the Space name's "⋯". [06 §28] observed.
            Color.clear
                .frame(width: layout.width, height: layout.urlBoxFrame.maxY)
                .contentShape(Rectangle())
                .contextMenu { SidebarSpaceMenu(viewModel: viewModel) }
                .accessibilityHidden(true)

            SidebarTopBarView(viewModel: viewModel, layout: layout)

            ZStack(alignment: .topLeading) {
                if layout.showsAddressControls {
                    if viewModel.selectedEaselID != nil {
                        // An Easel's URL box is a locked "Share" button. [06 §4, §9] observed. B56.
                        EaselShareURLBox(viewModel: viewModel)
                            .frame(width: url.width, height: url.height)
                            .offset(x: url.minX, y: url.minY)
                    } else {
                        SidebarURLBoxView(viewModel: viewModel)
                            .frame(width: url.width, height: url.height)
                            .offset(x: url.minX, y: url.minY)
                    }
                }

                // An incognito window has no favorites; the rows below move up (`hidesFavorites`). [06 §20.2] observed.
                if !viewModel.isIncognito {
                    SidebarFavoritesView(viewModel: viewModel, favorites: snapshot.favorites, layout: layout)
                        .frame(width: favorites.width, height: favorites.height)
                        .offset(x: favorites.minX, y: favorites.minY)
                }

                spacePage(layout: layout, snapshot: snapshot, listHeight: listHeight)

                // "Clear" at the right of the "Incognito Tabs" row. [06 §20.2] observed (B48).
                if viewModel.isIncognito {
                    IncognitoClearButton(viewModel: viewModel, layout: layout)
                }

                // An incognito window's dock has Home and "+" but no Space icons. [06 §20.2] observed (B48).
                SidebarDockView(viewModel: viewModel, layout: layout)
                    .frame(width: layout.width, height: layout.dockFrame.height)
                    .offset(y: layout.dockFrame.minY)
            }
            .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)

            dropIndicator(layout: layout)

            selectionJumpButton(layout: layout)

            hoverCard(layout: layout)

            folderQuickList(layout: layout)

            // Two-finger horizontal swipes page between Spaces. [05 §window hierarchy] observed.
            // Transparent to clicks and scrolls (it only watches them). B76.
            SidebarSwipeMonitor(onSwipe: { viewModel.swipeSpace(by: $0) })
                .frame(width: layout.width, height: layout.windowSize.height)
                .allowsHitTesting(false)

            // Starts drags past the per-axis threshold and selects on press. [06 §15.1] observed.
            // Transparent to clicks (it only watches the mouse events).
            SidebarDragSourceHost(viewModel: viewModel, items: dragSourceItems(snapshot, layout: layout), layout: layout)
                .frame(width: layout.width, height: layout.windowSize.height)
                .allowsHitTesting(false)
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
        // Space switch: the page slides by one sidebar width on a critically damped spring, no
        // fade. [07 §11] observed (response 0.2 s, dampingFraction 1.0). B40.
        .animation(ShellMotion.spaceSwitch, value: viewModel.selectedSpaceID)
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

    /// The Space page: the Space name row and the tab list, one page per Space. Switching Spaces
    /// pages it sideways ([07 §11] observed: the page container's x moves by 276 pt; [05] the URL
    /// box, favorites and dock are outside the page and stay). Clipped to the sidebar so the
    /// outgoing page never draws over the web panel.
    private func spacePage(layout: SidebarLayout, snapshot: SidebarSnapshot, listHeight: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                SidebarSpaceNameRowView(viewModel: viewModel, layout: layout)

                SidebarListView(viewModel: viewModel, snapshot: snapshot, isSidebarHovered: isSidebarHovered, layout: layout)
                    .frame(width: layout.width, height: listHeight)
                    .offset(y: layout.listTop)
            }
            .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
            .id(viewModel.selectedSpaceID)
            .transition(ShellMotion.spacePageTransition(viewModel.spacePager))
        }
        .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
        .clipped()
    }

    private func dropGeometry(_ snapshot: SidebarSnapshot, layout: SidebarLayout) -> SidebarDropGeometry {
        var geometry = SidebarDropGeometry.make(
            snapshot: snapshot,
            dockSpaceIDs: viewModel.dockSpaces.map(\.id),
            rowFrames: rowFrames,
            regions: regions,
            width: layout.width
        )
        // Reordering a favorite keeps the grid's tile count. [06 §21.4] B55.
        geometry.favoriteDraggedIndex = viewModel.draggedFavoriteIndex
        return geometry
    }

    private func dragSourceItems(_ snapshot: SidebarSnapshot, layout: SidebarLayout) -> [SidebarDragSourceItem] {
        let favoriteSlots = viewModel.isIncognito ? [] : layout.favoriteSlotFrames(count: snapshot.favorites.count)
        return SidebarDragSourceItem.make(
            snapshot: snapshot,
            rowFrames: rowFrames,
            listViewport: regions[.list] ?? .null,
            favoriteSlots: favoriteSlots,
            accessoryWidth: layout.width - layout.rowFillFrame.maxX + SidebarLocalTokens.rowAccessoryTrailingPadding + SidebarLocalTokens.rowAccessoryButtonSize
        )
    }

    /// The single insertion line of the current drop target, clipped to the list. [06 §15.2] observed.
    @ViewBuilder
    private func dropIndicator(layout: SidebarLayout) -> some View {
        let geometry = dropGeometry(viewModel.snapshot, layout: layout)
        let contentTrailing = layout.width - layout.horizontalInset - SidebarLocalTokens.dropIndicatorTrailingInset
        if let line = SidebarDropIndicatorLine.make(for: viewModel.dropTarget, in: geometry, contentTrailing: contentTrailing),
           geometry.list.isNull || (line.y >= geometry.list.minY - 1 && line.y <= geometry.list.maxY + 1) {
            SidebarDropIndicatorView(line: line, color: viewModel.palette.dropIndicatorColor.swiftUI)
        }
    }

    /// The round ↓ / ↑ button at the bottom / top middle of the list while the selected row is
    /// scrolled out of view; a click scrolls back to it. [06 §15.8] observed (white round button,
    /// arrow toward the selection); size, inset and the click behavior are inferred. B76.
    @ViewBuilder
    private func selectionJumpButton(layout: SidebarLayout) -> some View {
        let viewport = regions[.list] ?? .null
        let rowID = viewModel.selectedListRowID
        let rowFrame = rowID.flatMap { rowFrames[$0] }
        if viewModel.draggingItem == nil,
           let direction = SidebarSelectionJump.direction(rowFrame: rowFrame, viewport: viewport, fill: layout.rowFillFrame),
           let rowFrame {
            let size = SidebarSelectionJump.buttonSize
            Button {
                viewModel.revealSelectedRow(rowFrame: rowFrame, viewport: viewport)
            } label: {
                Image(systemName: direction == .down ? "arrow.down" : "arrow.up")
                    .font(.system(size: SidebarSelectionJump.glyphSize, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.7))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(SidebarSelectionJump.buttonCenter(direction: direction, viewport: viewport))
            .accessibilityLabel(direction == .down ? "Scroll down to the selected tab" : "Scroll up to the selected tab")
            .accessibilityIdentifier("openarc.sidebar.selectionJump")
        }
    }

    /// The hovered folder's quick list, in a bubble right of its row. [06 §14] observed. B76.
    private func folderQuickList(layout: SidebarLayout) -> some View {
        let id = viewModel.quickListFolderID
        let fill = layout.rowFillFrame
        let anchor = id.flatMap { rowFrames[$0] }.map {
            CGRect(x: fill.minX, y: $0.minY + fill.minY, width: fill.width, height: fill.height)
        }
        let palette = viewModel.palette
        return FolderQuickListPresenter(viewModel: viewModel, folderID: id, anchor: anchor,
                                        rowCount: id.map { viewModel.quickListRows(folderID: $0).count } ?? 0,
                                        tint: palette.floatingPanelBackground, isDark: palette.isDark)
            .frame(width: layout.width, height: layout.windowSize.height)
            .allowsHitTesting(false)
    }

    /// The hover card: its own floating panel at the pointer. [07 §12] observed.
    private func hoverCard(layout: SidebarLayout) -> some View {
        let id = viewModel.hoverCardTabID
        let tab = id.flatMap { viewModel.workspace.tabs[$0] }
        return SidebarHoverCardPresenter(tabID: tab == nil ? nil : id, title: tab?.displayTitle ?? "",
                                         fill: viewModel.palette.selectedTabFill)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
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
    @Environment(\.windowSurface) private var surface

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
                .fill(viewModel.palette.windowFills(on: surface).scrollEdgeLine.swiftUI)
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

// MARK: - Selected row jump button (B76)

/// Pure geometry of the ↓ / ↑ button. [06 §15.8] observed: when the selected tab is scrolled out
/// of the visible list, a white round button with an arrow toward it shows at the middle of the
/// list's bottom (or top). Size, inset and "out of view" = the row's fill is entirely outside the
/// list are inferred.
enum SidebarSelectionJump {
    enum Direction: Equatable { case up, down }

    static let buttonSize: CGFloat = 28
    static let glyphSize: CGFloat = 12
    /// Gap between the button and the list edge.
    static let edgeInset: CGFloat = 8

    /// Which way the selected row lies, or nil while any of its fill is visible (or there is no
    /// row, or no list). `rowFrame` is the 41 pt row and `viewport` the visible list, both in the
    /// sidebar root space; `fill` is the row's fill inside the row (`SidebarLayout.rowFillFrame`).
    static func direction(rowFrame: CGRect?, viewport: CGRect, fill: CGRect) -> Direction? {
        guard let rowFrame, !rowFrame.isNull, !viewport.isNull, viewport.height > 0 else { return nil }
        let top = rowFrame.minY + fill.minY, bottom = rowFrame.minY + fill.maxY
        if bottom <= viewport.minY { return .up }
        if top >= viewport.maxY { return .down }
        return nil
    }

    /// Center of the button: horizontally centered on the list, `edgeInset` inside its bottom
    /// (↓) or top (↑) edge.
    static func buttonCenter(direction: Direction, viewport: CGRect) -> CGPoint {
        let half = buttonSize / 2
        let y = direction == .down ? viewport.maxY - edgeInset - half : viewport.minY + edgeInset + half
        return CGPoint(x: viewport.midX, y: y)
    }

    /// Scroll offset that puts the selected row in the middle of the list, clamped to the content.
    static func revealOffset(rowFrame: CGRect, viewport: CGRect, metrics: SidebarScrollMetrics) -> CGFloat {
        let target = metrics.offset + (rowFrame.midY - viewport.midY)
        return min(max(target, 0), metrics.maxOffset)
    }
}

// MARK: - Trackpad swipe between Spaces (B76)

/// Turns the scroll events of one trackpad gesture into at most one Space step. [05 §window
/// hierarchy] observed: Spaces are horizontal pages switched by a swipe or the dock. Threshold
/// and the "mostly horizontal" rule are inferred. Pure, for tests.
struct SidebarSwipeRecognizer {
    /// Horizontal travel (points) before the gesture pages.
    static let threshold: CGFloat = 50
    /// The gesture must be this many times more horizontal than vertical (keeps list scrolling
    /// from switching Spaces).
    static let dominance: CGFloat = 1.5

    enum Phase { case began, changed, ended, other }

    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var fired = false
    private var tracking = false

    /// Feeds one event of the gesture (`deltaX`/`deltaY` as AppKit's `scrollingDelta`, content
    /// direction). Returns +1 (next Space) or -1 (previous Space) the moment the gesture qualifies;
    /// nil otherwise. Content moving left (fingers to the left with natural scrolling) reveals
    /// the next page on the right, as a horizontal page view does.
    mutating func feed(phase: Phase, deltaX: CGFloat, deltaY: CGFloat) -> Int? {
        switch phase {
        case .began:
            dx = 0; dy = 0; fired = false; tracking = true
        case .ended, .other:
            tracking = false
            return nil
        case .changed:
            guard tracking else { return nil }
        }
        dx += deltaX
        dy += deltaY
        guard !fired, abs(dx) >= Self.threshold, abs(dx) >= Self.dominance * abs(dy) else { return nil }
        fired = true
        return dx < 0 ? 1 : -1
    }
}

/// Watches two-finger trackpad swipes over the sidebar (window-local event monitor) and reports
/// one Space step per gesture. Never consumes the events, so vertical list scrolling and pages
/// behind are untouched. Momentum events and mouse wheels (no gesture phase) are ignored.
struct SidebarSwipeMonitor: NSViewRepresentable {
    let onSwipe: @MainActor (Int) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onSwipe = onSwipe
    }

    final class MonitorView: NSView {
        var onSwipe: (@MainActor (Int) -> Void)?
        private var recognizer = SidebarSwipeRecognizer()
        private var token: SwipeMonitorToken?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            token = nil
            guard window != nil else { return }
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let phase = event.phase, momentum = event.momentumPhase, precise = event.hasPreciseScrollingDeltas
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
                let location = event.locationInWindow, number = event.windowNumber
                MainActor.assumeIsolated {
                    self?.handle(phase: phase, momentum: momentum, precise: precise, dx: dx, dy: dy,
                                 location: location, windowNumber: number)
                }
                return event
            }
            token = monitor.map(SwipeMonitorToken.init)
        }

        private func handle(phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, dx: CGFloat, dy: CGFloat,
                            location: NSPoint, windowNumber: Int) {
            guard let window, windowNumber == window.windowNumber, precise, momentum.isEmpty, !phase.isEmpty else { return }
            let mapped: SidebarSwipeRecognizer.Phase
            if phase.contains(.began) {
                // A gesture counts only when it starts over the sidebar.
                guard bounds.contains(convert(location, from: nil)) else { return }
                mapped = .began
            } else if phase.contains(.changed) {
                mapped = .changed
            } else if phase.contains(.ended) || phase.contains(.cancelled) {
                mapped = .ended
            } else {
                mapped = .other
            }
            if let step = recognizer.feed(phase: mapped, deltaX: dx, deltaY: dy) { onSwipe?(step) }
        }
    }
}

/// Removes an `NSEvent` monitor when released.
private final class SwipeMonitorToken {
    private let monitor: Any
    init(_ monitor: Any) { self.monitor = monitor }
    deinit { NSEvent.removeMonitor(monitor) }
}
