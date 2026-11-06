import SwiftUI
import AppKit
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

/// The sidebar. The window's sidebar width (B144; 276 in the reference), full window height. Every block sits at
/// its measured window position [07 §1, §2, §4] observed: toolbar buttons (y 7.5–39.5), URL box
/// (46–82), favorites (90–137), Space header (145–181), the scrolling list (181 to H − 50) and
/// the dock (H − 50 to H).
public struct SidebarView: View {
    /// Observed for the layout inputs only (favorites height, incognito). Every block below
    /// observes the view model on its own and redraws only when what it shows changed (B104): a
    /// Space switch no longer re-evaluates the whole sidebar.
    @ObservedObject private var viewModel: SidebarViewModel
    @State private var isSidebarHovered = false
    /// Scroll offsets and reported regions. Only the small views that depend on them observe it,
    /// so scrolling never re-evaluates this body.
    @StateObject private var listScroll = SidebarListScrollState()
    /// View ▸ Show Toolbar: no URL box or navigation buttons here, content 46 pt higher. [06 §17.1] B43.
    @Environment(\.isWebToolbarShown) private var isWebToolbarShown

    /// Width of the sidebar area. 276 is the reference width [07 §1] observed; a window passes
    /// its resizable width (B144).
    private let width: CGFloat

    public init(viewModel: SidebarViewModel, width: CGFloat = CGFloat(Metrics.Sidebar.width)) {
        self.viewModel = viewModel
        self.width = width
    }

    public var body: some View {
        // An incognito window's controller has no updater of its own (the app's lives on the
        // main controller), so it shows no update pill. inferred.
        if viewModel.isIncognito {
            content(isUpdateReady: false)
        } else {
            SidebarUpdateReadyReader(updates: viewModel.controller.updates) { content(isUpdateReady: $0) }
        }
    }

    private func content(isUpdateReady: Bool) -> some View {
        let isIncognito = viewModel.isIncognito
        let tilesHeight = viewModel.favoritesTilesHeight
        return GeometryReader { proxy in
            SidebarContent(viewModel: viewModel, listScroll: listScroll, isSidebarHovered: isSidebarHovered,
                           layout: SidebarLayout(windowSize: CGSize(width: proxy.size.width, height: proxy.size.height),
                                                 isWebToolbarShown: isWebToolbarShown, hidesFavorites: isIncognito,
                                                 favoritesTilesHeight: tilesHeight, showsUpdatePill: isUpdateReady,
                                                 width: width),
                           onHover: { isSidebarHovered = $0 })
                .equatable()
        }
        .frame(width: width)
        .environment(\.sidebarWidth, width)
    }
}

/// Observes the update state only, so the sidebar's layout follows "update ready" (B111) without
/// the sidebar observing anything else of the updater.
private struct SidebarUpdateReadyReader<Content: View>: View {
    @ObservedObject var updates: UpdatesModel
    let content: (Bool) -> Content

    var body: some View { content(updates.isUpdateReady) }
}

/// The sidebar's blocks at their measured positions. Equatable on its layout and hover: the view
/// model's changes reach the blocks that observe it, not this body (B104).
private struct SidebarContent: View, Equatable {
    let viewModel: SidebarViewModel
    let listScroll: SidebarListScrollState
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    let onHover: (Bool) -> Void
    /// See-through window: no own background, controls as layers. [07 §8.4] B64.
    @Environment(\.windowSurface) private var surface

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.viewModel === rhs.viewModel && lhs.listScroll === rhs.listScroll
            && lhs.isSidebarHovered == rhs.isSidebarHovered && lhs.layout == rhs.layout
    }

    var body: some View {
        let url = layout.urlBoxFrame, favorites = layout.favoritesTilesFrame
        let viewModel = self.viewModel, listScroll = self.listScroll, layout = self.layout

        ZStack(alignment: .topLeading) {
            SidebarBackgroundFill(viewModel: viewModel)

            // Right-click anywhere on the sidebar background (the top bar, the gaps between the
            // blocks, around the dock) opens the current Space's menu, the same as the Space name's
            // "⋯". [06 §21.5, §28] observed. Blocks above it with their own menu win.
            Color.clear
                .frame(width: layout.width, height: layout.windowSize.height)
                .contentShape(Rectangle())
                .contextMenu { SidebarSpaceMenu(viewModel: viewModel) }
                .accessibilityHidden(true)

            SidebarTopBarHost(viewModel: viewModel, layout: layout)

            ZStack(alignment: .topLeading) {
                if layout.showsAddressControls {
                    SidebarURLBoxHost(viewModel: viewModel)
                        .frame(width: url.width, height: url.height)
                        .offset(x: url.minX, y: url.minY)
                }

                // An incognito window has no favorites; the rows below move up (`hidesFavorites`). [06 §20.2] observed.
                if !layout.hidesFavorites {
                    SidebarFavoritesHost(viewModel: viewModel, layout: layout)
                        .frame(width: favorites.width, height: favorites.height)
                        .offset(x: favorites.minX, y: favorites.minY)
                }

                spacePager

                // "Clear" at the right of the "Incognito Tabs" row. [06 §20.2] observed (B48).
                if layout.hidesFavorites {
                    IncognitoClearButton(viewModel: viewModel, layout: layout)
                }

                // An incognito window's dock has Home and "+" but no Space icons. [06 §20.2] observed (B48).
                SidebarDockHost(viewModel: viewModel, layout: layout)
                    .frame(width: layout.width, height: layout.dockFrame.height)
                    .offset(y: layout.dockFrame.minY)

                // A downloaded update waits: the pill right above the dock. [07 §8.6] observed (B111).
                if let pill = layout.updatePillFrame {
                    SidebarUpdatePill(lightInk: viewModel.palette.usesLightInk) { viewModel.controller.updates.installReadyUpdate() }
                        .frame(width: pill.width, height: pill.height)
                        .offset(x: pill.minX, y: pill.minY)
                }
            }
            .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)

            // Drop line, ↓ / ↑ jump button and folder quick list: they follow the scroll offset.
            SidebarListOverlays(viewModel: viewModel, scroll: listScroll, layout: layout)

            SidebarHoverCardHost(viewModel: viewModel)

            // Two-finger horizontal swipes page between Spaces. [05 §window hierarchy] observed.
            // Transparent to clicks and scrolls (it only watches them). B76.
            SidebarSwipeMonitor(viewModel: viewModel)
                .frame(width: layout.width, height: layout.windowSize.height)
                .allowsHitTesting(false)

            // Starts drags past the per-axis threshold and selects on press. [06 §15.1] observed.
            // Transparent to clicks (it only watches the mouse events).
            // The pickable items are computed at the press, from the scroll offset of that moment.
            // A drag from the blank list area below the rows moves the window (B110).
            SidebarDragSourceHost(viewModel: viewModel, items: {
                listScroll.dragSourceItems(viewModel: viewModel, layout: layout)
            }, windowMoveArea: {
                listScroll.windowMoveArea(viewModel: viewModel, layout: layout)
            }, layout: layout)
                .frame(width: layout.width, height: layout.windowSize.height)
                .allowsHitTesting(false)
        }
        .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
        .coordinateSpace(name: SidebarCoordinateSpace.root)
        .environment(\.sidebarAudioGlyphSink, listScroll)
        .onPreferenceChange(SidebarDropRegionsKey.self) { regions in
            MainActor.assumeIsolated { listScroll.setRegions(regions) }
        }
        .onDrop(of: [SidebarDragPayload.itemType, .url], delegate: SidebarRootDropDelegate(viewModel: viewModel, geometry: {
            listScroll.dropGeometry(viewModel: viewModel, layout: layout)
        }))
        .onHover(perform: onHover)
        // Space switch: the pages slide on a Core Animation spring in `SidebarSpacePager`
        // ([07 §11] observed, B101). The rest of the sidebar switches at once.
        // The tab Share picker (B77). New Folder, Delete Space, Change Icon… and Edit Pinned Page
        // are window cards (`SidebarWindowModals`, B91).
        .modifier(SidebarItemEditSheets(viewModel: viewModel))
        .onAppear { viewModel.listScrollState = listScroll }
        // The sidebar's cards are declared at the window root (`SidebarWindowModals`). B99.
        .declaresNoWindowModals()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar")
    }

    /// The Space pages: the Space name row and the tab list, one page per Space. Switching Spaces
    /// pages them sideways ([07 §11] observed: the page container's x moves by 276 pt; [05] the URL
    /// box, favorites and dock are outside the page and stay). The pager keeps recent pages built
    /// and clips them to the sidebar, so the outgoing page never draws over the web panel (B101).
    private var spacePager: some View {
        let top = SidebarSpacePager.bandTop(layout)
        return SidebarSpacePagerHost(viewModel: viewModel, scroll: listScroll, isSidebarHovered: isSidebarHovered,
                                     layout: layout, surface: surface)
            .frame(width: layout.width, height: max(0, layout.listBottom - top))
            .offset(y: top)
    }
}

