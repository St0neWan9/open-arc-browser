import Foundation
import AppKit
import UniformTypeIdentifiers
import OpenArcModel

// Settings ▸ Advanced ▸ Export Data (plan B84). [03 §Advanced] observed: a button "Export Data";
// what Arc writes is not recorded (unknown). Ours: one readable JSON file of the user's sidebar,
// in our own format, saved where the user picks (NSSavePanel). It holds the live (not deleted)
// profiles, Spaces, favorites, pinned folders and tabs, Today tabs and the archive, in display
// order. Easels, history, passwords and other engine data are not part of it (inferred: the
// export is the synced workspace the sidebar shows).

/// The export file's content. Field names are part of the file format; keep them stable.
public struct WorkspaceExport: Codable, Hashable, Sendable {
    /// Bump when the format changes incompatibly.
    public static let currentFormatVersion = 1
    /// Identifies the file's format.
    public static let formatName = "org.openarc.workspace-export"

    public struct Tab: Codable, Hashable, Sendable {
        public var title: String
        public var url: String?
        /// The URL saved when the tab was pinned or favorited, when it differs from `url`.
        public var pinnedURL: String?
    }

    public struct Item: Codable, Hashable, Sendable {
        /// "folder" or "tab".
        public var kind: String
        public var title: String
        public var url: String?
        public var pinnedURL: String?
        /// A folder's items, in order; nil for a tab.
        public var items: [Item]?
    }

    public struct SpaceEntry: Codable, Hashable, Sendable {
        public var name: String
        public var icon: String?
        public var pinned: [Item]
        public var today: [Tab]
    }

    public struct ProfileEntry: Codable, Hashable, Sendable {
        public var name: String
        public var favorites: [Tab]
        public var spaces: [SpaceEntry]
    }

    public struct ArchivedTab: Codable, Hashable, Sendable {
        public var title: String
        public var url: String?
        public var archivedAt: Date
        public var space: String?
    }

    public var format: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var application: String
    public var profiles: [ProfileEntry]
    public var archive: [ArchivedTab]

    /// The export of `workspace`'s live content, oldest profile (Default) first, Spaces in dock order.
    public static func make(_ workspace: WorkspaceState, exportedAt: Date, application: String = AppIdentity.displayName) -> WorkspaceExport {
        func tab(_ node: TabNode) -> Tab {
            let url = node.url?.absoluteString
            let pinned = node.pinnedURL?.absoluteString
            return Tab(title: node.displayTitle, url: url, pinnedURL: pinned == url ? nil : pinned)
        }
        func items(spaceID: UUID, folderID: UUID?) -> [Item] {
            workspace.pinnedChildren(spaceID: spaceID, folderID: folderID).map { child in
                switch child {
                case .folder(let folder):
                    return Item(kind: "folder", title: folder.title, url: nil, pinnedURL: nil,
                                items: items(spaceID: spaceID, folderID: folder.id))
                case .tab(let node):
                    let t = tab(node)
                    return Item(kind: "tab", title: t.title, url: t.url, pinnedURL: t.pinnedURL, items: nil)
                }
            }
        }
        let profiles = workspace.liveProfilesOldestFirst.map { profile in
            ProfileEntry(
                name: profile.name,
                favorites: workspace.favorites(profileID: profile.id).map(tab),
                spaces: workspace.spaces(inProfile: profile.id).map { space in
                    SpaceEntry(name: space.name, icon: space.icon,
                               pinned: items(spaceID: space.id, folderID: nil),
                               today: workspace.today(spaceID: space.id).map(tab))
                }
            )
        }
        let archive = workspace.archiveNewestFirst.map { item in
            ArchivedTab(title: item.title, url: item.url?.absoluteString, archivedAt: item.archivedAt,
                        space: item.spaceID.flatMap { workspace.spaces[$0]?.name })
        }
        return WorkspaceExport(format: formatName, formatVersion: currentFormatVersion, exportedAt: exportedAt,
                               application: application, profiles: profiles, archive: archive)
    }

    /// Pretty-printed JSON with sorted keys and ISO 8601 dates.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WorkspaceExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceExport.self, from: data)
    }

    /// Suggested file name, e.g. "Open Arc Export 2026-10-27.json".
    public static func suggestedFileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(AppIdentity.displayName) Export \(formatter.string(from: date)).json"
    }
}

/// Asks where to save the export. Injected so tests never show a panel.
@MainActor
public protocol ExportDestinationPicker: AnyObject, Sendable {
    /// The chosen file URL, or nil when the user cancelled.
    func chooseDestination(suggestedName: String) async -> URL?
}

/// Always cancels (tests, previews, `.fake()`), or answers with a fixed URL (tests).
@MainActor
public final class CancelledExportPicker: ExportDestinationPicker {
    public var answer: URL?
    public private(set) var suggestedNames: [String] = []
    public nonisolated init(answer: URL? = nil) { self.answer = answer }
    public func chooseDestination(suggestedName: String) async -> URL? {
        suggestedNames.append(suggestedName)
        return answer
    }
}

/// The system save panel (JSON files).
@MainActor
public final class SavePanelExportPicker: ExportDestinationPicker {
    public nonisolated init() {}

    public func chooseDestination(suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.title = "Export Data"
        panel.message = "Your Profiles, Spaces, pinned tabs and archive as a JSON file."
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.url : nil
    }
}
