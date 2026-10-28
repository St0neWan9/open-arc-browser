import Foundation
import Combine
import OpenArcModel
import OpenArcEngine

/// State and actions of the Library mode of the main window. Owned by `ShellModel`.
/// [06 §8] observed: the whole window switches to the Library view (rail, list column, web panel
/// on the right); "←" at the bottom of the rail goes back.
@MainActor
public final class LibraryModel: ObservableObject {
    /// The section on screen; nil means the window shows the normal browser view.
    @Published public private(set) var section: LibrarySection?
    /// Search text per section. Kept while the window lives, so coming back shows the same
    /// filter. inferred.
    @Published public var searchText: [LibrarySection: String] = [:]
    /// Whether the Media intro card ("Your Media in the Library") still shows. [06 §8] observed
    /// that it appears on the first visit. Dismissal is kept in the per-device UI state, so it
    /// stays hidden after a relaunch. inferred.
    @Published public private(set) var isMediaIntroVisible = true
    /// Section whose Filter panel is open (title + Done instead of the search field, chips above
    /// the list); nil when closed. [06 §8] Filter, observed.
    @Published public private(set) var filterPanelSection: LibrarySection?
    /// Chips switched on in the open Filter panel. Empty when the panel is closed.
    @Published public private(set) var filterSelection = LibraryFilterSelection()
    /// Space column being dragged by its handle on the Spaces board.
    @Published var draggingSpaceID: UUID?
    @Published public private(set) var lastError: Error?
    /// Library ▸ Downloads (C12): the current profile's downloads from the engine.
    public let downloads: LibraryDownloads
    /// Library ▸ Media (B57): screenshots, images and videos from the Mac's usual folders.
    public let media: LibraryMediaModel

    /// Calendar for the date groups of Archived Tabs. Settable so tests can fix the time zone.
    public var calendar: Calendar = .current

    let sidebar: SidebarViewModel
    private let now: () -> Date
    /// Last section shown, reopened by Open Library. inferred.
    private(set) var lastSection: LibrarySection?
    /// Called when a value kept in the per-device UI state changes (intro dismissed, last
    /// section), so the owner can save it. Set by `ShellModel`.
    var onPersistentStateChange: (() -> Void)?

    init(sidebar: SidebarViewModel, now: @escaping () -> Date) {
        self.sidebar = sidebar
        self.now = now
        self.downloads = LibraryDownloads(engine: sidebar.controller.dependencies.engine.downloads)
        self.media = LibraryMediaModel(folders: sidebar.controller.dependencies.mediaFolders)
    }

    public var isActive: Bool { section != nil }

    /// The injected clock (date groups).
    var currentDate: Date { now() }

    /// Applies the values saved at the last quit. Does not notify `onPersistentStateChange`.
    /// An unknown section name (e.g. from a newer build) is ignored.
    func restorePersistentState(mediaIntroDismissed: Bool, lastSectionName: String?) {
        isMediaIntroVisible = !mediaIntroDismissed
        updateMediaActivity()
        lastSection = lastSectionName.flatMap(LibrarySection.init(rawValue:))
    }

    // MARK: Entering and leaving

    /// Shows the Library on `section`.
    public func open(_ section: LibrarySection) {
        // Another section closes the Filter panel (it belongs to its section). inferred.
        if filterPanelSection != nil, filterPanelSection != section { resetFilter() }
        self.section = section
        if section == .downloads { observeDownloads() }
        updateMediaActivity()
        guard lastSection != section else { return }
        lastSection = section
        onPersistentStateChange?()
    }

    /// Open Library (⇧⌘L, Window ▸ Open Library…, command bar). The spec does not say which
    /// section it starts on: the last one shown, else the first rail item (Media). inferred.
    public func openDefault() {
        open(lastSection ?? LibrarySection.allCases[0])
    }

    /// "←" at the bottom of the rail. [06 §8] observed.
    public func exit() {
        section = nil
        draggingSpaceID = nil
        resetFilter()
        updateMediaActivity()
    }

    func query(for section: LibrarySection) -> String { searchText[section] ?? "" }

    /// The search text that filters `section`'s list. While the Filter panel replaces the search
    /// field, the hidden text does not apply (the user cannot see it). inferred.
    func activeQuery(for section: LibrarySection) -> String {
        filterPanelSection == section ? "" : query(for: section)
    }

    // MARK: Filter panel [06 §8] Filter

    public var isFilterPanelOpen: Bool { filterPanelSection != nil && filterPanelSection == section }

    /// Groups of chips for the section on screen. [06 §8] observed.
    public var filterGroups: [LibraryFilterGroup] {
        guard let section else { return [] }
        return LibraryFilter.groups(for: section, in: sidebar.workspace)
    }