// MARK: - Block hosts (B104)
//
// Each host observes the sidebar view model and hands its block a plain value; the block is
// Equatable and redraws only when that value changed. A host's body is a few property reads.

/// The sidebar fill: the window color, or the peek panel's deeper fill. [06 §14] B34.
private struct SidebarBackgroundFill: View {
    @ObservedObject var viewModel: SidebarViewModel
    /// The floating peek panel's deeper fill instead of the window color. [06 §14] B34.
    @Environment(\.sidebarFillOverride) private var fillOverride
    @Environment(\.windowSurface) private var surface

    var body: some View {
        fillOverride.map(\.swiftUI) ?? viewModel.palette.sidebarBackground(on: surface)
    }
}

private struct SidebarTopBarHost: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout

    var body: some View {
        SidebarTopBarView(viewModel: viewModel, state: viewModel.topBarState, layout: layout)
            .equatable()
    }
}

private struct SidebarURLBoxHost: View {
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        if viewModel.selectedEaselID != nil {
            // An Easel's URL box is a locked "Share" button. [06 §4, §9] observed. B56.
            EaselShareURLBox(viewModel: viewModel)
        } else {
            SidebarURLBoxView(viewModel: viewModel, state: viewModel.urlBoxState)
                .equatable()
        }
    }
}

private struct SidebarFavoritesHost: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout

    var body: some View {
        SidebarFavoritesView(viewModel: viewModel, state: viewModel.favoritesState(viewModel.snapshot.favorites), layout: layout)
            .equatable()
    }
}

private struct SidebarDockHost: View {
    @ObservedObject var viewModel: SidebarViewModel
    let layout: SidebarLayout

    var body: some View {
        SidebarDockView(viewModel: viewModel, state: viewModel.dockState, layout: layout)
            .equatable()
    }
}

/// Hands the pager the selected Space; the pages follow the view model through their own relays.
private struct SidebarSpacePagerHost: View {
    @ObservedObject var viewModel: SidebarViewModel
    let scroll: SidebarListScrollState
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    let surface: WindowSurface

    var body: some View {
        SidebarSpacePager(viewModel: viewModel, selectedSpaceID: viewModel.selectedSpaceID, scroll: scroll,
                          isSidebarHovered: isSidebarHovered, layout: layout, surface: surface)
    }
}

/// The hover card: its own floating panel at the pointer. [07 §12] observed.
private struct SidebarHoverCardHost: View {
    @ObservedObject var viewModel: SidebarViewModel

    var body: some View {
        let id = viewModel.hoverCardTabID
        let tab = id.flatMap { viewModel.workspace.tabs[$0] }
        SidebarHoverCardPresenter(tabID: tab == nil ? nil : id, title: tab?.displayTitle ?? "",
                                  fill: viewModel.palette.selectedTabFill)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }
}

/// Scrolling list: pinned area (folders and tabs), the divider, "+ New Tab" right under it at the
/// top of Today, then the Today tabs. [07 §1, §4] observed (row pitch 41, a 3 pt spacer on top,
/// a 17 pt divider; B31 found New Tab directly below the divider). An empty Space shows only
/// "+ New Tab", without the divider. [06 §4] observed.
///
/// Every entry has a fixed height, so the content is one block of `geometry.contentHeight` and
/// only the entries near the visible area exist as views (`SidebarListRows`). A Space with
/// thousands of pinned items scrolls and updates at the cost of a few screenfuls of rows.
struct SidebarListView: View {
    /// Not observed: the list itself draws nothing from the view model; its rows and decorations
    /// observe their page's `changes` relay. The list's body runs only when its inputs change
    /// (B104: re-running it on every sidebar change rebuilt the scroll view's content each time).
    let viewModel: SidebarViewModel
    let changes: SidebarSpacePageChanges
    /// The scroll state's changes, relayed while the page is shown.
    let scrollChanges: SidebarSpacePageChanges
    /// Rows and positions; held by reference so a view update compares one pointer.
    let content: SidebarListContent
    /// The Space this list belongs to (its page's Space).
    let spaceID: UUID?
    /// Not observed here: only `SidebarListDecorations` and `SidebarListOverlays` follow the offset.
    let scroll: SidebarListScrollState
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    @StateObject private var window = SidebarListWindow()

    var body: some View {
        list
            .overlay(alignment: .topLeading) {
                SidebarListDecorations(viewModel: viewModel, spaceSwipe: viewModel.spaceSwipe, changes: changes, scrollChanges: scrollChanges,
                                       scroll: scroll, spaceID: spaceID,
                                       isSidebarHovered: isSidebarHovered, layout: layout)
            }
    }

