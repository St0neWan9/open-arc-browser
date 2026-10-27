import Foundation

// Tree operations for Easels (plan B56). Same rules as `TreeOps`: pure, `now` and new ids come
// from the caller, only the changed field groups are stamped, deletion tombstones.
// Spec: docs/arc-spec/06-flows.md §9 (canvas), §4 (pinned row), §8 / §11 (Library ▸ Easels).

extension TreeOps {

    // MARK: Easels

    /// New Easel (⌃⇧E, File ▸ New Easel). Creates the Easel and its sidebar row: a tab whose URL is
    /// the Easel link, pinned at the top level of the Space's pinned area, after the existing
    /// items. [06 §4] observed: "an Easel appears as a row with an Easel icon in the pinned area";
    /// the position inside it is inferred (like ⌘D).
    public static func createEasel(
        _ state: WorkspaceState,
        id: UUID,
        tabID: UUID,
        spaceID: UUID,
        title: String = Easel.defaultTitle,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        s.easels[id] = Easel(id: id, title: title, now: now)
        return try placeEaselRow(s, easelID: id, tabID: tabID, spaceID: spaceID, now: now)
    }

    /// Opens an existing Easel in a Space that has no row for it (Library ▸ Easels, or after its
    /// row was archived): adds a pinned row like `createEasel`. inferred.
    public static func addEaselRow(
        _ state: WorkspaceState,
        easelID: UUID,
        tabID: UUID,
        spaceID: UUID,
        now: Date
    ) throws -> WorkspaceState {
        _ = try liveEasel(state, easelID)
        return try placeEaselRow(state, easelID: easelID, tabID: tabID, spaceID: spaceID, now: now)
    }

    /// Renames an Easel (the title on the canvas, or its sidebar row). Stamps the Easel's `naming`
    /// and the `content` of every live row showing it, so the rows, the command bar and archive
    /// entries carry the new title. A blank title becomes the default (inferred).
    public static func renameEasel(_ state: WorkspaceState, id: UUID, title: String, now: Date) throws -> WorkspaceState {
        var s = state
        var easel = try liveEasel(s, id)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let newTitle = trimmed.isEmpty ? Easel.defaultTitle : trimmed
        guard newTitle != easel.title else { return s }
        easel.title = newTitle
        easel.meta.stamp([Easel.FieldGroup.naming], at: now)
        s.easels[id] = easel
        for tab in s.tabs(showingEasel: id) {
            var row = tab
            row.title = newTitle
            var groups: [TabNode.FieldGroup] = [.content]
            if row.customTitle != nil {
                // The row shows the Easel's title; a custom row title would hide the rename.
                row.customTitle = nil
                groups.append(.naming)
            }
            row.meta.stamp(groups, at: now)
            s.tabs[tab.id] = row
        }
        return s
    }

    /// Deletes an Easel: tombstones it, its elements and the rows showing it (rows leave any split
    /// first). inferred: [06 §8, §12] observed only that the delete control is not in the context
    /// menu.
    public static func deleteEasel(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        _ = try liveEasel(s, id)
        s.easels[id]?.meta.markDeleted(at: now)
        for element in s.easelElements.values where element.easelID == id && !element.meta.isTombstone {
            s.easelElements[element.id]?.meta.markDeleted(at: now)
        }
        for tab in s.tabs(showingEasel: id) {
            s = removeSplitPane(s, tabID: tab.id, now: now)
            s.tabs[tab.id]?.meta.markDeleted(at: now)
        }
        return s
    }

    // MARK: Elements

    /// Adds an element on top of the Easel's stack. [06 §9] observed tools; stacking new elements
    /// on top is inferred.
    public static func addEaselElement(
        _ state: WorkspaceState,
        id: UUID,
        easelID: UUID,
        frame: EaselRect,
        content: EaselElementContent,
        style: EaselStyle,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        _ = try liveEasel(s, easelID)
        let key = try elementKey(&s, easelID: easelID, excluding: nil, position: .last, now: now)
        s.easelElements[id] = EaselElement(id: id, easelID: easelID, zKey: key, frame: frame, content: content, style: style, now: now)
        return s
    }

    /// Moves or resizes an element. Stamps only `geometry`.
    public static func setEaselElementFrame(_ state: WorkspaceState, id: UUID, frame: EaselRect, now: Date) throws -> WorkspaceState {
        var s = state
        var element = try liveElement(s, id)
        guard element.frame != frame else { return s }
        element.frame = frame
        element.meta.stamp([EaselElement.FieldGroup.geometry], at: now)
        s.easelElements[id] = element
        return s
    }

