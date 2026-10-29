import Foundation
import OpenArcModel
import OpenArcDesign

// What the sidebar's fixed blocks (top bar, URL box, favorites, dock) draw, as plain values (B104).
// The sidebar computes them on each of its updates and passes them to Equatable views, so a change
// of the view model re-evaluates only the blocks whose values changed: a Space switch redraws the
// dock's current item and, when the theme differs, the blocks' colors, but no longer every block.

extension SidebarViewModel {
    /// What the top bar's buttons show.
    var topBarState: SidebarTopBarView.State {
        SidebarTopBarView.State(palette: palette, canGoBack: canGoBack, canGoForward: canGoForward,
                                reloadMode: reloadMode, hasSelectedTab: selectedTabID != nil)
    }

    /// What the URL box shows.
    var urlBoxState: SidebarURLBoxView.State {
        SidebarURLBoxView.State(palette: palette, content: urlBoxContent, showsInsecureLock: urlBoxShowsInsecureLock,
                                selectedTabID: selectedTabID,
                                translationLabel: selectedLiveState.flatMap { TranslationEntryLabel.make($0.translation) })
    }

    /// What the favorites block shows for `favorites` (the selected Space's profile's).
    func favoritesState(_ favorites: [TabNode]) -> SidebarFavoritesView.State {
        let palette = self.palette
        var gap: Int?
        if case .favoriteGap(let index)? = dropTarget { gap = index }
        let tooltip = favoriteTooltipTabID
        return SidebarFavoritesView.State(
            palette: palette,
            cells: favorites.map { tab in
                SidebarFavoriteCell.State(tab: tab, palette: palette, isSelected: isSelected(tab.id),
                                          favicon: tab.icon == nil ? faviconImage(for: tab.id) : nil,
                                          isPeekSource: linkPeekSourceTabID == tab.id, unreadCount: unreadCount(tab.id))
            },
            showsEmptyCard: favorites.isEmpty && showsFavoritesEmptyCard,
            dropGap: gap,
            draggedIndex: gap == nil ? nil : draggedFavoriteIndex,
            tooltipTabID: tooltip,
            tooltipDetail: tooltip.flatMap { favoriteHoverTip($0) }
        )
    }

    /// What the dock shows.
    var dockState: SidebarDockView.State {
        var dropSpaceID: UUID?
        if case .dockSpace(let id)? = dropTarget { dropSpaceID = id }
        return SidebarDockView.State(palette: palette, spaces: dockSpaces, selectedSpaceID: selectedSpaceID,
                                     isIncognito: isIncognito, dropSpaceID: dropSpaceID)
    }
}
