import Foundation
import Combine
import OpenArcModel
import OpenArcImport

// Open Arc ▸ Import from Another Browser… (plan D3, bookmarks only). [01 §Arc] observed: the menu
// item, after Set as Default Browser. The sheet, the sources it lists, the summary and where the
// bookmarks land are inferred (see `BookmarkImportMapper` for the mapping).
//
// History and passwords come with Chromium's importer in phase C (plan D3b): that work adds them as
// further `ImportDataKind`s next to the bookmark readers; this sheet then shows a checkbox per kind.

extension WorkspaceController {
    /// Imports `tree` as a new Space "Imported from <source>" in one mutation, after the active
    /// window's Space, in the current profile. Returns the summary, or nil when there is no profile
    /// (the workspace is unchanged then).
    @discardableResult
    func importBookmarks(_ tree: BookmarkTree, source: String) -> BookmarkImportSummary? {
        guard let profileID = currentProfileID else { return nil }
        let anchor = activeSpaceID
        let stamp = now()
        var summary: BookmarkImportSummary?
        do {
            try mutate(origin: nil) { state in
                let result = try BookmarkImportMapper.apply(
                    tree, to: state, source: source, profileID: profileID, afterSpaceID: anchor,
                    theme: ThemeStyle(colors: [SpaceFlowLocalTokens.defaultThemeColor]),
                    now: stamp, makeID: makeID
                )
                summary = result.summary
                return result.state
            }
        } catch {
            return nil
        }
        return summary
    }
}

/// Values the spec does not give for the import sheet. All inferred.
enum BookmarkImportLocalTokens {
    static let title = "Import from Another Browser"
    static let message = "Bookmarks become pinned tabs and folders in a new Space."
    static let chooseFile = "Choose File…"
    static let importButton = "Import"
    static let cancel = "Cancel"
    static let done = "Done"
    static let noProfiles = "No Chrome, Brave, Edge, Chromium or Vivaldi profiles with bookmarks were found."
    static let fileHint = "Safari: File ▸ Export ▸ Bookmarks…, or choose a copy of Bookmarks.plist. Firefox: export bookmarks to HTML."
    static let laterKinds = "History and passwords can be imported once the Chromium engine is in place."
    static let sheetWidth: Double = 420
}

/// State and actions of the import sheet. One per presentation.
@MainActor
public final class BookmarkImportModel: ObservableObject {
    public enum Phase: Equatable {
        case choosing
        case done(BookmarkImportSummary)
        case failed(String)
    }

    /// Chromium-family profiles with a `Bookmarks` file, found when the sheet opens.
    @Published public private(set) var profiles: [BrowserProfile] = []
    @Published public var selectedProfileID: BrowserProfile.ID?
    @Published public private(set) var phase: Phase = .choosing

    private weak var controller: WorkspaceController?
    private let home: URL
    private let fileManager: FileManager
    /// Closes the sheet. Installed by the presenter.
    var onClose: (() -> Void)?

    /// - Parameter home: the folder whose `Library/Application Support` is searched (tests pass a
    ///   temporary fake home).
    public init(controller: WorkspaceController, home: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.controller = controller
        self.home = home
        self.fileManager = fileManager
        reloadProfiles()
    }

    public func reloadProfiles() {
        profiles = BrowserProfileDiscovery.discover(home: home, fileManager: fileManager)
        if selectedProfileID.map({ id in profiles.contains { $0.id == id } }) != true {
            selectedProfileID = profiles.first?.id
        }
    }

    /// Label in the source list: "Chrome — Work" (the profile name is left out for a lone Default).
    public func label(for profile: BrowserProfile) -> String {
        let siblings = profiles.filter { $0.browser == profile.browser }
        if siblings.count == 1, profile.directoryName == "Default" { return profile.browser.displayName }
        return "\(profile.browser.displayName) — \(profile.profileName)"
    }

    /// Imports the selected profile's bookmarks.
    public func importSelectedProfile() {
        guard let profile = profiles.first(where: { $0.id == selectedProfileID }) else { return }
        let source = profiles.filter({ $0.browser == profile.browser }).count > 1
            ? "\(profile.browser.displayName) (\(profile.profileName))"
            : profile.browser.displayName
        run(file: profile.bookmarksFile, source: source)
    }

    /// Imports a file the user chose (HTML export, Safari plist or a Chromium `Bookmarks` JSON).
    public func importFile(_ url: URL) {
        run(file: url, source: nil)
    }

    public func close() {
        onClose?()
    }

    /// The source name for a chosen file: Safari for its plist, the browser whose data folder holds
    /// a Chromium JSON, else the file name. inferred.
    static func sourceName(for url: URL, format: BookmarkFileFormat) -> String {
        switch format {
        case .safariPlist:
            return "Safari"
        case .chromiumJSON:
            let path = url.standardizedFileURL.path
            if let browser = ChromiumBrowser.known.first(where: { path.contains("/Application Support/\($0.relativeDataPath)/") }) {
                return browser.displayName
            }
            return url.lastPathComponent
        case .netscapeHTML:
            return url.lastPathComponent
        }
    }

    private func run(file url: URL, source: String?) {
        guard let controller else { return }
        do {
            let (format, tree) = try BookmarkFileReader.read(contentsOf: url)
            let name = source ?? Self.sourceName(for: url, format: format)
            guard let summary = controller.importBookmarks(tree, source: name) else {
                phase = .failed("The bookmarks could not be added.")
                return
            }
            if let spaceID = summary.spaceID { controller.activeWindow?.sidebar.selectSpace(spaceID) }
            phase = .done(summary)
        } catch let error as BookmarkImportError {
            phase = .failed(Self.message(for: error))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    static func message(for error: BookmarkImportError) -> String {
        switch error {
        case .unrecognizedFormat: return "This file is not a bookmarks file Open Arc can read."
        case .malformed(let detail): return "The bookmarks file is damaged (\(detail))."
        case .unreadable(let name): return "“\(name)” could not be read."
        }
    }

    /// The summary line after an import.
    static func summaryText(_ summary: BookmarkImportSummary) -> String {
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        var text = "Added \(plural(summary.bookmarks, "bookmark")) in \(plural(summary.folders, "folder")) to “\(summary.spaceName)”."
        if summary.skipped > 0 {
            text += " Skipped \(plural(summary.skipped, "item")) that are not web or file links."
        }
        return text
    }
}
