import Foundation

/// Errors from tree operations. Operations never partially apply: on error the input is untouched.
public enum TreeError: Error, Equatable, Sendable {
    case notFound(UUID)
    /// The record exists but is a tombstone.
    case tombstoned(UUID)
    /// `.before(id)` / `.after(id)` refers to something that is not a sibling in the target container.
    case anchorNotInContainer(UUID)
    /// A folder would be moved into itself or one of its descendants.
    case wouldCreateCycle
    /// Folder and target belong to different spaces.
    case spaceMismatch
    /// A profile cannot be deleted while live spaces still use it; move or delete them first.
    /// Carries the number of live spaces. inferred (the spec shows only the Default rule).
    case profileHasSpaces(Int)
    /// The Default profile (the oldest live one) cannot be deleted. [03 §Profiles] observed:
    /// "The Default Profile cannot be deleted."
    case defaultProfileNotDeletable
    /// A split resize names no split node at that path, or the fractions do not fit its children
    /// (wrong count, not finite, not positive).
    case invalidSplitFractions
    /// A new record's id is already taken (`archivePage`).
    case idInUse(UUID)
    /// A theme cannot be deleted while a live space shows it (`deleteTheme`).
    case themeInUse(UUID)
}

/// Where to put a node within its target container.
public enum InsertPosition: Hashable, Sendable {
    case first
    case last
    case before(UUID)
    case after(UUID)
}

/// Archive policy constants.
public enum ArchivePolicy {
    /// Default lifetime of an idle Today tab before auto-archive: 12 hours
    /// (docs/arc-spec/05-surfaces.md §window and app entry points, observed).
    public static let defaultTodayLifetime: TimeInterval = 12 * 60 * 60
}

/// Pure tree operations over `WorkspaceState`.
///
/// Rules every operation follows:
/// - Takes `now` and any new ids as parameters; never calls `Date()` or `UUID()`.
/// - Returns a new state; throws without side effects on invalid input.
/// - Stamps only the field groups it actually changes (required by the field-group LWW
///   conflict policy, see OpenArcSyncAPI).
/// - Deletion means tombstoning, never removing the record.
public enum TreeOps {

    // MARK: Profiles

    /// Creates a profile (File ▸ New Profile, Set Profile ▸ New Profile…). [01, 05 §context menus] observed.
    /// `icon` is an emoji or an icon name (nil: the default icon).
    public static func createProfile(_ state: WorkspaceState, id: UUID, name: String, icon: String? = nil, now: Date) -> WorkspaceState {
        var s = state
        s.profiles[id] = Profile(id: id, name: name, icon: icon, now: now)
        return s
    }

    /// Renames a profile. Stamps only `naming`.
    public static func renameProfile(_ state: WorkspaceState, id: UUID, name: String, now: Date) throws -> WorkspaceState {
        var s = state
        var profile = try live(s.profiles, id)
        profile.name = name
        profile.meta.stamp([Profile.FieldGroup.naming], at: now)
        s.profiles[id] = profile
        return s
    }

    /// Replaces a profile's settings (search engine, Today lifetime). Stamps only
    /// `Profile.settings`. Unchanged settings return the state untouched (no stamp, no version
    /// bump). A non-positive lifetime is replaced by the default. [03 §Profiles] observed.
    public static func updateProfileSettings(
        _ state: WorkspaceState,
        id: UUID,
        settings: ProfileSettings,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        var profile = try live(s.profiles, id)
        var newSettings = settings
        newSettings.todayLifetime = ProfileSettings.validLifetime(settings.todayLifetime)
        guard profile.settings != newSettings else { return state }
        profile.settings = newSettings
        profile.meta.stamp([Profile.FieldGroup.settings], at: now)
        s.profiles[id] = profile
        return s
    }

    /// Why a profile cannot be deleted, or nil when `deleteProfile` would succeed.
    public static func profileDeletionBlocker(_ state: WorkspaceState, id: UUID) -> TreeError? {
        guard let profile = state.profiles[id] else { return .notFound(id) }
        guard !profile.meta.isTombstone else { return .tombstoned(id) }
        if state.defaultProfileID == id { return .defaultProfileNotDeletable }
        let spaces = state.spaces(inProfile: id).count
        if spaces > 0 { return .profileHasSpaces(spaces) }
        return nil
    }

    /// Deletes a profile. Refused for the Default profile ([03 §Profiles] observed) and while
    /// live spaces still use it ([06 §16.3] observed: Arc disables "−" with "Only Profiles not
    /// assigned to any Spaces can be deleted."; it neither moves nor deletes those spaces). Otherwise the profile's favorites
    /// are archived (inferred, mirrors deleting a space, 06 §11) with reason `.spaceDeleted` (their
    /// container went away; a new reason case would break older builds) and the profile is
    /// tombstoned.
    public static func deleteProfile(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        if let blocker = profileDeletionBlocker(state, id: id) { throw blocker }
        var s = state
        for tab in s.favorites(profileID: id) {
            s = archiveUnchecked(s, tab: tab, reason: .spaceDeleted, now: now)
        }
        s.profiles[id]?.meta.markDeleted(at: now)
        return s
    }

    // MARK: Spaces

