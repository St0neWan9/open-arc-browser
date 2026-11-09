import XCTest
import Combine
import OpenArcModel
import OpenArcEngine
import OpenArcSyncAPI
@testable import OpenArcShell

/// Plan B203: a download that starts puts a progress badge on the dock's Library button, an icon
/// flies from the click to it, and the finished file's icon replaces the badge for ≈ 33 s.
/// Spec: docs/arc-spec/06-flows.md §43 (observed).
@MainActor
final class DownloadBadgeB203Tests: XCTestCase {
    // MARK: Flight path

    /// Constant horizontal speed, a thrown-object fall, start and end exact. The recorded run went
    /// from (1020, 397) to (42, 948): it rose ≈ 117 pt first.
    func testFlightPath() {
        let start = CGPoint(x: 1020, y: 397), end = CGPoint(x: 42, y: 948)
        XCTAssertEqual(DownloadFlightPath.point(at: 0, from: start, to: end), start)
        let last = DownloadFlightPath.point(at: DownloadFlightPath.duration, from: start, to: end)
        XCTAssertEqual(last.x, end.x, accuracy: 0.001)
        XCTAssertEqual(last.y, end.y, accuracy: 0.001)
        XCTAssertEqual(DownloadFlightPath.point(at: 0.5, from: start, to: end).x, 531, accuracy: 0.001, "even x speed")
        let apex = stride(from: 0.0, through: 1.0, by: 0.01).map { DownloadFlightPath.point(at: $0, from: start, to: end).y }.min()!
        XCTAssertEqual(start.y - apex, 117, accuracy: 15, "rises ≈ 117 pt as recorded")
    }

    func testFlightLook() {
        XCTAssertEqual(DownloadFlightPath.diameter(at: 0), 30)
        XCTAssertEqual(DownloadFlightPath.diameter(at: DownloadFlightPath.growTime), 44)
        XCTAssertEqual(DownloadFlightPath.diameter(at: 1), 9)
        XCTAssertEqual(DownloadFlightPath.opacity(at: 0), 0)
        XCTAssertEqual(DownloadFlightPath.opacity(at: 0.5), 1)
        XCTAssertEqual(DownloadFlightPath.arrowAngle(at: 0), -.pi / 4, accuracy: 0.0001)
        XCTAssertEqual(DownloadFlightPath.arrowAngle(at: 1), 0, accuracy: 0.0001)
    }

    /// The badge sits at the Library button's center plus (9.5, −12.5).
    func testBadgeCenter() {
        let center = DownloadFlightOverlay.badgeCenter(sidebarFrame: CGRect(x: 0, y: 0, width: 357, height: 985), windowHeight: 985)
        XCTAssertEqual(center.x, 24 + 9.5)
        XCTAssertEqual(center.y, 960 - 12.5)
    }

    // MARK: Badge and flights

    private let now = Date(timeIntervalSince1970: 2_000_000)

    private func makeModel() -> (ShellModel, FakeEngine) {
        let engine = FakeEngine()
        let model = ShellModel(
            dependencies: AppDependencies(engine: engine, sync: DisabledSyncStore(), preferences: .inMemory()),
            workspace: .demo(now: now), now: { [now] in now }
        )
        model.sidebar.downloadsShelf.finishedIconDuration = .milliseconds(30)
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

    private func item(_ id: String, profile: UUID, state: DownloadState, received: Int64 = 50, started: Date) -> DownloadItem {
        DownloadItem(id: id, profileID: profile, sourceURL: URL(string: "https://example.org/\(id)")!,
                     fileURL: URL(fileURLWithPath: "/tmp/\(id)"), suggestedFilename: id, state: state,
                     receivedBytes: received, totalBytes: 100, startDate: started,
                     endDate: state == .complete ? now : nil)
    }

    /// Start: progress badge and one flight. Done: the file's icon, then nothing.
    func testBadgeFollowsADownload() async throws {
        let (model, engine) = makeModel()
        defer { model.stop() }
        let shelf = model.sidebar.downloadsShelf
        let profile = try XCTUnwrap(model.sidebar.currentProfileID)
        var flights: [String] = []
        let subscription = shelf.flights.sink { flights.append($0) }
        defer { subscription.cancel() }

        engine.fakeDownloadService.simulateDownload(item("a", profile: profile, state: .inProgress, started: now))
        try await waitUntil { shelf.badge != nil }
        XCTAssertEqual(shelf.badge, .progress(id: "a", progress: 0.5))
        XCTAssertEqual(flights, ["a"])

        // The engine reports the same download, now finished.
        engine.fakeDownloadService.simulateDownload(item("a", profile: profile, state: .complete, received: 100, started: now))
        try await waitUntil { if case .finished = shelf.badge { return true } else { return false } }
        XCTAssertEqual(shelf.badge, .finished(id: "a", file: URL(fileURLWithPath: "/tmp/a")))
        try await waitUntil { shelf.badge == nil }
        XCTAssertEqual(flights, ["a"], "no second flight")
    }

    /// Downloads that were already there (an old one, or one that started long ago) do not fly.
    func testNoFlightForOldDownloads() async throws {
        let (model, engine) = makeModel()
        defer { model.stop() }
        let shelf = model.sidebar.downloadsShelf
        let profile = try XCTUnwrap(model.sidebar.currentProfileID)
        var flights: [String] = []
        let subscription = shelf.flights.sink { flights.append($0) }
        defer { subscription.cancel() }
        engine.fakeDownloadService.simulateDownload(item("old", profile: profile, state: .complete, started: now.addingTimeInterval(-600)))
        engine.fakeDownloadService.simulateDownload(item("slow", profile: profile, state: .inProgress, started: now.addingTimeInterval(-60)))
        try await waitUntil { shelf.entries.count == 2 }
        XCTAssertTrue(flights.isEmpty)
        XCTAssertEqual(shelf.badge, .progress(id: "slow", progress: 0.5))
    }
}
