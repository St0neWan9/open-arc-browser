import Foundation
import OpenArcModel
import OpenArcDesign

// The window's side of the web toolbar (plan B43): which bars show, what they show, and what their
// buttons do. Geometry lives in `WebToolbarLayout`, the settings in `WebToolbarSettings`.
//
// Spec sources (docs/arc-spec/):
//   [06 §17.1] observed: View ▸ Show Toolbar (⇧⌘D) is global; the address and back / forward /
//              reload leave the sidebar.
//   [06 §17.3] observed: the domain opens the centered command bar with the full URL selected (as
//              ⌘L); copy link copies the full URL and shows "Copied Current URL"; the lock and the
//              site controls button open the Site Control Center; the split menu adds a split on
//              any of the four sides.

/// Which way the split menu adds the new pane. [06 §17.3] observed items and order.
public enum WebToolbarSplitPlacement: String, CaseIterable, Sendable {
    case right, left, top, bottom

    public var title: String {
        switch self {
        case .right: return "Add Right Split"
        case .left: return "Add Left Split"
        case .top: return "Add Top Split"
        case .bottom: return "Add Bottom Split"
        }
    }

    /// Small icon left of each item ([06 §17.3] observed "with a small icon"; ours are SF Symbols).
    var symbol: String {
        switch self {
        case .right: return "rectangle.righthalf.inset.filled"
        case .left: return "rectangle.lefthalf.inset.filled"
        case .top: return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        }
    }

    var axis: SplitAxis { self == .right || self == .left ? .horizontal : .vertical }
    var side: SplitSide { self == .right || self == .bottom ? .trailing : .leading }
}

extension ShellModel {
    /// The app-wide toolbar settings.
    public var webToolbar: WebToolbarSettings { controller.webToolbar }

    /// View ▸ Show Toolbar is on. The Library keeps its own layout (inferred: not captured).
    public var isWebToolbarShown: Bool { webToolbar.isShown }

    /// View ▸ Show Toolbar / Hide Toolbar (⇧⌘D). Every window follows. [06 §17.1] observed.
    public func toggleWebToolbar() { webToolbar.toggle() }

    /// What the bar of `tabID` (nil: the empty panel) shows.
    public func webToolbarState(for tabID: UUID?) -> WebToolbarState {
        guard let tabID else { return WebToolbarState(tabID: nil, url: nil) }
        let live = sidebar.liveState(for: tabID)
        return WebToolbarState(
            tabID: tabID,
            url: sidebar.linkURL(for: tabID),
            canGoBack: live?.canGoBack ?? false,
            canGoForward: live?.canGoForward ?? false,
            isLoading: live?.isLoading ?? false,
            isActive: selectedTabID == tabID
        )
    }

    /// The buttons of a bar. With the sidebar hidden the bar at the panel's top-left corner leads
    /// with the show-sidebar button. [06 §17.2] observed for the single page.
    func webToolbarItems(role: WebToolbarRole, isTopLeading: Bool = true) -> WebToolbarItems {
        WebToolbarItems.make(role: role, isToolbarShown: isWebToolbarShown,
                             showsSidebarButton: isTopLeading && !isSidebarVisible && !spaceFlow.isCreating)
    }

    /// Where the bar of `tabID` takes its background (plan B45, [06 §17.4] observed, E18): the
    /// page's top-right color from its last finished load; the Space-mode neutral when that sample
    /// hit a classic scrollbar (observed) or none arrived yet (inferred); transparent when the
    /// panel or pane shows no page (observed: a new empty split pane, an empty panel).
    func webToolbarBackgroundSource(for tabID: UUID?) -> WebToolbarBackgroundSource {
        guard let tabID, sidebar.linkURL(for: tabID) != nil else { return .transparent }
        switch sidebar.liveState(for: tabID)?.pageTopColor {
        case .color(let color): return .page(color)
        case .scrollbar, nil: return .neutral
        }
    }

    /// The bar of `tabID`: background from its own page (each split pane samples its own,
    /// [06 §17.4] observed), ink by the bar's luminance.
    func webToolbarColors(for tabID: UUID?) -> WebToolbarColors {
        ThemeDerivation.webToolbarColors(appearance: windowPalette.appearance,
                                         source: webToolbarBackgroundSource(for: tabID),
                                         panelBackground: windowPalette.webPanelBackground)
    }

    // MARK: Actions

    /// Back in the bar's tab (a pane's own history in a split).
    func webToolbarGoBack(_ tabID: UUID?) {
        guard let tabID else { return }
        if hasActiveSplit { paneGoBack(tabID) } else { sidebar.goBack() }
    }

    func webToolbarGoForward(_ tabID: UUID?) {
        guard let tabID else { return }
        if hasActiveSplit { paneGoForward(tabID) } else { sidebar.goForward() }
    }

    /// Reload, or stop while loading. [06 §17.2] observed.
    func webToolbarReload(_ tabID: UUID?) {
        guard let tabID else { return }
        focusPane(tabID)
        sidebar.reloadOrStop()
    }

    /// The domain: the centered command bar with the full URL selected, like ⌘L. [06 §17.3]
    /// observed for the single page. A split pane keeps its own command bar in the pane ([06 §5],
    /// B18).
    func webToolbarOpenAddress(_ tabID: UUID?) {
        if hasActiveSplit, let tabID {
            paneOpenAddressBar(tabID)
        } else {
            presentCommandBar(.currentTab)
        }
    }

    /// Copies the tab's full URL (with its scheme). [06 §17.3] observed. Returns whether anything
    /// was copied, so the view shows "Copied Current URL".
    @discardableResult
    func webToolbarCopyLink(_ tabID: UUID?) -> Bool {
        guard let tabID, let url = sidebar.linkURL(for: tabID) else { return false }
        siteControls.pasteboard.writeURL(url)
        return true
    }

    /// The lock and the site controls button open the Site Control Center for the bar's tab.
    /// [06 §17.3] observed.
    func webToolbarShowSiteControls(_ tabID: UUID?) {
        guard let tabID else { return }
        focusPane(tabID)
        if siteControls.isPresented { siteControls.close(.action) } else { siteControls.present() }
    }

    /// Add Right / Left / Top / Bottom Split: the new empty pane goes on that side of the tab and
    /// takes the command bar, as ⌃⇧= does. [06 §17.3] observed items; the rest follows [06 §5].
    public func addSplit(_ placement: WebToolbarSplitPlacement, beside tabID: UUID? = nil) {
        if let tabID { focusPane(tabID) }
        isSplitExpanded = false
        sidebar.addSplitView(axis: placement.axis, side: placement.side)
    }

    /// The pane's ✕. [06 §17.6] observed.
    func webToolbarClosePane(_ tabID: UUID?) {
        guard let tabID else { return }
        paneClose(tabID)
    }

    /// The show-sidebar button: the sidebar comes back pinned. [06 §17.2] observed.
    func webToolbarShowSidebar() {
        if !isSidebarVisible { toggleSidebar() }
    }
}