    /// Creates a space and places it in the dock right after `afterSpaceID`
    /// (06 §1: "inserted after the current space, not at the end", observed).
    /// `afterSpaceID == nil` appends at the end.
    public static func createSpace(
        _ state: WorkspaceState,
        id: UUID,
        profileID: UUID,
        name: String,
        icon: String? = nil,
        themeID: UUID? = nil,
        afterSpaceID: UUID? = nil,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        _ = try live(s.profiles, profileID)
        let siblings = s.spaces(inProfile: profileID).map { ($0.dockSortKey, $0.id) }
        let position: InsertPosition = afterSpaceID.map { .after($0) } ?? .last
        let (key, rebalanced) = try placementKey(siblings: siblings, position: position)
        for (sid, k) in rebalanced {
            s.spaces[sid]?.dockSortKey = k
            s.spaces[sid]?.meta.stamp([Space.FieldGroup.placement], at: now)
        }
        s.spaces[id] = Space(id: id, profileID: profileID, name: name, icon: icon, themeID: themeID, dockSortKey: key, now: now)
        return s
    }

    /// Deletes a space: archives all its tabs (pinned, in folders, Today), tombstones its folders
    /// and split layouts, then tombstones the space (06 §11: "This will archive all the tabs and
    /// folders inside it", observed). Favorites are shared and are not touched.
    public static func deleteSpace(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        _ = try live(s.spaces, id)
        for tab in s.allTabs(inSpace: id) {
            s = archiveUnchecked(s, tab: tab, reason: .spaceDeleted, now: now)
        }
        for folder in s.folders.values where folder.spaceID == id && !folder.meta.isTombstone {
            s.folders[folder.id]?.meta.markDeleted(at: now)
        }
        for split in s.splits.values where split.spaceID == id && !split.meta.isTombstone {
            s.splits[split.id]?.meta.markDeleted(at: now)
        }
        s.spaces[id]?.meta.markDeleted(at: now)
        return s
    }

    /// Renames a space. Stamps only `naming`. [01 §Spaces] observed (Rename Space).
    public static func renameSpace(_ state: WorkspaceState, id: UUID, name: String, now: Date) throws -> WorkspaceState {
        var s = state
        var space = try live(s.spaces, id)
        space.name = name
        space.meta.stamp([Space.FieldGroup.naming], at: now)
        s.spaces[id] = space
        return s
    }

    /// Sets (or clears, with nil) a space's icon. Stamps only `naming` (name and icon share it).
    /// [05 §context menus] observed (Change Space Icon…).
    public static func setSpaceIcon(_ state: WorkspaceState, id: UUID, icon: String?, now: Date) throws -> WorkspaceState {
        var s = state
        var space = try live(s.spaces, id)
        space.icon = icon
        space.meta.stamp([Space.FieldGroup.naming], at: now)
        s.spaces[id] = space
        return s
    }

    /// Points a space at a theme (nil = the default light neutral theme, 06 §1 observed).
    /// Stamps only `Space.theme`. A non-nil theme must be live.
    public static func setSpaceTheme(_ state: WorkspaceState, id: UUID, themeID: UUID?, now: Date) throws -> WorkspaceState {
        var s = state
        var space = try live(s.spaces, id)
        if let themeID { _ = try live(s.themes, themeID) }
        space.themeID = themeID
        space.meta.stamp([Space.FieldGroup.theme], at: now)
        s.spaces[id] = space
        return s
    }

    /// Moves a space within the dock order (the Library Spaces board drag handle, 06 §8 observed:
    /// "Manage Spaces"). The order is the one the dock and the board show: every live space of all
    /// profiles (`allLiveSpaces`). Anchors in `position` are other space ids. Stamps only
    /// `Space.placement` (on the moved space, plus any siblings a rebalance re-keys).
    public static func moveSpace(_ state: WorkspaceState, id: UUID, position: InsertPosition, now: Date) throws -> WorkspaceState {
        var s = state
        var space = try live(s.spaces, id)
        switch position {
        case .before(let anchor), .after(let anchor):
            if anchor == id { return s }
            _ = try live(s.spaces, anchor)
        case .first, .last:
            break
        }
        let siblings = s.allLiveSpaces.filter { $0.id != id }.map { ($0.dockSortKey, $0.id) }
        let (key, rebalanced) = try placementKey(siblings: siblings, position: position)
        for (sid, k) in rebalanced {
            s.spaces[sid]?.dockSortKey = k
            s.spaces[sid]?.meta.stamp([Space.FieldGroup.placement], at: now)
        }
        space.dockSortKey = key
        space.meta.stamp([Space.FieldGroup.placement], at: now)
        s.spaces[id] = space
        return s
    }

    // MARK: Themes

    /// Creates a theme record. [06 §2] observed (theme bubble). Nothing references it yet; use
    /// `createSpace(themeID:)` or `setSpaceTheme`.
    public static func createTheme(_ state: WorkspaceState, id: UUID, style: ThemeStyle, now: Date) -> WorkspaceState {
        var s = state
        s.themes[id] = Theme(
            id: id, appearance: style.appearance, colors: style.colors,
            grain: style.grain, brightness: style.brightness, now: now
        )
        return s
    }

