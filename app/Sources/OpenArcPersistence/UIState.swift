import Foundation

/// Per-device UI state restored at launch: the open browser windows (each with its selected Space
/// and tab and whether its sidebar was showing) and a few app-level Library flags.
///
/// Files written before multiple windows (B14) have no `windows` list; their top-level selection
/// stands for one window (`restorableWindows`). New files keep the top-level fields as a copy of
/// the first window, so an older build still restores that one.
///
/// This is not a sync record and is never part of `WorkspaceState`: another device has its own
/// selection. It lives in `ui-state.json` next to the workspace file. The restore behavior itself
/// is inferred (the spec records no launch behavior); we keep the user where they left off.
public struct UIState: Codable, Hashable, Sendable {
    /// Bump when the format changes incompatibly. A file with a newer version is ignored.
    public static let currentVersion = 1

    public var version: Int
    public var selectedSpaceID: UUID?
    public var selectedTabID: UUID?
    public var isSidebarVisible: Bool
    /// Whether the Library's Media intro card was dismissed. [06 §8] observed that the card shows
    /// on the first visit; keeping it dismissed across launches is inferred.
    public var mediaIntroDismissed: Bool
    /// Raw value of the last Library section shown, reopened by Open Library. inferred. A string,
    /// not the Shell's enum, so this module stays UI-free; an unknown value is ignored by the Shell.
    public var lastLibrarySection: String?
    /// Open browser windows at the last save, front-to-back order not guaranteed (creation order).
    /// Incognito windows are never listed. Empty in files from before B14.
    public var windows: [WindowUIState]
    /// First-run onboarding (D9, own design): true once it was finished or skipped, false while it
    /// is pending (first launch, not yet finished). nil in files from before D9: those devices
    /// already had a workspace, so the Shell treats nil as "do not show" unless there was no
    /// workspace file. Per device, never synced.
    public var onboardingCompleted: Bool?
    /// The faint "Double-click to rename" line under the title of the first tab pinned on this
    /// device was shown. [06 §4] observed: it appears on the first pin only. Per device, never
    /// synced (inferred: a hint belongs to the device it taught). False in older files.
    public var pinRenameHintShown: Bool

    public init(
        selectedSpaceID: UUID? = nil,
        selectedTabID: UUID? = nil,
        isSidebarVisible: Bool = true,
        mediaIntroDismissed: Bool = false,
        lastLibrarySection: String? = nil,
        windows: [WindowUIState] = [],
        onboardingCompleted: Bool? = nil,
        pinRenameHintShown: Bool = false
    ) {
        self.version = Self.currentVersion
        self.selectedSpaceID = selectedSpaceID
        self.selectedTabID = selectedTabID
        self.isSidebarVisible = isSidebarVisible
        self.mediaIntroDismissed = mediaIntroDismissed
        self.lastLibrarySection = lastLibrarySection
        self.windows = windows
        self.onboardingCompleted = onboardingCompleted
        self.pinRenameHintShown = pinRenameHintShown
    }

    /// A state for these windows: the top-level fields copy the first window (for older builds).
    public init(
        windows: [WindowUIState],
        mediaIntroDismissed: Bool = false,
        lastLibrarySection: String? = nil,
        onboardingCompleted: Bool? = nil,
        pinRenameHintShown: Bool = false
    ) {
        let first = windows.first ?? WindowUIState()
        self.init(
            selectedSpaceID: first.selectedSpaceID,
            selectedTabID: first.selectedTabID,
            isSidebarVisible: first.isSidebarVisible,
            mediaIntroDismissed: mediaIntroDismissed,
            lastLibrarySection: lastLibrarySection,
            windows: windows,
            onboardingCompleted: onboardingCompleted,
            pinRenameHintShown: pinRenameHintShown
        )
    }

    /// The windows to restore: `windows`, or for a file without that list, one window built from
    /// the top-level fields.
    public var restorableWindows: [WindowUIState] {
        guard windows.isEmpty else { return windows }
        return [WindowUIState(selectedSpaceID: selectedSpaceID, selectedTabID: selectedTabID, isSidebarVisible: isSidebarVisible)]
    }

    /// Persisted key names; never rename.
    private enum CodingKeys: String, CodingKey {
        case version, selectedSpaceID, selectedTabID, isSidebarVisible, mediaIntroDismissed, lastLibrarySection, windows
        case onboardingCompleted
        case pinRenameHintShown
    }

    /// Missing keys fall back to defaults, so an older or partial file still restores what it has.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        selectedSpaceID = try c.decodeIfPresent(UUID.self, forKey: .selectedSpaceID)
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        isSidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true
        mediaIntroDismissed = try c.decodeIfPresent(Bool.self, forKey: .mediaIntroDismissed) ?? false
        lastLibrarySection = try c.decodeIfPresent(String.self, forKey: .lastLibrarySection)
        windows = try c.decodeIfPresent([WindowUIState].self, forKey: .windows) ?? []
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted)
        pinRenameHintShown = try c.decodeIfPresent(Bool.self, forKey: .pinRenameHintShown) ?? false
    }
}

/// One browser window in `UIState`: its selected Space and tab and whether its sidebar shows.
public struct WindowUIState: Codable, Hashable, Sendable {
    public var selectedSpaceID: UUID?
    public var selectedTabID: UUID?
    public var isSidebarVisible: Bool

    public init(selectedSpaceID: UUID? = nil, selectedTabID: UUID? = nil, isSidebarVisible: Bool = true) {
        self.selectedSpaceID = selectedSpaceID
        self.selectedTabID = selectedTabID
        self.isSidebarVisible = isSidebarVisible
    }

    /// Persisted key names; never rename.
    private enum CodingKeys: String, CodingKey {
        case selectedSpaceID, selectedTabID, isSidebarVisible
    }

    /// Missing keys fall back to defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        selectedSpaceID = try c.decodeIfPresent(UUID.self, forKey: .selectedSpaceID)
        selectedTabID = try c.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        isSidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .isSidebarVisible) ?? true
    }
}

extension PersistenceDefaults {
    /// Per-device UI state, next to the workspace file. Persisted name; never rename.
    public static let uiStateFileName = "ui-state.json"
}

/// Reads and writes `ui-state.json`. The file is small and only written on demand (app
/// termination, explicit flush), so there is no debounce.
public enum UIStateFile {
    public static func url(in directory: URL) -> URL {
        directory.appendingPathComponent(PersistenceDefaults.uiStateFileName)
    }

    /// The saved state, or nil when the file is missing, unreadable or from a newer version.
    /// UI state is a convenience, so a bad file is simply ignored (and replaced on the next save).
    public static func load(from directory: URL) -> UIState? {
        guard let data = try? Data(contentsOf: url(in: directory)),
              let state = try? JSONDecoder().decode(UIState.self, from: data),
              state.version <= UIState.currentVersion
        else { return nil }
        return state
    }

    /// Writes the state atomically, creating the directory if needed.
    public static func save(_ state: UIState, to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(state)
        } catch {
            throw PersistenceError.encodingFailed(String(describing: error))
        }
        try AtomicFile.write(data, to: url(in: directory))
    }
}
