import Foundation
import OpenArcModel
import OpenArcEngine

// The Library's Filter panel (plan B94). [06 §8] Filter (E24), observed: clicking "Filter" swaps
// the search field for a title and a "Done" button, and a set of capsule buttons appears above the
// list. Downloads: "Filter Downloads…", group "Profiles" with one button per Profile. Archived Tabs:
// "Filter Archived Tabs", group "How was the tab closed?" (Auto-Closed, Manually Closed) and group
// "Where was the tab?" (Little Arc, then one button per Space in dock order). "Done" closes the
// panel and brings the search field back.
//
// How chips combine is not observed. inferred: chips of one group are alternatives (OR), groups
// narrow each other (AND), and a group with no chip selected does not filter.

/// One capsule of the Filter panel.
public enum LibraryFilterOption: Hashable, Sendable {
    /// Downloads ▸ Profiles.
    case profile(UUID)
    /// Archived Tabs ▸ How was the tab closed?
    case autoClosed
    case manuallyClosed
    /// Archived Tabs ▸ Where was the tab?
    case littleArc
    case space(UUID)

    public var group: LibraryFilterGroupKind {
        switch self {
        case .profile: return .profiles
        case .autoClosed, .manuallyClosed: return .closing
        case .littleArc, .space: return .origin
        }
    }
}

/// The chip groups of the panel.
public enum LibraryFilterGroupKind: Hashable, Sendable {
    case profiles
    case closing
    case origin

    /// Group label above its chips. [06 §8] observed.
    public var title: String {
        switch self {
        case .profiles: return LibraryTexts.filterProfilesGroup
        case .closing: return LibraryTexts.filterClosingGroup
        case .origin: return LibraryTexts.filterOriginGroup
        }
    }
}

public struct LibraryFilterChip: Identifiable, Equatable, Sendable {
    public var option: LibraryFilterOption
    public var title: String
    public var id: LibraryFilterOption { option }
}

public struct LibraryFilterGroup: Identifiable, Equatable, Sendable {
    public var kind: LibraryFilterGroupKind
    public var chips: [LibraryFilterChip]
    public var id: LibraryFilterGroupKind { kind }
    public var title: String { kind.title }
}

/// The chips switched on.
public struct LibraryFilterSelection: Equatable, Sendable {
    public var options: Set<LibraryFilterOption> = []

    public init(_ options: Set<LibraryFilterOption> = []) {
        self.options = options
    }

    public var isEmpty: Bool { options.isEmpty }

    /// Whether an item with the `traits` passes: every group that has a selected chip must share
    /// at least one option with the item (OR within a group, AND across groups; inferred).
    public func allows(_ traits: Set<LibraryFilterOption>) -> Bool {
        let selectedGroups = Set(options.map(\.group))
        return selectedGroups.allSatisfy { group in
            options.contains { $0.group == group && traits.contains($0) }
        }
    }
}

public enum LibraryFilter {
    /// Title that replaces the search field while the panel is open; nil for sections without a
    /// Filter button. [06 §8] observed.
    public static func title(for section: LibrarySection) -> String? {
        switch section {
        case .downloads: return LibraryTexts.filterDownloadsTitle
        case .archivedTabs: return LibraryTexts.filterArchiveTitle
        case .media, .easels, .spaces, .boosts: return nil
        }
    }

    /// The panel's groups for `section`. Downloads: one chip per live profile, oldest (Default)
    /// first (the order is inferred). Archived Tabs: the two closing chips, then Little Arc and one
    /// chip per live Space in dock order. [06 §8] observed.
    public static func groups(for section: LibrarySection, in workspace: WorkspaceState) -> [LibraryFilterGroup] {
        switch section {
        case .downloads:
            let chips = workspace.liveProfilesOldestFirst.map { LibraryFilterChip(option: .profile($0.id), title: $0.name) }
            return [LibraryFilterGroup(kind: .profiles, chips: chips)]
        case .archivedTabs:
            let closing = [
                LibraryFilterChip(option: .autoClosed, title: LibraryTexts.filterAutoClosed),
                LibraryFilterChip(option: .manuallyClosed, title: LibraryTexts.filterManuallyClosed),
            ]
            let origin = [LibraryFilterChip(option: .littleArc, title: LibraryTexts.filterLittleArc)]
                + workspace.allLiveSpaces.map { LibraryFilterChip(option: .space($0.id), title: $0.name) }
            return [LibraryFilterGroup(kind: .closing, chips: closing), LibraryFilterGroup(kind: .origin, chips: origin)]
        case .media, .easels, .spaces, .boosts:
            return []
        }
    }

    /// What an archived tab answers to. "Auto-Closed" is the idle auto-archive (sidebar tabs and
    /// Little Arc pages); every other way out of the sidebar (⌘W, Today "Clear", deleting the
    /// Space) is a user action, so "Manually Closed". inferred. Where: a Little Arc page is "Little
    /// Arc" (not the Space it would restore into); a sidebar tab is its Space; a favorite (no
    /// Space) matches no "Where" chip.
    public static func traits(of item: ArchiveItem) -> Set<LibraryFilterOption> {
        var traits: Set<LibraryFilterOption> = [item.reason == .autoArchived ? .autoClosed : .manuallyClosed]
        if item.isFromLittleArc {
            traits.insert(.littleArc)
        } else if let spaceID = item.spaceID {
            traits.insert(.space(spaceID))
        }
        return traits
    }

    /// What a download answers to: its profile.
    public static func traits(of item: DownloadItem) -> Set<LibraryFilterOption> {
        [.profile(item.profileID)]
    }
}