    /// Deletes (tombstones) a theme. Refused while a live space points at it. Used when a space
    /// that owned its theme goes away for good (the first-launch Space replaced by the account's
    /// Spaces, `FirstLaunchSpaceAdoption`); our own operation, the spec has no theme deletion.
    public static func deleteTheme(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        _ = try live(s.themes, id)
        if s.spaces.values.contains(where: { !$0.meta.isTombstone && $0.themeID == id }) {
            throw TreeError.themeInUse(id)
        }
        s.themes[id]?.meta.markDeleted(at: now)
        return s
    }

    /// Replaces a theme's `style` group (appearance, colors, grain, brightness). Stamps only
    /// `Theme.style`. An unchanged style returns the state untouched (no stamp, no version bump),
    /// because the editor applies every change live. [06 §2] observed.
    public static func editTheme(_ state: WorkspaceState, id: UUID, style: ThemeStyle, now: Date) throws -> WorkspaceState {
        var s = state
        var theme = try live(s.themes, id)
        guard theme.style != style else { return state }
        theme.style = style
        theme.meta.stamp([Theme.FieldGroup.style], at: now)
        s.themes[id] = theme
        return s
    }

    /// Edits the theme a space shows (Edit Theme…, 06 §2 observed). If the space has a live theme,
    /// that theme's `style` changes (`editTheme`). If it has none (nil `themeID`, or a tombstoned
    /// theme), a new theme with `newThemeID` is created and assigned, which stamps `Space.theme`.
    public static func editSpaceTheme(
        _ state: WorkspaceState,
        spaceID: UUID,
        newThemeID: UUID,
        style: ThemeStyle,
        now: Date
    ) throws -> WorkspaceState {
        let space = try live(state.spaces, spaceID)
        if let themeID = space.themeID, let theme = state.themes[themeID], !theme.meta.isTombstone {
            return try editTheme(state, id: themeID, style: style, now: now)
        }
        let created = createTheme(state, id: newThemeID, style: style, now: now)
        return try setSpaceTheme(created, id: spaceID, themeID: newThemeID, now: now)
    }

    // MARK: Tabs

    /// Opens a new tab at the **top** of the space's Today area (06 §13, observed).
    public static func openTab(
        _ state: WorkspaceState,
        id: UUID,
        spaceID: UUID,
        url: URL?,
        title: String,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        _ = try live(s.spaces, spaceID)
        let location = TabLocation.today(spaceID: spaceID)
        let key = try applyPlacement(&s, location: location, excluding: nil, position: .first, now: now)
        s.tabs[id] = TabNode(id: id, location: location, sortKey: key, url: url, title: title, now: now)
        return s
    }

    /// Moves a tab to any location/position (drag and drop, Move to ▸, favorite, unpin…).
    /// Moving into favorites or the pinned area records `pinnedURL` if it was not set yet.
    public static func moveTab(
        _ state: WorkspaceState,
        id: UUID,
        to location: TabLocation,
        position: InsertPosition,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        var tab = try live(s.tabs, id)
        try validate(location, in: s)
        let key = try applyPlacement(&s, location: location, excluding: id, position: position, now: now)
        tab.location = location
        tab.sortKey = key
        var groups: [TabNode.FieldGroup] = [.placement]
        if case .today = location {
            // Unpinned tabs keep their pinnedURL; it is harmless and lets a re-pin restore it (inferred).
        } else if tab.pinnedURL == nil {
            tab.pinnedURL = tab.url
            groups.append(.pin)
        }
        tab.meta.stamp(groups, at: now)
        s.tabs[id] = tab
        return s
    }

    /// Pins a tab (⌘D): it moves to the top level of the pinned area, after the existing
    /// folders and pinned tabs, i.e. just above the divider (06 §4, observed: "below the folders,
    /// above the divider"; order relative to existing pinned tabs is inferred).
    public static func pinTab(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        let tab = try live(state.tabs, id)
        guard let spaceID = tab.location.spaceID else { throw TreeError.spaceMismatch }
        return try moveTab(state, id: id, to: .pinned(spaceID: spaceID, folderID: nil), position: .last, now: now)
    }

    /// Renames a tab. Stamps only the `naming` group.
    public static func renameTab(_ state: WorkspaceState, id: UUID, customTitle: String?, now: Date) throws -> WorkspaceState {
        var s = state
        var tab = try live(s.tabs, id)
        tab.customTitle = customTitle
        tab.meta.stamp([TabNode.FieldGroup.naming], at: now)
        s.tabs[id] = tab
        return s
    }

    /// Applies engine-reported content (URL, title, favicon). Stamps only the `content` group.
    public static func updateTabContent(
        _ state: WorkspaceState,
        id: UUID,
        url: URL?,
        title: String,
        faviconURL: URL?,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        var tab = try live(s.tabs, id)
        tab.url = url
        tab.title = title
        tab.faviconURL = faviconURL
        tab.meta.stamp([TabNode.FieldGroup.content], at: now)
        s.tabs[id] = tab
        return s
    }

    /// Edit Pinned Page ▸ Replace Pinned URL with Current: the current URL becomes the pinned
    /// (original) URL. Stamps only the `pin` group. Only pinned tabs and favorites have one.
    /// [05 §context menus] observed menu item; semantics inferred from its title.
    public static func replacePinnedURLWithCurrent(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        var tab = try live(s.tabs, id)
        if case .today = tab.location { throw TreeError.spaceMismatch }
        guard let url = tab.url else { return s }
        tab.pinnedURL = url
        tab.meta.stamp([TabNode.FieldGroup.pin], at: now)
        s.tabs[id] = tab
        return s
    }

