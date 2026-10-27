import XCTest
import UniformTypeIdentifiers
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Library ▸ Media (B57). Acceptance: `06 §8` (Media: "Search Media…", date groups Today /
/// Yesterday / Earlier This Week, first-visit intro card); the sources, rows and paging are
/// inferred (see LibraryMedia.swift).
@MainActor
final class LibraryMediaTests: XCTestCase {
    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1 // Sunday
        return c
    }()

    private func at(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func item(_ name: String, _ iso: String, kind: LibraryMediaKind = .image) -> LibraryMediaItem {
        LibraryMediaItem(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name, kind: kind, date: at(iso))
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("b57-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// Writes an empty file and sets its creation and modification date.
    private func touch(_ dir: URL, _ name: String, _ date: Date) throws {
        let url = dir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    // MARK: Pure logic

    /// [06 §8] observed group labels; newest first inside a group, groups Today → Older.
    func testGroupsNewestFirst() {
        // Wednesday 2026-10-28, week from Sunday 10-25.
        let now = at("2026-10-28T15:00:00Z")
        let items = LibraryMediaCatalog.sorted([
            item("old.png", "2026-10-01T10:00:00Z"),
            item("today-early.png", "2026-10-28T08:00:00Z"),
            item("yesterday.mov", "2026-10-27T22:00:00Z", kind: .video),
            item("today-late.png", "2026-10-28T14:00:00Z", kind: .screenshot),
            item("sunday.jpg", "2026-10-25T01:00:00Z"),
        ])
        let page = LibraryMediaCatalog.page(items, query: "", limit: 100, now: now, calendar: utc)
        XCTAssertEqual(page.groups.map(\.group.title), ["Today", "Yesterday", "Earlier This Week", "Older"])
        XCTAssertEqual(page.groups[0].items.map(\.name), ["today-late.png", "today-early.png"])
        XCTAssertEqual(page.groups[1].items.map(\.name), ["yesterday.mov"])
        XCTAssertEqual(page.groups[2].items.map(\.name), ["sunday.jpg"])
        XCTAssertFalse(page.hasMore)
    }

    /// "Search Media…" [06 §8] observed; matching on the file name, case- and diacritic-insensitive. inferred.
    func testSearchFiltersByName() {
        let now = at("2026-10-28T15:00:00Z")
        let items = [item("Café Photo.PNG", "2026-10-28T10:00:00Z"), item("diagram.png", "2026-10-28T09:00:00Z")]
        let hit = LibraryMediaCatalog.page(items, query: "  cafe ", limit: 10, now: now, calendar: utc)
        XCTAssertEqual(hit.groups.flatMap(\.items).map(\.name), ["Café Photo.PNG"])
        XCTAssertTrue(LibraryMediaCatalog.page(items, query: "zzz", limit: 10, now: now, calendar: utc).groups.isEmpty)
        XCTAssertEqual(LibraryMediaCatalog.page(items, query: "", limit: 10, now: now, calendar: utc).groups.flatMap(\.items).count, 2)
    }

    /// Paging: the first `limit` matches show, `hasMore` tells the list to load the next page. inferred.
    func testPageLimit() {
        let now = at("2026-10-28T15:00:00Z")
        let items = LibraryMediaCatalog.sorted((0..<5).map { item("f\($0).png", "2026-10-28T0\($0):00:00Z") })
        let page = LibraryMediaCatalog.page(items, query: "", limit: 3, now: now, calendar: utc)
        XCTAssertEqual(page.groups.flatMap(\.items).map(\.name), ["f4.png", "f3.png", "f2.png"])
        XCTAssertTrue(page.hasMore)
    }

    /// Kinds and the sort date: added, else created, else modified. inferred.
    func testKindAndDate() {
        XCTAssertEqual(LibraryMediaScanner.kind(for: .png, isScreenCapture: true), .screenshot)
        XCTAssertEqual(LibraryMediaScanner.kind(for: .jpeg, isScreenCapture: false), .image)
        XCTAssertEqual(LibraryMediaScanner.kind(for: .quickTimeMovie, isScreenCapture: false), .video)
        XCTAssertNil(LibraryMediaScanner.kind(for: .pdf, isScreenCapture: false))
        XCTAssertNil(LibraryMediaScanner.kind(for: .mp3, isScreenCapture: false))
        let a = at("2026-10-01T00:00:00Z"), b = at("2026-10-02T00:00:00Z"), c = at("2026-10-03T00:00:00Z")
        XCTAssertEqual(LibraryMediaScanner.date(added: a, created: b, modified: c), a)
        XCTAssertEqual(LibraryMediaScanner.date(added: nil, created: b, modified: c), b)
        XCTAssertEqual(LibraryMediaScanner.date(added: nil, created: nil, modified: c), c)
    }

    /// The intro card names "screenshots, images, and videos from your computer" [06 §8]: the
    /// screenshot location (if set), Desktop and Downloads, without duplicates. inferred.
    func testFolderSources() {
        let desktop = URL(fileURLWithPath: "/Users/u/Desktop", isDirectory: true)
        let downloads = URL(fileURLWithPath: "/Users/u/Downloads", isDirectory: true)
        XCTAssertEqual(LibraryMediaFolders.standard(desktop: desktop, downloads: downloads, screenshotLocation: nil).map(\.path),
                       ["/Users/u/Desktop", "/Users/u/Downloads"])
        XCTAssertEqual(LibraryMediaFolders.standard(desktop: desktop, downloads: downloads, screenshotLocation: "/Users/u/Shots").map(\.path),
                       ["/Users/u/Shots", "/Users/u/Desktop", "/Users/u/Downloads"])
        XCTAssertEqual(LibraryMediaFolders.standard(desktop: desktop, downloads: downloads, screenshotLocation: "/Users/u/Desktop/").map(\.path),
                       ["/Users/u/Desktop", "/Users/u/Downloads"])
        XCTAssertEqual(LibraryMediaFolders.overrideFolders(environment: ["OPENARC_MEDIA_DIRS": "/a:/b"])?.map(\.path), ["/a", "/b"])
        XCTAssertNil(LibraryMediaFolders.overrideFolders(environment: ["OPENARC_MEDIA_DIRS": "  "]))
        XCTAssertNil(LibraryMediaFolders.overrideFolders(environment: [:]))
    }

    // MARK: Scanning and the view model (temp directory)

    /// Only top-level images and videos are listed, newest first; others, hidden files and
    /// subfolders are skipped. [06 §8], inferred sources.
    func testScanTempDirectory() throws {
        let dir = try makeTempDir()
        try touch(dir, "a.png", at("2026-10-28T10:00:00Z"))
        try touch(dir, "b.mov", at("2026-10-28T12:00:00Z"))
        try touch(dir, "notes.txt", at("2026-10-28T13:00:00Z"))
        try touch(dir, ".hidden.png", at("2026-10-28T13:00:00Z"))
        let sub = dir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try touch(sub, "deep.png", at("2026-10-28T13:00:00Z"))
        let found = LibraryMediaScanner.scan([dir, dir], limit: 10) { $0.lastPathComponent == "a.png" }
        // Order is by "added to folder" (the write time here), covered by the catalog tests.
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0.kind) }), ["b.mov": .video, "a.png": .screenshot])
        XCTAssertEqual(LibraryMediaScanner.scan([dir], limit: 1, isScreenCapture: { _ in false }).count, 1)
        XCTAssertTrue(LibraryMediaScanner.scan([dir.appendingPathComponent("missing")], limit: 10).isEmpty)
    }

    /// The Media page lists nothing while the intro card shows (the card is the opt-in), and
    /// lists the folder's media, grouped by date and filtered by the search, once it is dismissed.
    /// [06 §8] observed card, search and groups; inferred opt-in.
    func testShellModelListsMediaAfterIntro() async throws {
        let dir = try makeTempDir()
        let now = Date()
        try touch(dir, "shot one.png", now.addingTimeInterval(-60))
        try touch(dir, "clip.mov", now.addingTimeInterval(-120))
        var deps = AppDependencies.fake()
        deps.mediaFolders = LibraryMediaFolders { [dir] }
        let model = ShellModel(dependencies: deps, workspace: SidebarFixture().ws, now: { now })
        defer { model.stop() }
        let library = model.library

        model.openLibrary(.media)
        XCTAssertTrue(library.isMediaIntroVisible)
        XCTAssertFalse(library.media.isActive, "nothing is scanned before the card is dismissed")

        library.dismissMediaIntro()
        XCTAssertTrue(library.media.isActive)
        await library.media.refresh().value
        XCTAssertTrue(library.media.hasLoaded)
        XCTAssertEqual(library.mediaPage.groups.first?.group, .today)
        // The sort date is "added to folder", which is the write time here, so the order is not checked.
        XCTAssertEqual(Set(library.mediaPage.groups.flatMap(\.items).map(\.name)), ["shot one.png", "clip.mov"])

        library.searchText[.media] = "SHOT"
        XCTAssertEqual(library.mediaPage.groups.flatMap(\.items).map(\.name), ["shot one.png"])
        library.searchText[.media] = nil

        // A new file shows after a refresh (the page also refreshes on folder changes).
        try touch(dir, "new.jpg", now)
        await library.media.refresh().value
        XCTAssertTrue(library.mediaPage.groups.flatMap(\.items).map(\.name).contains("new.jpg"))

        // A click opens the file in a tab; the Library stays open. inferred.
        let item = try XCTUnwrap(library.mediaPage.groups.first?.items.first)
        let tabID = try XCTUnwrap(library.openMedia(item))
        XCTAssertEqual(model.workspace.tabs[tabID]?.url, item.url)
        XCTAssertTrue(model.isLibraryActive)

        // Leaving the page stops the watch.
        library.open(.downloads)
        XCTAssertFalse(library.media.isActive)
        model.exitLibrary()
    }

    /// Paging in the view model: `showMore` grows the visible rows by a page. inferred.
    func testShowMorePages() async throws {
        let dir = try makeTempDir()
        let now = Date()
        for i in 0..<5 { try touch(dir, "p\(i).png", now.addingTimeInterval(Double(-i))) }
        let media = LibraryMediaModel(folders: LibraryMediaFolders { [dir] }, scanLimit: 4, pageSize: 2, isScreenCapture: { _ in false })
        media.activate()
        defer { media.deactivate() }
        await media.refresh().value
        XCTAssertEqual(media.items.count, 4, "the scan keeps the newest scanLimit files")
        XCTAssertEqual(media.displayLimit, 2)
        media.showMore()
        XCTAssertEqual(media.displayLimit, 4)
    }
}
