import Foundation
import OpenArcModel
import OpenArcSyncAPI
import OpenArcPersistence

/// A new device joins the account's Spaces instead of adding its own first-launch Space.
///
/// Every fresh install makes a first-launch workspace with one Space ("Home",
/// `FirstLaunchDefaults`). Uploaded as it is, each device that turns sync on would add another
/// empty "Home" to the account. Arc's sidebar behaves like an account: a new device shows the
/// account's Spaces and adds none of its own. Decided by the user (2026-10-28, from two-Mac sync
/// testing); the spec records no first-sync behavior.
///
/// How it works:
/// - When the first-launch workspace is created (no usable workspace file), its Space is recorded
///   as pending (`AppPreferences.firstLaunchSpaceID`).
/// - While it is pending, that Space and its theme are held back from the sync store
///   (`SyncUploadHold`); everything else uploads as usual.
/// - After the first sync that completed cleanly (status `.idle` with a "Last synced" time), `decide`
///   runs on the stored workspace: when this device's sidebar is still the default
///   (`isUntouchedWorkspace`) and the server brought live Spaces, the Space and its theme are
///   tombstoned (`dropping`) and windows showing it move to the first remaining Space. Otherwise
///   (edited, or an empty account) the held records upload as before. Either way it is final.
/// - A local edit that makes the sidebar no longer the default settles it at once (keep, upload).
/// - A dropped Space's tombstones never go up: the server never had the records.
///
/// Profiles need nothing here: they are local-only (plan Q13 / B73), so the local Default profile
/// never reaches the account, and the account's Spaces, whose profile ids are unknown on this
/// device, resolve to it (`WorkspaceState.localProfileID(for:)`).
enum FirstLaunchSpaceAdoption {
    enum Decision: Equatable {
        /// Upload the held records (the Space has content, or the account has no Spaces).
        case keep
        /// Drop the first-launch Space; the account's Spaces (in dock order) replace it.
        case adopt(accountSpaceIDs: [UUID])
        /// The Space is gone (deleted by the user): nothing is held any more.
        case gone
    }

    /// Whether the first-launch Space `spaceID` is still exactly as it was created:
    /// - the Space record never changed (no rename, icon, theme or profile change, no move: its
    ///   version is still the creation's 1),
    /// - its theme never changed (no theme edit, e.g. in onboarding), or it has none,
    /// - nothing was ever put in it: no tab (open, pinned, in Today, archived or deleted), folder,
    ///   split or archive entry names it.
    ///
    /// Favorites and Easels belong to no Space; they upload as usual and do not count.
    static func isUntouched(_ workspace: WorkspaceState, spaceID: UUID) -> Bool {
        guard let space = workspace.spaces[spaceID], !space.meta.isTombstone, space.meta.version == 1 else { return false }
        if let themeID = space.themeID {
            guard let theme = workspace.themes[themeID], !theme.meta.isTombstone, theme.meta.version == 1 else { return false }
        }
        if workspace.tabs.values.contains(where: { $0.location.spaceID == spaceID }) { return false }
        if workspace.folders.values.contains(where: { $0.spaceID == spaceID }) { return false }
        if workspace.splits.values.contains(where: { $0.spaceID == spaceID }) { return false }
        if workspace.archive.values.contains(where: { $0.spaceID == spaceID }) { return false }
        return true
    }

    /// The other live Spaces the server brought, in dock order. A record the sync backend fetched
    /// carries its system fields (`SyncMetadata.backendSystemFields`); a Space made on this device
    /// has none until its own upload comes back.
    static func accountSpaces(_ workspace: WorkspaceState, excluding spaceID: UUID) -> [Space] {
        workspace.allLiveSpaces.filter { $0.id != spaceID && $0.meta.backendSystemFields != nil }
    }

    /// Whether this device's sidebar is still the first-launch default: the Space is untouched
    /// (`isUntouched`) and no other live Space was made on this device (an import, New Space…).
    /// Spaces that came from the server do not count.
    static func isUntouchedWorkspace(_ workspace: WorkspaceState, spaceID: UUID) -> Bool {
        guard isUntouched(workspace, spaceID: spaceID) else { return false }
        return !workspace.spaces.values.contains { $0.id != spaceID && $0.meta.backendSystemFields == nil }
    }

    /// The decision for the pending Space `spaceID`, from the workspace after a clean sync.
    static func decide(_ workspace: WorkspaceState, spaceID: UUID) -> Decision {
        guard let space = workspace.spaces[spaceID], !space.meta.isTombstone else { return .gone }
        guard isUntouchedWorkspace(workspace, spaceID: spaceID) else { return .keep }
        let account = accountSpaces(workspace, excluding: spaceID)
        return account.isEmpty ? .keep : .adopt(accountSpaceIDs: account.map(\.id))
    }

    /// The records held back for the first-launch Space `spaceID`: the Space and its theme (when
    /// no other live Space shows that theme).
    static func heldRecordIDs(_ workspace: WorkspaceState, spaceID: UUID) -> Set<SyncRecordID> {
        var ids: Set<SyncRecordID> = [SyncRecordID(type: .space, uuid: spaceID)]
        if let themeID = workspace.spaces[spaceID]?.themeID,
           !workspace.spaces.values.contains(where: { $0.id != spaceID && !$0.meta.isTombstone && $0.themeID == themeID }) {
            ids.insert(SyncRecordID(type: .theme, uuid: themeID))
        }
        return ids
    }