    /// Edit Pinned Page ▸ Edit…: sets the pinned URL explicitly. Stamps only `pin`.
    /// [05 §context menus] observed menu item.
    public static func setPinnedURL(_ state: WorkspaceState, id: UUID, url: URL, now: Date) throws -> WorkspaceState {
        var s = state
        var tab = try live(s.tabs, id)
        if case .today = tab.location { throw TreeError.spaceMismatch }
        tab.pinnedURL = url
        tab.meta.stamp([TabNode.FieldGroup.pin], at: now)
        s.tabs[id] = tab
        return s
    }

    /// Reset Tab to Original URL: the tab's URL goes back to its pinned URL. Stamps only
    /// `content`; the engine must load the URL. Returns the state unchanged when there is no
    /// pinned URL. [02 §tabs] observed command name; behavior inferred from its title.
    public static func resetTabToPinnedURL(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        let tab = try live(state.tabs, id)
        guard let pinned = tab.pinnedURL, pinned != tab.url else { return state }
        return try updateTabContent(state, id: id, url: pinned, title: tab.title, faviconURL: tab.faviconURL, now: now)
    }

    /// Records that the tab was focused (resets its auto-archive clock).
    public static func markTabActive(_ state: WorkspaceState, id: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        var tab = try live(s.tabs, id)
        tab.lastActiveAt = now
        tab.meta.stamp([TabNode.FieldGroup.activity], at: now)
        s.tabs[id] = tab
        return s
    }

    // MARK: Folders

    /// Creates a folder at the **top** of the pinned container, expanded by default
    /// (06 §3, observed).
    public static func createFolder(
        _ state: WorkspaceState,
        id: UUID,
        spaceID: UUID,
        parentFolderID: UUID? = nil,
        title: String,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        let location = TabLocation.pinned(spaceID: spaceID, folderID: parentFolderID)
        try validate(location, in: s)
        let key = try applyPlacement(&s, location: location, excluding: nil, position: .first, now: now)
        s.folders[id] = Folder(id: id, spaceID: spaceID, parentFolderID: parentFolderID, title: title, isExpanded: true, sortKey: key, now: now)
        return s
    }

    /// Moves a folder (with its whole subtree) under `parentFolderID` in `spaceID`.
    /// Rejects moving a folder into itself or its descendants. Moving across spaces also moves
    /// every descendant folder and tab.
    public static func moveFolder(
        _ state: WorkspaceState,
        id: UUID,
        toSpace spaceID: UUID,
        parentFolderID: UUID?,
        position: InsertPosition,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        var folder = try live(s.folders, id)
        if let parent = parentFolderID, s.folder(parent, isWithin: id) {
            throw TreeError.wouldCreateCycle
        }
        let location = TabLocation.pinned(spaceID: spaceID, folderID: parentFolderID)
        try validate(location, in: s)
        let key = try applyPlacement(&s, location: location, excluding: id, position: position, now: now)
        let oldSpace = folder.spaceID
        folder.spaceID = spaceID
        folder.parentFolderID = parentFolderID
        folder.sortKey = key
        folder.meta.stamp([Folder.FieldGroup.placement], at: now)
        s.folders[id] = folder
        if oldSpace != spaceID {
            moveSubtree(&s, rootFolderID: id, toSpace: spaceID, now: now)
        }
        return s
    }

    public static func renameFolder(_ state: WorkspaceState, id: UUID, title: String, now: Date) throws -> WorkspaceState {
        var s = state
        var folder = try live(s.folders, id)
        folder.title = title
        folder.meta.stamp([Folder.FieldGroup.naming], at: now)
        s.folders[id] = folder
        return s
    }

    public static func setFolderExpanded(_ state: WorkspaceState, id: UUID, isExpanded: Bool, now: Date) throws -> WorkspaceState {
        var s = state
        var folder = try live(s.folders, id)
        folder.isExpanded = isExpanded
        folder.meta.stamp([Folder.FieldGroup.display], at: now)
        s.folders[id] = folder
        return s
    }

    // MARK: Archive

    /// Archives one tab: tombstones the tab, creates an `ArchiveItem` with the same id, and
    /// removes the tab from any split layout. ⌘W archives by default (05, observed).
    public static func archiveTab(_ state: WorkspaceState, id: UUID, reason: ArchiveReason = .closed, now: Date) throws -> WorkspaceState {
        let tab = try live(state.tabs, id)
        return archiveUnchecked(state, tab: tab, reason: reason, now: now)
    }

    /// "Clear" (⇧⌘K): archives every Today tab of the space (05, observed).
    public static func clearToday(_ state: WorkspaceState, spaceID: UUID, now: Date) throws -> WorkspaceState {
        var s = state
        _ = try live(s.spaces, spaceID)
        for tab in s.today(spaceID: spaceID) {
            s = archiveUnchecked(s, tab: tab, reason: .clearedToday, now: now)
        }
        return s
    }