    /// The clip view scrolled or resized. Called by AppKit for every scroll step, outside any
    /// SwiftUI update: it only touches the scroll state and the row band.
    private func scrolled(_ metrics: SidebarScrollMetrics) {
        let contentFrame = CGRect(x: 0, y: -metrics.offset, width: layout.width, height: metrics.contentHeight)
        scroll.update(spaceID, contentFrame: contentFrame, viewportSize: CGSize(width: layout.width, height: metrics.viewportHeight))
        window.update(offset: metrics.offset, viewportHeight: metrics.viewportHeight)
        scroll.noteRowBand(spaceID, minY: window.minY, maxY: window.maxY)
        // Auto-scroll moves rows under a pointer that may not move: re-hit-test with the new
        // frames so the indicator stays on the row actually under the pointer. inferred (B20).
        if viewModel.isDragActive, spaceID == viewModel.selectedSpaceID {
            viewModel.refreshDropTarget(in: scroll.dropGeometry(viewModel: viewModel, layout: layout))
        }
    }

    private var list: some View {
        ScrollView(.vertical) {
            SidebarListRows(viewModel: viewModel, changes: changes, content: content, spaceID: spaceID, window: window,
                            isSidebarHovered: isSidebarHovered, layout: layout)
                .frame(width: layout.width, height: content.geometry.contentHeight, alignment: .topLeading)
                // Rows report no drop regions (their frames follow from the list geometry): the key
                // stops here, so it is not combined through every row on each update. B99.
                .preference(key: SidebarDropRegionsKey.self, value: [:])
                // Gives the view model a handle on the backing scroll view for drag auto-scroll
                // (B20), and reports every scroll step (the clip view's bounds).
                .background(SidebarListScrollProbe(viewModel: viewModel, spaceID: spaceID, scroll: scroll,
                                                   onScroll: { metrics in scrolled(metrics) }))
        }
        // The system scroller is replaced by the thin hover-revealed knob drawn in
        // `SidebarListDecorations` ([04 §sidebar] observed); AppKit's overlay scroller follows
        // the system setting and shows while scrolling, not while hovering.
        .scrollIndicators(.never)
        .sidebarDropRegion(.list)
        .contentShape(Rectangle())
        .contextMenu { SidebarSpaceMenu(viewModel: viewModel) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.tabList")
    }
}

/// The part of the list around the visible area (`SidebarListWindow`), each entry placed at its
/// fixed position. A scroll of a few points does not change which rows exist.
private struct SidebarListRows: View {
    let viewModel: SidebarViewModel
    @ObservedObject var changes: SidebarSpacePageChanges
    let content: SidebarListContent
    let spaceID: UUID?
    @ObservedObject var window: SidebarListWindow
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let geometry = content.geometry
        // How much the content grew with the latest folder open / close, while it animates. B176.
        let growth = window.noteDisclosure(count: viewModel.folderDisclosureCount(in: spaceID),
                                           contentHeight: geometry.contentHeight)
        let reveal = SidebarFolderRevealPlan(geometry: geometry, viewModel: viewModel, spaceID: spaceID)
        // A close: the closed folder's rows stay drawn for the animation, slid up by the block's
        // height under the folder row, so they move there with the rows below instead of being
        // removed in place. B176.
        let closingRows = window.closingRows(growth: growth) {
            SidebarFolderRevealPlan.closingRows(previous: changes.drawnRows) {
                SidebarFolderRevealPlan(geometry: $0, viewModel: viewModel, spaceID: spaceID)
            }
        }
        let closing = closingRows?.rows ?? []
        // Each row gets its state by value and is re-evaluated only when that state changed (B99).
        // A page draws its own Space's colors and selection (B101). While a folder opens, the rows
        // it pushes past the band stay built until they have slid away.
        // At most a screenful more: the pinned area of an imported Space can push rows by tens of
        // thousands of points, and building all of them dropped frames (B178). Rows pushed further
        // slide down as they go (`otherRowTransition`).
        let rows = viewModel.listRowsLook(content: content, spaceID: spaceID, minY: window.minY,
                                          maxY: window.maxY + min(max(0, growth), SidebarListWindow.disclosureBandLimit))
        // What this page drew, so a hidden page can tell whether it is still current (B106).
        // A plain record: never published.
        let _ = changes.noteDrawn(rows: rows)
        // One list, so a closing row keeps its identity and slides instead of being replaced.
        let drawn = rows.entries.filter { row in !closing.contains { $0.row.id == row.id } }
            .map { SidebarPlacedListEntry(row: $0, top: $0.entry.top,
                                          mask: reveal?.mask(for: $0.entry) ?? .none(for: $0.entry)) }
            + closing.map { SidebarPlacedListEntry(row: $0.row, top: $0.top,
                                                   mask: SidebarFolderRevealMask(clipTop: $0.clipY - $0.top, height: $0.row.entry.height)) }
        SidebarListRowsLayout(size: CGSize(width: layout.width, height: geometry.contentHeight)) {
            ForEach(drawn) { placed in
                entryView(placed.row.look)
                    .frame(width: layout.width, height: placed.row.entry.height, alignment: .topLeading)
                    .modifier(SidebarFolderRevealEffect(shift: 0, mask: placed.mask))
                    // Only takes effect in an animated update: scrolling builds rows without it.
                    .transition(reveal?.transition(for: placed.row.entry, bandMaxY: window.maxY)
                        ?? SidebarFolderRevealPlan.otherRowTransition(closingTravel: closingRows?.travel,
                                                                      openingGrowth: min(growth, SidebarListWindow.disclosureBandLimit)))
                    .layoutValue(key: SidebarListEntryTop.self, value: placed.top)
            }
        }
        // Applied here, inside the content's fixed frame: the rows move, the scroll view's content
        // height changes at once. B167, B176.
        .animation(folderDisclosureAnimation(contentHeight: geometry.contentHeight, growth: growth),
                   value: viewModel.folderDisclosureCount(in: spaceID))
    }

    private func folderDisclosureAnimation(contentHeight: CGFloat, growth: CGFloat) -> Animation? {
        guard let metrics = viewModel.listScroller?.metrics,
              SidebarListRowsLayout.keepsScrollOffset(metrics, newContentHeight: contentHeight) else { return nil }
        return ShellMotion.folderDisclosure(expanding: growth >= 0, reduceMotion: reduceMotion,
                                            pinnedArea: viewModel.revealsPinnedArea)
    }

    @ViewBuilder
    private func entryView(_ look: SidebarListEntryLook) -> some View {
        switch look {
        case .folder(let row):
            SidebarFolderRowView(viewModel: viewModel, row: row)
                .equatable()
        case .tab(let row):
            SidebarTabRowView(viewModel: viewModel, row: row)
                .equatable()
        case .splitGroup(let row):
            SidebarSplitGroupRowView(viewModel: viewModel, row: row)
                .equatable()
        case .divider(let palette, let canClear):
            SidebarDividerRowView(viewModel: viewModel, palette: palette, canClear: canClear, isSidebarHovered: isSidebarHovered)
        case .newTabRow(let palette, let isEmptySpace, let isSelected, let isIncognito):
            SidebarNewTabRowView(viewModel: viewModel, palette: palette, isEmptySpace: isEmptySpace,
                                 isSelected: isSelected, isIncognito: isIncognito)
        }
    }
}

