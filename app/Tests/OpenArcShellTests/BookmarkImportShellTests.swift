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
}