    /// Auto-archive: archives every Today tab (in all spaces) idle for at least its lifetime.
    /// Each tab uses the "Archive tabs after" setting of its space's profile
    /// (`WorkspaceState.todayLifetime(forSpace:)`, [03 §Profiles] observed per profile, default
    /// 12 h). `lifetimeOverride` replaces every profile's value (tests, diagnostics).
    /// Pinned tabs and favorites are never auto-archived. Tabs in `excluding` are skipped and left
    /// untouched (the caller passes the tab on screen and its split partners; inferred).
    public static func autoArchive(
        _ state: WorkspaceState,
        lifetimeOverride: TimeInterval? = nil,
        excluding: Set<UUID> = [],
        now: Date
    ) -> WorkspaceState {
        var s = state
        let expired = s.tabs.values.filter { tab in
            guard !tab.meta.isTombstone, !excluding.contains(tab.id), case .today(let spaceID) = tab.location else { return false }
            let lifetime = lifetimeOverride ?? state.todayLifetime(forSpace: spaceID)
            return now.timeIntervalSince(tab.lastActiveAt) >= lifetime
        }
        for tab in expired {
            s = archiveUnchecked(s, tab: tab, reason: .autoArchived, now: now)
        }
        return s
    }

    /// Archives a page that never had a tab in the tree: an idle Little Arc window's page (plan
    /// B82; [03 §Links] observed "Archive Little Arcs after", default 6 hours). Creates a live
    /// `ArchiveItem` with id `id` and touches nothing else. `spaceID`, when given, must be a live
    /// Space (the item restores there); nil leaves the item without a Space. The item is marked
    /// `isFromLittleArc`. Throws when `id` is already used by an archive item or a tab (ids never
    /// repeat, see `ArchiveItem`).
    public static func archivePage(
        _ state: WorkspaceState,
        id: UUID,
        url: URL?,
        title: String,
        faviconURL: URL? = nil,
        spaceID: UUID?,
        reason: ArchiveReason = .autoArchived,
        now: Date
    ) throws -> WorkspaceState {
        if let spaceID { _ = try live(state.spaces, spaceID) }
        guard state.archive[id] == nil, state.tabs[id] == nil else { throw TreeError.idInUse(id) }
        var s = state
        s.archive[id] = ArchiveItem(
            id: id, url: url, title: title, faviconURL: faviconURL, spaceID: spaceID,
            folderPath: [], reason: reason, archivedAt: now, isFromLittleArc: true
        )
        return s
    }

    /// Restores an archive item as a new tab at the top of the space's Today area.
    /// The archive item is tombstoned (inferred: whether the original keeps it is unknown).
    public static func restoreFromArchive(
        _ state: WorkspaceState,
        itemID: UUID,
        newTabID: UUID,
        spaceID: UUID,
        now: Date
    ) throws -> WorkspaceState {
        let item = try live(state.archive, itemID)
        var s = try openTab(state, id: newTabID, spaceID: spaceID, url: item.url, title: item.title, now: now)
        s.tabs[newTabID]?.faviconURL = item.faviconURL
        s.archive[itemID]?.meta.markDeleted(at: now)
        return s
    }

    /// Archive ▸ Clear Archive ([01 §Archive] observed item): tombstones every live archive item.
    /// Tabs, folders and Spaces are left alone; nothing new is archived. Which items it removes
    /// (all of them, not only one Space's or Profile's) is inferred. Already tombstoned items are
    /// not stamped again.
    public static func clearArchive(_ state: WorkspaceState, now: Date) -> WorkspaceState {
        var s = state
        for (id, item) in s.archive where !item.meta.isTombstone {
            s.archive[id]?.meta.markDeleted(at: now)
        }
        return s
    }

    // MARK: Split view

    /// Adds `newTabID` as a pane next to `existingTabID`. If the existing tab is not in a split
    /// yet, a new layout with id `layoutID` is created (06 §5: current tab left, new tab right,
    /// observed). Both tabs must be live and in the same space. `side` puts the new pane before
    /// (`.leading`: left or top) or after (`.trailing`: right or bottom) the existing one; the web
    /// toolbar's split menu offers all four (06 §17.3 observed: Add Right / Left / Top / Bottom Split).
    public static func addSplitPane(
        _ state: WorkspaceState,
        layoutID: UUID,
        existingTabID: UUID,
        newTabID: UUID,
        axis: SplitAxis = .horizontal,
        side: SplitSide = .trailing,
        now: Date
    ) throws -> WorkspaceState {
        var s = state
        let existing = try live(s.tabs, existingTabID)
        let newTab = try live(s.tabs, newTabID)
        guard let spaceID = existing.location.spaceID ?? newTab.location.spaceID else { throw TreeError.spaceMismatch }
        if let other = newTab.location.spaceID, other != spaceID { throw TreeError.spaceMismatch }
        if let layout = s.splits.values.first(where: { !$0.meta.isTombstone && $0.root.tabIDs.contains(existingTabID) }) {
            var updated = layout
            updated.root = layout.root.inserting(newTabID, beside: existingTabID, side: side, axis: axis)
            updated.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
            s.splits[layout.id] = updated
        } else {
            let panes = side == .leading ? [newTabID, existingTabID] : [existingTabID, newTabID]
            let root = SplitNode.split(axis: axis, children: panes.map { SplitChild(node: .pane(tabID: $0), fraction: 0.5) })
            s.splits[layoutID] = SplitLayout(id: layoutID, spaceID: spaceID, root: root, now: now)
        }
        return s
    }