/// What one list entry draws: the value its row view is given. B106 compares these to tell
/// whether a hidden Space page still draws its Space's current state.
enum SidebarListEntryLook: Equatable {
    case folder(SidebarFolderRowView.State)
    case tab(SidebarTabRowState)
    case splitGroup(SidebarSplitGroupRowView.State)
    case divider(palette: ThemePalette, canClear: Bool)
    case newTabRow(palette: ThemePalette, isEmptySpace: Bool, isSelected: Bool, isIncognito: Bool)
}

/// One built list entry and what it draws.
struct SidebarDrawnListEntry: Identifiable {
    let entry: SidebarListEntry
    let look: SidebarListEntryLook
    var id: SidebarListEntry.ID { entry.id }
}

/// The entries a page's list builds for one row band (`SidebarListWindow`), and what each draws.
struct SidebarListRowsLook {
    /// The rows the list draws from (compared by reference, see `SidebarListContent`).
    let content: SidebarListContent
    /// The band the entries were built for.
    let minY: CGFloat
    let maxY: CGFloat
    let entries: [SidebarDrawnListEntry]

    /// Same rows, same band and every built entry draws the same.
    func drawsSame(as other: SidebarListRowsLook) -> Bool {
        content === other.content && minY == other.minY && maxY == other.maxY
            && entries.count == other.entries.count
            && zip(entries, other.entries).allSatisfy { $0.look == $1.look }
    }
}

extension SidebarViewModel {
    /// What Space `spaceID`'s list draws for the band `minY..<maxY` of `content`, now.
    func listRowsLook(content: SidebarListContent, spaceID: UUID?, minY: CGFloat, maxY: CGFloat) -> SidebarListRowsLook {
        let geometry = content.geometry
        let range = geometry.range(overlapping: minY, maxY)
        // Read once for all rows.
        let palette = palette(forSpace: spaceID)
        let selected = pageSelectedTabID(for: spaceID)
        let entries = geometry.entries[range].map { entry in
            SidebarDrawnListEntry(entry: entry, look: listEntryLook(entry, snapshot: content.snapshot, palette: palette, selected: selected))
        }
        return SidebarListRowsLook(content: content, minY: minY, maxY: maxY, entries: entries)
    }

    private func listEntryLook(_ entry: SidebarListEntry, snapshot: SidebarSnapshot, palette: ThemePalette,
                               selected: UUID?) -> SidebarListEntryLook {
        switch entry.content {
        case .row(let item):
            switch item.kind {
            case .folder(let folder):
                return .folder(folderRowState(folder, depth: item.depth, palette: palette))
            case .tab(let tab):
                return .tab(tabRowState(tab, depth: item.depth, area: item.area, palette: palette, selectedTabID: selected))
            case .splitGroup(let group):
                return .splitGroup(splitGroupRowState(group, depth: item.depth, area: item.area, palette: palette, selectedTabID: selected))
            }
        case .divider:
            return .divider(palette: palette, canClear: snapshot.canClear)
        case .newTabRow:
            return .newTabRow(palette: palette, isEmptySpace: snapshot.isEmptySpace,
                              isSelected: isNewTabRowSelected, isIncognito: isIncognito)
        }
    }
}

/// A built row at its place in the content, and the part of it that shows (B176).
struct SidebarPlacedListEntry: Identifiable {
    let row: SidebarDrawnListEntry
    let top: CGFloat
    let mask: SidebarFolderRevealMask
    var id: SidebarListEntry.ID { row.id }
}

/// How a folder's rows open and close (B176, observed on a 57 fps recording of Arc): they move as
/// one block that slides down out from under the folder row, or up under it, cut off at the folder
/// row's bottom edge; the rows below move with the block's end. The plan covers the folder the
/// pointer is on: its block when open, where its rows will be when it opens.
struct SidebarFolderRevealPlan {
    /// Indices in `geometry.entries` of the block's rows.
    let block: Range<Int>
    /// Content y of the block's top edge (the folder row's bottom, or the top of the pinned
    /// area): rows are cut off above it.
    let clipY: CGFloat
    /// Height of the block in this geometry.
    let height: CGFloat
    /// How far its rows slide: the block's height less the rows that stay (`keptIDs`).
    let distance: CGFloat
    /// Rows that stay when the block closes: the selected tab of a collapsed pinned area (B178).
    let keptIDs: Set<UUID>
    /// Content y where the closed block ends: `clipY` plus the rows that stay.
    var closedEnd: CGFloat { clipY + height - distance }

    init?(geometry: SidebarListGeometry, folderID: UUID?) {
        guard let folderID, let index = geometry.rowIndex[folderID], case .row(let folder) = geometry.entries[index].content,
              case .folder = folder.kind else { return nil }
        var end = index + 1
        while end < geometry.entries.count, case .row(let item) = geometry.entries[end].content,
              item.depth > folder.depth, item.area == folder.area {
            end += 1
        }
        guard end > index + 1 else { return nil }
        block = (index + 1)..<end
        clipY = geometry.entries[index + 1].top
        let next = end < geometry.entries.count ? geometry.entries[end].top : geometry.entries[end - 1].bottom
        height = next - clipY
        distance = height
        keptIDs = []
    }

    /// The whole pinned area, under the Space name row (Collapse Pinned Tabs). Row `keptRowID`
    /// stays when it closes. B178.
    init?(pinnedAreaOf geometry: SidebarListGeometry, keptRowID: UUID?) {
        var end = 0
        while end < geometry.entries.count, case .row(let item) = geometry.entries[end].content, item.area == .pinned {
            end += 1
        }
        guard end > 0 else { return nil }
        block = 0..<end
        clipY = geometry.entries[0].top
        let next = end < geometry.entries.count ? geometry.entries[end].top : geometry.entries[end - 1].bottom
        height = next - clipY
        var kept: Set<UUID> = []
        var keptHeight: CGFloat = 0
        if let keptRowID, let index = geometry.rowIndex[keptRowID], block.contains(index) {
            kept.insert(keptRowID)
            keptHeight = geometry.entries[index].height + (end > index + 1 ? geometry.entries[index + 1].top - geometry.entries[index].bottom : 0)
        }
        keptIDs = kept
        distance = height - keptHeight
    }

    /// The plan the list draws with: the pinned area when the view model says so, else the folder.
    @MainActor
    init?(geometry: SidebarListGeometry, viewModel: SidebarViewModel, spaceID: UUID?) {
        if viewModel.revealsPinnedArea {
            let kept = viewModel.pageSelectedTabID(for: spaceID).flatMap { geometry.rowID(showingTab: $0) }
            self.init(pinnedAreaOf: geometry, keptRowID: kept)
        } else {
            self.init(geometry: geometry, folderID: viewModel.revealFolderID)
        }
    }

    /// A row of the block that comes and goes with it (not one that stays).
    func contains(_ entry: SidebarListEntry) -> Bool {
        guard entry.top >= clipY, entry.top < clipY + height else { return false }
        if case .row(let id) = entry.id, keptIDs.contains(id) { return false }
        return true
    }

