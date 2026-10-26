import Foundation
import XCTest
import OpenArcModel
@testable import OpenArcImport

/// D3: mapping a bookmark tree onto a new Space through `TreeOps`, and finding Chromium-family
/// profiles. All inferred (plan D3); [01 §Arc] observed only the menu item.
final class BookmarkImportMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 5_000)
    private let profile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let home = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    private let work = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

    private func baseState() throws -> WorkspaceState {
        var s = WorkspaceState()
        s.profiles[profile] = Profile(id: profile, name: "Default", now: now)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: now)
        s = try TreeOps.createSpace(s, id: work, profileID: profile, name: "Work", afterSpaceID: home, now: now)
        return s
    }

    private func idMaker() -> () -> UUID {
        var n = 100
        return { n += 1; return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    }

    /// Titles of a pinned container in display order, folders written as "[title]".
    private func outline(_ s: WorkspaceState, space: UUID, folder: UUID? = nil) -> [String] {
        s.pinnedChildren(spaceID: space, folderID: folder).map {
            switch $0 {
            case .folder(let f): return "[\(f.title)]"
            case .tab(let t): return t.title
            }
        }
    }

    private func folderID(_ s: WorkspaceState, space: UUID, parent: UUID? = nil, title: String) -> UUID? {
        s.pinnedChildren(spaceID: space, folderID: parent).compactMap {
            if case .folder(let f) = $0, f.title == title { return f.id } else { return nil }
        }.first
    }

    func testChromeTreeBecomesNewSpaceWithPinnedItemsAndOtherBookmarks() throws {
        let tree = try ChromiumBookmarksParser.parse(Data(BookmarkParserTests.chromeJSON.utf8))
        let base = try baseState()
        let (s, summary) = try BookmarkImportMapper.apply(
            tree, to: base, source: "Chrome", profileID: profile, afterSpaceID: home,
            theme: ThemeStyle(colors: [RGBAColor(hex: 0x7FA6E8)]), now: now, makeID: idMaker()
        )
        let space = try XCTUnwrap(summary.spaceID)
        XCTAssertEqual(s.spaces[space]?.name, "Imported from Chrome")
        XCTAssertNotNil(s.spaces[space]?.themeID.flatMap { s.themes[$0] })
        // Inserted after the anchor Space, like New Space. [06 §1] observed for New Space.
        XCTAssertEqual(s.spaces(inProfile: profile).map(\.name), ["Home", "Imported from Chrome", "Work"])

        // The bar in source order (the bookmarklet skipped), then Other Bookmarks.
        XCTAssertEqual(outline(s, space: space), ["Example", "[Work]", "[Other Bookmarks]"])
        let workFolder = try XCTUnwrap(folderID(s, space: space, title: "Work"))
        XCTAssertEqual(outline(s, space: space, folder: workFolder), ["Docs", "[Deep]", "[Empty]"])
        let deep = try XCTUnwrap(folderID(s, space: space, parent: workFolder, title: "Deep"))
        XCTAssertEqual(outline(s, space: space, folder: deep), ["Deeper"])
        let other = try XCTUnwrap(folderID(s, space: space, title: "Other Bookmarks"))
        XCTAssertEqual(outline(s, space: space, folder: other), ["Other one", "[Mobile bookmarks]"])

        // Top-level folders start expanded, nested ones and Other Bookmarks collapsed.
        XCTAssertEqual(s.folders[workFolder]?.isExpanded, true)
        XCTAssertEqual(s.folders[deep]?.isExpanded, false)
        XCTAssertEqual(s.folders[other]?.isExpanded, false)

        // Pinned tabs keep the bookmark URL as their pinned URL; nothing lands in Today.
        XCTAssertTrue(s.today(spaceID: space).isEmpty)
        let example = try XCTUnwrap(s.allTabs(inSpace: space).first { $0.title == "Example" })
        XCTAssertEqual(example.url, URL(string: "https://example.com/"))
        XCTAssertEqual(example.pinnedURL, example.url)

        // Counts: folders Work, Deep, Empty, Mobile bookmarks; javascript: and chrome:// skipped.
        XCTAssertEqual(summary.folders, 4)
        XCTAssertEqual(summary.bookmarks, 5)
        XCTAssertEqual(summary.skipped, 2)
        // Other Spaces are untouched.
        XCTAssertEqual(s.spaces[home], base.spaces[home])
        XCTAssertEqual(s.spaces[work], base.spaces[work])
    }

    func testDuplicatesAndEmptyFoldersAreKept() throws {
        let tree = BookmarkTree(bar: [
            .bookmark(Bookmark(title: "Same", url: "https://same.example.com/")),
            .bookmark(Bookmark(title: "Same", url: "https://same.example.com/")),
            .folder(BookmarkFolder(title: "Nothing")),
            .bookmark(Bookmark(title: "", url: "https://untitled.example.com/path")),
        ])
        let (s, summary) = try BookmarkImportMapper.apply(
            tree, to: try baseState(), source: "Safari", profileID: profile, afterSpaceID: nil,
            theme: nil, now: now, makeID: idMaker()
        )
        let space = try XCTUnwrap(summary.spaceID)
        XCTAssertEqual(outline(s, space: space), ["Same", "Same", "[Nothing]", "untitled.example.com"])
        XCTAssertEqual(summary.bookmarks, 3)
        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(s.spaces(inProfile: profile).last?.id, space, "no anchor: appended at the end")
        XCTAssertNil(folderID(s, space: space, title: BookmarkImportMapper.otherBookmarksTitle), "no other roots, no Other Bookmarks folder")
    }

    func testSkippedSchemesAreCounted() throws {
        let urls = ["javascript:void(0)", "chrome://flags", "place:folder=1", "about:blank", "data:text/html,hi",
                    "mailto:a@example.com", "not a url", "https://", "https://ok.example.com/", "HTTP://upper.example.com/",
                    "file:///Users/someone/page.html"]
        let tree = BookmarkTree(bar: urls.map { .bookmark(Bookmark(title: $0, url: $0)) })
        let (s, summary) = try BookmarkImportMapper.apply(
            tree, to: try baseState(), source: "Test", profileID: profile, afterSpaceID: nil,
            theme: nil, now: now, makeID: idMaker()
        )
        XCTAssertEqual(summary.bookmarks, 3)
        XCTAssertEqual(summary.skipped, 8)
        let space = try XCTUnwrap(summary.spaceID)
        XCTAssertEqual(s.allTabs(inSpace: space).count, 3)
    }

    func testInvalidProfileChangesNothing() throws {
        let base = try baseState()
        XCTAssertThrowsError(try BookmarkImportMapper.apply(
            BookmarkTree(), to: base, source: "X", profileID: UUID(), afterSpaceID: nil, theme: nil, now: now, makeID: idMaker()
        ))
    }

    func testNewRecordsAreStampedWithNow() throws {
        let tree = BookmarkTree(bar: [.folder(BookmarkFolder(title: "F", children: [.bookmark(Bookmark(title: "A", url: "https://a.example.com/"))]))])
        let base = try baseState()
        let (s, summary) = try BookmarkImportMapper.apply(
            tree, to: base, source: "X", profileID: profile, afterSpaceID: nil, theme: nil, now: now, makeID: idMaker()
        )
        let space = try XCTUnwrap(summary.spaceID)
        for tab in s.allTabs(inSpace: space) { XCTAssertEqual(tab.meta.createdAt, now) }
        for folder in s.folders.values where folder.spaceID == space { XCTAssertEqual(folder.meta.createdAt, now) }
    }
}