    /// The "Filter" button: opens the panel on the section on screen, with no chip selected.
    public func openFilterPanel() {
        guard let section, section.hasFilterButton, filterPanelSection != section else { return }
        filterSelection = LibraryFilterSelection()
        filterPanelSection = section
    }

    /// Clicking a chip switches it on or off.
    public func toggleFilter(_ option: LibraryFilterOption) {
        guard isFilterPanelOpen else { return }
        if filterSelection.options.contains(option) {
            filterSelection.options.remove(option)
        } else {
            filterSelection.options.insert(option)
        }
        if section == .downloads { observeDownloads() }
    }

    /// "Done": closes the panel and brings the search field back. The chips are cleared, so the
    /// list is unfiltered again (inferred: the spec does not say whether the filter stays).
    public func closeFilterPanel() {
        resetFilter()
    }

    private func resetFilter() {
        guard filterPanelSection != nil || !filterSelection.isEmpty else { return }
        filterPanelSection = nil
        filterSelection = LibraryFilterSelection()
        if section == .downloads { observeDownloads() }
    }

    /// Downloads follow the current space's profile; with Profiles chips selected, the selected
    /// profiles instead (in chip order).
    private func observeDownloads() {
        let selected = filterGroups.flatMap { $0.chips }.compactMap { chip -> UUID? in
            guard case .profile(let id) = chip.option, filterSelection.options.contains(chip.option) else { return nil }
            return id
        }
        if selected.isEmpty {
            downloads.observe(profileID: sidebar.currentProfileID)
        } else {
            downloads.observe(profileIDs: selected)
        }
    }

    /// The Downloads list: search text, then the Filter panel's chips.
    public var visibleDownloads: [DownloadItem] {
        downloads.filtered(by: activeQuery(for: .downloads)).filter {
            filterSelection.allows(LibraryFilter.traits(of: $0))
        }
    }

    // MARK: Media

    /// ✕ on the intro card, or its "Show Media" button: both hide the card for good, and the page
    /// starts listing media (B57; the card is the opt-in, see LibraryMedia.swift). inferred.
    public func dismissMediaIntro() {
        guard isMediaIntroVisible else { return }
        isMediaIntroVisible = false
        updateMediaActivity()
        onPersistentStateChange?()
    }

    // MARK: Archived Tabs

    /// Archived tabs matching the Archived Tabs search, grouped by date. [06 §8] observed
    /// (search field, date groups, favicon + title + gray URL).
    public var archiveGroups: [LibraryArchiveGroup] {
        let selection = filterPanelSection == .archivedTabs ? filterSelection : LibraryFilterSelection()
        return LibraryArchive.groups(in: sidebar.workspace, query: activeQuery(for: .archivedTabs), filter: selection, now: now(), calendar: calendar)
    }

    /// Clicking a row restores the tab (`TreeOps.restoreFromArchive` through the sidebar) and
    /// leaves the Library on that tab. inferred: the spec shows the list, not the click.
    @discardableResult
    public func restore(_ itemID: UUID) -> UUID? {
        guard let id = sidebar.restoreArchived(itemID) else { return nil }
        exit()
        return id
    }

    // MARK: Spaces board

    /// One column per live space, in dock order. [06 §8] observed.
    /// Cached favicon of an archived item (C9): its favicon URL, else its site.
    func faviconImage(for item: ArchiveItem) -> Data? {
        sidebar.controller.faviconImage(iconURL: item.faviconURL, pageURL: item.url)
    }

    /// Favicon of a tab on the Spaces board (C9).
    func faviconImage(forTab id: UUID) -> Data? { sidebar.faviconImage(for: id) }

    var boardColumns: [LibraryBoardColumn] { LibraryBoard.columns(in: sidebar.workspace, systemAppearance: sidebar.controller.systemAppearance) }

    /// Moves a space with the column drag handle. [06 §8] observed (handle); `TreeOps.moveSpace`.
    @discardableResult
    public func moveSpace(_ id: UUID, to position: InsertPosition) -> Bool {
        do {
            let new = try TreeOps.moveSpace(sidebar.workspace, id: id, position: position, now: now())
            guard new != sidebar.workspace else { return true }
            sidebar.commitWorkspace(new)
            lastError = nil
            return true
        } catch {
            lastError = error
            return false
        }
    }

    /// Drop of the dragged column on `target` at `locationX` inside it.
    @discardableResult
    func dropDraggedSpace(on target: UUID, locationX: CGFloat, columnWidth: CGFloat) -> Bool {
        defer { draggingSpaceID = nil }
        guard let dragged = draggingSpaceID,
              let position = LibraryBoard.dropPosition(dragged: dragged, target: target, locationX: locationX, columnWidth: columnWidth)
        else { return false }
        return moveSpace(dragged, to: position)
    }
}
