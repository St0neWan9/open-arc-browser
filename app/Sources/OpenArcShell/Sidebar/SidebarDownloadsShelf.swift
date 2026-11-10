import SwiftUI
import AppKit
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcDesign

// The recent-files shelf (plan B200): resting the pointer on the dock's Library button shows the
// newest downloads, running and finished, at the bottom of the sidebar list.
//
// [06 §42] observed (Arc 1.170, 2026-11-09, 57 fps recordings):
// - about 0.2 s after the pointer reaches the Library button, up to 4 rows rise from the dock,
//   newest at the bottom, over a veil of the window color that fades the list above;
// - row pitch 56, a 38 pt thumbnail at x 9, a 14 pt title at x 60 over a 12 pt gray line
//   ("6 days ago"); the row under the pointer gets a rounded fill, black ≈ 3 % (48 pt high,
//   x 4 to width − 8.5);
// - a running download: a 24 pt near-white disc with a purple progress ring and down arrow,
//   "2.1/31.5 MB · 1m 38s" (received / total · time left) and an × at the right that cancels;
// - the rows stay while the pointer is on them and leave within ≈ 3 frames when it leaves;
// - Arc mixes in recent Library media (screenshots): ours does too once Library ▸ Media is on.
// Opening on click and the right-click menu are inferred.
//
// [06 §43] observed (B203, same recordings, Arc's window active): a download that starts puts a
// 20 pt progress badge on the Library button (it drops in and bounces), an icon flies from the
// click to it, and when the file is done the badge turns into the file's icon for ≈ 33 s.

/// Values of the shelf. [06 §42] observed unless marked.
enum SidebarDownloadsShelfTokens {
    static let maxRows = 4
    static let rowPitch: CGFloat = 56
    static let highlightHeight: CGFloat = 48
    static let highlightLeading: CGFloat = 4
    static let highlightTrailing: CGFloat = 8.5
    /// inferred (≈ the tab rows').
    static let highlightCornerRadius: CGFloat = 8
    static let thumbnailLeading: CGFloat = 9
    static let thumbnailSize: CGFloat = 38
    /// inferred.
    static let thumbnailCornerRadius: CGFloat = 4
    static let titleLeading: CGFloat = 60
    static let titleSize: CGFloat = 14
    static let detailSize: CGFloat = 12
    /// Distance from the right edge to the centre of the cancel ×.
    static let cancelCenterTrailing: CGFloat = 27
    static let progressDiscSize: CGFloat = 24
    /// Progress ring and arrow: the same blue in every theme. [06 §43] observed with Arc's window
    /// active (the purple first read in §42 was an inactive window's).
    static let progressTint = RGBAColor(hex: 0x2849FF)
    static let progressTrack = RGBAColor(hex: 0xD1D6FF)
    static let progressFill = RGBAColor(hex: 0xF1F2FF)
    /// The list fades out over this height above the first row (≈ 70 pt observed).
    static let veilFadeHeight: CGFloat = 70
    /// The list's fade follows the rows: ≈ 130 ms in, ≈ 50 ms out observed (B205).
    static let fadeInDuration: CFTimeInterval = 0.13
    static let fadeOutDuration: CFTimeInterval = 0.06
    /// Hover time on the Library button before the shelf shows (≈ 0.2 s observed).
    static let showDelay: Duration = .milliseconds(200)
    /// Room to move from the button up onto the rows without the shelf closing. inferred.
    static let hideGrace: Duration = .milliseconds(80)
    /// Hidden rows sit closer together toward the dock: row k from the bottom starts this share of
    /// a pitch per step lower (≈ 16 / 56 observed mid-way). inferred.
    static let collapsedSpreadShare: CGFloat = 0.3

