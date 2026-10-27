import Foundation
import OpenArcModel
import OpenArcEngine

// Pure derivations that turn `WorkspaceState` and live engine state into what the views draw.

/// Which area of the list a row belongs to.
enum SidebarArea: Hashable {
    case pinned
    case today
}

/// Tabs that share one live `SplitLayout`, shown as ONE row. [06 §5] observed: "the two split tabs
/// are treated as one group in the sidebar". Nothing else about the group is specified, so the
/// look and the rules around it are local choices (labeled where they are made).
struct SidebarSplitGroup: Hashable {
    /// Id of the `SplitLayout`. It is also the id of the row (frames, drag item, selection).
    var layoutID: UUID
    /// Members that appear in the list, in pane order (the order the panes are laid out in).
    /// Members that are favorites or hidden inside a collapsed folder are not part of the row. inferred.
    var members: [TabNode]
    /// Member ids in sidebar order. The first one is where the row sits.
    var sidebarOrder: [UUID]

    var id: UUID { layoutID }

    /// The member whose position the row takes: the first one by sidebar order. [06 §5] gives no
    /// position rule; this follows the task rule "position of the first member". inferred.
    var anchorID: UUID { sidebarOrder[0] }

    func contains(_ tabID: UUID) -> Bool { sidebarOrder.contains(tabID) }

    /// Groups the visible rows of `pinned` and `today` into split-group rows. A layout becomes a
    /// group only when at least two of its tabs are rows; otherwise its tabs stay plain rows.
    /// Rows keep their depth and area from the first member.
    static func apply(
        workspace: WorkspaceState,
        pinned: inout [SidebarItemModel],
        today: inout [SidebarItemModel]
    ) {
        let layouts = workspace.splits.values
            .filter { !$0.meta.isTombstone && $0.root.tabIDs.count > 1 }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !layouts.isEmpty else { return }

        // A tab belongs to at most one layout; on conflicting data the smaller layout id wins.
        var layoutOfTab: [UUID: SplitLayout] = [:]
        for layout in layouts {
            for tabID in layout.root.tabIDs where layoutOfTab[tabID] == nil { layoutOfTab[tabID] = layout }
        }

        // Pass 1: visible member ids per layout, in sidebar order.
        var visible: [UUID: [UUID]] = [:]
        for item in pinned + today {
            guard case .tab(let tab) = item.kind, let layout = layoutOfTab[tab.id] else { continue }
            visible[layout.id, default: []].append(tab.id)
        }

        // Pass 2: replace the first member by the group row, drop the other members.
        var emitted: Set<UUID> = []
        func transform(_ items: [SidebarItemModel]) -> [SidebarItemModel] {
            var result: [SidebarItemModel] = []
            for item in items {
                guard case .tab(let tab) = item.kind, let layout = layoutOfTab[tab.id],
                      let order = visible[layout.id], order.count > 1 else {
                    result.append(item)
                    continue
                }
                guard emitted.insert(layout.id).inserted else { continue }
                let paneOrder = layout.root.tabIDs.filter { order.contains($0) }
                let members = paneOrder.compactMap { workspace.tabs[$0] }
                let group = SidebarSplitGroup(layoutID: layout.id, members: members, sidebarOrder: order)
                result.append(SidebarItemModel(kind: .splitGroup(group), depth: item.depth, area: item.area))
            }
            return result
        }
        // The pinned area comes first in sidebar order, so it emits the row when it holds the first member.
        pinned = transform(pinned)
        today = transform(today)
    }
}

/// One visible row of the pinned area or the Today area.
struct SidebarItemModel: Identifiable, Hashable {
    enum Kind: Hashable {
        case folder(Folder)
        case tab(TabNode)
        case splitGroup(SidebarSplitGroup)
    }

    var kind: Kind
    /// Nesting depth (0 = top level). [06 §12] observed: tabs inside a folder are indented.
    var depth: Int
    var area: SidebarArea

    var id: UUID {
        switch kind {
        case .folder(let f): return f.id
        case .tab(let t): return t.id
        case .splitGroup(let g): return g.layoutID
        }
    }
}

/// Everything the list needs for one space, computed from the workspace.
struct SidebarSnapshot: Equatable {
    var spaceID: UUID?
    var favorites: [TabNode]
    /// Visible pinned rows, depth first; collapsed folders hide their children.
    var pinned: [SidebarItemModel]
    var today: [SidebarItemModel]
    /// Whether the pinned area has any content (folders or tabs, visible or collapsed).
    var hasPinnedContent: Bool

    /// The divider (with "↓ Clear") separates the pinned area from Today tabs: it shows only while
    /// Today has tabs. Every observation agrees: [06 §4] an empty Space shows only "+ New Tab"
    /// without a divider; after opening a site the tab is in Today below the divider; and the
    /// reference's accessibility tree (B31/B16, [07 §1] row structure) shows pinned rows followed
    /// directly by "+ New Tab" and no divider row when Today is empty, but pinned rows, the 17 pt
    /// divider, "+ New Tab", then the Today rows when it is not. inferred rule. (06 §4's "the divider
    /// only shows when the pinned area has content" contradicts the second example.)
    var showsDivider: Bool { !today.isEmpty }

