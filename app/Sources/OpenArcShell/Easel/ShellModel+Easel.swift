import Foundation
import OpenArcModel

// Easel entry points of a window (plan B56): New Easel (⌃⇧E, File ▸ New Easel) and opening one
// from Library ▸ Easels. [02] ⌃⇧E observed; [01 §File] New Easel observed; [06 §4] observed: the
// Easel is a pinned row with an Easel icon.

extension ShellModel {
    /// Whether the window can make an Easel: a normal window with a Space. An incognito window
    /// keeps nothing, so it offers no Easels. inferred.
    public var canCreateEasel: Bool { !isIncognito && selectedSpaceID != nil }

    /// New Easel: creates an "Untitled Easel" with its pinned row in the current Space, selects it
    /// and leaves the Library. Returns the Easel's id.
    @discardableResult
    public func newEasel() -> UUID? {
        guard canCreateEasel, let spaceID = selectedSpaceID else { return nil }
        let easelID = controller.makeID(), tabID = controller.makeID(), now = controller.now()
        do {
            try controller.mutate(origin: sidebar) {
                try TreeOps.createEasel($0, id: easelID, tabID: tabID, spaceID: spaceID, now: now)
            }
        } catch {
            return nil
        }
        if isCommandBarPresented { dismissCommandBar() }
        library.exit()
        sidebar.selectTab(tabID)
        return easelID
    }

    /// Shows an Easel (see `LibraryModel.openEasel`).
    @discardableResult
    public func openEasel(_ easelID: UUID) -> UUID? {
        guard !isIncognito else { return nil }
        return library.openEasel(easelID)
    }
}

extension SidebarViewModel {
    /// The Easel the selected tab shows, if live: the web panel shows its canvas and the URL box
    /// shows the Share button. [06 §4, §9] observed.
    var selectedEaselID: UUID? {
        guard let id = selectedTabID, let easelID = workspace.easelID(ofTab: id), workspace.liveEasel(easelID) != nil else { return nil }
        return easelID
    }

    /// Whether a row shows an Easel (it gets the Easel icon). [06 §4] observed.
    func isEaselRow(_ tabID: UUID) -> Bool { workspace.easelID(ofTab: tabID) != nil }
}

extension LibraryModel {
    /// Shows an Easel: its row in the current Space if there is one, else a row in another Space
    /// (switching to it), else a new pinned row in the current Space. Leaves the Library. Returns
    /// the row's tab id. inferred: [06 §8, §11] show the list, not what a click does.
    @discardableResult
    public func openEasel(_ easelID: UUID) -> UUID? {
        let workspace = sidebar.workspace
        guard !sidebar.isIncognito, workspace.liveEasel(easelID) != nil else { return nil }
        let rows = workspace.tabs(showingEasel: easelID)
        let tabID: UUID
        if let row = rows.first(where: { $0.location.spaceID == sidebar.selectedSpaceID }) ?? rows.first(where: { $0.location.spaceID != nil }) {
            tabID = row.id
            if let spaceID = row.location.spaceID, spaceID != sidebar.selectedSpaceID { sidebar.selectSpace(spaceID) }
        } else {
            guard let spaceID = sidebar.selectedSpaceID else { return nil }
            let controller = sidebar.controller
            tabID = controller.makeID()
            let now = controller.now()
            do {
                try controller.mutate(origin: sidebar) {
                    try TreeOps.addEaselRow($0, easelID: easelID, tabID: tabID, spaceID: spaceID, now: now)
                }
            } catch {
                return nil
            }
        }
        exit()
        sidebar.selectTab(tabID)
        return tabID
    }

    /// Deletes an Easel (the card's hover ✕). inferred: [06 §12] only saw that the delete entry
    /// is not in the context menu.
    public func deleteEasel(_ easelID: UUID) {
        let controller = sidebar.controller, now = controller.now()
        try? controller.mutate(origin: sidebar) { try TreeOps.deleteEasel($0, id: easelID, now: now) }
    }

    /// Library ▸ Easels: live Easels whose title contains the search text (case and diacritics
    /// ignored), newest first. [06 §8] observed ("Search Easels…" field, cards with icon + title).
    public var easelResults: [Easel] {
        let query = query(for: .easels).trimmingCharacters(in: .whitespacesAndNewlines)
        let all = sidebar.workspace.liveEaselsNewestFirst
        guard !query.isEmpty else { return all }
        return all.filter { $0.displayTitle.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
