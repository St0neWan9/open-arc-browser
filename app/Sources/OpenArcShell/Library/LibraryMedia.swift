import Foundation
import CoreServices
import UniformTypeIdentifiers
import OpenArcModel

// Library ▸ Media (plan B57). [06 §8] observed: a search field "Search Media…" and thumbnail rows
// grouped by date (Today / Yesterday / Earlier This Week); on the first visit an intro card
// "Your Media in the Library — Quickly grab screenshots, images, and videos from your computer by
// showing them in the … Library! [Show Media]" with the note "Media never leaves your computer and
// is not viewable by anyone but you." The spec records no filled list ("Media 内容页未测",
// 00 feature inventory), so the sources, the rows and the actions are inferred:
// - Sources: the folders where a Mac's screenshots, images and videos usually land: the
//   screenshot location (`com.apple.screencapture` `location`, default Desktop), Desktop and
//   Downloads. Top level only, read-only: file metadata (type, dates, size) and, in the view,
//   Quick Look thumbnails. File contents are never read and nothing goes to the network.
// - The card is the opt-in: nothing is scanned (so no folder-access prompt from the system)
//   until it is dismissed. inferred from "[Show Media]" and the privacy note.
// - Date: when the file arrived in its folder (date added), else its creation date, else its
//   modification date. Newest first.

/// What a media file is. inferred (the intro card names screenshots, images and videos).
public enum LibraryMediaKind: String, Hashable, Sendable {
    case screenshot
    case image
    case video

    /// Shown in the row's detail line. inferred.
    public var title: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .image: return "Image"
        case .video: return "Video"
        }
    }
}

/// One media file on the Mac. Metadata only.
public struct LibraryMediaItem: Identifiable, Hashable, Sendable {
    public var url: URL
    public var name: String
    public var kind: LibraryMediaKind
    /// The date the list sorts and groups by (see the file header).
    public var date: Date
    public var byteSize: Int64?

    public init(url: URL, name: String, kind: LibraryMediaKind, date: Date, byteSize: Int64? = nil) {
        self.url = url
        self.name = name
        self.kind = kind
        self.date = date
        self.byteSize = byteSize
    }

    public var id: String { url.path }

    /// Gray second line of a row: kind and size, e.g. "Screenshot · 1.2 MB". inferred.
    public var detail: String {
        guard let byteSize else { return kind.title }
        return kind.title + " · " + ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }
}

/// One date group of the Media list, newest first.
public struct LibraryMediaGroup: Equatable, Sendable {
    public var group: LibraryDateGroup
    public var items: [LibraryMediaItem]
}

/// The folders the Media page lists. Resolved each time the page refreshes, so a changed
/// screenshot location is picked up.
public struct LibraryMediaFolders: Sendable {
    public var resolve: @Sendable () -> [URL]

    public init(resolve: @escaping @Sendable () -> [URL]) {
        self.resolve = resolve
    }

    /// No folders: previews and tests never look at the user's files.
    public static let none = LibraryMediaFolders { [] }

    /// Development override: a colon-separated list of folders that replaces the default ones
    /// (`~` is expanded), so the page can be tried on test folders.
    public static let environmentKey = "OPENARC_MEDIA_DIRS"

    /// What the app uses: `OPENARC_MEDIA_DIRS` if set, else the screenshot location, Desktop and
    /// Downloads of the current user.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> LibraryMediaFolders {
        if let override = overrideFolders(environment: environment) {
            return LibraryMediaFolders { override }
        }
        return LibraryMediaFolders {
            let files = FileManager.default
            return standard(
                desktop: files.urls(for: .desktopDirectory, in: .userDomainMask).first,
                downloads: files.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                screenshotLocation: UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location")
            )
        }
    }

    /// The folders of `OPENARC_MEDIA_DIRS`, or nil when it is unset or blank.
    static func overrideFolders(environment: [String: String]) -> [URL]? {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let folders = raw.split(separator: ":").map { part in
            URL(fileURLWithPath: (String(part) as NSString).expandingTildeInPath, isDirectory: true)
        }
        return unique(folders)
    }

    /// Screenshot location (if set), Desktop, Downloads, without duplicates (the screenshot
    /// location is often the Desktop).
    static func standard(desktop: URL?, downloads: URL?, screenshotLocation: String?) -> [URL] {
        var folders: [URL] = []
        if let location = screenshotLocation?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty {
            folders.append(URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true))
        }
        folders += [desktop, downloads].compactMap { $0 }
        return unique(folders)
    }

    static func unique(_ folders: [URL]) -> [URL] {
        var seen: Set<String> = []
        return folders.filter { seen.insert($0.standardizedFileURL.resolvingSymlinksInPath().path).inserted }
    }
}