    /// The part of a block row below the block's top edge; nil for other rows.
    func mask(for entry: SidebarListEntry) -> SidebarFolderRevealMask? {
        entry.top >= clipY && entry.top < clipY + height ? SidebarFolderRevealMask(clipTop: clipY - entry.top, height: entry.height) : nil
    }

    /// A row of the block opening slides down by the block's height and is cut off at the folder
    /// row; any other row: `otherRowTransition`.
    /// `bandMaxY` is the bottom of the built rows: a block taller than that slides as if it ended
    /// there, so only rows that can be seen move, by at most a screenful (B178).
    func transition(for entry: SidebarListEntry, bandMaxY: CGFloat = .infinity) -> AnyTransition? {
        guard let mask = mask(for: entry) else { return nil }
        // Rows built past the band (kept for rows an open pushes down) land off screen: no slide,
        // or they would cross the visible list.
        guard entry.top < bandMaxY else { return .identity }
        let shift = min(distance, max(0, bandMaxY - clipY))
        return .modifier(active: SidebarFolderRevealEffect(shift: -shift, mask: mask),
                         identity: SidebarFolderRevealEffect(shift: 0, mask: mask))
    }

    /// A row of a closing folder, drawn where it slides to: `top` is its last place moved up by
    /// the block's height, cut off at `clipY`.
    struct ClosingRow {
        let row: SidebarDrawnListEntry
        let top: CGFloat
        let clipY: CGFloat
    }

    /// The rows folder `folderID` drew before it closed, each moved up by the height of the part
    /// that was drawn: a folder longer than the built band closes as if it ended there, so the rows
    /// below follow right behind its last drawn row (`ClosingRows.travel`).
    static func closingRows(previous: SidebarListRowsLook?, plan: (SidebarListGeometry) -> SidebarFolderRevealPlan?) -> ClosingRows {
        guard let previous, let plan = plan(previous.content.geometry) else {
            return ClosingRows(rows: [], travel: 0)
        }
        let drawn = previous.entries.filter { plan.contains($0.entry) }
        let end = plan.closedEnd
        let travel = min(plan.distance, max(0, (drawn.map(\.entry.bottom).max() ?? end) - end))
        return ClosingRows(rows: drawn.map { ClosingRow(row: $0, top: $0.entry.top - travel, clipY: end) }, travel: travel)
    }

    struct ClosingRows {
        var rows: [ClosingRow]
        /// How far they slide; rows below that come into the band start this much lower.
        var travel: CGFloat
    }

    /// Rows outside the block that come into the built band during a close come up from right
    /// behind the closing rows, `closingTravel` lower; others fade.
    static func otherRowTransition(closingTravel: CGFloat?, openingGrowth: CGFloat = 0) -> AnyTransition {
        if let closingTravel { return .offset(y: closingTravel) }
        // An open pushes a row out of the built band: it slides down by the growth as it goes.
        if openingGrowth > 0 { return .asymmetric(insertion: .opacity, removal: .offset(y: openingGrowth)) }
        return .opacity
    }
}

/// The part of a row below the folder row: row coordinates from `clipTop` down.
struct SidebarFolderRevealMask: Equatable {
    var clipTop: CGFloat
    var height: CGFloat

    /// No cut: the mask reaches the top of the content.
    static func none(for entry: SidebarListEntry) -> Self {
        SidebarFolderRevealMask(clipTop: -entry.top, height: entry.height)
    }
}

struct SidebarFolderRevealEffect: ViewModifier {
    var shift: CGFloat
    let mask: SidebarFolderRevealMask

    func body(content: Content) -> some View {
        content
            .offset(y: shift)
            .mask(alignment: .topLeading) {
                Rectangle()
                    .frame(height: max(0, mask.height - mask.clipTop))
                    .offset(y: mask.clipTop)
            }
    }
}

/// Places each list entry at its fixed top (`SidebarListEntryTop`), full width. Its size is given,
/// never measured, and it reports no alignment guides of its own: a `ZStack` of offset rows made
/// every scroll step and every frame of the Space slide walk the alignment guides of all built rows
/// (B99 profile), because the scroll view and the views around the content ask for them.
struct SidebarListRowsLayout: Layout {
    var size: CGSize

    /// Whether content of the new height still reaches the scroll offset. When it does not, AppKit
    /// moves the offset in one frame and rows sliding from their old places would jump, so that
    /// change is drawn without animation. B167.
    static func keepsScrollOffset(_ metrics: SidebarScrollMetrics, newContentHeight: CGFloat) -> Bool {
        metrics.offset <= max(0, newContentHeight - metrics.viewportHeight) + 0.5
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + subview[SidebarListEntryTop.self]),
                          anchor: .topLeading, proposal: ProposedViewSize(width: size.width, height: nil))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// Top edge of a list entry in content coordinates, for `SidebarListRowsLayout`.
struct SidebarListEntryTop: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// A view of a known, fixed size: proposes exactly that size to its content, never measures it,
/// and reports no alignment guides. Wrapping a list row in it keeps SwiftUI's geometry queries
/// (hover regions, scroll geometry) from re-measuring the row's text on every frame (B99).
struct SidebarFixedFrameLayout: Layout {
    var size: CGSize

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { size }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(size))
        }
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
}

/// Which content-space band of the list has views: the viewport widened by `margin` on each side,
/// its edges snapped to `step`. Published only when the band changes.
///
/// The step is one row pitch: each scroll frame then builds and drops about the rows it uncovers,
/// instead of a burst of ten rows every few frames (a 400 pt step made those frames miss their
/// deadline during a fast fling, B99 profile). The margin keeps rows ready well beyond the edge.
@MainActor
final class SidebarListWindow: ObservableObject {
    /// Band edges snap to this many points: one row pitch (41 pt row + 0 spacing).
    static let step: CGFloat = 41
    /// Rows built beyond each edge of the viewport. Own value: half a typical list height.
    static let margin: CGFloat = 300

    @Published private(set) var minY: CGFloat = 0
    @Published private(set) var maxY: CGFloat = 1_200

    // The latest folder open / close of this list (B176). Plain records, read by the rows' body.
    private var lastContentHeight: CGFloat?
    private var disclosureCount: Int?
    private var disclosureGrowth: CGFloat = 0
    private var disclosureEnds: CFTimeInterval = 0
    /// The latest `noteDisclosure` saw a new open / close.
    private(set) var disclosureIsNew = false
    /// The rows of the folder closed last, drawn while it animates (`SidebarFolderRevealPlan.closingRows`).
    private var closing: SidebarFolderRevealPlan.ClosingRows?

    /// The closing rows to draw with `growth` (from `noteDisclosure`): taken from `make` when the
    /// close is new, kept while it animates, nil otherwise.
    func closingRows(growth: CGFloat, make: () -> SidebarFolderRevealPlan.ClosingRows) -> SidebarFolderRevealPlan.ClosingRows? {
        if disclosureIsNew { closing = growth < 0 ? make() : nil }
        return growth < 0 ? closing : nil
    }
    /// How long a folder animation may run: the slower spring settles within this. Own value.
    static let disclosureWindow: CFTimeInterval = 0.5
    /// How far below the band rows stay built while an open pushes them down. Own value: more
    /// than a tall window's list.
    static let disclosureBandLimit: CGFloat = 1_400