    /// The workspace without the first-launch Space: the Space is deleted (`TreeOps.deleteSpace`,
    /// a tombstone) and so is its theme when no other live Space shows it. Throws when the Space is
    /// not live.
    static func dropping(_ workspace: WorkspaceState, spaceID: UUID, now: Date) throws -> WorkspaceState {
        let themeID = workspace.spaces[spaceID]?.themeID
        var s = try TreeOps.deleteSpace(workspace, id: spaceID, now: now)
        if let themeID, let theme = s.themes[themeID], !theme.meta.isTombstone {
            s = (try? TreeOps.deleteTheme(s, id: themeID, now: now)) ?? s
        }
        return s
    }
}

// MARK: - Controller wiring

extension WorkspaceController {
    /// The `SyncUploadHold` of this controller: holds the pending first-launch Space (and its
    /// theme) and, once dropped, its tombstones. Holds nothing for an incognito controller or
    /// without a writable store.
    var firstLaunchSpaceHold: SyncUploadHold {
        guard !isOffTheRecord, let persistence = dependencies.persistence, !persistence.isReadOnly else { return .none }
        return SyncUploadHold(
            heldRecordIDs: { [weak self] in self?.heldFirstLaunchRecordIDs() ?? [] },
            isDecisionPending: { [weak self] in self?.dependencies.preferences.firstLaunchSpaceID != nil },
            releaseIfEdited: { [weak self] in self?.releaseFirstLaunchSpaceIfEdited() ?? [] },
            decide: { [weak self] in await self?.decideFirstLaunchSpace() ?? [] }
        )
    }

    private func heldFirstLaunchRecordIDs() -> Set<SyncRecordID> {
        let preferences = dependencies.preferences
        var held: Set<SyncRecordID> = []
        if let pending = preferences.firstLaunchSpaceID {
            held.formUnion(FirstLaunchSpaceAdoption.heldRecordIDs(workspace, spaceID: pending))
        }
        if let dropped = preferences.droppedFirstLaunchSpaceID {
            held.insert(SyncRecordID(type: .space, uuid: dropped))
            if let themeID = workspace.spaces[dropped]?.themeID, workspace.themes[themeID]?.meta.isTombstone == true {
                held.insert(SyncRecordID(type: .theme, uuid: themeID))
            }
        }
        return held
    }

    /// Settles the pending decision when the sidebar is no longer the first-launch default. A
    /// Space the user deleted is never uploaded (the server never had it); an edited one is
    /// released for upload. A Space this workspace does not have only clears the marker.
    private func releaseFirstLaunchSpaceIfEdited() -> [SyncRecordID] {
        let preferences = dependencies.preferences
        guard let spaceID = preferences.firstLaunchSpaceID else { return [] }
        guard let space = workspace.spaces[spaceID] else {
            preferences.firstLaunchSpaceID = nil
            return []
        }
        if space.meta.isTombstone {
            preferences.firstLaunchSpaceID = nil
            preferences.droppedFirstLaunchSpaceID = spaceID
            return []
        }
        guard !FirstLaunchSpaceAdoption.isUntouchedWorkspace(workspace, spaceID: spaceID) else { return [] }
        let released = FirstLaunchSpaceAdoption.heldRecordIDs(workspace, spaceID: spaceID)
        preferences.firstLaunchSpaceID = nil
        return released.sorted { $0.recordName < $1.recordName }
    }

    /// Runs the first-launch decision after a clean sync. First brings everything the sync store
    /// applied into the shown workspace (the forwarding task may not have merged it yet), then
    /// keeps the Space (returns its records for upload) or drops it for the account's Spaces.
    private func decideFirstLaunchSpace() async -> [SyncRecordID] {
        guard let persistence = dependencies.persistence else { return [] }
        let stored = await persistence.currentWorkspace()
        let preferences = dependencies.preferences
        guard let spaceID = preferences.firstLaunchSpaceID, !isStopped else { return [] }
        // Records the store has that this copy lacks or differs in; nothing is removed here.
        let diff = WorkspaceDiff.changes(from: workspace, to: stored)
        mergeStored(stored, changes: WorkspaceDiff.Changes(saved: diff.saved))
        switch FirstLaunchSpaceAdoption.decide(workspace, spaceID: spaceID) {
        case .gone:
            preferences.firstLaunchSpaceID = nil
            if workspace.spaces[spaceID] != nil { preferences.droppedFirstLaunchSpaceID = spaceID }
            return []
        case .keep:
            let released = FirstLaunchSpaceAdoption.heldRecordIDs(workspace, spaceID: spaceID)
            preferences.firstLaunchSpaceID = nil
            return released.sorted { $0.recordName < $1.recordName }
        case .adopt:
            guard let next = try? FirstLaunchSpaceAdoption.dropping(workspace, spaceID: spaceID, now: now()) else { return [] }
            // Held before the commit, so the tombstones never reach the store.
            preferences.droppedFirstLaunchSpaceID = spaceID
            preferences.firstLaunchSpaceID = nil
            // Every window repairs its selection: one that showed the dropped Space moves to the
            // first of the account's Spaces in dock order.
            commit(next, origin: nil)
            return []
        }
    }
}