    /// "↓ Clear" archives Today tabs, so it is only active when there are some. inferred.
    var canClear: Bool { !today.isEmpty }

    /// True for a space with no folders and no tabs (only "+ New Tab"). [06 §4] observed.
    var isEmptySpace: Bool { !hasPinnedContent && today.isEmpty }

    /// Kinds of all list entries, in order (for frame computation): pinned rows, the divider,
    /// "+ New Tab" at the top of Today, then the Today rows. [07 §4] observed (B31: New Tab sits
    /// directly below the divider).
    var listKinds: [SidebarListItemKind] {
        var kinds = [SidebarListItemKind](repeating: .row, count: pinned.count)
        if showsDivider { kinds.append(.divider) }
        kinds.append(.newTabRow)
        kinds += [SidebarListItemKind](repeating: .row, count: today.count)
        return kinds
    }

    /// What a tab-carrying row stands for in keyboard order and neighbor selection.
    enum TabEntry: Equatable {
        case tab(UUID)
        case group(SidebarSplitGroup)
    }

    /// Tab rows in sidebar order (pinned rows, then Today). A split group is ONE entry. inferred:
    /// [06 §5] only says the group is one unit in the sidebar, so ⌘1–9 and Next/Previous Tab count it once.
    var visibleTabEntries: [TabEntry] {
        (pinned + today).compactMap { item in
            switch item.kind {
            case .tab(let t): return .tab(t.id)
            case .splitGroup(let g): return .group(g)
            case .folder: return nil
            }
        }
    }

    /// Ids of the tabs in sidebar order, used for neighbor selection. A group contributes its
    /// anchor (first member by sidebar order).
    var visibleTabOrder: [UUID] {
        visibleTabEntries.map { entry in
            switch entry {
            case .tab(let id): return id
            case .group(let g): return g.anchorID
            }
        }
    }

    /// Whether the pinned rows right after folder `folderID` are its (visible) children.
    func hasVisibleChildren(folderID: UUID) -> Bool {
        guard let index = pinned.firstIndex(where: { $0.id == folderID }), index + 1 < pinned.count else { return false }
        return pinned[index + 1].depth > pinned[index].depth
    }

    /// The split-group row with this layout id, if shown.
    func splitGroup(layoutID: UUID) -> SidebarSplitGroup? {
        for item in pinned + today {
            if case .splitGroup(let g) = item.kind, g.layoutID == layoutID { return g }
        }
        return nil
    }

    /// The split-group row that holds this tab, if any.
    func splitGroup(containing tabID: UUID) -> SidebarSplitGroup? {
        for item in pinned + today {
            if case .splitGroup(let g) = item.kind, g.contains(tabID) { return g }
        }
        return nil
    }

    static func make(workspace: WorkspaceState, spaceID: UUID?, profileID: UUID?) -> SidebarSnapshot {
        guard let spaceID else {
            return SidebarSnapshot(spaceID: nil, favorites: [], pinned: [], today: [], hasPinnedContent: false)
        }
        let favorites = profileID.map { workspace.favorites(profileID: $0) } ?? []
        var pinned: [SidebarItemModel] = []
        func walk(_ folderID: UUID?, depth: Int) {
            for child in workspace.pinnedChildren(spaceID: spaceID, folderID: folderID) {
                switch child {
                case .folder(let f):
                    pinned.append(SidebarItemModel(kind: .folder(f), depth: depth, area: .pinned))
                    if f.isExpanded { walk(f.id, depth: depth + 1) }
                case .tab(let t):
                    pinned.append(SidebarItemModel(kind: .tab(t), depth: depth, area: .pinned))
                }
            }
        }
        walk(nil, depth: 0)
        let hasPinned = !workspace.pinnedChildren(spaceID: spaceID, folderID: nil).isEmpty
        var today = workspace.today(spaceID: spaceID).map { SidebarItemModel(kind: .tab($0), depth: 0, area: .today) }
        // [06 §5] observed: the tabs of a split are treated as one group in the sidebar.
        SidebarSplitGroup.apply(workspace: workspace, pinned: &pinned, today: &today)
        return SidebarSnapshot(spaceID: spaceID, favorites: favorites, pinned: pinned, today: today, hasPinnedContent: hasPinned)
    }
}

// MARK: - Live tab state

/// What the sidebar needs to know about a live engine tab.
struct SidebarTabLiveState: Equatable {
    var url: URL?
    var title: String = ""
    var isLoading = false
    var progress: Double = 1
    var favicon: Favicon?
    /// The page the favicon arrived for (committed URL then). The bridge keeps the old icon across a
    /// navigation until the new page's icon arrives, so `currentFavicon` checks the site. C9.
    var faviconPageURL: URL?
    var canGoBack = false
    var canGoForward = false
    var isCrashed = false
    /// Audio is playing (from `BrowserTabState.audio`).
    var isAudible = false
    var isMuted = false
    /// Last committed URL (Copy URL uses it, never a pending one). C7b.
    var committedURL: URL?
    var security: SecurityLevel = .none
    /// Page zoom factor (View ▸ Zoom items, Site Control Center zoom row). C7b.
    var zoomFactor: Double = 1
    var capture: CaptureState = []
    var isFullscreen = false
    var themeColor: RGBAColor?
    /// The page's top-right color from the last finished load; the web toolbar paints with it.
    /// [06 §17.4] observed. B45.
    var pageTopColor: PageTopColor?
    /// Page translation (B47): drives the URL box's second line and the translate bubble. [06 §19].
    var translation: PageTranslation = .unavailable
    /// Latest find-in-page result; nil when no search ran.
    var findResult: FindResult?