    /// Puts `tabID` in a split next to `targetTabID`, on `side` of it (06 §15 observed: a tab
    /// dropped on the middle band of a tab row, or on the web panel, forms a split with that tab;
    /// the dropped tab is on the pointer's side).
    ///
    /// - The dropped tab first leaves any split it was in (it cannot be in two layouts).
    /// - If the target is already in a live split, the dropped tab joins that layout beside it;
    ///   otherwise a new two-pane layout with id `layoutID` is created.
    /// - With `moveNextToTarget`, the dropped tab also moves into the target's container, right
    ///   before (leading) or after (trailing) it, so the group row shows where it was dropped
    ///   (inferred: 06 §15 shows one row with two cells, not where it sits). Ignored when the
    ///   target is a favorite (favorites are not rows).
    /// Both tabs must be live, distinct and in the same space.
    public static func splitTab(
        _ state: WorkspaceState,
        layoutID: UUID,
        tabID: UUID,
        targetTabID: UUID,
        side: SplitSide,
        moveNextToTarget: Bool,
        now: Date
    ) throws -> WorkspaceState {
        guard tabID != targetTabID else { throw TreeError.anchorNotInContainer(tabID) }
        var s = state
        let target = try live(s.tabs, targetTabID)
        let dropped = try live(s.tabs, tabID)
        guard let spaceID = target.location.spaceID ?? dropped.location.spaceID else { throw TreeError.spaceMismatch }
        if let other = dropped.location.spaceID, other != spaceID { throw TreeError.spaceMismatch }

        removeFromSplits(&s, tabID: tabID, now: now)
        if moveNextToTarget, target.location.spaceID != nil {
            s = try moveTab(s, id: tabID, to: target.location, position: side == .leading ? .before(targetTabID) : .after(targetTabID), now: now)
        }
        if let layout = s.splits.values.first(where: { !$0.meta.isTombstone && $0.root.tabIDs.contains(targetTabID) }) {
            var updated = layout
            updated.root = layout.root.inserting(tabID, beside: targetTabID, side: side, axis: .horizontal)
            updated.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
            s.splits[layout.id] = updated
        } else {
            let panes = side == .leading ? [tabID, targetTabID] : [targetTabID, tabID]
            let root = SplitNode.split(axis: .horizontal, children: panes.map { SplitChild(node: .pane(tabID: $0), fraction: 0.5) })
            s.splits[layoutID] = SplitLayout(id: layoutID, spaceID: spaceID, root: root, now: now)
        }
        return s
    }

    /// Moves a whole split group to another space: every member tab goes to the target space's
    /// Today area at `position`, next to each other and in their current relative order (pinned
    /// members first, then by sort key), and the layout's `spaceID` follows. The sidebar treats
    /// the group as one unit (06 §5, observed); landing in Today mirrors a single tab dropped on
    /// a dock icon (inferred). Favorite members are shared across spaces and stay where they are.
    /// Stamps only `placement` on the moved tabs and `layout` on the layout when its space changes.
    /// An anchor in `position` must be a tab in the target Today area that is not a member.
    public static func moveSplitLayout(
        _ state: WorkspaceState,
        layoutID: UUID,
        toSpaceID: UUID,
        position: InsertPosition,
        now: Date
    ) throws -> WorkspaceState {
        var layout = try live(state.splits, layoutID)
        _ = try live(state.spaces, toSpaceID)
        let members = layout.root.tabIDs.compactMap { id -> TabNode? in
            guard let tab = state.tabs[id], !tab.meta.isTombstone else { return nil }
            if case .favorite = tab.location { return nil }
            return tab
        }
        let ordered = members.sorted { a, b in
            let ra = a.location.isPinned ? 0 : 1, rb = b.location.isPinned ? 0 : 1
            if ra != rb { return ra < rb }
            return SortKey.order((a.sortKey, a.id), (b.sortKey, b.id))
        }.map(\.id)
        if case .before(let anchor) = position, ordered.contains(anchor) { throw TreeError.anchorNotInContainer(anchor) }
        if case .after(let anchor) = position, ordered.contains(anchor) { throw TreeError.anchorNotInContainer(anchor) }

        var s = state
        let target = TabLocation.today(spaceID: toSpaceID)
        for step in groupMoveSteps(ids: ordered, position: position) {
            s = try moveTab(s, id: step.id, to: target, position: step.position, now: now)
        }
        if layout.spaceID != toSpaceID {
            layout.spaceID = toSpaceID
            layout.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
            s.splits[layoutID] = layout
        }
        return s
    }

    /// Removes a pane (⌃⇧-). A layout left with a single pane is tombstoned (back to a single page,
    /// 06 §5, observed). The tab itself is not archived.
    public static func removeSplitPane(_ state: WorkspaceState, tabID: UUID, now: Date) -> WorkspaceState {
        var s = state
        removeFromSplits(&s, tabID: tabID, now: now)
        return s
    }

    /// Stores new child fractions for the split node at `path` inside layout `layoutID` (a divider
    /// drag, B58). `path` lists child indices from the root to that split node (`[]` is the root).
    /// The fractions are normalized to sum to 1. [06 §21.6] observed: the stored value is the
    /// ratio, not a width, so it survives tab switches and hiding the sidebar. Stamps only the
    /// layout's `layout` group, and only when the tree changes.
    public static func setSplitFractions(
        _ state: WorkspaceState,
        layoutID: UUID,
        path: [Int],
        fractions: [Double],
        now: Date
    ) throws -> WorkspaceState {
        var layout = try live(state.splits, layoutID)
        guard let root = layout.root.replacingFractions(at: path, with: fractions) else {
            throw TreeError.invalidSplitFractions
        }
        guard root != layout.root else { return state }
        var s = state
        layout.root = root
        layout.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
        s.splits[layoutID] = layout
        return s
    }