    /// Records the content height of this update and returns how much the latest folder open
    /// (positive) or close (negative) changed it, while that animation may still run; else 0.
    func noteDisclosure(count: Int, contentHeight: CGFloat, now: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        defer { lastContentHeight = contentHeight }
        disclosureIsNew = false
        if let disclosureCount, count != disclosureCount {
            disclosureIsNew = true
            disclosureGrowth = contentHeight - (lastContentHeight ?? contentHeight)
            disclosureEnds = now + Self.disclosureWindow
        }
        disclosureCount = count
        return now < disclosureEnds ? disclosureGrowth : 0
    }

    func update(offset: CGFloat, viewportHeight: CGFloat) {
        let low = max(0, ((offset - Self.margin) / Self.step).rounded(.down) * Self.step)
        let high = ((offset + viewportHeight + Self.margin) / Self.step).rounded(.up) * Self.step
        if low != minY { minY = low }
        if high != maxY { maxY = high }
    }
}

/// The scroll-edge lines and the overlay scroller knob of one list: they follow the offset.
private struct SidebarListDecorations: View {
    let viewModel: SidebarViewModel
    /// Published only when a swipe starts or ends.
    @ObservedObject var spaceSwipe: SpaceSwipeState
    @ObservedObject var changes: SidebarSpacePageChanges
    /// Relays `scroll`'s changes while the page is shown: the offset is read from `scroll`.
    @ObservedObject var scrollChanges: SidebarSpacePageChanges
    let scroll: SidebarListScrollState
    let spaceID: UUID?
    let isSidebarHovered: Bool
    let layout: SidebarLayout
    @Environment(\.windowSurface) private var surface

    var body: some View {
        let contentFrame = scroll.contentFrame(for: spaceID)
        let viewport = scroll.viewportSize(for: spaceID)
        let edges = SidebarScrollEdges(contentFrame: contentFrame, viewportHeight: viewport.height)
        ZStack(alignment: .topLeading) {
            edgeLine(visible: edges.top)
            edgeLine(visible: edges.bottom)
                .offset(y: max(0, viewport.height - SidebarLocalTokens.scrollEdgeLineThickness))
            scroller(contentFrame: contentFrame, viewport: viewport)
        }
        .frame(width: layout.width, height: viewport.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// Thin overlay knob at the list's right edge, shown while the pointer is over the sidebar
    /// and the list overflows. [04 §sidebar] observed ("thin, visible on hover"); the knob's size,
    /// ink and fade are placeholders (`Metrics.SidebarScroller`, `Motion.sidebarScrollerFade`, unknown). It only indicates the
    /// position: scrolling stays with the wheel / trackpad.
    @ViewBuilder
    private func scroller(contentFrame: CGRect, viewport: CGSize) -> some View {
        let knob = SidebarScrollerGeometry.knobFrame(contentFrame: contentFrame, viewport: viewport)
        let palette = viewModel.palette(forSpace: spaceID)
        let ink: Color = palette.isDark || palette.usesLightInk ? .white : .black
        // Hidden while a two-finger swipe moves the pages (B184, issue #1: Arc hides it as the
        // swipe starts).
        let visible = isSidebarHovered && knob != nil && !spaceSwipe.isActive
        Capsule(style: .continuous)
            .fill(ink.opacity(Metrics.SidebarScroller.knobOpacity))
            .frame(width: knob?.width ?? 0, height: knob?.height ?? 0)
            .offset(x: knob?.minX ?? 0, y: knob?.minY ?? 0)
            .opacity(visible ? 1 : 0)
            .animation(ShellMotion.sidebarScrollerFade, value: visible)
            .accessibilityHidden(true)
    }

    /// Full-width 1 pt line at the list's top or bottom edge while rows are scrolled under it.
    /// Round-1 comparison (B32) observed: lines at y 181 and 934 across the sidebar, window + 5 %
    /// white on a light-ink window, in a scrolled list; shown only while scrolled (inferred).
    @ViewBuilder
    private func edgeLine(visible: Bool) -> some View {
        if visible {
            Rectangle()
                .fill(viewModel.palette(forSpace: spaceID).windowFills(on: surface).scrollEdgeLine.swiftUI)
                .frame(width: layout.width, height: SidebarLocalTokens.scrollEdgeLineThickness)
                .accessibilityHidden(true)
        }
    }
}

/// Everything over the sidebar that sits at a list row: the drop insertion line, the ↓ / ↑ jump
/// button and the folder quick list's anchor. They follow the scroll offset, so they observe
/// `SidebarListScrollState`; the rest of the sidebar does not.
struct SidebarListOverlays: View {
    @ObservedObject var viewModel: SidebarViewModel
    @ObservedObject var scroll: SidebarListScrollState
    let layout: SidebarLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            dropIndicator
            selectionJumpButton
            folderQuickList
        }
        .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
    }

    /// The single insertion line of the current drop target, clipped to the list. [06 §15.2] observed.
    @ViewBuilder
    private var dropIndicator: some View {
        if let target = viewModel.dropTarget {
            let geometry = scroll.dropGeometry(viewModel: viewModel, layout: layout)
            let contentTrailing = layout.width - layout.horizontalInset - SidebarLocalTokens.dropIndicatorTrailingInset
            if let line = SidebarDropIndicatorLine.make(for: target, in: geometry, contentTrailing: contentTrailing),
               geometry.list.isNull || (line.y >= geometry.list.minY - 1 && line.y <= geometry.list.maxY + 1) {
                SidebarDropIndicatorView(line: line, color: viewModel.palette.dropIndicatorColor.swiftUI)
            }
        }
    }

