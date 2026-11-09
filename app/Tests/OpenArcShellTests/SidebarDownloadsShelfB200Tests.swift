import XCTest
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B200: resting the pointer on the dock's Library button shows the newest downloads, running
/// and finished, over the bottom of the list. Spec: docs/arc-spec/06-flows.md §42 (observed): up
/// to 4 rows, newest at the bottom, ≈ 0.2 s after the pointer arrives; "6 days ago" under a
/// finished file, "2.1/31.5 MB · 1m 38s" and an × under a running one; Library media mixed in.
@MainActor
final class SidebarDownloadsShelfB200Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let profile = UUID()

    private func download(_ id: String, state: DownloadState = .complete, ended: TimeInterval = 0,
                          received: Int64 = 0, total: Int64 = -1, started: TimeInterval = 0) -> DownloadItem {
        DownloadItem(id: id, profileID: profile, sourceURL: URL(string: "https://example.org/\(id)")!,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id)"), suggestedFilename: id, state: state,
                     receivedBytes: received, totalBytes: total, startDate: now.addingTimeInterval(started),
                     endDate: state == .complete ? now.addingTimeInterval(ended) : nil)
    }

    // MARK: Which rows

    /// Newest 4, oldest first so the newest sits by the dock; a running download is the newest.
    func testRecentKeepsTheNewestFourNewestLast() {
        let items = [download("a", ended: -500), download("b", ended: -400), download("c", ended: -300),
                     download("d", ended: -200), download("run", state: .inProgress, started: -10)]
        let ids = SidebarShelfEntry.recent(downloads: items, media: [], now: now, fileExists: { _ in true }).map(\.title)
        XCTAssertEqual(ids, ["b", "c", "d", "run"])
    }

    /// B204, 06 §42 observed: a cancelled download stays ("Cancelled"); a finished one whose file was
    /// deleted is left out.
    func testCancelledStaysDeletedFilesGo() {
        let items = [download("kept", ended: -300), download("deleted", ended: -200),
                     download("stopped", state: .cancelled, started: -100)]
        let entries = SidebarShelfEntry.recent(downloads: items, media: [], now: now, fileExists: { $0.lastPathComponent != "deleted" })
        XCTAssertEqual(entries.map(\.title), ["kept", "stopped"])
        XCTAssertEqual(entries.last?.detail(now: now), "Cancelled")
    }

    /// Library media join the list by date; a file that is also a download shows once.
    func testMediaMixInWithoutDuplicates() {
        let shot = LibraryMediaItem(url: URL(fileURLWithPath: "/tmp/shot.png"), name: "shot.png", kind: .screenshot,
                                    date: now.addingTimeInterval(-250))
        let same = LibraryMediaItem(url: URL(fileURLWithPath: "/tmp/b"), name: "b", kind: .image, date: now)
        let entries = SidebarShelfEntry.recent(downloads: [download("a", ended: -300), download("b", ended: -100)],
                                               media: [shot, same], now: now, fileExists: { _ in true })
        XCTAssertEqual(entries.map(\.title), ["a", "shot.png", "b"])
        XCTAssertEqual(entries.map(\.id).filter { $0.hasPrefix("media:") }, ["media:/tmp/shot.png"])
    }

    // MARK: Lines

    func testDetailLines() {
        XCTAssertEqual(SidebarShelfEntry(source: .download(download("a", ended: -6 * 86_400))).detail(now: now), "6 days ago")
        XCTAssertEqual(SidebarShelfEntry(source: .download(download("a", ended: -21 * 3600))).detail(now: now), "21 hours ago")
        XCTAssertEqual(SidebarShelfEntry(source: .download(download("a", ended: -9 * 60))).detail(now: now), "9 minutes ago")
        XCTAssertEqual(SidebarShelfEntry(source: .download(download("a", ended: -5))).detail(now: now), "Just now")
        // 2.1 MB of 31.5 MB in 7 s: 29.4 MB left at 0.3 MB/s ≈ 98 s.
        let running = download("r", state: .inProgress, received: 2_100_000, total: 31_457_280, started: -7)
        XCTAssertEqual(SidebarShelfEntry(source: .download(running)).detail(now: now), "2.1/31.5 MB · 1m 38s")
        XCTAssertEqual(SidebarShelfEntry.amount(received: 512_000, total: -1), "512.0 KB")
        XCTAssertTrue(SidebarShelfEntry(source: .download(running)).isActiveDownload)
        XCTAssertEqual(SidebarShelfEntry(source: .download(running)).progress ?? 0, 2_100_000 / 31_457_280, accuracy: 0.0001)
        XCTAssertNil(SidebarShelfEntry(source: .download(running)).fileURL, "no file to open while it runs")
    }

    // MARK: Showing

    private func makeModel() -> (ShellModel, FakeEngine) {
        let engine = FakeEngine()
        let model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory()),
            workspace: .demo(now: now), now: { [now] in now }
        )
        model.sidebar.downloadsShelf.showDelay = .milliseconds(1)
        model.sidebar.downloadsShelf.hideGrace = .milliseconds(1)
        model.sidebar.downloadsShelf.fileExists = { _ in true }
        return (model, engine)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    /// Hovering the Library button shows the shelf; it stays while the pointer is on the rows and
    /// goes when the pointer leaves both.
    func testHoverShowsAndLeavingHides() async throws {
        let (model, engine) = makeModel()
        defer { model.stop() }
        let shelf = model.sidebar.downloadsShelf
        let profileID = try XCTUnwrap(model.sidebar.currentProfileID)
        engine.fakeDownloadService.simulateDownload(DownloadItem(
            id: "x", profileID: profileID, sourceURL: URL(string: "https://example.org/x.zip")!,
            fileURL: URL(fileURLWithPath: "/tmp/x.zip"), suggestedFilename: "x.zip", state: .complete,
            receivedBytes: 10, totalBytes: 10, startDate: now, endDate: now))
        try await waitUntil { shelf.entries.count == 1 }

        shelf.iconHovered(true)
        try await waitUntil { shelf.isShown }
        shelf.listHovered(true)
        shelf.iconHovered(false)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(shelf.isShown, "the rows keep it open")
        shelf.listHovered(false)
        try await waitUntil { !shelf.isShown }
    }

    /// Nothing downloaded: nothing shows. A drag or a Space swipe keeps it closed.
    func testNothingToShowOrBusy() async throws {
        let (model, engine) = makeModel()
        defer { model.stop() }
        let shelf = model.sidebar.downloadsShelf
        shelf.iconHovered(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(shelf.isShown)
        shelf.iconHovered(false)

        let profileID = try XCTUnwrap(model.sidebar.currentProfileID)
        engine.fakeDownloadService.simulateDownload(DownloadItem(
            id: "y", profileID: profileID, sourceURL: URL(string: "https://example.org/y")!, suggestedFilename: "y",
            state: .inProgress, receivedBytes: 1, totalBytes: 10, startDate: now))
        try await waitUntil { shelf.entries.count == 1 }
        XCTAssertTrue(model.sidebar.spaceSwipeBegan())
        shelf.iconHovered(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(shelf.isShown, "not during a swipe")
        model.sidebar.spaceSwipeCancelled()
        shelf.iconHovered(false)
        shelf.iconHovered(true)
        try await waitUntil { shelf.isShown }

        // The × cancels the running download.
        shelf.cancel(try XCTUnwrap(shelf.entries.first))
        try await waitUntil { engine.fakeDownloadService.commands.contains("cancel:y") }
    }
}