    // MARK: - Internals

    private static func live<T: SyncableEntity>(_ table: [UUID: T], _ id: UUID) throws -> T {
        guard let value = table[id] else { throw TreeError.notFound(id) }
        guard !value.meta.isTombstone else { throw TreeError.tombstoned(id) }
        return value
    }

    /// Checks that the target container exists and is live.
    private static func validate(_ location: TabLocation, in s: WorkspaceState) throws {
        switch location {
        case .favorite(let profileID):
            _ = try live(s.profiles, profileID)
        case .today(let spaceID):
            _ = try live(s.spaces, spaceID)
        case .pinned(let spaceID, let folderID):
            _ = try live(s.spaces, spaceID)
            if let folderID {
                let folder = try live(s.folders, folderID)
                guard folder.spaceID == spaceID else { throw TreeError.spaceMismatch }
            }
        }
    }

    /// Ordered siblings in a container (excluding the node being moved).
    private static func siblings(_ s: WorkspaceState, location: TabLocation, excluding: UUID?) -> [(SortKey, UUID)] {
        let all: [(SortKey, UUID)]
        switch location {
        case .pinned(let spaceID, let folderID):
            all = s.pinnedChildren(spaceID: spaceID, folderID: folderID).map { ($0.sortKey, $0.id) }
        case .favorite, .today:
            all = s.tabs(at: location).map { ($0.sortKey, $0.id) }
        }
        return all.filter { $0.1 != excluding }
    }

    /// Computes the sort key for a node entering `location` and writes any sibling rebalance into `s`.
    private static func applyPlacement(
        _ s: inout WorkspaceState,
        location: TabLocation,
        excluding: UUID?,
        position: InsertPosition,
        now: Date
    ) throws -> SortKey {
        let sibs = siblings(s, location: location, excluding: excluding)
        let (key, rebalanced) = try placementKey(siblings: sibs, position: position)
        for (id, k) in rebalanced {
            if s.tabs[id] != nil {
                s.tabs[id]?.sortKey = k
                s.tabs[id]?.meta.stamp([TabNode.FieldGroup.placement], at: now)
            } else if s.folders[id] != nil {
                s.folders[id]?.sortKey = k
                s.folders[id]?.meta.stamp([Folder.FieldGroup.placement], at: now)
            }
        }
        return key
    }

    /// Finds a key for `position` among ordered `siblings`. If neighbours have equal keys (possible
    /// after concurrent edits on two devices), all siblings are re-keyed and returned in `rebalanced`.
    static func placementKey(
        siblings: [(SortKey, UUID)],
        position: InsertPosition
    ) throws -> (key: SortKey, rebalanced: [UUID: SortKey]) {
        let index: Int
        switch position {
        case .first: index = 0
        case .last: index = siblings.count
        case .before(let anchor):
            guard let i = siblings.firstIndex(where: { $0.1 == anchor }) else { throw TreeError.anchorNotInContainer(anchor) }
            index = i
        case .after(let anchor):
            guard let i = siblings.firstIndex(where: { $0.1 == anchor }) else { throw TreeError.anchorNotInContainer(anchor) }
            index = i + 1
        }
        let lower = index > 0 ? siblings[index - 1].0 : nil
        let upper = index < siblings.count ? siblings[index].0 : nil
        if let key = SortKey.between(lower, upper) {
            return (key, [:])
        }
        // Rebalance: fresh increasing keys for everyone, leaving a slot at `index`.
        let fresh = SortKey.sequence(count: siblings.count + 1)
        var rebalanced: [UUID: SortKey] = [:]
        var cursor = 0
        for (offset, key) in fresh.enumerated() where offset != index {
            rebalanced[siblings[cursor].1] = key
            cursor += 1
        }
        return (fresh[index], rebalanced)
    }

    /// Per-tab moves that put `ids` (in order) next to each other at `position`.
    private static func groupMoveSteps(ids: [UUID], position: InsertPosition) -> [(id: UUID, position: InsertPosition)] {
        switch position {
        case .first:
            // Each move goes to the front, so the last id is moved first.
            return ids.reversed().map { ($0, .first) }
        case .last:
            return ids.map { ($0, .last) }
        case .before(let anchor):
            return ids.map { ($0, .before(anchor)) }
        case .after(let anchor):
            var previous = anchor
            return ids.map { id in
                defer { previous = id }
                return (id, .after(previous))
            }
        }
    }

    private static func archiveUnchecked(_ state: WorkspaceState, tab: TabNode, reason: ArchiveReason, now: Date) -> WorkspaceState {
        var s = state
        let folderPath: [String]
        if case .pinned(_, let folderID) = tab.location {
            folderPath = s.folderPath(folderID)
        } else {
            folderPath = []
        }
        s.archive[tab.id] = ArchiveItem(
            id: tab.id,
            url: tab.url,
            title: tab.displayTitle,
            faviconURL: tab.faviconURL,
            spaceID: tab.location.spaceID,
            folderPath: folderPath,
            reason: reason,
            archivedAt: now
        )
        s.tabs[tab.id]?.meta.markDeleted(at: now)
        removeFromSplits(&s, tabID: tab.id, now: now)
        return s
    }