// MARK: - Scanning

/// Lists the media files at the top level of folders. Reads directory entries and their metadata
/// only. Runs off the main actor.
public enum LibraryMediaScanner {
    /// Entries looked at per folder, so a huge Downloads folder stays bounded. inferred.
    public static let maxEntriesPerFolder = 20_000

    static let resourceKeys: [URLResourceKey] = [
        .contentTypeKey, .isRegularFileKey, .addedToDirectoryDateKey, .creationDateKey,
        .contentModificationDateKey, .fileSizeKey,
    ]

    /// Media files of `folders`, newest first, at most `limit`. Hidden files, folders and
    /// packages are skipped; a folder that cannot be read is skipped. `isScreenCapture` tells
    /// screenshots apart from other images (Spotlight metadata by default).
    public static func scan(
        _ folders: [URL],
        limit: Int,
        isScreenCapture: (URL) -> Bool = LibraryMediaScanner.spotlightSaysScreenCapture
    ) -> [LibraryMediaItem] {
        var items: [LibraryMediaItem] = []
        var seen: Set<String> = []
        for folder in folders {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: resourceKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
            ) else { continue }
            for url in entries.prefix(maxEntriesPerFolder) {
                guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                      values.isRegularFile == true,
                      let type = values.contentType,
                      isMedia(type),
                      let date = date(added: values.addedToDirectoryDate, created: values.creationDate, modified: values.contentModificationDate),
                      seen.insert(url.standardizedFileURL.path).inserted
                else { continue }
                let screenCapture = type.conforms(to: .image) && isScreenCapture(url)
                guard let kind = kind(for: type, isScreenCapture: screenCapture) else { continue }
                items.append(LibraryMediaItem(
                    url: url, name: url.lastPathComponent, kind: kind, date: date,
                    byteSize: values.fileSize.map(Int64.init)
                ))
            }
        }
        return Array(LibraryMediaCatalog.sorted(items).prefix(max(0, limit)))
    }

    static func isMedia(_ type: UTType) -> Bool {
        type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// Images (screenshots apart) and movies; nil for anything else (audio, documents). inferred.
    public static func kind(for type: UTType, isScreenCapture: Bool) -> LibraryMediaKind? {
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .image) { return isScreenCapture ? .screenshot : .image }
        return nil
    }

    /// The date a file sorts by: added to its folder, else created, else modified. inferred.
    public static func date(added: Date?, created: Date?, modified: Date?) -> Date? {
        added ?? created ?? modified
    }

    /// Spotlight's screen-capture flag (metadata, not file contents). False when Spotlight has
    /// not indexed the file.
    public static func spotlightSaysScreenCapture(_ url: URL) -> Bool {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL),
              let value = MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString)
        else { return false }
        return (value as? Bool) ?? ((value as? NSNumber)?.boolValue ?? false)
    }
}

// MARK: - Sorting, search, grouping

