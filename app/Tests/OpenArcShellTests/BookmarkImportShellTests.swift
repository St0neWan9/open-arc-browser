import Foundation
import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
import OpenArcPersistence
import OpenArcImport
@testable import OpenArcShell

/// D3: Open Arc ▸ Import from Another Browser… [01 §Arc] observed (the menu item). The sheet, the
/// sources and the new "Imported from <Browser>" Space are inferred (plan D3). Uses a temporary
/// fake home folder; no real browser data is read.
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

    private func makeController(_ f: SidebarFixture) -> WorkspaceController {
        var counter = 2_000
        let controller = WorkspaceController(
            dependencies: AppDependencies(engine: FakeEngine(), sync: DisabledSyncStore()),
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
        XCTAssertEqual(model.selectedProfileID, "chrome/Default")
        XCTAssertEqual(model.label(for: model.profiles[0]), "Chrome")

        model.importSelectedProfile()

        guard case .done(let summary) = model.phase else { return XCTFail("expected a summary, got \(model.phase)") }
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
        guard case .done(let summary) = model.phase else { return XCTFail("expected a summary") }
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

    /// Only bookmarks are importable before the Chromium importer (plan D3b).
    func testOnlyBookmarksAreAvailableInShell() {
        XCTAssertEqual(ImportDataKind.availableInShell, [.bookmarks])
    }
}