    /// The round ↓ / ↑ button at the bottom / top middle of the list while the selected row is
    /// scrolled out of view; a click scrolls back to it. [06 §15.8] observed (white round button,
    /// arrow toward the selection); size, inset and the click behavior are inferred. B76.
    @ViewBuilder
    private var selectionJumpButton: some View {
        let viewport = scroll.listViewport
        let rowFrame = viewModel.selectedListRowID.flatMap { scroll.rowFrame(of: $0, viewModel: viewModel, layout: layout) }
        if viewModel.draggingItem == nil,
           let direction = SidebarSelectionJump.direction(rowFrame: rowFrame, viewport: viewport, fill: layout.rowFillFrame),
           let rowFrame {
            let size = SidebarSelectionJump.buttonSize
            Button {
                viewModel.revealSelectedRow(rowFrame: rowFrame, viewport: viewport)
            } label: {
                Image(systemName: direction == .down ? "arrow.down" : "arrow.up")
                    .font(.system(size: SidebarSelectionJump.glyphSize, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(SidebarLocalTokens.jumpButtonInkOpacity))
                    .frame(width: size, height: size)
                    .background(Circle().fill(Color.white))
                    .panelShadow(SidebarLocalTokens.jumpButtonShadow)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .position(SidebarSelectionJump.buttonCenter(direction: direction, viewport: viewport))
            .accessibilityLabel(direction == .down ? "Scroll down to the selected tab" : "Scroll up to the selected tab")
            .accessibilityIdentifier("openarc.sidebar.selectionJump")
        }
    }

    /// The hovered folder's quick list, in a bubble right of its row. [06 §14] observed. B76.
    private var folderQuickList: some View {
        let id = viewModel.quickListFolderID
        let fill = layout.rowFillFrame
        let anchor = id.flatMap { scroll.rowFrame(of: $0, viewModel: viewModel, layout: layout) }.map {
            CGRect(x: fill.minX, y: $0.minY + fill.minY, width: fill.width, height: fill.height)
        }
        let palette = viewModel.palette
        return FolderQuickListPresenter(viewModel: viewModel, folderID: id, anchor: anchor,
                                        rowCount: id.map { viewModel.quickListRows(folderID: $0).count } ?? 0,
                                        tint: palette.floatingPanelBackground, isDark: palette.isDark)
            .frame(width: layout.width, height: layout.windowSize.height)
            .allowsHitTesting(false)
    }
}

/// Pure geometry of the list's overlay scroller. [04 §sidebar] observed (thin, on hover); the
/// sizes come from `Metrics.SidebarScroller` (unknown placeholders).
enum SidebarScrollerGeometry {
    /// The knob in the viewport's space, or nil while the content fits (nothing to scroll).
    /// `contentFrame` is the content in the viewport's space (its minY is minus the offset).
    static func knobFrame(contentFrame: CGRect, viewport: CGSize) -> CGRect? {
        let m = Metrics.SidebarScroller.self
        let contentHeight = contentFrame.height, viewportHeight = viewport.height
        guard viewportHeight > 0, contentHeight > viewportHeight + 0.5 else { return nil }
        let inset = CGFloat(m.trackInset)
        let track = max(0, viewportHeight - 2 * inset)
        let length = min(track, max(CGFloat(m.minKnobLength), track * viewportHeight / contentHeight))
        let maxOffset = contentHeight - viewportHeight
        let progress = min(max(-contentFrame.minY / maxOffset, 0), 1)
        let width = CGFloat(m.knobWidth)
        return CGRect(x: viewport.width - CGFloat(m.trailingInset) - width,
                      y: inset + (track - length) * progress, width: width, height: length)
    }
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
    /// The Space of the list: each kept Space page has its own scroll view (B101).
    let spaceID: UUID?
    let scroll: SidebarListScrollState
    /// Called with the scroll metrics whenever the clip view scrolls or resizes.
    var onScroll: @MainActor (SidebarScrollMetrics) -> Void = { _ in }

    func makeCoordinator() -> SidebarNSScrollHook { SidebarNSScrollHook() }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        let hook = context.coordinator
        hook.onScroll = onScroll
        if let spaceID, let offset = viewModel.listScrollOffsets[spaceID], offset > 0 {
            hook.pendingRestoreOffset = offset
        }
        hook.onOffset = { [weak viewModel] offset in
            guard let spaceID else { return }
            viewModel?.listScrollOffsets[spaceID] = offset
        }
        view.onMoveToWindow = { [weak hook] probe in
            guard let hook, let scrollView = probe.enclosingScrollView else { return }
            hook.scrollView = scrollView
        }
        register(hook)
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        let hook = context.coordinator
        hook.onScroll = onScroll
        if hook.scrollView == nil { hook.scrollView = nsView.enclosingScrollView }
        register(hook)
    }

    /// Records the hook as its Space's list; the shown Space's list is the one the view model
    /// scrolls (drag auto-scroll, the jump button).
    private func register(_ hook: SidebarNSScrollHook) {
        scroll.setScrollHook(hook, for: spaceID)
        if spaceID == viewModel.selectedSpaceID { viewModel.listScroller = hook }
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
    weak var scrollView: NSScrollView? {
        didSet {
            guard scrollView !== oldValue else { return }
            observe()
        }
    }
    /// Reports scrolling and resizing of the clip view (bounds changes).
    var onScroll: @MainActor (SidebarScrollMetrics) -> Void = { _ in }
    /// Records the offset after each scroll (`SidebarViewModel.listScrollOffsets`).
    var onOffset: @MainActor (CGFloat) -> Void = { _ in }
    /// An offset to return to once the content is tall enough (a rebuilt list, B162). Until then
    /// the list's own offsets are not recorded, so its first report at the top does not overwrite it.
    var pendingRestoreOffset: CGFloat?
    private var restoreAttempts = 0
    private var observation: NSObjectProtocol?

    private func observe() {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
        guard let clip = scrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.report() }
        }
        report()
    }

    private func report() {
        guard let metrics else { return }
        if let target = pendingRestoreOffset {
            let reachable = metrics.contentHeight - metrics.viewportHeight
            restoreAttempts += 1
            if metrics.viewportHeight > 0, reachable >= target - 0.5 || restoreAttempts > 20 {
                pendingRestoreOffset = nil
                let offset = max(0, min(target, reachable))
                if abs(metrics.offset - offset) > 0.5 {
                    // The scroll reports again with the restored offset.
                    scroll(toOffset: offset)
                    return
                }
            }
        }
        if pendingRestoreOffset == nil { onOffset(metrics.offset) }
        onScroll(metrics)
    }

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

    static var buttonSize: CGFloat { SidebarLocalTokens.jumpButtonSize }
    static var glyphSize: CGFloat { SidebarLocalTokens.jumpButtonGlyphSize }
    /// Gap between the button and the list edge.
    static var edgeInset: CGFloat { SidebarLocalTokens.jumpButtonEdgeInset }

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

// MARK: - Trackpad swipe between Spaces (B76, B184)

/// Turns the scroll events of one trackpad gesture into an interactive Space swipe. [05 §window
/// hierarchy] observed: Spaces are horizontal pages switched by a swipe or the dock. Issue #1
/// (B184): the pages follow the fingers while the swipe runs. The lock distance and the "mostly
/// horizontal" rule are inferred. Pure, for tests.
struct SidebarSwipeTracker {
    /// Travel (points, either axis) before the gesture picks its axis.
    static let lockDistance: CGFloat = 6
    /// The gesture must be this many times more horizontal than vertical to page (keeps list
    /// scrolling from switching Spaces).
    static let dominance: CGFloat = 1.5
    /// Velocity is measured over the events of this last stretch of the gesture (seconds).
    static let velocityWindow: TimeInterval = 0.08

    enum Phase { case began, changed, ended, cancelled, other }

    enum Output: Equatable {
        /// The gesture became a horizontal swipe.
        case start
        /// The content moved by `offset` points since the gesture began (negative: to the left,
        /// toward the next Space).
        case move(CGFloat)
        /// The fingers lifted; `velocity` in points per second, same sign convention.
        case end(offset: CGFloat, velocity: CGFloat)
        /// The system cancelled the gesture.
        case cancel
    }