    init() {}

    init(snapshot: BrowserTabState) {
        url = snapshot.url
        title = snapshot.title
        isLoading = snapshot.loadState.isLoading
        progress = snapshot.loadState.progress
        favicon = snapshot.favicon
        faviconPageURL = snapshot.favicon == nil ? nil : (snapshot.committedURL ?? snapshot.url)
        canGoBack = snapshot.navigation.canGoBack
        canGoForward = snapshot.navigation.canGoForward
        isCrashed = snapshot.isCrashed
        isAudible = snapshot.audio.isAudible
        isMuted = snapshot.audio.isMuted
        committedURL = snapshot.committedURL
        security = snapshot.security
        zoomFactor = snapshot.zoomFactor
        capture = snapshot.capture
        isFullscreen = snapshot.isFullscreen
        themeColor = snapshot.themeColor
        pageTopColor = snapshot.pageTopColor
        translation = snapshot.translation
    }

    /// The favicon if it belongs to the site now shown (inferred: an icon of the previous site must
    /// not stay on the row after a cross-site navigation). C9.
    var currentFavicon: Favicon? {
        guard let favicon else { return nil }
        guard let page = committedURL ?? url, let iconPage = faviconPageURL else { return favicon }
        return FaviconCache.isSameSite(page, iconPage) ? favicon : nil
    }

    /// Pure reducer for engine events.
    mutating func apply(_ event: TabEvent) {
        switch event {
        case .snapshot(let s):
            self = SidebarTabLiveState(snapshot: s)
        case .urlChanged(let u):
            url = u
        case .titleChanged(let t):
            title = t
        case .loadStateChanged(let l):
            isLoading = l.isLoading
            progress = l.progress
            // A new load (the crash page's Reload) brings up a new renderer. No event reports
            // `BrowserTabState.isCrashed` going back to false, so the load start clears it. C9.
            if l.isLoading { isCrashed = false }
        case .faviconChanged(let f):
            favicon = f
            // `committedURLChanged` comes before `faviconChanged` in one update (TabChannel order).
            faviconPageURL = f == nil ? nil : (committedURL ?? url)
        case .audioStateChanged(let a):
            isAudible = a.isAudible
            isMuted = a.isMuted
        case .navigationStateChanged(let n):
            canGoBack = n.canGoBack
            canGoForward = n.canGoForward
        case .committedURLChanged(let u):
            committedURL = u
        case .securityChanged(let level):
            security = level
        case .zoomChanged(let factor):
            zoomFactor = factor
        case .captureStateChanged(let c):
            capture = c
        case .fullscreenChanged(let on):
            isFullscreen = on
        case .themeColorChanged(let color):
            themeColor = color
        case .pageTopColorChanged(let color):
            pageTopColor = color
        case .translationChanged(let value):
            translation = value
        case .findResultChanged(let result):
            findResult = result
        case .renderProcessGone:
            isCrashed = true
            isLoading = false
        case .closed:
            isLoading = false
            isAudible = false
        case .hoveredLinkChanged, .closeRequested, .activationRequested, .dialogCancelled:
            // Requests, handled by `WorkspaceController` / `DialogQueue`, not state.
            break
        }
    }
}

// MARK: - Top bar and URL box derivations

/// What the reload button shows. [06 §13] observed: "while loading the reload button becomes ✕
/// (stop); when loading finishes it becomes reload again".
enum SidebarReloadMode: Equatable {
    case reload
    case stop

    static func make(isLoading: Bool) -> SidebarReloadMode { isLoading ? .stop : .reload }
}

/// What the URL box displays. [06 §4] observed: only the domain is shown (not the full URL), and
/// secure pages use green text. [05 §window hierarchy] observed: the box is a placeholder that
/// opens the command bar rather than an in-place editor.
enum SidebarURLBoxContent: Equatable {
    case placeholder
    case domain(String, isSecure: Bool)

    static let placeholderText = "Search or Enter URL…"

    static func make(url: URL?) -> SidebarURLBoxContent {
        guard let url, let host = url.host, !host.isEmpty else { return .placeholder }
        return .domain(host, isSecure: url.scheme?.lowercased() == "https")
    }

    /// Plain http pages get the red struck-through lock before the domain, in the toolbar and in
    /// the sidebar URL box alike; https (and anything else) shows none. [06 §17.2, §17.7] observed.
    static func showsInsecureLock(url: URL?) -> Bool { url?.scheme?.lowercased() == "http" }
}