/// D3: Chromium-family profiles under a temporary fake home folder.
final class BrowserProfileDiscoveryTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("openarc-d3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func write(_ text: String, to relative: String) throws {
        let url = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(relative, isDirectory: true), withIntermediateDirectories: true)
    }

    func testOnlyProfilesWithBookmarksAreListed() throws {
        let support = "Library/Application Support"
        let bookmarks = BookmarkParserTests.chromeJSON
        try write(bookmarks, to: "\(support)/Google/Chrome/Default/Bookmarks")
        try write(bookmarks, to: "\(support)/Google/Chrome/Profile 10/Bookmarks")
        try write(bookmarks, to: "\(support)/Google/Chrome/Profile 2/Bookmarks")
        try makeDirectory("\(support)/Google/Chrome/Profile 3")             // no Bookmarks file
        try write(bookmarks, to: "\(support)/Google/Chrome/System Profile/Bookmarks")   // not a user profile
        try write(bookmarks, to: "\(support)/Google/Chrome/Guest Profile/Bookmarks")
        try makeDirectory("\(support)/Google/Chrome/Profile 4/Bookmarks")   // a folder, not a file
        try write(#"{"profile":{"info_cache":{"Default":{"name":"Personal"},"Profile 2":{"name":"Work"}}}}"#,
                  to: "\(support)/Google/Chrome/Local State")
        try write(bookmarks, to: "\(support)/BraveSoftware/Brave-Browser/Default/Bookmarks")
        try makeDirectory("\(support)/Microsoft Edge/Default")              // Edge without bookmarks
        try write(bookmarks, to: "\(support)/Vivaldi/Default/Bookmarks")

        let found = BrowserProfileDiscovery.discover(home: home)
        XCTAssertEqual(found.map(\.id), ["chrome/Default", "chrome/Profile 2", "chrome/Profile 10", "brave/Default", "vivaldi/Default"])
        XCTAssertEqual(found.map(\.profileName), ["Personal", "Work", "Profile 10", "Default", "Default"])
        XCTAssertEqual(found.first?.bookmarksFile.lastPathComponent, "Bookmarks")
        XCTAssertEqual(try ChromiumBookmarksParser.parse(Data(contentsOf: try XCTUnwrap(found.first).bookmarksFile)).bookmarkCount, 7)
    }

    func testEmptyHomeFindsNothing() {
        XCTAssertTrue(BrowserProfileDiscovery.discover(home: home).isEmpty)
    }

    func testReadingAChosenFile() throws {
        try write(BookmarkParserTests.netscapeHTML, to: "export.html")
        let result = try BookmarkFileReader.read(contentsOf: home.appendingPathComponent("export.html"))
        XCTAssertEqual(result.format, .netscapeHTML)
        XCTAssertThrowsError(try BookmarkFileReader.read(contentsOf: home.appendingPathComponent("missing.html"))) {
            XCTAssertEqual($0 as? BookmarkImportError, .unreadable("missing.html"))
        }
    }
}