public enum LibraryMediaCatalog {
    /// Newest first; equal dates by name, so the order is stable.
    public static func sorted(_ items: [LibraryMediaItem]) -> [LibraryMediaItem] {
        items.sorted { a, b in
            if a.date != b.date { return a.date > b.date }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Case- and diacritic-insensitive substring of the file name; a blank query matches all.
    /// inferred (as the Archived Tabs search).
    public static func matches(_ item: LibraryMediaItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return true }
        return item.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// The first `limit` items (already newest first) matching `query`, grouped by date in the
    /// group order Today → Older; `hasMore` when matching items were left out. [06 §8] observed
    /// group labels; boundaries as `LibraryDateGroup.group` (inferred).
    public static func page(
        _ items: [LibraryMediaItem], query: String, limit: Int, now: Date, calendar: Calendar
    ) -> (groups: [LibraryMediaGroup], hasMore: Bool) {
        let matching = items.filter { matches($0, query: query) }
        var buckets: [LibraryDateGroup: [LibraryMediaItem]] = [:]
        for item in matching.prefix(max(0, limit)) {
            buckets[LibraryDateGroup.group(of: item.date, now: now, calendar: calendar), default: []].append(item)
        }
        let groups = LibraryDateGroup.allCases.compactMap { group in
            buckets[group].map { LibraryMediaGroup(group: group, items: $0) }
        }
        return (groups, matching.count > limit)
    }
}

// MARK: - Model

/// The Media page's files, live from disk while the page is on screen. Owned by `LibraryModel`.
@MainActor
public final class LibraryMediaModel: ObservableObject {
    /// Newest first, at most `scanLimit`.
    @Published public private(set) var items: [LibraryMediaItem] = []
    /// True once a scan has finished (the page shows a spinner before).
    @Published public private(set) var hasLoaded = false
    /// Rows shown; grows a page at a time as the list is scrolled to its end.
    @Published public private(set) var displayLimit: Int
    public private(set) var isActive = false

    /// Newest files kept from a scan. inferred.
    public let scanLimit: Int
    /// Rows added per page. inferred.
    public let pageSize: Int

    private let folders: LibraryMediaFolders
    private let isScreenCapture: @Sendable (URL) -> Bool
    private var scanTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var watch: LibraryMediaFolderWatch?

    /// Delay between a folder change and the rescan, so a burst of changes scans once. inferred.
    static let refreshDelay: Duration = .milliseconds(300)

    public init(
        folders: LibraryMediaFolders,
        scanLimit: Int = 2000,
        pageSize: Int = 100,
        isScreenCapture: @escaping @Sendable (URL) -> Bool = { LibraryMediaScanner.spotlightSaysScreenCapture($0) }
    ) {
        self.folders = folders
        self.scanLimit = scanLimit
        self.pageSize = pageSize
        self.displayLimit = pageSize
        self.isScreenCapture = isScreenCapture
    }

    /// The page came on screen: rescans and watches the folders until `deactivate`.
    public func activate() {
        if !isActive {
            isActive = true
            displayLimit = pageSize
        }
        refresh()
    }

    /// The page left the screen: stops watching and scanning. Items stay for the next visit.
    public func deactivate() {
        isActive = false
        watch = nil
        scanTask?.cancel()
        scanTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Rescans now (replacing a scan in flight) and re-arms the folder watch. The returned task
    /// finishes when the items are updated.
    @discardableResult
    public func refresh() -> Task<Void, Never> {
        scanTask?.cancel()
        let folderList = folders.resolve()
        if isActive { watch = LibraryMediaFolderWatch(folders: folderList) { [weak self] in self?.folderDidChange() } }
        let limit = scanLimit
        let isScreenCapture = self.isScreenCapture
        let task = Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                LibraryMediaScanner.scan(folderList, limit: limit, isScreenCapture: isScreenCapture)
            }.value
            guard let self, !Task.isCancelled else { return }
            if self.items != found { self.items = found }
            self.hasLoaded = true
        }
        scanTask = task
        return task
    }

    /// The end of the list came on screen: shows the next page.
    public func showMore() {
        displayLimit += pageSize
    }

    private func folderDidChange() {
        guard isActive else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.refreshDelay)
            guard let self, !Task.isCancelled, self.isActive else { return }
            self.refresh()
        }
    }
}

/// Kernel-event watch (DispatchSource, `O_EVTONLY`) on folders: entries added, removed or renamed.
/// Cancelled when released.
final class LibraryMediaFolderWatch {
    private var sources: [any DispatchSourceFileSystemObject] = []

    /// `onChange` runs on the main actor.
    init(folders: [URL], onChange: @escaping @MainActor () -> Void) {
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
            )
            source.setEventHandler {
                MainActor.assumeIsolated { onChange() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    deinit {
        for source in sources { source.cancel() }
    }
}

// MARK: - Library hooks

extension LibraryModel {
    /// The Media page watches its folders only while it is on screen and the intro card has been
    /// dismissed (the card is the opt-in, see the file header).
    func updateMediaActivity() {
        if section == .media && !isMediaIntroVisible {
            media.activate()
        } else if media.isActive {
            media.deactivate()
        }
    }

    /// Media groups for the current search, at most `media.displayLimit` rows.
    public var mediaPage: (groups: [LibraryMediaGroup], hasMore: Bool) {
        LibraryMediaCatalog.page(media.items, query: query(for: .media), limit: media.displayLimit, now: currentDate, calendar: calendar)
    }

    /// Click on a media row: opens the file in a new tab, which the web panel next to the list
    /// shows; the Library stays open, so more files can be looked at. inferred (the spec shows no
    /// click; Archived Tabs rows open in a tab too).
    @discardableResult
    public func openMedia(_ item: LibraryMediaItem) -> UUID? {
        sidebar.newTab(url: item.url, title: item.name)
    }
}
