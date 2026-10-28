import Foundation
import XCTest
import OpenArcModel
@testable import OpenArcImport

/// D15: Import from Arc. Reads a SYNTHETIC sidebar file written by hand in Arc's layout (made-up
/// names and example.com URLs; no real user data) and maps it onto the workspace through
/// `TreeOps`. Everything about the mapping is inferred (plan D15).
final class ArcSidebarImportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 7_000)
    private let profile = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let home = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Two Spaces ("Work": theme, known icon, nested folders, a split, an onboarding page, Today
    /// tabs with a bookmarklet and a dangling id; "Play": another profile, no theme, unknown icon,
    /// a canvas-like unknown item), and favorites with an emoji tab and a folder. The items table
    /// alternates id and record like the real file; the Space table mixes both forms.
    static let fixture = #"""
    {
      "version": 1,
      "sidebar": {
        "containers": [
          { "global": {} },
          {
            "topAppsContainerIDs": [ { "default": true }, "fav-root" ],
            "spaces": [
              "space-work",
              {
                "id": "space-work", "title": "Work",
                "profile": { "default": true },
                "customInfo": {
                  "iconType": { "icon": "briefcase" },
                  "windowTheme": {
                    "background": { "single": { "_0": {
                      "contentOverBackgroundAppearance": "dark", "isVibrant": false,
                      "style": { "color": { "_0": { "blendedSingleColor": { "_0": {
                        "color": { "red": 0.2, "green": 0.4, "blue": 1.25, "alpha": 1, "colorSpace": "extendedSRGB" },
                        "modifiers": { "intensityFactor": 1, "noiseFactor": 0.3, "overlay": "plusLighter" },
                        "translucencyStyle": "light"
                      } } } } }
                    } } },
                    "primaryColorPalette": { "midTone": { "red": 0.9, "green": 0.9, "blue": 0.9, "alpha": 1 } }
                  }
                },
                "containerIDs": [ "unpinned", "work-today", "pinned", "work-pinned" ],
                "newContainerIDs": [ { "pinned": {} }, "work-pinned", { "unpinned": { "_0": { "shared": {} } } }, "work-today" ]
              },
              {
                "id": "space-play", "title": "  Play  ",
                "profile": { "default": false },
                "customInfo": { "iconType": { "icon": "notOneOfOurs" } },
                "containerIDs": [ "unpinned", "play-today", "pinned", "play-pinned" ]
              }
            ],
            "items": [
              "work-pinned",
              { "id": "work-pinned", "parentID": null, "title": null, "childrenIds": [ "tab-docs", "folder-projects", "split-1", "welcome-1" ],
                "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "space-work" } } } } },
              "tab-docs",
              { "id": "tab-docs", "parentID": "work-pinned", "title": "Docs", "childrenIds": [],
                "data": { "tab": { "savedTitle": "Docs Home", "savedURL": "https://docs.example.com/", "savedMuteStatus": "allowAudio", "timeLastActiveAt": 1000 } } },
              "folder-projects",
              { "id": "folder-projects", "parentID": "work-pinned", "title": "Projects", "childrenIds": [ "tab-alpha", "folder-archive" ],
                "data": { "list": {} } },
              "tab-alpha",
              { "id": "tab-alpha", "parentID": "folder-projects", "title": null, "childrenIds": [],
                "data": { "tab": { "savedTitle": "Alpha", "savedURL": "https://alpha.example.com/" } } },
              "folder-archive",
              { "id": "folder-archive", "parentID": "folder-projects", "title": "Archive", "childrenIds": [ "tab-old" ],
                "data": { "list": {} } },
              "tab-old",
              { "id": "tab-old", "parentID": "folder-archive", "childrenIds": [],
                "data": { "tab": { "savedURL": "https://old.example.com/page" } } },
              "split-1",
              { "id": "split-1", "parentID": "work-pinned", "title": null, "childrenIds": [ "tab-left", "tab-right" ],
                "data": { "splitView": { "layoutOrientation": "horizontal", "itemWidthFactors": [ "tab-left", 0.5 ], "customInfo": null } } },
              "tab-left",
              { "id": "tab-left", "parentID": "split-1", "title": "Left", "childrenIds": [],
                "data": { "tab": { "savedTitle": "Left", "savedURL": "https://left.example.com/" } } },
              "tab-right",
              { "id": "tab-right", "parentID": "split-1", "title": "Right", "childrenIds": [],
                "data": { "tab": { "savedTitle": "Right", "savedURL": "https://right.example.com/" } } },
              "welcome-1",
              { "id": "welcome-1", "parentID": "work-pinned", "title": null, "childrenIds": [],
                "data": { "welcomeToArc": { "tabType": "intro" } } },
              "work-today",
              { "id": "work-today", "parentID": null, "title": null, "childrenIds": [ "tab-news", "tab-bookmarklet", "missing-id" ],
                "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "space-work" } } } } },
              "tab-news",
              { "id": "tab-news", "parentID": "work-today", "title": "News", "childrenIds": [],
                "data": { "tab": { "savedTitle": "News", "savedURL": "https://news.example.com/" } } },
              "tab-bookmarklet",
              { "id": "tab-bookmarklet", "parentID": "work-today", "title": "Script", "childrenIds": [],
                "data": { "tab": { "savedTitle": "Script", "savedURL": "javascript:void(0)" } } },
              "play-pinned",
              { "id": "play-pinned", "parentID": null, "title": null, "childrenIds": [ "canvas-1" ],
                "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "space-play" } } } } },
              "canvas-1",
              { "id": "canvas-1", "parentID": "play-pinned", "title": "Board", "childrenIds": [ "canvas-part" ],
                "data": { "drawing": { "pages": 1 } } },
              "canvas-part",
              { "id": "canvas-part", "parentID": "canvas-1", "title": null, "childrenIds": [],
                "data": { "drawingPart": {} } },
              "play-today",
              { "id": "play-today", "parentID": null, "title": null, "childrenIds": [],
                "data": { "itemContainer": { "containerType": { "spaceItems": { "_0": "space-play" } } } } },
              "fav-root",
              { "id": "fav-root", "parentID": null, "title": null, "childrenIds": [ "fav-mail", "fav-music", "fav-folder" ],
                "data": { "itemContainer": { "containerType": { "topApps": { "_0": { "default": true } } } } } },
              "fav-mail",
              { "id": "fav-mail", "parentID": "fav-root", "title": null, "childrenIds": [],
                "data": { "tab": { "savedTitle": "Mail", "savedURL": "https://mail.example.com/" } } },
              "fav-music",
              { "id": "fav-music", "parentID": "fav-root", "title": null, "childrenIds": [],
                "data": { "tab": { "savedTitle": "Music", "savedURL": "https://music.example.com/",
                  "customInfo": { "iconType": { "emoji": 127925, "emoji_v2": "🎵" } } } } },
              "fav-folder",
              { "id": "fav-folder", "parentID": "fav-root", "title": "Group", "childrenIds": [ "fav-in-folder" ],
                "data": { "list": {} } },
              "fav-in-folder",
              { "id": "fav-in-folder", "parentID": "fav-folder", "title": null, "childrenIds": [],
                "data": { "tab": { "savedTitle": "Inner", "savedURL": "https://inner.example.com/" } } }
            ]
          }
        ]
      }
    }
    """#

    static func read() throws -> ForeignSidebar {
        try ArcSidebarReader.read(Data(fixture.utf8))
    }

    private func baseState() throws -> WorkspaceState {
        var s = WorkspaceState()
        s.profiles[profile] = Profile(id: profile, name: "Default", now: now)
        s = try TreeOps.createSpace(s, id: home, profileID: profile, name: "Home", now: now)
        return s
    }

    private func idMaker() -> () -> UUID {
        var n = 100
        return { n += 1; return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
    }

    private let symbols: Set<String> = ["briefcase", "house"]
    private let fallbackTheme = ThemeStyle(colors: [RGBAColor(hex: 0x7FA6E8)])

    private func apply(_ sidebar: ForeignSidebar, to state: WorkspaceState, makeID: () -> UUID) throws
        -> (state: WorkspaceState, summary: ForeignSidebarImportSummary) {
        try ForeignSidebarMapper.apply(
            sidebar, to: state, profileID: profile, defaultTheme: fallbackTheme, knownSymbols: symbols, now: now, makeID: makeID
        )
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

    // MARK: Reader

    /// D15: Spaces in file order with names, icons, theme and profile marker; pinned rows with
    /// nested folders and a split; Today rows; favorites; unknown kinds and dangling ids skipped.
    func testReaderReadsSpacesFoldersFavoritesAndToday() throws {
        let sidebar = try Self.read()
        XCTAssertEqual(sidebar.spaces.map(\.name), ["Work", "Play"])

        let work = sidebar.spaces[0]
        XCTAssertEqual(work.icon, .symbol("briefcase"))
        XCTAssertFalse(work.isFromOtherProfile)
        let theme = try XCTUnwrap(work.theme)
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertEqual(theme.colors, [RGBAColor(red: 0.2, green: 0.4, blue: 1, alpha: 1)], "the background color, clamped to 0…1")
        XCTAssertEqual(theme.grain, 0.3)
        XCTAssertEqual(work.pinned, [
            .page(ForeignPage(title: "Docs", url: "https://docs.example.com/")),
            .folder(ForeignFolder(title: "Projects", children: [
                .page(ForeignPage(title: "Alpha", url: "https://alpha.example.com/")),
                .folder(ForeignFolder(title: "Archive", children: [
                    .page(ForeignPage(title: "", url: "https://old.example.com/page")),
                ])),
            ])),
            .split(ForeignSplit(axis: .horizontal, pages: [
                ForeignPage(title: "Left", url: "https://left.example.com/"),
                ForeignPage(title: "Right", url: "https://right.example.com/"),
            ])),
        ])
        XCTAssertEqual(work.today.count, 2, "news and the bookmarklet; the dangling id is skipped")

        let play = sidebar.spaces[1]
        XCTAssertEqual(play.name, "Play")
        XCTAssertNil(play.theme, "no theme in the file")
        XCTAssertEqual(play.icon, .symbol("notOneOfOurs"))
        XCTAssertTrue(play.isFromOtherProfile)
        XCTAssertTrue(play.pinned.isEmpty)

        XCTAssertEqual(sidebar.favorites.count, 3)
        guard case .page(let music) = sidebar.favorites[1] else { return XCTFail("expected a page") }
        XCTAssertEqual(music.emoji, "🎵")
        // welcome page (1) + dangling id (1) + canvas with its part (2).
        XCTAssertEqual(sidebar.skipped, 4)
    }

    func testReaderRejectsOtherFiles() {
        XCTAssertThrowsError(try ArcSidebarReader.read(Data("not json".utf8))) {
            XCTAssertEqual($0 as? BookmarkImportError, .unrecognizedFormat)
        }
        XCTAssertThrowsError(try ArcSidebarReader.read(Data(#"{"roots":{}}"#.utf8))) {
            XCTAssertEqual($0 as? BookmarkImportError, .malformed("no sidebar"))
        }
        XCTAssertThrowsError(try ArcSidebarReader.read(Data(#"{"sidebar":{"containers":[{"global":{}}]}}"#.utf8))) {
            XCTAssertEqual($0 as? BookmarkImportError, .malformed("no Spaces"))
        }
    }

    /// D15: a cycle in the item table (a folder listing itself) ends at the depth limit instead of
    /// recursing forever.
    func testReaderSurvivesCycles() throws {
        let json = #"""
        {"sidebar":{"containers":[{"spaces":[{"id":"s","title":"Loop","containerIDs":["pinned","p"]}],
         "items":[{"id":"p","childrenIds":["f"],"data":{"itemContainer":{}}},
                  {"id":"f","title":"Self","childrenIds":["f"],"data":{"list":{}}}]}]}}
        """#
        let sidebar = try ArcSidebarReader.read(Data(json.utf8))
        XCTAssertEqual(sidebar.spaces.count, 1)
        XCTAssertGreaterThan(sidebar.skipped, 0)
    }

    // MARK: Mapper

    /// D15: each Arc Space becomes a new Space after the existing ones, with its pinned tabs,
    /// nested folders, split and Today tabs in order; favorites join the profile's favorites.
    func testMappingCreatesSpacesAfterExistingOnes() throws {
        let (s, summary) = try apply(try Self.read(), to: try baseState(), makeID: idMaker())

        XCTAssertEqual(s.spaces(inProfile: profile).map(\.name), ["Home", "Work", "Play"])
        XCTAssertEqual(summary.spaces, 2)
        XCTAssertEqual(summary.folders, 2)
        XCTAssertEqual(summary.tabs, 6, "docs, alpha, old, left, right, news")
        XCTAssertEqual(summary.todayTabs, 1)
        XCTAssertEqual(summary.splits, 1)
        XCTAssertEqual(summary.favorites, 2)
        XCTAssertEqual(summary.spacesFromOtherProfiles, 1)
        // reader 4 + bookmarklet 1 + folder among favorites with its tab 2.
        XCTAssertEqual(summary.skipped, 7)

        let work = summary.spaceIDs[0]
        let play = summary.spaceIDs[1]
        XCTAssertEqual(s.spaces[work]?.icon, "briefcase")
        XCTAssertNil(s.spaces[play]?.icon, "an icon name we do not have is dropped")
        XCTAssertEqual(s.spaces[play]?.name, "Play", "trimmed")
        let workTheme = try XCTUnwrap(s.spaces[work]?.themeID.flatMap { s.themes[$0] })
        XCTAssertEqual(workTheme.colors, [RGBAColor(red: 0.2, green: 0.4, blue: 1, alpha: 1)])
        XCTAssertEqual(workTheme.appearance, .dark)
        let playTheme = try XCTUnwrap(s.spaces[play]?.themeID.flatMap { s.themes[$0] })
        XCTAssertEqual(playTheme.colors, fallbackTheme.colors, "no theme in the file: the default color")

        XCTAssertEqual(outline(s, space: work), ["Docs", "[Projects]", "Left", "Right"])
        let projects = try XCTUnwrap(s.folders.values.first { $0.title == "Projects" })
        let archive = try XCTUnwrap(s.folders.values.first { $0.title == "Archive" })
        XCTAssertTrue(projects.isExpanded)
        XCTAssertFalse(archive.isExpanded, "deeper folders start collapsed")
        XCTAssertEqual(outline(s, space: work, folder: projects.id), ["Alpha", "[Archive]"])
        XCTAssertEqual(outline(s, space: work, folder: archive.id), ["old.example.com"], "no title: the host")

        let docs = try XCTUnwrap(s.tabs.values.first { $0.title == "Docs" })
        XCTAssertEqual(docs.pinnedURL, URL(string: "https://docs.example.com/"))
        XCTAssertEqual(s.today(spaceID: work).map(\.title), ["News"])
        XCTAssertTrue(s.today(spaceID: play).isEmpty)

        let split = try XCTUnwrap(s.splits.values.first)
        XCTAssertEqual(split.spaceID, work)
        XCTAssertEqual(split.root.tabIDs.compactMap { s.tabs[$0]?.title }, ["Left", "Right"])

        let favorites = s.favorites(profileID: profile)
        XCTAssertEqual(favorites.map(\.title), ["Mail", "Music"])
        XCTAssertEqual(favorites.last?.icon, "🎵")
    }

    /// D15: a second import adds the Spaces again (no merge) but does not repeat favorites that are
    /// already there; existing Spaces are never changed.
    func testSecondImportAppendsAgainWithoutDuplicatingFavorites() throws {
        let makeID = idMaker()
        let base = try baseState()
        let first = try apply(try Self.read(), to: base, makeID: makeID)
        let second = try apply(try Self.read(), to: first.state, makeID: makeID)

        XCTAssertEqual(second.state.spaces(inProfile: profile).map(\.name), ["Home", "Work", "Play", "Work", "Play"])
        XCTAssertEqual(second.summary.favorites, 0)
        XCTAssertEqual(second.summary.existingFavorites, 2)
        XCTAssertEqual(second.state.favorites(profileID: profile).count, 2)
        XCTAssertEqual(second.state.spaces[home], base.spaces[home], "the existing Space is untouched")
    }

    /// D15: optional fields may be missing (no title, no icon, no theme, no Today list, no
    /// favorites); the Space is still created with defaults.
    func testMissingOptionalFields() throws {
        let json = #"{"sidebar":{"containers":[{"items":[],"spaces":[{"id":"bare","containerIDs":[]}]}]}}"#
        let sidebar = try ArcSidebarReader.read(Data(json.utf8))
        XCTAssertEqual(sidebar.spaces, [ForeignSpace(name: "")])
        let (s, summary) = try apply(sidebar, to: try baseState(), makeID: idMaker())
        XCTAssertEqual(s.spaces(inProfile: profile).map(\.name), ["Home", ForeignSidebarMapper.untitledSpaceName])
        XCTAssertEqual(summary.spaces, 1)
        XCTAssertEqual(summary.tabs, 0)
        XCTAssertEqual(summary.skipped, 0)
    }

    /// D15: the mapping goes through TreeOps only: every new record carries `now` and a fresh id
    /// from `makeID`, and nothing that existed before changes.
    func testMappingStampsNowAndUsesGivenIDs() throws {
        let base = try baseState()
        var issued: [UUID] = []
        var n = 500
        let (s, _) = try apply(try Self.read(), to: base) {
            n += 1
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
            issued.append(id)
            return id
        }
        let newIDs = Set(s.spaces.keys).union(s.tabs.keys).union(s.folders.keys).union(s.themes.keys).union(s.splits.keys)
            .subtracting(base.spaces.keys)
        XCTAssertTrue(newIDs.isSubset(of: Set(issued)))
        XCTAssertTrue(s.tabs.values.allSatisfy { $0.meta.createdAt == now })
        XCTAssertEqual(s.profiles, base.profiles)
    }

    /// D15: Arc's Chromium profile reuses the Chromium-family keychain naming: "Arc Safe Storage",
    /// account "Arc"; it is not part of the generic browser list.
    func testArcProfileKeychainNaming() {
        XCTAssertEqual(ChromiumBrowser.arc.keychainService, "Arc Safe Storage")
        XCTAssertEqual(ChromiumBrowser.arc.keychainAccount, "Arc")
        XCTAssertEqual(ChromiumBrowser.arc.relativeDataPath, "Arc/User Data")
        XCTAssertFalse(ChromiumBrowser.known.contains(.arc))
    }
}
