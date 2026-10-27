import Foundation
import XCTest
@testable import OpenArcPersistence

/// Per-device UI state file (`ui-state.json`): never part of the synced workspace.
final class UIStateTests: XCTestCase {
    private let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/b2-tmp", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { UIStateFile.url(in: directory) }

    func testRoundTrip() throws {
        let state = UIState(selectedSpaceID: Fx.uuid(1), selectedTabID: Fx.uuid(2), isSidebarVisible: false)
        try UIStateFile.save(state, to: directory)
        XCTAssertEqual(UIStateFile.load(from: directory), state)
        XCTAssertEqual(fileURL.lastPathComponent, "ui-state.json")
        XCTAssertNotEqual(fileURL.lastPathComponent, PersistenceDefaults.workspaceFileName)
    }

    func testMissingFileLoadsNil() {
        XCTAssertNil(UIStateFile.load(from: directory))
    }

    func testCorruptFileLoadsNilAndIsReplacedOnSave() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertNil(UIStateFile.load(from: directory))
        try UIStateFile.save(UIState(), to: directory)
        XCTAssertEqual(UIStateFile.load(from: directory), UIState())
    }

    func testNewerVersionIsIgnored() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version": 99, "isSidebarVisible": false}"#.utf8).write(to: fileURL)
        XCTAssertNil(UIStateFile.load(from: directory))
    }

    func testMissingKeysFallBackToDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let space = Fx.uuid(7)
        try Data(#"{"selectedSpaceID": "\#(space.uuidString)"}"#.utf8).write(to: fileURL)
        let loaded = try XCTUnwrap(UIStateFile.load(from: directory))
        XCTAssertEqual(loaded.selectedSpaceID, space)
        XCTAssertNil(loaded.selectedTabID)
        XCTAssertTrue(loaded.isSidebarVisible)
        XCTAssertEqual(loaded.version, UIState.currentVersion)
    }

    /// B22: the Library flags round-trip. [06 §8] observed (intro card, sections); persistence inferred.
    func testRoundTripWithLibraryFlags() throws {
        let state = UIState(selectedSpaceID: Fx.uuid(1), mediaIntroDismissed: true, lastLibrarySection: "archivedTabs")
        try UIStateFile.save(state, to: directory)
        let loaded = try XCTUnwrap(UIStateFile.load(from: directory))
        XCTAssertEqual(loaded, state)
        XCTAssertTrue(loaded.mediaIntroDismissed)
        XCTAssertEqual(loaded.lastLibrarySection, "archivedTabs")
    }

    /// B22: a file written before the Library flags existed still loads, with their defaults.
    func testFileWithoutLibraryFlagsLoadsDefaults() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"version": 1, "isSidebarVisible": false}"#.utf8).write(to: fileURL)
        let loaded = try XCTUnwrap(UIStateFile.load(from: directory))
        XCTAssertFalse(loaded.isSidebarVisible)
        XCTAssertFalse(loaded.mediaIntroDismissed)
        XCTAssertNil(loaded.lastLibrarySection)
    }

    /// B14: two windows round-trip; the top-level fields copy the first window so an older build
    /// still restores it. inferred (the spec records no launch behavior).
    func testTwoWindowsRoundTrip() throws {
        let a = WindowUIState(selectedSpaceID: Fx.uuid(1), selectedTabID: Fx.uuid(2), isSidebarVisible: false)
        let b = WindowUIState(selectedSpaceID: Fx.uuid(3), selectedTabID: nil, isSidebarVisible: true)
        let state = UIState(windows: [a, b], mediaIntroDismissed: true, lastLibrarySection: "downloads")
        try UIStateFile.save(state, to: directory)
        let loaded = try XCTUnwrap(UIStateFile.load(from: directory))
        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.restorableWindows, [a, b])
        XCTAssertEqual(loaded.selectedSpaceID, Fx.uuid(1))
        XCTAssertEqual(loaded.selectedTabID, Fx.uuid(2))
        XCTAssertFalse(loaded.isSidebarVisible)
        XCTAssertTrue(loaded.mediaIntroDismissed)
    }

    /// A file from before B14 (no `windows`) restores one window from its top-level fields.
    func testFileWithoutWindowsRestoresOneWindow() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let space = Fx.uuid(7), tab = Fx.uuid(8)
        let json = #"{"version": 1, "selectedSpaceID": "\#(space.uuidString)", "selectedTabID": "\#(tab.uuidString)", "isSidebarVisible": false}"#
        try Data(json.utf8).write(to: fileURL)
        let loaded = try XCTUnwrap(UIStateFile.load(from: directory))
        XCTAssertTrue(loaded.windows.isEmpty)
        XCTAssertEqual(loaded.restorableWindows, [WindowUIState(selectedSpaceID: space, selectedTabID: tab, isSidebarVisible: false)])
    }

    /// `subscribe()` returns the current value and a stream of later changes, with no gap.
    func testSubscribeReturnsCurrentWorkspaceAndLaterEvents() async throws {
        let store = WorkspaceStore(directory: directory, scheduler: ManualAutosaveScheduler(), now: { Fx.t(0) })
        let first = try Sample.workspace()
        await store.update(first)
        let (current, events) = await store.subscribe()
        XCTAssertEqual(current, first)
        var second = first
        second.spaces[Sample.ids.space]?.name = "Renamed"
        await store.update(second)
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        XCTAssertEqual(event?.workspace, second)
        XCTAssertEqual(event?.pendingChanges, [.save(.init(type: .space, uuid: Sample.ids.space))])
    }
}
