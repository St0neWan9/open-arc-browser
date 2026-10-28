import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
import OpenArcImport
@testable import OpenArcShell

/// D3 / D3b: Open Arc ▸ Import from Another Browser… [01 §Arc] observed (the menu item). The sheet,
/// the sources, the data kinds and the new "Imported from <Browser>" Space are inferred (plans D3,
/// D3b). Uses a temporary fake home folder and FakeEngine's importer; no real browser data is read.
@MainActor
final class BookmarkImportShellTests: XCTestCase {
    private nonisolated let home: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("openarc-d3-shell-\(UUID().uuidString)", isDirectory: true)

    override nonisolated func setUpWithError() throws {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override nonisolated func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func makeController(_ f: SidebarFixture, engine: FakeEngine = FakeEngine()) -> WorkspaceController {
        var counter = 2_000
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore()),
            workspace: f.ws, now: { f.now.addingTimeInterval(10) },
            makeID: { counter += 1; return SidebarFixture.id(counter) },
            notificationCenter: NotificationCenter(), autoArchiveTicker: ManualTicker()
        )
        addTeardownBlock { @MainActor in controller.stop() }
        return controller
    }

    private func window(_ controller: WorkspaceController, space: UUID) -> ShellModel {
        let model = ShellModel(controller: controller, window: WindowUIState(selectedSpaceID: space))
        addTeardownBlock { @MainActor in model.stop() }
        return model
    }

    private let chromeJSON = #"""
    {"roots":{"bookmark_bar":{"type":"folder","name":"Bar","children":[
      {"type":"url","name":"One","url":"https://one.example.com/"},
      {"type":"folder","name":"Dir","children":[{"type":"url","name":"Two","url":"https://two.example.com/"}]},
      {"type":"url","name":"JS","url":"javascript:void(0)"}]},
     "other":{"type":"folder","name":"Other","children":[{"type":"url","name":"Three","url":"https://three.example.com/"}]}}}
    """#

    @discardableResult
    private func writeChromeProfile() throws -> URL {
        let file = home.appendingPathComponent("Library/Application Support/Google/Chrome/Default/Bookmarks")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(chromeJSON.utf8).write(to: file)
        return file
    }

    /// The import is one mutation: one new Space after the window's current Space, selected in the
    /// window that asked, saved like any other change.
    func testImportFromDetectedProfileCreatesSpaceAfterCurrentAndSelectsIt() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        let shell = window(controller, space: f.home)
        try writeChromeProfile()

        let model = BookmarkImportModel(controller: controller, home: home)
        XCTAssertEqual(model.profiles.map(\.id), ["chrome/Default"])
        XCTAssertEqual(model.selectedSourceID, "chrome/Default")
        XCTAssertEqual(model.label(for: model.profiles[0]), "Chrome")

        model.importSelectedProfile()

        guard case .done = model.phase, let summary = model.lastBookmarkSummary else { return XCTFail("expected a summary, got \(model.phase)") }
        XCTAssertEqual(summary.spaceName, "Imported from Chrome")
        XCTAssertEqual(summary.bookmarks, 3)
        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(summary.skipped, 1)
        let space = try XCTUnwrap(summary.spaceID)
        XCTAssertEqual(controller.workspace.spaces(inProfile: f.profile).map(\.name), ["Home", "Imported from Chrome", "Work"])
        XCTAssertEqual(shell.selectedSpaceID, space)
        XCTAssertEqual(controller.workspace.pinnedChildren(spaceID: space, folderID: nil).count, 3, "One, Dir, Other Bookmarks")
        XCTAssertTrue(BookmarkImportModel.summaryText(summary).contains("Skipped 1 item"))
    }

    func testImportChosenFileNamesSourceAndReportsBadFiles() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        _ = window(controller, space: f.work)
        let model = BookmarkImportModel(controller: controller, home: home)
        XCTAssertTrue(model.profiles.isEmpty)

        let html = home.appendingPathComponent("bookmarks.html")
        try Data("<!DOCTYPE NETSCAPE-Bookmark-file-1><DL><DT><A HREF=\"https://a.example.com/\">A</A></DL>".utf8).write(to: html)
        model.importFile(html)
        guard case .done = model.phase, let summary = model.lastBookmarkSummary else { return XCTFail("expected a summary") }
        XCTAssertEqual(summary.spaceName, "Imported from bookmarks.html")
        XCTAssertEqual(controller.workspace.spaces(inProfile: f.profile).last?.name, "Imported from bookmarks.html", "after Work")

        let bad = home.appendingPathComponent("notes.txt")
        try Data("just text".utf8).write(to: bad)
        let before = controller.workspace
        let second = BookmarkImportModel(controller: controller, home: home)
        second.importFile(bad)
        guard case .failed = second.phase else { return XCTFail("expected a failure") }
        XCTAssertEqual(controller.workspace, before, "a failed import changes nothing")
    }

    func testSafariPlistIsNamedSafari() throws {
        let plist: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Children": [Any]()]
        let url = home.appendingPathComponent("Bookmarks.plist")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        XCTAssertEqual(BookmarkImportModel.sourceName(for: url, format: .safariPlist), "Safari")
        let chrome = URL(fileURLWithPath: "/tmp/x/Library/Application Support/BraveSoftware/Brave-Browser/Profile 1/Bookmarks")
        XCTAssertEqual(BookmarkImportModel.sourceName(for: chrome, format: .chromiumJSON), "Brave")
    }

    /// D3b: history and passwords join bookmarks in the sheet. [01 §Arc] observed the menu item;
    /// the kinds and their checkboxes are inferred ([00] import wizard not captured).
    func testEngineKindsAreAvailableInShell() {
        XCTAssertEqual(ImportDataKind.availableInShell, [.bookmarks, .history, .passwords])
        XCTAssertEqual(ImportDataKind.engineKinds, [.history, .passwords])
    }

    private func touch(_ relative: String) throws {
        let file = home.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: file)
    }

    /// D3b: a Chrome profile offers the kinds it has files for, all checked; importing sends
    /// history and passwords to the engine for the current profile with the browser's keychain item,
    /// and bookmarks to the sidebar.
    func testImportFromChromeSendsHistoryAndPasswordsToEngine() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        _ = window(controller, space: f.home)
        try writeChromeProfile()
        try touch("Library/Application Support/Google/Chrome/Default/History")
        try touch("Library/Application Support/Google/Chrome/Default/Login Data")
        engine.fakeImporter.nextResult = EngineImportResult(
            historyStatus: .success, historyCount: 12, passwordStatus: .success, passwordCount: 3, passwordConflicts: 1
        )

        let model = BookmarkImportModel(controller: controller, home: home)
        XCTAssertEqual(model.sources.map(\.id), ["chrome/Default"])
        XCTAssertEqual(model.availableKinds(for: model.selectedSource), [.bookmarks, .history, .passwords])
        XCTAssertEqual(model.selectedKinds, [.bookmarks, .history, .passwords])
        model.selectedKinds.remove(.bookmarks)

        await model.importSelected()

        let request = try XCTUnwrap(engine.fakeImporter.requests.first)
        XCTAssertEqual(engine.fakeImporter.requests.count, 1)
        XCTAssertEqual(request.kinds, [.history, .passwords])
        XCTAssertEqual(request.profileID, f.profile)
        guard case .chromiumProfile(let directory, let service, let account) = request.source else {
            return XCTFail("expected a Chromium profile source")
        }
        XCTAssertEqual(directory.lastPathComponent, "Default")
        XCTAssertEqual(service, "Chrome Safe Storage")
        XCTAssertEqual(account, "Chrome")
        XCTAssertEqual(controller.workspace.spaces(inProfile: f.profile).map(\.name), ["Home", "Work"], "bookmarks unchecked")
        guard case .done(let lines) = model.phase else { return XCTFail("expected a summary, got \(model.phase)") }
        XCTAssertEqual(lines.map(\.text), [
            "Added 12 pages to History.",
            "Saved 3 passwords. Kept your saved password for 1 login that differ.",
        ])
    }

    /// D3b: Safari is listed when ~/Library/Safari exists and offers history only (its bookmarks
    /// and passwords come from export files). Missing Full Disk Access is reported, never requested.
    func testSafariWithoutFullDiskAccessReportsPermission() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        _ = window(controller, space: f.home)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Safari"), withIntermediateDirectories: true)
        engine.fakeImporter.nextResult = .all(.permissionDenied, for: .history)

        let model = BookmarkImportModel(controller: controller, home: home)
        XCTAssertEqual(model.sources.map(\.id), ["safari"])
        XCTAssertEqual(model.label(for: try XCTUnwrap(model.selectedSource)), "Safari")
        XCTAssertEqual(model.availableKinds(for: model.selectedSource), [.history])

        await model.importSelected()

        guard case .safari(let library)? = engine.fakeImporter.requests.first?.source else { return XCTFail("expected Safari") }
        XCTAssertEqual(library.lastPathComponent, "Safari")
        guard case .done(let lines) = model.phase else { return XCTFail("expected a summary") }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].isError)
        XCTAssertTrue(lines[0].needsFullDiskAccess)
    }

    /// D3b: a chosen CSV goes to the engine as a passwords export; an engine without an importer
    /// offers bookmarks only.
    func testChosenCSVImportsPasswordsAndNoImporterMeansBookmarksOnly() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        _ = window(controller, space: f.home)
        let csv = home.appendingPathComponent("Passwords.csv")
        try Data("Title,URL,Username,Password\n".utf8).write(to: csv)
        engine.fakeImporter.nextResult = EngineImportResult(passwordStatus: .success, passwordCount: 0)

        let model = BookmarkImportModel(controller: controller, home: home)
        model.importFile(csv)
        for _ in 0..<50 where model.phase == .importing { await Task.yield() }
        XCTAssertEqual(engine.fakeImporter.requests.first?.kinds, .passwords)
        XCTAssertEqual(engine.fakeImporter.requests.first?.source, .exportFile(csv))
        guard case .done(let lines) = model.phase else { return XCTFail("expected a summary, got \(model.phase)") }
        XCTAssertEqual(lines.map(\.text), ["Saved 0 passwords."])

        try writeChromeProfile()
        try touch("Library/Application Support/Google/Chrome/Default/History")
        let bare = BookmarkImportModel(controller: controller, home: home, importer: UnavailableImporter())
        XCTAssertEqual(bare.availableKinds(for: bare.selectedSource), [.bookmarks])
    }

    func testSummaryLinesForFailures() {
        let lines = BookmarkImportModel.summaryLines(EngineImportResult(
            historyStatus: .notFound, passwordStatus: .keychainDenied
        ))
        XCTAssertEqual(lines.map(\.isError), [false, true])
        XCTAssertEqual(lines[0].text, "Found no history.")
    }

    // MARK: D15: Import from Arc

    /// A synthetic Arc sidebar file (made-up names): one Space with a pinned folder, one Today tab
    /// and one favorite.
    private let arcSidebarJSON = #"""
    {"sidebar":{"containers":[{"global":{}},{"spaces":["s1",{"id":"s1","title":"Studio","profile":{"default":true},
      "customInfo":{"iconType":{"icon":"star"}},"containerIDs":["unpinned","t","pinned","p"]}],
     "items":[
      {"id":"p","parentID":null,"childrenIds":["f"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"s1"}}}}},
      {"id":"f","parentID":"p","title":"Refs","childrenIds":["a"],"data":{"list":{}}},
      {"id":"a","parentID":"f","title":"A","childrenIds":[],"data":{"tab":{"savedTitle":"A","savedURL":"https://a.example.com/"}}},
      {"id":"t","parentID":null,"childrenIds":["b"],"data":{"itemContainer":{"containerType":{"spaceItems":{"_0":"s1"}}}}},
      {"id":"b","parentID":"t","title":"B","childrenIds":[],"data":{"tab":{"savedTitle":"B","savedURL":"https://b.example.com/"}}},
      {"id":"fav","parentID":null,"childrenIds":["c"],"data":{"itemContainer":{"containerType":{"topApps":{"_0":{"default":true}}}}}},
      {"id":"c","parentID":"fav","title":null,"childrenIds":[],"data":{"tab":{"savedTitle":"C","savedURL":"https://c.example.com/"}}}
     ]}]}}
    """#

    private func writeArc(sidebar: Bool = true, history: Bool = true, passwords: Bool = true) throws {
        if sidebar {
            let file = home.appendingPathComponent(ArcSidebarReader.relativeFilePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(arcSidebarJSON.utf8).write(to: file)
        }
        if history { try touch(ArcSidebarReader.relativeProfilePath + "/History") }
        if passwords { try touch(ArcSidebarReader.relativeProfilePath + "/Login Data") }
    }

    /// D15: Arc is detected from its sidebar file and its profile, listed first, and offers the
    /// sidebar plus history and passwords (like Chrome). Importing appends its Spaces after the
    /// existing ones, selects the first, sends history and passwords to the engine with Arc's
    /// keychain item, and the summary gives counts and says a repeat adds new copies.
    func testArcSourceImportsSidebarAndSendsEngineKinds() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        let shell = window(controller, space: f.home)
        try writeArc()
        try writeChromeProfile()

        let model = BookmarkImportModel(controller: controller, home: home)
        XCTAssertEqual(model.sources.map(\.id), ["arc", "chrome/Default"])
        XCTAssertEqual(model.selectedSourceID, "arc")
        XCTAssertEqual(model.label(for: try XCTUnwrap(model.selectedSource)), "Arc")
        XCTAssertEqual(model.availableKinds(for: model.selectedSource), [.bookmarks, .history, .passwords])
        XCTAssertEqual(BookmarkImportLocalTokens.label(for: .bookmarks, isSidebarSource: true), "Sidebar (Spaces, tabs and favorites)")

        await model.importSelected()

        let summary = try XCTUnwrap(model.lastSidebarSummary)
        XCTAssertEqual(summary.spaces, 1)
        XCTAssertEqual(summary.folders, 1)
        XCTAssertEqual(summary.tabs, 2)
        XCTAssertEqual(summary.favorites, 1)
        XCTAssertEqual(controller.workspace.spaces(inProfile: f.profile).map(\.name), ["Home", "Work", "Studio"], "appended")
        XCTAssertEqual(shell.selectedSpaceID, summary.spaceIDs.first)
        XCTAssertEqual(controller.workspace.spaces[try XCTUnwrap(summary.spaceIDs.first)]?.icon, "star")

        let request = try XCTUnwrap(engine.fakeImporter.requests.first)
        XCTAssertEqual(request.kinds, [.history, .passwords])
        guard case .chromiumProfile(let directory, let service, let account) = request.source else {
            return XCTFail("expected a Chromium profile source")
        }
        XCTAssertTrue(directory.path.hasSuffix("Arc/User Data/Default"))
        XCTAssertEqual(service, "Arc Safe Storage")
        XCTAssertEqual(account, "Arc")

        guard case .done(let lines) = model.phase else { return XCTFail("expected a summary, got \(model.phase)") }
        XCTAssertEqual(lines.first?.text,
                       "Added 1 Space with 2 tabs in 1 folder, and 1 favorite. Your existing Spaces are unchanged; importing again adds new copies.")

        // A second import appends the Space again; the favorite is already there.
        let again = BookmarkImportModel(controller: controller, home: home)
        again.selectedKinds = [.bookmarks]
        await again.importSelected()
        XCTAssertEqual(controller.workspace.spaces(inProfile: f.profile).map(\.name), ["Home", "Work", "Studio", "Studio"])
        XCTAssertEqual(again.lastSidebarSummary?.existingFavorites, 1)
        XCTAssertEqual(engine.fakeImporter.requests.count, 1, "history and passwords unchecked")
    }

    /// D15: without the sidebar file Arc still offers history and passwords from its profile;
    /// without Arc at all it is not listed. A damaged sidebar file changes nothing.
    func testArcSourceVariants() async throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        _ = window(controller, space: f.home)
        XCTAssertFalse(BookmarkImportModel(controller: controller, home: home).sources.contains { $0.id == "arc" })

        try writeArc(sidebar: false)
        let profileOnly = BookmarkImportModel(controller: controller, home: home)
        XCTAssertEqual(profileOnly.availableKinds(for: profileOnly.selectedSource), [.history, .passwords])

        let file = home.appendingPathComponent(ArcSidebarReader.relativeFilePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"sidebar":{"containers":[]}}"#.utf8).write(to: file)
        let damaged = BookmarkImportModel(controller: controller, home: home)
        damaged.selectedKinds = [.bookmarks]
        let before = controller.workspace
        await damaged.importSelected()
        guard case .done(let lines) = damaged.phase else { return XCTFail("expected a summary") }
        XCTAssertEqual(lines.map(\.isError), [true])
        XCTAssertEqual(controller.workspace, before)
    }

    /// D15: Choose File… recognizes an Arc sidebar file by its layout.
    func testChosenArcSidebarFileImports() throws {
        let f = SidebarFixture()
        let controller = makeController(f)
        _ = window(controller, space: f.home)
        let url = home.appendingPathComponent("Sidebar.json")
        try Data(arcSidebarJSON.utf8).write(to: url)
        let model = BookmarkImportModel(controller: controller, home: home)
        model.importFile(url)
        guard case .done = model.phase else { return XCTFail("expected a summary, got \(model.phase)") }
        XCTAssertEqual(model.lastSidebarSummary?.spaces, 1)
    }

    /// D15: the development self test is off unless asked for, and never in the release build.
    func testImportSelfTestIsDevelopmentOnly() {
        XCTAssertNil(ImportSelfTest.outputURL(environment: [:], bundleIdentifier: "org.openarc.browser.dev"))
        XCTAssertNil(ImportSelfTest.outputURL(environment: [ImportSelfTest.environmentKey: "/tmp/x"], bundleIdentifier: "org.openarc.browser"))
        XCTAssertEqual(ImportSelfTest.outputURL(environment: [ImportSelfTest.environmentKey: "/tmp/x"], bundleIdentifier: "org.openarc.browser.dev")?.path, "/tmp/x")
        XCTAssertNil(ImportSelfTest.requestedKinds(environment: [:]))
        XCTAssertEqual(ImportSelfTest.requestedKinds(environment: [ImportSelfTest.kindsEnvironmentKey: "bookmarks, history"]), [.bookmarks, .history])
    }

    /// D15: the self test imports from Arc with the requested kinds and reports counts only.
    func testImportSelfTestReportsCounts() async throws {
        let f = SidebarFixture()
        let engine = FakeEngine()
        let controller = makeController(f, engine: engine)
        _ = window(controller, space: f.home)
        try writeArc()
        let report = await ImportSelfTest.run(controller: controller, home: home, kinds: [.bookmarks, .history])
        XCTAssertTrue(report.contains("offered=bookmarks,history,passwords\n"))
        XCTAssertTrue(report.contains("selected=bookmarks,history\n"))
        XCTAssertTrue(report.contains("spaces=1\n"))
        XCTAssertTrue(report.contains("historyStatus=success\n"))
        XCTAssertFalse(report.contains("Studio"), "no names in the report")
        XCTAssertEqual(engine.fakeImporter.requests.first?.kinds, .history)
    }
}