    // Badge and flight (B203). [06 §43] observed unless marked.
    /// The badge on the Library button, centered this far from the button's center.
    static let badgeSize: CGFloat = 20
    static let badgeOffset = CGSize(width: 9.5, height: -12.5)
    /// The finished file's icon in place of the badge, and how long it stays (32–35 s observed).
    static let finishedIconSize: CGFloat = 28
    static let finishedIconDuration: Duration = .seconds(33)
    /// The badge drops in from this far above. ≈ 12 pt observed.
    static let badgeDropDistance: CGFloat = 12
    /// A download that started this recently is new (the flight runs for it). inferred.
    static let newDownloadWindow: TimeInterval = 5
}

/// One row of the shelf: a download or a Library media file.
struct SidebarShelfEntry: Identifiable, Equatable {
    enum Source: Equatable {
        case download(DownloadItem)
        case media(LibraryMediaItem)
    }

    let source: Source

    var id: String {
        switch source {
        case .download(let item): return "download:" + item.id
        case .media(let item): return "media:" + item.id
        }
    }

    var title: String {
        switch source {
        case .download(let item): return DownloadRowPresentation(item).title
        case .media(let item): return item.name
        }
    }

    /// The file on disk, once there is one.
    var fileURL: URL? {
        switch source {
        case .download(let item): return item.state == .complete ? item.fileURL : nil
        case .media(let item): return item.url
        }
    }

    /// When it arrived; a download still running counts as now.
    func date(now: Date) -> Date {
        switch source {
        case .download(let item):
            switch item.state {
            case .inProgress, .paused, .needsConfirmation: return now
            default: return item.endDate ?? item.startDate
            }
        case .media(let item): return item.date
        }
    }

    /// A running or paused download: the progress disc and the cancel ×.
    var isActiveDownload: Bool {
        guard case .download(let item) = source else { return false }
        return item.state == .inProgress || item.state == .paused
    }

    var downloadID: String? {
        guard case .download(let item) = source else { return nil }
        return item.id
    }

    /// Received share for the progress ring, nil when the size is unknown.
    var progress: Double? {
        guard case .download(let item) = source, item.totalBytes > 0 else { return nil }
        return min(1, max(0, Double(item.receivedBytes) / Double(item.totalBytes)))
    }

    /// The gray line under the title. [06 §42] observed "6 days ago", "2.1/31.5 MB · 1m 38s".
    func detail(now: Date) -> String {
        guard case .download(let item) = source else { return Self.relative(date(now: now), now: now) }
        switch item.state {
        case .inProgress:
            let amount = Self.amount(received: item.receivedBytes, total: item.totalBytes)
            guard let left = Self.timeLeft(item, now: now) else { return amount }
            return amount + " · " + left
        case .paused:
            // inferred.
            return "Paused · " + Self.amount(received: item.receivedBytes, total: item.totalBytes)
        case .needsConfirmation:
            return item.warningText ?? "This file may be dangerous."
        case .interrupted:
            return "Failed"
        case .cancelled:
            // [06 §42] observed (B204).
            return "Cancelled"
        case .complete:
            return Self.relative(date(now: now), now: now)
        }
    }