    private enum State { case idle, deciding, horizontal, vertical }
    private var state = State.idle
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var samples: [(time: TimeInterval, x: CGFloat)] = []

    /// A horizontal swipe is running: its events belong to it, not to the list.
    var isTracking: Bool { state == .horizontal }

    /// Feeds one event of the gesture (`deltaX`/`deltaY` as AppKit's `scrollingDelta`, content
    /// direction; `time` the event's timestamp).
    mutating func feed(phase: Phase, deltaX: CGFloat, deltaY: CGFloat, time: TimeInterval) -> [Output] {
        switch phase {
        case .began:
            state = .deciding
            dx = 0; dy = 0; samples = []
            return accumulate(deltaX, deltaY, time)
        case .changed:
            guard state == .deciding || state == .horizontal else { return [] }
            return accumulate(deltaX, deltaY, time)
        case .ended:
            defer { state = .idle }
            guard state == .horizontal else { return [] }
            return [.end(offset: dx, velocity: velocity())]
        case .cancelled:
            defer { state = .idle }
            return state == .horizontal ? [.cancel] : []
        case .other:
            return []
        }
    }

    private mutating func accumulate(_ deltaX: CGFloat, _ deltaY: CGFloat, _ time: TimeInterval) -> [Output] {
        dx += deltaX
        dy += deltaY
        samples.append((time, dx))
        samples.removeAll { time - $0.time > Self.velocityWindow }
        switch state {
        case .deciding:
            guard max(abs(dx), abs(dy)) >= Self.lockDistance else { return [] }
            guard abs(dx) >= Self.dominance * abs(dy) else {
                state = .vertical
                return []
            }
            state = .horizontal
            return [.start, .move(dx)]
        case .horizontal:
            return [.move(dx)]
        case .idle, .vertical:
            return []
        }
    }

    private func velocity() -> CGFloat {
        guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
        return (last.x - first.x) / CGFloat(last.time - first.time)
    }
}

/// How an interactive Space swipe draws and ends (B184, issue #1). All values inferred: Arc's
/// swipe could not be sampled (it does not take synthetic gestures), so they follow how macOS
/// pages (half a page or a flick commits; a rubber band past the ends).
enum SpaceSwipe {
    /// Past the first or last Space the page moves this fraction of the finger travel.
    static let edgeResistance: CGFloat = 0.3
    /// Dragged this fraction of the page width, the swipe commits on release.
    static let commitFraction: CGFloat = 0.5
    /// A flick at least this fast (points per second) toward the neighbor commits, once it moved
    /// at least `flickMinimumOffset`.
    static let flickVelocity: CGFloat = 300
    static let flickMinimumOffset: CGFloat = 20

    /// The Space step the content travel points at: content to the left reveals the next Space.
    static func step(forOffset offset: CGFloat) -> Int { offset < 0 ? 1 : -1 }

    /// Where the shown page is drawn for a finger travel of `offset`: one page at most, resisted
    /// when there is no Space that way.
    static func displayedOffset(_ offset: CGFloat, width: CGFloat, hasNeighbor: Bool) -> CGFloat {
        guard hasNeighbor else { return offset * edgeResistance }
        return min(max(offset, -width), width)
    }

    /// Whether releasing at `offset` with `velocity` moves to the neighbor.
    static func commits(offset: CGFloat, velocity: CGFloat, width: CGFloat) -> Bool {
        guard offset != 0 else { return false }
        // A flick back toward the start cancels.
        if velocity != 0, (velocity < 0) != (offset < 0), abs(velocity) >= flickVelocity { return false }
        if abs(offset) >= width * commitFraction { return true }
        return abs(offset) >= flickMinimumOffset && abs(velocity) >= flickVelocity && (velocity < 0) == (offset < 0)
    }
}

/// Watches two-finger trackpad swipes over the sidebar (window-local event monitor) and drives the
/// interactive Space swipe (B184). Events of a horizontal swipe are consumed, so the list does not
/// scroll under it; every other event passes through untouched. Momentum events and mouse wheels
/// (no gesture phase) are ignored.
struct SidebarSwipeMonitor: NSViewRepresentable {
    let viewModel: SidebarViewModel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.viewModel = viewModel
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.viewModel = viewModel
    }

    final class MonitorView: NSView {
        weak var viewModel: SidebarViewModel?
        private var tracker = SidebarSwipeTracker()
        private var isSwiping = false
        private var token: SwipeMonitorToken?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            token = nil
            guard window != nil else { return }
            let monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let phase = event.phase, momentum = event.momentumPhase, precise = event.hasPreciseScrollingDeltas
                let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY, time = event.timestamp
                let location = event.locationInWindow, number = event.windowNumber
                let consumed = MainActor.assumeIsolated {
                    self?.handle(phase: phase, momentum: momentum, precise: precise, dx: dx, dy: dy, time: time,
                                 location: location, windowNumber: number) ?? false
                }
                return consumed ? nil : event
            }
            token = monitor.map(SwipeMonitorToken.init)
        }

        /// Returns whether the event belongs to a running swipe.
        private func handle(phase: NSEvent.Phase, momentum: NSEvent.Phase, precise: Bool, dx: CGFloat, dy: CGFloat,
                            time: TimeInterval, location: NSPoint, windowNumber: Int) -> Bool {
            guard let window, windowNumber == window.windowNumber, precise, momentum.isEmpty, !phase.isEmpty else { return false }
            let mapped: SidebarSwipeTracker.Phase
            if phase.contains(.began) {
                // A gesture counts only when it starts over the sidebar.
                guard bounds.contains(convert(location, from: nil)) else { return false }
                mapped = .began
            } else if phase.contains(.changed) {
                mapped = .changed
            } else if phase.contains(.ended) {
                mapped = .ended
            } else if phase.contains(.cancelled) {
                mapped = .cancelled
            } else {
                mapped = .other
            }
            let wasTracking = tracker.isTracking
            for output in tracker.feed(phase: mapped, deltaX: dx, deltaY: dy, time: time) {
                apply(output)
            }
            return wasTracking || tracker.isTracking
        }

        private func apply(_ output: SidebarSwipeTracker.Output) {
            guard let viewModel else { return }
            switch output {
            case .start:
                isSwiping = viewModel.spaceSwipeBegan()
            case .move(let offset):
                if isSwiping { viewModel.spaceSwipeMoved(offset: offset) }
            case .end(let offset, let velocity):
                if isSwiping { viewModel.spaceSwipeEnded(offset: offset, velocity: velocity) }
                isSwiping = false
            case .cancel:
                if isSwiping { viewModel.spaceSwipeCancelled() }
                isSwiping = false
            }
        }
    }
}

/// Removes an `NSEvent` monitor when released.
private final class SwipeMonitorToken {
    private let monitor: Any
    init(_ monitor: Any) { self.monitor = monitor }
    deinit { NSEvent.removeMonitor(monitor) }
}
