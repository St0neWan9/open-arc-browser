import Foundation
import XCTest
import OpenArcModel
@testable import OpenArcImport

/// D3 bookmark import: parsers, mapping and profile discovery. Spec: [01 §Arc] observed only the
/// menu item "Import from Another Browser…"; formats, mapping and sources are inferred (plan D3).
/// Every fixture is written by the test; no real browser data is read.
final class BookmarkParserTests: XCTestCase {

    // MARK: Chromium JSON

    static let chromeJSON = #"""
    {
      "checksum": "x",
      "roots": {
        "bookmark_bar": { "type": "folder", "name": "Bookmarks bar", "children": [
          { "type": "url", "name": "Example", "url": "https://example.com/" },
          { "type": "folder", "name": "Work", "children": [
            { "type": "url", "name": "Docs", "url": "https://docs.example.com/" },
            { "type": "folder", "name": "Deep", "children": [
              { "type": "url", "name": "Deeper", "url": "http://deep.example.com/a?b=1" }
            ]},
            { "type": "folder", "name": "Empty", "children": [] }
          ]},
          { "type": "url", "name": "Bookmarklet", "url": "javascript:alert(1)" }
        ]},
        "other": { "type": "folder", "name": "Other bookmarks", "children": [
          { "type": "url", "name": "Other one", "url": "https://other.example.com/" },
          { "type": "url", "name": "Settings", "url": "chrome://settings" }
        ]},
        "synced": { "type": "folder", "name": "Mobile bookmarks", "children": [
          { "type": "url", "name": "Phone", "url": "https://m.example.com/" }
        ]}
      },
      "version": 1
    }
    """#

    func testChromeJSONParsesRootsAndNesting() throws {
        let tree = try ChromiumBookmarksParser.parse(Data(Self.chromeJSON.utf8))
        XCTAssertEqual(tree.bar, [
            .bookmark(Bookmark(title: "Example", url: "https://example.com/")),
            .folder(BookmarkFolder(title: "Work", children: [
                .bookmark(Bookmark(title: "Docs", url: "https://docs.example.com/")),
                .folder(BookmarkFolder(title: "Deep", children: [
                    .bookmark(Bookmark(title: "Deeper", url: "http://deep.example.com/a?b=1")),
                ])),
                .folder(BookmarkFolder(title: "Empty")),
            ])),
            .bookmark(Bookmark(title: "Bookmarklet", url: "javascript:alert(1)")),
        ])
        XCTAssertEqual(tree.other, [
            .bookmark(Bookmark(title: "Other one", url: "https://other.example.com/")),
            .bookmark(Bookmark(title: "Settings", url: "chrome://settings")),
            .folder(BookmarkFolder(title: "Mobile bookmarks", children: [
                .bookmark(Bookmark(title: "Phone", url: "https://m.example.com/")),
            ])),
        ])
        XCTAssertEqual(tree.bookmarkCount, 7)
    }

    func testChromeJSONWithoutRootsIsMalformed() {
        XCTAssertThrowsError(try ChromiumBookmarksParser.parse(Data(#"{"version":1}"#.utf8))) {
            XCTAssertEqual($0 as? BookmarkImportError, .malformed("no \"roots\" object"))
        }
        XCTAssertThrowsError(try ChromiumBookmarksParser.parse(Data("not json".utf8))) {
            XCTAssertEqual($0 as? BookmarkImportError, .unrecognizedFormat)
        }
    }

    // MARK: Netscape HTML

    /// Chrome-style export: unclosed DT and p, the toolbar marked, an empty folder, a heading with
    /// no DL after it, entities in titles and attributes, a DD description, mixed tag case.
    static let netscapeHTML = """
    <!DOCTYPE NETSCAPE-Bookmark-file-1>
    <!-- This is an automatically generated file.
         It will be read and overwritten.
         DO NOT EDIT! -->
    <META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
    <TITLE>Bookmarks</TITLE>
    <H1>Bookmarks</H1>
    <DL><p>
        <DT><H3 ADD_DATE="1" LAST_MODIFIED="2" PERSONAL_TOOLBAR_FOLDER="true">Bookmarks bar</H3>
        <DL><p>
            <DT><A HREF="https://example.com/?a=1&amp;b=2" ADD_DATE="3">Tom &amp; Jerry &lt;3 &#233;&#x263A;</A>
            <DT><H3>News</H3>
            <dl><p>
                <dt><a href='https://news.example.com/'>News   site</a>
                <DD>A description that is ignored
                <DT><H3>Nested</H3>
                <DL><p>
                    <DT><A HREF="https://nested.example.com/">Nested link</A>
                </DL><p>
            </DL><p>
            <DT><H3>Empty</H3>
            <DL><p>
            </DL><p>
            <DT><H3>No list</H3>
            <DT><A HREF="place:sort=8">Firefox smart folder</A>
        </DL><p>
        <DT><A HREF="https://loose.example.com/">Loose</A>
        <DT><H3>Other folder</H3>
        <DL><p>
            <DT><A HREF="https://other.example.com/">Other</A>
        </DL><p>
    </DL><p>
    """

    func testNetscapeHTMLParsesNestingQuirksAndEntities() throws {
        let tree = try NetscapeBookmarksParser.parse(Self.netscapeHTML)
        XCTAssertEqual(tree.bar, [
            .bookmark(Bookmark(title: "Tom & Jerry <3 é☺", url: "https://example.com/?a=1&b=2")),
            .folder(BookmarkFolder(title: "News", children: [
                .bookmark(Bookmark(title: "News site", url: "https://news.example.com/")),
                .folder(BookmarkFolder(title: "Nested", children: [
                    .bookmark(Bookmark(title: "Nested link", url: "https://nested.example.com/")),
                ])),
            ])),
            .folder(BookmarkFolder(title: "Empty")),
            .folder(BookmarkFolder(title: "No list")),
            .bookmark(Bookmark(title: "Firefox smart folder", url: "place:sort=8")),
        ])
        XCTAssertEqual(tree.other, [
            .bookmark(Bookmark(title: "Loose", url: "https://loose.example.com/")),
            .folder(BookmarkFolder(title: "Other folder", children: [
                .bookmark(Bookmark(title: "Other", url: "https://other.example.com/")),
            ])),
        ])
    }

    /// Safari's HTML export has no toolbar mark; its "Favorites" folder is the bar. A file with no
    /// bar puts everything in `bar`.
    func testNetscapeBarFallbacks() throws {
        let safari = """
        <!DOCTYPE NETSCAPE-Bookmark-file-1>
        <HTML><META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">
        <Title>Bookmarks</Title><H1>Bookmarks</H1>
        <DT><H3 FOLDED>Favorites</H3>
        <DL><DT><A HREF="https://fav.example.com/">Fav</A></DL>
        <DT><H3 FOLDED>Bookmarks Menu</H3>
        <DL><DT><A HREF="https://menu.example.com/">Menu</A></DL>
        </HTML>
        """
        let tree = try NetscapeBookmarksParser.parse(safari)
        XCTAssertEqual(tree.bar, [.bookmark(Bookmark(title: "Fav", url: "https://fav.example.com/"))])
        XCTAssertEqual(tree.other, [.folder(BookmarkFolder(title: "Bookmarks Menu", children: [
            .bookmark(Bookmark(title: "Menu", url: "https://menu.example.com/")),
        ]))])

        let flat = "<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF=https://a.example.com/>A</A><DT><A HREF=\"https://b.example.com/\">B</A></DL>"
        let flatTree = try NetscapeBookmarksParser.parse(flat)
        XCTAssertEqual(flatTree.bar.count, 2)
        XCTAssertEqual(flatTree.bar.first, .bookmark(Bookmark(title: "A", url: "https://a.example.com/")))
        XCTAssertTrue(flatTree.other.isEmpty)
    }

    func testNetscapeRejectsOtherHTML() {
        XCTAssertThrowsError(try NetscapeBookmarksParser.parse("<html><body><p>Hello</p></body></html>")) {
            XCTAssertEqual($0 as? BookmarkImportError, .unrecognizedFormat)
        }
    }

    // MARK: Safari plist

    static func safariPlist(binary: Bool) throws -> Data {
        func leaf(_ title: String, _ url: String) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": url, "URIDictionary": ["title": title], "WebBookmarkUUID": UUID().uuidString]
        }
        func list(_ title: String, _ children: [[String: Any]]) -> [String: Any] {
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": title, "Children": children]
        }
        let root: [String: Any] = [
            "WebBookmarkType": "WebBookmarkTypeList",
            "WebBookmarkFileVersion": 1,
            "Children": [
                ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
                list("BookmarksBar", [
                    leaf("Apple", "https://www.apple.com/"),
                    list("Dev", [leaf("Swift", "https://swift.org/"), list("Empty", [])]),
                ]),
                list("BookmarksMenu", [leaf("Menu item", "https://menu.example.com/")]),
                list("com.apple.ReadingList", [leaf("Later", "https://later.example.com/")]),
            ],
        ]
        return try PropertyListSerialization.data(fromPropertyList: root, format: binary ? .binary : .xml, options: 0)
    }

    func testSafariPlistParsesBarMenuAndReadingList() throws {
        for binary in [true, false] {
            let data = try Self.safariPlist(binary: binary)
            XCTAssertEqual(BookmarkFileFormat.detect(data), .safariPlist)
            let tree = try SafariBookmarksParser.parse(data)
            XCTAssertEqual(tree.bar, [
                .bookmark(Bookmark(title: "Apple", url: "https://www.apple.com/")),
                .folder(BookmarkFolder(title: "Dev", children: [
                    .bookmark(Bookmark(title: "Swift", url: "https://swift.org/")),
                    .folder(BookmarkFolder(title: "Empty")),
                ])),
            ])
            XCTAssertEqual(tree.other, [
                .bookmark(Bookmark(title: "Menu item", url: "https://menu.example.com/")),
                .folder(BookmarkFolder(title: "Reading List", children: [
                    .bookmark(Bookmark(title: "Later", url: "https://later.example.com/")),
                ])),
            ])
        }
    }

    // MARK: Format detection

    func testFormatDetection() throws {
        XCTAssertEqual(BookmarkFileFormat.detect(Data(Self.chromeJSON.utf8)), .chromiumJSON)
        XCTAssertEqual(BookmarkFileFormat.detect(Data(Self.netscapeHTML.utf8)), .netscapeHTML)
        XCTAssertNil(BookmarkFileFormat.detect(Data("plain text".utf8)))
        XCTAssertThrowsError(try BookmarkFileReader.read(Data("plain text".utf8)))
        XCTAssertEqual(try BookmarkFileReader.read(Data(Self.chromeJSON.utf8)).format, .chromiumJSON)
    }
}