    /// "Just now" under a minute (inferred), else "9 minutes ago", "21 hours ago", "6 days ago".
    static func relative(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// "2.1/31.5 MB": decimal units picked by the total, one decimal. Without a total, "2.1 MB".
    static func amount(received: Int64, total: Int64) -> String {
        let reference = Double(total > 0 ? total : received)
        let units: [(String, Double)] = [("GB", 1e9), ("MB", 1e6), ("KB", 1e3)]
        let (name, size) = units.first { reference >= $0.1 } ?? ("KB", 1e3)
        func number(_ bytes: Int64) -> String { String(format: "%.1f", Double(bytes) / size) }
        return total > 0 ? "\(number(received))/\(number(total)) \(name)" : "\(number(received)) \(name)"
    }

    /// Time left at the average rate so far: "1m 38s", "45s", "1h 2m". nil without a total or rate.
    static func timeLeft(_ item: DownloadItem, now: Date) -> String? {
        let elapsed = now.timeIntervalSince(item.startDate)
        guard item.totalBytes > 0, item.receivedBytes > 0, elapsed > 0 else { return nil }
        let rate = Double(item.receivedBytes) / elapsed
        let seconds = Int((Double(item.totalBytes - item.receivedBytes) / rate).rounded())
        guard seconds >= 0 else { return nil }
        if seconds >= 3600 { return "\(seconds / 3600)h \(seconds % 3600 / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    /// The newest `limit` entries, oldest first (the newest sits by the dock). [06 §42] observed
    /// (B204): cancelled downloads stay ("Cancelled"), finished ones whose file was deleted are left
    /// out. A media file that is also a listed download shows once.
    static func recent(downloads: [DownloadItem], media: [LibraryMediaItem], now: Date,
                       limit: Int = SidebarDownloadsShelfTokens.maxRows,
                       fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
                       hidden: Set<String> = []) -> [SidebarShelfEntry] {
        let kept = downloads.filter { item in
            guard item.state == .complete else { return true }
            return item.fileURL.map(fileExists) ?? false
        }
        let downloadFiles = Set(kept.compactMap { $0.fileURL?.standardizedFileURL.path })
        let entries = kept.map { SidebarShelfEntry(source: .download($0)) }
            + media.filter { !downloadFiles.contains($0.url.standardizedFileURL.path) }
                .map { SidebarShelfEntry(source: .media($0)) }
        return Array(entries.filter { !hidden.contains($0.id) }
            .sorted { $0.date(now: now) < $1.date(now: now) }.suffix(limit))
    }
}

/// When the shelf shows and what it lists. Owned by the sidebar view model; not published through
/// it, so hovering the Library button updates only the shelf (B104).
@MainActor
final class SidebarDownloadsShelf: ObservableObject {
    @Published private(set) var isShown = false
    @Published private(set) var entries: [SidebarShelfEntry] = []
    /// The Library button's badge: a running download's progress, or a finished file's icon.
    @Published private(set) var badge: SidebarDownloadBadge?
    /// A download started in this window: the icon flies from the pointer to the badge.
    let flights = PassthroughSubject<String, Never>()
    private var activeDownloadIDs: Set<String> = []
    private var knownDownloadIDs: Set<String> = []
    private var badgeClear: Task<Void, Never>?
    var finishedIconDuration = SidebarDownloadsShelfTokens.finishedIconDuration
    /// Whether this window is the one in use (a flight runs in that window only).
    private var isActiveWindow: () -> Bool = { true }

    private var downloads: LibraryDownloads?
    private var media: LibraryMediaModel?
    private var profileID: () -> UUID? = { nil }
    private var isMediaEnabled: () -> Bool = { false }
    /// Whether the shelf may show now (no drag or swipe running).
    private var canShow: () -> Bool = { true }
    private var openLibraryDownloads: () -> Void = {}
    private(set) var now: () -> Date = { Date() }
    private var sources: AnyCancellable?
    private var isIconHovered = false
    private var isListHovered = false
    private var pending: Task<Void, Never>?
    var showDelay = SidebarDownloadsShelfTokens.showDelay
    var hideGrace = SidebarDownloadsShelfTokens.hideGrace

    /// Hooks the shelf to its sources. Set by the window (`ShellModel`); unattached it never shows.
    func attach(downloads: LibraryDownloads, media: LibraryMediaModel?, profileID: @escaping () -> UUID?,
                isMediaEnabled: @escaping () -> Bool, canShow: @escaping () -> Bool,
                openLibraryDownloads: @escaping () -> Void, now: @escaping () -> Date,
                isActiveWindow: @escaping () -> Bool = { true }) {
        self.isActiveWindow = isActiveWindow
        self.downloads = downloads
        self.media = media
        self.profileID = profileID
        self.isMediaEnabled = isMediaEnabled
        self.canShow = canShow
        self.openLibraryDownloads = openLibraryDownloads
        self.now = now
        let mediaItems = media?.$items.eraseToAnyPublisher() ?? Just([]).eraseToAnyPublisher()
        sources = downloads.$items.combineLatest(mediaItems).sink { [weak self] downloads, media in
            MainActor.assumeIsolated { self?.update(downloads: downloads, media: media) }
        }
        downloads.observe(profileID: profileID())
    }

    /// Follows the profile of the window's Space: the badge and the flight belong to the downloads
    /// of the Space on screen, also before the Library button was ever hovered (B207). Called after
    /// every Space change.
    func profileMayHaveChanged() {
        downloads?.observe(profileID: profileID())
    }

    /// Whether a finished download's file is still there. Tests replace it.
    var fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }

    /// Rows hidden with "Hide from Open Arc" (media files; downloads leave the download list).
    /// For this run of the app. inferred.
    private(set) var hiddenIDs: Set<String> = []
    private var lastDownloads: [DownloadItem] = []
    private var lastMedia: [LibraryMediaItem] = []
    /// A row's menu is open: the shelf stays while it tracks. [06 §42] observed (B206).
    private var isMenuTracking = false
    private var menuObservers: [NSObjectProtocol] = []

    private func update(downloads: [DownloadItem], media: [LibraryMediaItem]) {
        lastDownloads = downloads
        lastMedia = media
        let next = SidebarShelfEntry.recent(downloads: downloads, media: isMediaEnabled() ? media : [], now: now(),
                                            fileExists: fileExists, hidden: hiddenIDs)
        if next != entries { entries = next }
        if isShown, next.isEmpty { setShown(false) }
        updateBadge(downloads)
    }

    /// Follows the downloads for the badge and the flights. [06 §43] observed: the badge shows
    /// the newest running download; when a running download finishes its file's icon takes the
    /// badge's place for ≈ 33 s. Several running downloads: the newest (inferred).
    private func updateBadge(_ downloads: [DownloadItem]) {
        let date = now()
        for item in downloads where !knownDownloadIDs.contains(item.id) {
            knownDownloadIDs.insert(item.id)
            // A file Chromium holds for Keep / Discard (a .dmg from a site seen for the first time)
            // started all the same: it flies too (B207).
            if item.state == .inProgress || item.state == .needsConfirmation,
               date.timeIntervalSince(item.startDate) < SidebarDownloadsShelfTokens.newDownloadWindow,
               isActiveWindow() {
                flights.send(item.id)
            }
        }
        let active = downloads.filter { $0.state == .inProgress || $0.state == .paused || $0.state == .needsConfirmation }
        let finished = downloads.filter { activeDownloadIDs.contains($0.id) && $0.state == .complete && $0.fileURL != nil }
        activeDownloadIDs = Set(active.map(\.id))
        if let newest = active.max(by: { $0.startDate < $1.startDate }) {
            badgeClear?.cancel()
            let progress = SidebarShelfEntry(source: .download(newest)).progress
            let next = SidebarDownloadBadge.progress(id: newest.id, progress: progress)
            if badge != next { badge = next }
        } else if let done = finished.last, let url = done.fileURL {
            badge = .finished(id: done.id, file: url)
            badgeClear?.cancel()
            let duration = finishedIconDuration
            badgeClear = Task { [weak self] in
                try? await Task.sleep(for: duration)
                guard let self, !Task.isCancelled else { return }
                if case .finished = self.badge { self.badge = nil }
            }
        } else if case .progress = badge {
            // Cancelled or failed: nothing to show. inferred.
            badge = nil
        }
    }

    /// The pointer entered or left the dock's Library button.
    func iconHovered(_ hovered: Bool) {
        isIconHovered = hovered
        if hovered { prepareSources() }
        schedule()
    }

    /// The pointer entered or left the shelf's rows.
    func listHovered(_ hovered: Bool) {
        isListHovered = hovered
        schedule()
    }

    /// Closes at once (a row was opened, the sidebar went away).
    func dismiss() {
        pending?.cancel()
        isIconHovered = false
        isListHovered = false
        setShown(false)
    }

    func open(_ entry: SidebarShelfEntry) {
        if case .download(let item) = entry.source, item.state == .needsConfirmation {
            dismiss()
            openLibraryDownloads()
            return
        }
        guard let url = entry.fileURL else { return }
        dismiss()
        NSWorkspace.shared.open(url)
    }

    func cancel(_ entry: SidebarShelfEntry) {
        guard let id = entry.downloadID else { return }
        downloads?.cancel(id)
    }

    // MARK: Row menu (B206)

    /// The items of a row's right-click menu. [06 §42] observed (Arc 1.170, a finished download):
    /// Copy File ‖ Send via iMessage · AirDrop ‖ Open in <app> · Show in Finder ‖ Hide from Arc ·
    /// Move to Trash. A cancelled row has no menu; running rows: none (inferred).
    enum MenuItem: Equatable {
        case copyFile, sendViaMessages, airDrop, openIn(app: String), showInFinder, hide, moveToTrash
    }

    /// Groups of `entry`'s menu, separated by lines; empty without a file on disk.
    static func menu(for entry: SidebarShelfEntry, appName: String?) -> [[MenuItem]] {
        guard entry.fileURL != nil, !entry.isActiveDownload else { return [] }
        if case .download(let item) = entry.source, item.state != .complete { return [] }
        let open: [MenuItem] = (appName.map { [.openIn(app: $0)] } ?? []) + [.showInFinder]
        return [[.copyFile], [.sendViaMessages, .airDrop], open, [.hide, .moveToTrash]]
    }

    /// The default app for `url`, as Finder names it ("Preview"), nil when there is none.
    static func defaultAppName(for url: URL) -> String? {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { return nil }
        return FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
    }

    func perform(_ item: MenuItem, on entry: SidebarShelfEntry) {
        guard let url = entry.fileURL else { return }
        switch item {
        case .copyFile:
            let board = NSPasteboard.general
            board.clearContents()
            board.writeObjects([url as NSURL])
        case .sendViaMessages:
            NSSharingService(named: .composeMessage)?.perform(withItems: [url])
        case .airDrop:
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
        case .openIn:
            open(entry)
        case .showInFinder:
            dismiss()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case .hide:
            hide(entry)
        case .moveToTrash:
            NSWorkspace.shared.recycle([url]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    /// "Hide from Arc": the row leaves the shelf, the file stays. A download also leaves the
    /// download list (Library ▸ Downloads). inferred: Arc's wording only.
    func hide(_ entry: SidebarShelfEntry) {
        hiddenIDs.insert(entry.id)
        if let id = entry.downloadID { downloads?.remove(id) }
        refresh()
    }

    /// Recomputes the rows (a file went to the Trash, a row was hidden).
    private func refresh() {
        update(downloads: lastDownloads, media: lastMedia)
    }

    /// Follows the app's menus while the shelf shows: a row's menu keeps it open.
    private func followMenus(_ follow: Bool) {
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        isMenuTracking = false
        guard follow else { return }
        let center = NotificationCenter.default
        menuObservers = [
            center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isMenuTracking = true }
            },
            center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isMenuTracking = false
                    self.schedule()
                }
            },
        ]
    }

    /// Follows the current profile's downloads and, with Library ▸ Media on, rescans media.
    private func prepareSources() {
        downloads?.observe(profileID: profileID())
        if let media, isMediaEnabled(), !media.isActive { media.activate() }
    }

    private func schedule() {
        pending?.cancel()
        let wantsShown = (isIconHovered || isListHovered || (isShown && isMenuTracking)) && canShow()
        guard wantsShown != isShown else { return }
        let delay = wantsShown ? showDelay : hideGrace
        pending = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            let stillWanted = (self.isIconHovered || self.isListHovered || (self.isShown && self.isMenuTracking)) && self.canShow()
            guard stillWanted == wantsShown else { return }
            self.setShown(wantsShown && !self.entries.isEmpty)
        }
    }

