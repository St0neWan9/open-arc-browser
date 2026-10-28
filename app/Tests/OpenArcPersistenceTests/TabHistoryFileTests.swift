import Foundation
import XCTest
@testable import OpenArcPersistence

/// Plan C20: `tab-history.plist`, the per-device file of saved back/forward lists
/// (`docs/arc-spec/03-settings.md` §Advanced, inferred (analysis)). Never part of the workspace.
final class TabHistoryFileTests: XCTestCase {
    private let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/c20-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripNextToTheWorkspaceFile() throws {
        let snapshot = TabHistorySnapshot(entries: [
            Fx.uuid(1): .init(url: URL(string: "https://a.example/x"), data: Data([1, 2, 3])),
            Fx.uuid(2): .init(url: nil, data: Data([4])),
        ])
        try TabHistoryFile.save(snapshot, to: directory)
        XCTAssertEqual(TabHistoryFile.load(from: directory), snapshot)
        let file = TabHistoryFile.url(in: directory)
        XCTAssertEqual(file.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertNotEqual(file.lastPathComponent, PersistenceDefaults.workspaceFileName)
        XCTAssertNotEqual(file.lastPathComponent, PersistenceDefaults.syncStateFileName)
    }

    func testEmptySnapshotRemovesTheFile() throws {
        try TabHistoryFile.save(TabHistorySnapshot(entries: [Fx.uuid(1): .init(url: nil, data: Data([1]))]), to: directory)
        try TabHistoryFile.save(TabHistorySnapshot(), to: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TabHistoryFile.url(in: directory).path))
        XCTAssertNil(TabHistoryFile.load(from: directory))
    }

    func testCorruptFileLoadsNil() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: TabHistoryFile.url(in: directory))
        XCTAssertNil(TabHistoryFile.load(from: directory))
    }
}
