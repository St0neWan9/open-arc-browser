import Foundation
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcImport

// Open Arc ▸ Import from Another Browser… (plans D3 and D3b). [01 §Arc] observed: the menu item,
// after Set as Default Browser. [00] records the import wizard as not captured: the sheet, the
// sources it lists, the data kinds, the summary and where the data lands are inferred.
//
// - Bookmarks are read by the shell and become pinned tabs and folders in a new Space (D3,
//   `BookmarkImportMapper`).
// - History and passwords go into the current profile's engine data through the engine's importer
//   (D3b, `EngineImporter`): Chromium-family profiles directly (passwords need the browser's
//   keychain key, which macOS asks the user for), Safari's history from `~/Library/Safari` when
//   Open Arc has Full Disk Access (never requested: the sheet explains how to grant it), and
//   Safari's passwords from its export file (File ▸ Export Browsing Data…).
// - Arc (D15): its sidebar file becomes new Spaces with their pinned tabs, folders, Today tabs and
//   favorites (`ArcSidebarReader`, `ForeignSidebarMapper`); its Chromium profile's history and
//   passwords go through the engine like Chrome's.

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
                    theme: SpaceFlowLocalTokens.defaultThemeStyle,
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

    /// Imports another browser's sidebar (D15: Arc) as new Spaces appended to the current
    /// profile's dock, in one mutation. Returns the summary, or nil when there is no profile or the
    /// mapping fails (the workspace is unchanged then).
    @discardableResult
    func importForeignSidebar(_ sidebar: ForeignSidebar) -> ForeignSidebarImportSummary? {
        guard let profileID = currentProfileID else { return nil }
        let stamp = now()
        var summary: ForeignSidebarImportSummary?
        do {
            try mutate(origin: nil) { state in
                let result = try ForeignSidebarMapper.apply(
                    sidebar, to: state, profileID: profileID,
                    defaultTheme: SpaceFlowLocalTokens.defaultThemeStyle,
                    knownSymbols: Set(SpaceFlowLocalTokens.symbols), now: stamp, makeID: makeID
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
    static let message = "Bookmarks become pinned tabs and folders in a new Space. History and passwords go to this profile."
    static let chooseFile = "Choose File…"
    static let importButton = "Import"
    static let cancel = "Cancel"
    static let done = "Done"
    static let importing = "Importing…"
    static let noProfiles = "No Arc, Chrome, Brave, Edge, Chromium or Vivaldi profiles were found."
    static let fileHint = "Bookmarks: an HTML export or Safari's Bookmarks.plist. History and passwords: Safari's File ▸ Export Browsing Data… (ZIP) or a passwords CSV."
    static let safari = "Safari"
    static let arc = "Arc"
    static let arcHint = "Arc’s Spaces, pinned tabs, folders, Today tabs and favorites become new Spaces after yours. Importing again adds them again."
    static let safariHint = "Safari’s history needs Full Disk Access for Open Arc (System Settings ▸ Privacy & Security). For Safari’s bookmarks and passwords, export them from Safari and choose the file."
    static let keychainHint = "macOS will ask to let Open Arc read the browser’s password key."
    static let fullDiskAccessURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static let openPrivacySettings = "Open Privacy Settings"
    static let noEngineKinds = "History and passwords need the Chromium engine."
    static let sheetWidth: Double = 440

    static func label(for kind: ImportDataKind, isSidebarSource: Bool = false) -> String {
        switch kind {
        case .bookmarks: return isSidebarSource ? "Sidebar (Spaces, tabs and favorites)" : "Bookmarks"
        case .history: return "History"
        case .passwords: return "Passwords"
        }
    }
}

/// One line of the summary after an import.
public struct ImportSummaryLine: Hashable, Sendable {
    public var text: String
    public var isError: Bool
    /// The line is about missing Full Disk Access (the sheet offers to open Privacy settings).
    public var needsFullDiskAccess: Bool = false
}

/// State and actions of the import sheet. One per presentation.
@MainActor
public final class BookmarkImportModel: ObservableObject {
    /// A source the sheet lists.
    public enum Source: Hashable, Identifiable, Sendable {
        case chromium(BrowserProfile)
        /// Safari's library folder (`~/Library/Safari`).
        case safari(URL)
        /// Arc (D15): its sidebar file and its Default Chromium profile; either may be missing.
        case arc(sidebarFile: URL?, profile: BrowserProfile?)

        public var id: String {
            switch self {
            case .chromium(let profile): return profile.id
            case .safari: return "safari"
            case .arc: return "arc"
            }
        }
    }

    public enum Phase: Equatable {
        case choosing
        case importing
        case done([ImportSummaryLine])
        case failed(String)
    }

    /// Sources found when the sheet opens: Chromium-family profiles, then Safari.
    @Published public private(set) var sources: [Source] = []
    @Published public var selectedSourceID: Source.ID? {
        didSet { if selectedSourceID != oldValue { resetKindsToSource() } }
    }
    /// The kinds checked in the sheet.
    @Published public var selectedKinds: Set<ImportDataKind> = []
    @Published public private(set) var phase: Phase = .choosing
    /// The last bookmark import's result (the new Space), for tests and the caller.
    public private(set) var lastBookmarkSummary: BookmarkImportSummary?
    /// The last sidebar import's result (D15), for tests and the caller.
    public private(set) var lastSidebarSummary: ForeignSidebarImportSummary?
    /// The last engine import's result (history and passwords), for tests and the caller.
    public private(set) var lastEngineResult: EngineImportResult?

    private weak var controller: WorkspaceController?
    private let home: URL
    private let fileManager: FileManager
    private let importer: any EngineImporter
    /// Closes the sheet. Installed by the presenter.
    var onClose: (() -> Void)?

    /// - Parameters:
    ///   - home: the folder whose `Library/Application Support` and `Library/Safari` are looked at
    ///     (tests pass a temporary fake home).
    ///   - importer: the engine's importer; nil takes the controller's engine's.
    public init(
        controller: WorkspaceController, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default, importer: (any EngineImporter)? = nil
    ) {
        self.controller = controller
        self.home = home
        self.fileManager = fileManager
        self.importer = importer ?? controller.dependencies.engine.importer
        reloadSources()
    }

    /// Chromium-family profiles with bookmarks, history or passwords (for compatibility with D3).
    public var profiles: [BrowserProfile] {
        sources.compactMap { if case .chromium(let profile) = $0 { return profile } else { return nil } }
    }

    public var selectedSource: Source? { sources.first { $0.id == selectedSourceID } }

    public func reloadSources() {
        var found = arcSources() + BrowserProfileDiscovery.discover(home: home, fileManager: fileManager).map(Source.chromium)
        // Safari is listed when its library folder exists. Its contents are not read here: that
        // needs Full Disk Access, which the import reports if it is missing.
        let safari = home.appendingPathComponent("Library/Safari", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: safari.path, isDirectory: &isDirectory), isDirectory.boolValue {
            found.append(.safari(safari))
        }
        sources = found
        if selectedSourceID.map({ id in sources.contains { $0.id == id } }) != true {
            selectedSourceID = sources.first?.id
        }
        resetKindsToSource()
    }

    /// Arc first (D15: people switching from Arc), when its sidebar file or a profile exists: one
    /// source for the sidebar and the Default profile, and one per further Arc profile (history and
    /// passwords only). Only the files' existence is checked here.
    private func arcSources() -> [Source] {
        let sidebar = home.appendingPathComponent(ArcSidebarReader.relativeFilePath)
        var isDirectory: ObjCBool = false
        let hasSidebar = fileManager.fileExists(atPath: sidebar.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        let profiles = BrowserProfileDiscovery.discover(home: home, browsers: [.arc], fileManager: fileManager)
        let main = profiles.first { $0.directoryName == "Default" }
        var sources: [Source] = []
        if hasSidebar || main != nil {
            sources.append(.arc(sidebarFile: hasSidebar ? sidebar : nil, profile: main))
        }
        sources += profiles.filter { $0.directoryName != "Default" }.map(Source.chromium)
        return sources
    }

    /// Label in the source list: "Chrome — Work" (the profile name is left out for a lone Default).
    public func label(for source: Source) -> String {
        switch source {
        case .chromium(let profile): return label(for: profile)
        case .safari: return BookmarkImportLocalTokens.safari
        case .arc: return BookmarkImportLocalTokens.arc
        }
    }

    public func label(for profile: BrowserProfile) -> String {
        let siblings = profiles.filter { $0.browser == profile.browser }
        if siblings.count == 1, profile.directoryName == "Default" { return profile.browser.displayName }
        return "\(profile.browser.displayName) — \(profile.profileName)"
    }

    /// Whether the engine can import this kind at all.
    public func engineSupports(_ kind: ImportDataKind) -> Bool {
        switch kind {
        case .bookmarks: return true
        case .history: return importer.supportedKinds.contains(.history)
        case .passwords: return importer.supportedKinds.contains(.passwords)
        }
    }

    /// The kinds the selected source offers, in sheet order. Safari's bookmarks and passwords come
    /// from its export files (Choose File…), so the Safari row offers history only.
    public func availableKinds(for source: Source?) -> [ImportDataKind] {
        guard let source else { return [] }
        switch source {
        case .chromium(let profile):
            return ImportDataKind.allCases.filter { kind in
                guard ImportDataKind.availableInShell.contains(kind), engineSupports(kind) else { return false }
                switch kind {
                case .bookmarks: return profile.hasBookmarks
                case .history: return profile.hasHistory
                case .passwords: return profile.hasPasswords
                }
            }
        case .safari:
            return engineSupports(.history) ? [.history] : []
        case .arc(let sidebarFile, let profile):
            // The sidebar takes the bookmarks checkbox: Arc keeps no separate bookmarks.
            var kinds: [ImportDataKind] = sidebarFile == nil ? [] : [.bookmarks]
            if let profile, profile.hasHistory, engineSupports(.history) { kinds.append(.history) }
            if let profile, profile.hasPasswords, engineSupports(.passwords) { kinds.append(.passwords) }
            return kinds
        }
    }

    private func resetKindsToSource() {
        selectedKinds = Set(availableKinds(for: selectedSource))
    }

    public var canImport: Bool {
        phase == .choosing && selectedSource != nil && !selectedKinds.isEmpty
    }

    /// Imports the checked kinds from the selected source.
    public func importSelected() async {
        guard canImport, let source = selectedSource, let controller else { return }
        let kinds = selectedKinds.intersection(availableKinds(for: source))
        phase = .importing
        var lines: [ImportSummaryLine] = []
        switch source {
        case .chromium(let profile):
            if kinds.contains(.bookmarks) {
                let name = profiles.filter({ $0.browser == profile.browser }).count > 1
                    ? "\(profile.browser.displayName) (\(profile.profileName))"
                    : profile.browser.displayName
                lines.append(importBookmarkFile(profile.bookmarksFile, source: name, controller: controller))
            }
            let engineKinds = Self.engineKinds(kinds)
            if !engineKinds.isEmpty {
                let request = EngineImportSource.chromiumProfile(
                    directory: profile.directory,
                    keychainService: profile.browser.keychainService, keychainAccount: profile.browser.keychainAccount
                )
                lines += await importEngineData(engineKinds, from: request, controller: controller)
            }
        case .safari(let library):
            lines += await importEngineData(Self.engineKinds(kinds), from: .safari(libraryDirectory: library), controller: controller)
        case .arc(let sidebarFile, let profile):
            if kinds.contains(.bookmarks), let sidebarFile {
                lines.append(importSidebarFile(sidebarFile, controller: controller))
            }
            let engineKinds = Self.engineKinds(kinds)
            if !engineKinds.isEmpty, let profile {
                let request = EngineImportSource.chromiumProfile(
                    directory: profile.directory,
                    keychainService: profile.browser.keychainService, keychainAccount: profile.browser.keychainAccount
                )
                lines += await importEngineData(engineKinds, from: request, controller: controller)
            }
        }
        phase = .done(lines)
    }

    /// Kept for D3 callers: imports the selected profile's bookmarks only.
    public func importSelectedProfile() {
        guard let controller, case .chromium(let profile)? = selectedSource else { return }
        let name = profiles.filter({ $0.browser == profile.browser }).count > 1
            ? "\(profile.browser.displayName) (\(profile.profileName))"
            : profile.browser.displayName
        let line = importBookmarkFile(profile.bookmarksFile, source: name, controller: controller)
        phase = line.isError ? .failed(line.text) : .done([line])
    }

    /// Imports a file the user chose: a bookmarks file (HTML export, Safari plist or a Chromium
    /// `Bookmarks` JSON) through the shell, else an export (Safari's ZIP, a passwords CSV, a Safari
    /// history JSON) through the engine.
    public func importFile(_ url: URL) {
        guard let controller else { return }
        // A Safari history JSON starts like a Chromium bookmarks JSON: try the bookmark readers
        // first, then hand export files to the engine.
        let ext = url.pathExtension.lowercased()
        // Arc's sidebar file (D15) is JSON too; it is recognized by its own layout.
        if ext == "json", let sidebar = try? ArcSidebarReader.read(contentsOf: url) {
            let line = importSidebar(sidebar, controller: controller)
            phase = line.isError ? .failed(line.text) : .done([line])
            return
        }
        let bookmarks = Result { try BookmarkFileReader.read(contentsOf: url) }
        if case .failure = bookmarks, ["zip", "csv", "json"].contains(ext),
           engineSupports(.history) || engineSupports(.passwords) {
            let kinds: EngineImportKinds = ext == "csv" ? .passwords : ext == "json" ? .history : [.history, .passwords]
            phase = .importing
            Task { @MainActor in
                let lines = await importEngineData(kinds, from: .exportFile(url), controller: controller, reportNotFound: false)
                phase = lines.isEmpty ? .failed(Self.notAnExport) : .done(lines)
            }
            return
        }
        let line = importBookmarks(bookmarks, url: url, source: nil, controller: controller)
        phase = line.isError ? .failed(line.text) : .done([line])
    }

    public func close() {
        onClose?()
    }

    static let notAnExport = "This file has no bookmarks, history or passwords Open Arc can read."

    private static func engineKinds(_ kinds: Set<ImportDataKind>) -> EngineImportKinds {
        var result: EngineImportKinds = []
        if kinds.contains(.history) { result.insert(.history) }
        if kinds.contains(.passwords) { result.insert(.passwords) }
        return result
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

    private func importSidebarFile(_ url: URL, controller: WorkspaceController) -> ImportSummaryLine {
        do {
            return importSidebar(try ArcSidebarReader.read(contentsOf: url), controller: controller)
        } catch let error as BookmarkImportError {
            return ImportSummaryLine(text: Self.sidebarMessage(for: error), isError: true)
        } catch {
            return ImportSummaryLine(text: error.localizedDescription, isError: true)
        }
    }

    private func importSidebar(_ sidebar: ForeignSidebar, controller: WorkspaceController) -> ImportSummaryLine {
        guard let summary = controller.importForeignSidebar(sidebar) else {
            return ImportSummaryLine(text: "The sidebar could not be added.", isError: true)
        }
        if let first = summary.spaceIDs.first { controller.activeWindow?.sidebar.selectSpace(first) }
        lastSidebarSummary = summary
        return ImportSummaryLine(text: Self.sidebarSummaryText(summary), isError: false)
    }

    static func sidebarMessage(for error: BookmarkImportError) -> String {
        switch error {
        case .unrecognizedFormat, .malformed: return "Arc’s sidebar file has a layout Open Arc cannot read."
        case .unreadable: return "Arc’s sidebar file could not be read."
        }
    }

    /// The summary line after a sidebar import (D15). Counts only; inferred wording.
    static func sidebarSummaryText(_ summary: ForeignSidebarImportSummary) -> String {
        guard summary.spaces > 0 || summary.favorites > 0 else {
            return "Found no Spaces or favorites to import."
        }
        var text = "Added \(plural(summary.spaces, "Space")) with \(plural(summary.tabs, "tab")) in \(plural(summary.folders, "folder"))"
        text += summary.favorites > 0 ? ", and \(plural(summary.favorites, "favorite"))." : "."
        if summary.skipped > 0 {
            text += " Skipped \(plural(summary.skipped, "item")) Open Arc cannot import."
        }
        if summary.existingFavorites > 0 {
            text += " \(plural(summary.existingFavorites, "favorite")) already there."
        }
        if summary.spacesFromOtherProfiles > 0 {
            text += " \(plural(summary.spacesFromOtherProfiles, "Space")) from other Arc profiles joined this profile."
        }
        text += " Your existing Spaces are unchanged; importing again adds new copies."
        return text
    }

    private func importBookmarkFile(_ url: URL, source: String?, controller: WorkspaceController) -> ImportSummaryLine {
        importBookmarks(Result { try BookmarkFileReader.read(contentsOf: url) }, url: url, source: source, controller: controller)
    }

    private func importBookmarks(
        _ read: Result<(format: BookmarkFileFormat, tree: BookmarkTree), any Error>, url: URL, source: String?,
        controller: WorkspaceController
    ) -> ImportSummaryLine {
        do {
            let (format, tree) = try read.get()
            let name = source ?? Self.sourceName(for: url, format: format)
            guard let summary = controller.importBookmarks(tree, source: name) else {
                return ImportSummaryLine(text: "The bookmarks could not be added.", isError: true)
            }
            if let spaceID = summary.spaceID { controller.activeWindow?.sidebar.selectSpace(spaceID) }
            lastBookmarkSummary = summary
            return ImportSummaryLine(text: Self.summaryText(summary), isError: false)
        } catch let error as BookmarkImportError {
            return ImportSummaryLine(text: Self.message(for: error), isError: true)
        } catch {
            return ImportSummaryLine(text: error.localizedDescription, isError: true)
        }
    }

    private func importEngineData(
        _ kinds: EngineImportKinds, from source: EngineImportSource, controller: WorkspaceController,
        reportNotFound: Bool = true
    ) async -> [ImportSummaryLine] {
        guard !kinds.isEmpty else { return [] }
        guard let profileID = controller.currentProfileID, !controller.isOffTheRecord else {
            return [ImportSummaryLine(text: "History and passwords cannot be imported into this window.", isError: true)]
        }
        let result = await importer.importData(kinds, from: source, into: profileID)
        lastEngineResult = result
        return Self.summaryLines(result, reportNotFound: reportNotFound)
    }

    static func message(for error: BookmarkImportError) -> String {
        switch error {
        case .unrecognizedFormat: return "This file is not a bookmarks file Open Arc can read."
        case .malformed(let detail): return "The bookmarks file is damaged (\(detail))."
        case .unreadable(let name): return "“\(name)” could not be read."
        }
    }

    private static func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

    /// The summary line after a bookmark import.
    static func summaryText(_ summary: BookmarkImportSummary) -> String {
        var text = "Added \(plural(summary.bookmarks, "bookmark")) in \(plural(summary.folders, "folder")) to “\(summary.spaceName)”."
        if summary.skipped > 0 {
            text += " Skipped \(plural(summary.skipped, "item")) that are not web or file links."
        }
        return text
    }

    /// The summary lines of an engine import. inferred wording.
    static func summaryLines(_ result: EngineImportResult, reportNotFound: Bool = true) -> [ImportSummaryLine] {
        var lines: [ImportSummaryLine] = []
        func failure(_ status: EngineImportStatus, _ what: String) -> ImportSummaryLine? {
            switch status {
            case .notRequested, .success: return nil
            case .notFound:
                return reportNotFound ? ImportSummaryLine(text: "Found no \(what).", isError: false) : nil
            case .permissionDenied:
                return ImportSummaryLine(
                    text: "Open Arc may not read the \(what). Give it Full Disk Access in System Settings ▸ Privacy & Security, then import again.",
                    isError: true, needsFullDiskAccess: true
                )
            case .keychainDenied:
                return ImportSummaryLine(text: "The \(what) could not be imported: access to the browser’s password key was not allowed.", isError: true)
            case .decryptionFailed:
                return ImportSummaryLine(text: "The \(what) could not be decrypted.", isError: true)
            case .unreadable:
                return ImportSummaryLine(text: "The \(what) could not be read.", isError: true)
            case .unavailable:
                return ImportSummaryLine(text: "The \(what) could not be imported into this profile.", isError: true)
            }
        }
        if result.historyStatus == .success {
            lines.append(ImportSummaryLine(text: "Added \(plural(result.historyCount, "page")) to History.", isError: false))
        } else if let line = failure(result.historyStatus, "history") {
            lines.append(line)
        }
        if result.passwordStatus == .success {
            var text = "Saved \(plural(result.passwordCount, "password"))."
            if result.passwordConflicts > 0 {
                text += " Kept your saved password for \(plural(result.passwordConflicts, "login")) that differ."
            }
            if result.passwordFailures > 0 {
                text += " Skipped \(plural(result.passwordFailures, "login")) that could not be read."
            }
            lines.append(ImportSummaryLine(text: text, isError: false))
        } else if let line = failure(result.passwordStatus, "passwords") {
            lines.append(line)
        }
        return lines
    }
}