    private func setShown(_ shown: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        followMenus(shown)
        if !shown, let media, media.isActive { media.deactivate() }
    }
}

/// What the Library button carries. [06 §43] observed.
enum SidebarDownloadBadge: Equatable {
    case progress(id: String, progress: Double?)
    case finished(id: String, file: URL)
}

// MARK: - View

/// The shelf over the bottom of the list: the veil and the rows, ending at the list's bottom.
struct SidebarDownloadsShelfView: View {
    @ObservedObject var shelf: SidebarDownloadsShelf
    let palette: ThemePalette
    let layout: SidebarLayout
    @State private var hoveredID: String?

    private typealias T = SidebarDownloadsShelfTokens

    var body: some View {
        let entries = shelf.entries
        let rowsHeight = CGFloat(entries.count) * T.rowPitch
        let bottom = layout.listBottom
        if !entries.isEmpty { shelfBody(entries: entries, rowsHeight: rowsHeight, bottom: bottom) }
    }

    private func shelfBody(entries: [SidebarShelfEntry], rowsHeight: CGFloat, bottom: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            // No fill of its own: the list under it fades out instead (`SidebarSpacePagerView`), so
            // the rows sit on the sidebar. [06 §42] observed (B205).
            ZStack(alignment: .topLeading) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let fromBottom = CGFloat(entries.count - 1 - index)
                    SidebarShelfRow(entry: entry, shelf: shelf, palette: palette, width: layout.width,
                                    isHovered: hoveredID == entry.id)
                        .onHover { inside in
                            if inside { hoveredID = entry.id } else if hoveredID == entry.id { hoveredID = nil }
                        }
                        .offset(y: CGFloat(index) * T.rowPitch
                                + (shelf.isShown ? 0 : fromBottom * T.rowPitch * T.collapsedSpreadShare))
                        .opacity(shelf.isShown ? 1 : 0)
                }
            }
            .frame(width: layout.width, height: rowsHeight, alignment: .topLeading)
            .contentShape(Rectangle())
            .onHover { shelf.listHovered($0) }
            .offset(y: bottom - rowsHeight)
            .allowsHitTesting(shelf.isShown)
        }
        .frame(width: layout.width, height: layout.windowSize.height, alignment: .topLeading)
        .animation(ShellMotion.downloadsShelf(isShown: shelf.isShown), value: shelf.isShown)
        .onChange(of: shelf.isShown) { _, shown in if !shown { hoveredID = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("openarc.sidebar.downloadsShelf")
        .accessibilityHidden(!shelf.isShown)
    }
}