    /// Moves several elements by the same offset (a drag of the selection). Stamps `geometry` of each.
    public static func moveEaselElements(_ state: WorkspaceState, ids: [UUID], dx: Double, dy: Double, now: Date) throws -> WorkspaceState {
        var s = state
        guard dx != 0 || dy != 0 else { return s }
        for id in ids {
            let element = try liveElement(s, id)
            s = try setEaselElementFrame(s, id: id, frame: element.frame.offsetBy(dx: dx, dy: dy), now: now)
        }
        return s
    }

    /// Replaces what an element draws (text edits). Stamps only `content`.
    public static func setEaselElementContent(_ state: WorkspaceState, id: UUID, content: EaselElementContent, now: Date) throws -> WorkspaceState {
        var s = state
        var element = try liveElement(s, id)
        guard element.content != content else { return s }
        element.content = content
        element.meta.stamp([EaselElement.FieldGroup.content], at: now)
        s.easelElements[id] = element
        return s
    }

    /// Changes an element's colors, line width or text size. Stamps only `style`.
    public static func setEaselElementStyle(_ state: WorkspaceState, id: UUID, style: EaselStyle, now: Date) throws -> WorkspaceState {
        var s = state
        var element = try liveElement(s, id)
        guard element.style != style else { return s }
        element.style = style
        element.meta.stamp([EaselElement.FieldGroup.style], at: now)
        s.easelElements[id] = element
        return s
    }

    /// Changes an element's place in the stack: `.last` = bring to front, `.first` = send to back,
    /// `.before(id)` / `.after(id)` = next to another element of the same Easel. Stamps `placement`.
    public static func reorderEaselElement(_ state: WorkspaceState, id: UUID, position: InsertPosition, now: Date) throws -> WorkspaceState {
        var s = state
        var element = try liveElement(s, id)
        let key = try elementKey(&s, easelID: element.easelID, excluding: id, position: position, now: now)
        element.zKey = key
        element.meta.stamp([EaselElement.FieldGroup.placement], at: now)
        s.easelElements[id] = element
        return s
    }

    /// Deletes elements (⌫ on the selection). Tombstones each.
    public static func deleteEaselElements(_ state: WorkspaceState, ids: [UUID], now: Date) throws -> WorkspaceState {
        var s = state
        for id in ids {
            _ = try liveElement(s, id)
            s.easelElements[id]?.meta.markDeleted(at: now)
        }
        return s
    }

    // MARK: Internals

    private static func liveEasel(_ s: WorkspaceState, _ id: UUID) throws -> Easel {
        guard let easel = s.easels[id] else { throw TreeError.notFound(id) }
        guard !easel.meta.isTombstone else { throw TreeError.tombstoned(id) }
        return easel
    }

    /// A live element of a live Easel.
    private static func liveElement(_ s: WorkspaceState, _ id: UUID) throws -> EaselElement {
        guard let element = s.easelElements[id] else { throw TreeError.notFound(id) }
        guard !element.meta.isTombstone else { throw TreeError.tombstoned(id) }
        _ = try liveEasel(s, element.easelID)
        return element
    }

    /// The pinned row: opened like a tab, then pinned at the end of the top level (which records
    /// the Easel link as its pinned URL). Both steps stamp at `now`.
    private static func placeEaselRow(_ state: WorkspaceState, easelID: UUID, tabID: UUID, spaceID: UUID, now: Date) throws -> WorkspaceState {
        let title = state.easels[easelID]?.displayTitle ?? Easel.defaultTitle
        let s = try openTab(state, id: tabID, spaceID: spaceID, url: EaselLink.url(for: easelID), title: title, now: now)
        return try moveTab(s, id: tabID, to: .pinned(spaceID: spaceID, folderID: nil), position: .last, now: now)
    }

    /// Stacking key for an element entering `position` in an Easel's stack; writes any rebalance of
    /// the other elements (stamping their `placement`) into `s`.
    private static func elementKey(_ s: inout WorkspaceState, easelID: UUID, excluding: UUID?, position: InsertPosition, now: Date) throws -> SortKey {
        let siblings = s.elements(inEasel: easelID).filter { $0.id != excluding }.map { ($0.zKey, $0.id) }
        let (key, rebalanced) = try placementKey(siblings: siblings, position: position)
        for (id, k) in rebalanced {
            s.easelElements[id]?.zKey = k
            s.easelElements[id]?.meta.stamp([EaselElement.FieldGroup.placement], at: now)
        }
        return key
    }
}