    private static func removeFromSplits(_ s: inout WorkspaceState, tabID: UUID, now: Date) {
        for layout in s.splits.values where !layout.meta.isTombstone && layout.root.tabIDs.contains(tabID) {
            if let remaining = layout.root.removing(tabID), remaining.tabIDs.count > 1 {
                s.splits[layout.id]?.root = remaining
                s.splits[layout.id]?.meta.stamp([SplitLayout.FieldGroup.layout], at: now)
            } else {
                s.splits[layout.id]?.meta.markDeleted(at: now)
            }
        }
    }

    /// After a folder moved across spaces, re-home its descendants (folders and pinned tabs).
    private static func moveSubtree(_ s: inout WorkspaceState, rootFolderID: UUID, toSpace spaceID: UUID, now: Date) {
        for folder in s.folders.values where folder.id != rootFolderID && !folder.meta.isTombstone && s.folder(folder.id, isWithin: rootFolderID) {
            s.folders[folder.id]?.spaceID = spaceID
            s.folders[folder.id]?.meta.stamp([Folder.FieldGroup.placement], at: now)
        }
        for tab in s.tabs.values where !tab.meta.isTombstone {
            if case .pinned(_, let folderID?) = tab.location, s.folder(folderID, isWithin: rootFolderID) {
                s.tabs[tab.id]?.location = .pinned(spaceID: spaceID, folderID: folderID)
                s.tabs[tab.id]?.meta.stamp([TabNode.FieldGroup.placement], at: now)
            }
        }
    }
}

// MARK: - Split tree helpers

extension SplitNode {
    /// Removes a pane. Splits left with one child collapse into that child; sibling fractions are
    /// renormalized. Returns nil if nothing remains.
    public func removing(_ tabID: UUID) -> SplitNode? {
        switch self {
        case .pane(let id):
            return id == tabID ? nil : self
        case .split(let axis, let children):
            let kept: [SplitChild] = children.compactMap { child in
                child.node.removing(tabID).map { SplitChild(node: $0, fraction: child.fraction) }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0].node }
            let total = kept.reduce(0) { $0 + $1.fraction }
            return .split(axis: axis, children: kept.map { SplitChild(node: $0.node, fraction: total > 0 ? $0.fraction / total : 1 / Double(kept.count)) })
        }
    }

    /// The node at `path` (child indices from this node; `[]` is this node), or nil if the path
    /// leaves the tree.
    public func node(at path: [Int]) -> SplitNode? {
        guard let first = path.first else { return self }
        guard case .split(_, let children) = self, children.indices.contains(first) else { return nil }
        return children[first].node.node(at: Array(path.dropFirst()))
    }

    /// This tree with the split node at `path` given `fractions` (one per child, finite and
    /// positive, normalized to sum to 1). Nil if `path` does not name a split node or the
    /// fractions do not fit it.
    public func replacingFractions(at path: [Int], with fractions: [Double]) -> SplitNode? {
        guard case .split(let axis, var children) = self else { return nil }
        guard let first = path.first else {
            guard fractions.count == children.count, fractions.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
            let total = fractions.reduce(0, +)
            for i in children.indices { children[i].fraction = fractions[i] / total }
            return .split(axis: axis, children: children)
        }
        guard children.indices.contains(first),
              let replaced = children[first].node.replacingFractions(at: Array(path.dropFirst()), with: fractions) else { return nil }
        children[first].node = replaced
        return .split(axis: axis, children: children)
    }

    /// Inserts `newTabID` right after `existingTabID`. If the existing pane's parent split has the
    /// same axis, the new pane becomes its sibling and fractions are equalized; otherwise the
    /// existing pane is replaced by a two-pane split.
    public func inserting(_ newTabID: UUID, after existingTabID: UUID, axis: SplitAxis) -> SplitNode {
        inserting(newTabID, beside: existingTabID, side: .trailing, axis: axis)
    }

    /// Inserts `newTabID` on `side` of `existingTabID` (leading = before it, trailing = after it),
    /// with the same sibling / nesting rules as `inserting(_:after:axis:)`.
    public func inserting(_ newTabID: UUID, beside existingTabID: UUID, side: SplitSide, axis: SplitAxis) -> SplitNode {
        switch self {
        case .pane(let id):
            guard id == existingTabID else { return self }
            let panes: [SplitNode] = side == .leading ? [.pane(tabID: newTabID), self] : [self, .pane(tabID: newTabID)]
            return .split(axis: axis, children: panes.map { SplitChild(node: $0, fraction: 0.5) })
        case .split(let ownAxis, let children):
            if ownAxis == axis, let i = children.firstIndex(where: { $0.node == .pane(tabID: existingTabID) }) {
                var nodes = children.map(\.node)
                nodes.insert(.pane(tabID: newTabID), at: side == .leading ? i : i + 1)
                let share = 1 / Double(nodes.count)
                return .split(axis: axis, children: nodes.map { SplitChild(node: $0, fraction: share) })
            }
            return .split(axis: ownAxis, children: children.map {
                SplitChild(node: $0.node.inserting(newTabID, beside: existingTabID, side: side, axis: axis), fraction: $0.fraction)
            })
        }
    }
}