/// One shelf row. [06 §42] observed geometry (`SidebarDownloadsShelfTokens`).
private struct SidebarShelfRow: View {
    let entry: SidebarShelfEntry
    let shelf: SidebarDownloadsShelf
    let palette: ThemePalette
    let width: CGFloat
    let isHovered: Bool

    private typealias T = SidebarDownloadsShelfTokens

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: T.highlightCornerRadius, style: .continuous)
                .fill(palette.isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.03))
                .frame(width: width - T.highlightLeading - T.highlightTrailing, height: T.highlightHeight)
                .offset(x: T.highlightLeading, y: (T.rowPitch - T.highlightHeight) / 2)
                .opacity(isHovered ? 1 : 0)

            icon
                .frame(width: T.thumbnailSize, height: T.thumbnailSize)
                .offset(x: T.thumbnailLeading, y: (T.rowPitch - T.thumbnailSize) / 2)

            // The time left and the relative date move on while the shelf is up.
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: T.titleSize))
                        .foregroundStyle(palette.primaryText.swiftUI)
                    Text(entry.detail(now: shelf.now()))
                        .font(.system(size: T.detailSize))
                        .foregroundStyle(palette.secondaryText.swiftUI)
                }
                .lineLimit(1)
                .truncationMode(.middle)
            }
            .frame(width: max(0, width - T.titleLeading - (entry.isActiveDownload ? 2 * T.cancelCenterTrailing : T.highlightTrailing + 8)),
                   height: T.rowPitch, alignment: .leading)
            .offset(x: T.titleLeading)

            if entry.isActiveDownload {
                Button { shelf.cancel(entry) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(palette.secondaryText.swiftUI)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel Download")
                .offset(x: width - T.cancelCenterTrailing - 12, y: (T.rowPitch - 24) / 2)
            }
        }
        .frame(width: width, height: T.rowPitch, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture { shelf.open(entry) }
        .contextMenu {
            let groups = SidebarDownloadsShelf.menu(for: entry, appName: entry.fileURL.flatMap(SidebarDownloadsShelf.defaultAppName))
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                ForEach(Array(group.enumerated()), id: \.offset) { _, item in
                    Button(Self.title(item)) { shelf.perform(item, on: entry) }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// [06 §42] observed titles; "Arc" is our app's name, "Messages" the system's.
    static func title(_ item: SidebarDownloadsShelf.MenuItem) -> String {
        switch item {
        case .copyFile: return "Copy File"
        case .sendViaMessages: return "Send via iMessage"
        case .airDrop: return "AirDrop"
        case .openIn(let app): return "Open in \(app)"
        case .showInFinder: return "Show in Finder"
        case .hide: return "Hide from Open Arc"
        case .moveToTrash: return "Move to Trash"
        }
    }

    @ViewBuilder
    private var icon: some View {
        if case .download(let item) = entry.source, item.state == .cancelled || item.state == .interrupted {
            // No icon. [06 §42] observed for a cancelled download (B204).
            Color.clear
        } else if entry.isActiveDownload || entry.fileURL == nil {
            SidebarShelfProgressDisc(progress: entry.progress)
        } else if let url = entry.fileURL {
            SidebarShelfThumbnail(url: url)
        }
    }
}

/// A running download's icon: a pale blue disc, a blue ring that fills with the progress over a
/// light track, and a blue down arrow. [06 §42, §43] observed.
struct SidebarShelfProgressDisc: View {
    let progress: Double?
    var size: CGFloat = SidebarDownloadsShelfTokens.progressDiscSize

    private typealias T = SidebarDownloadsShelfTokens

    var body: some View {
        let tint = T.progressTint.swiftUI
        let line = max(1.5, size / 12)
        ZStack {
            Circle().fill(T.progressFill.swiftUI)
            Circle().inset(by: line / 2).stroke(T.progressTrack.swiftUI, lineWidth: line)
            Circle()
                .inset(by: line / 2)
                .trim(from: 0, to: progress ?? 0)
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.down")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }
}

/// The badge on the dock's Library button. [06 §43] observed: it drops in from above and bounces
/// when a download starts; it hides while the shelf is open (the row shows the download).
struct SidebarDownloadBadgeView: View {
    @ObservedObject var shelf: SidebarDownloadsShelf
    let layout: SidebarLayout

    private typealias T = SidebarDownloadsShelfTokens

    var body: some View {
        let button = layout.dockHomeFrame
        let center = CGPoint(x: button.midX + T.badgeOffset.width, y: button.midY + T.badgeOffset.height)
        ZStack {
            switch shelf.isShown ? nil : shelf.badge {
            case .progress(let id, let progress):
                SidebarShelfProgressDisc(progress: progress, size: T.badgeSize)
                    .id(id)
                    .transition(.asymmetric(insertion: .offset(y: -T.badgeDropDistance).combined(with: .opacity),
                                            removal: .opacity))
            case .finished(let id, let file):
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: T.finishedIconSize, height: T.finishedIconSize)
                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
                    .id("finished:" + id)
                    .transition(.opacity)
            case nil:
                EmptyView()
            }
        }
        .animation(ShellMotion.downloadBadgeDrop, value: shelf.isShown ? nil : shelf.badge.map(Self.identity))
        .position(center)
        .frame(width: layout.width, height: layout.windowSize.height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Changes that animate (the progress itself does not).
    private static func identity(_ badge: SidebarDownloadBadge) -> String {
        switch badge {
        case .progress(let id, _): return "progress:" + id
        case .finished(let id, _): return "finished:" + id
        }
    }
}

/// A finished file's Quick Look thumbnail (its Finder icon until it loads).
private struct SidebarShelfThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    private typealias T = SidebarDownloadsShelfTokens

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: T.thumbnailCornerRadius, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .task(id: url) {
            image = await LibraryMediaThumbnails.shared.thumbnail(for: url, size: CGSize(width: T.thumbnailSize, height: T.thumbnailSize))
        }
    }
}
