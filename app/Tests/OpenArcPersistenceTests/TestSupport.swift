import Foundation
import XCTest
import OpenArcModel
import OpenArcSyncAPI
@testable import OpenArcPersistence

/// Fixed clock values and ids for deterministic tests.
enum Fx {
    /// Fractional seconds check that timestamps survive the JSON round trip exactly.
    static func t(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + seconds + 0.123) }

    static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }
}

/// Collects autosave work instead of sleeping; tests fire it by hand.
// @unchecked: every mutable stored property is read and written only under `lock` (`Mutex` needs macOS 15).
final class ManualAutosaveScheduler: AutosaveScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () async -> Void] = []
    private var delays: [TimeInterval] = []

    var requestedDelays: [TimeInterval] { lock.withLock { delays } }

    func schedule(after delay: TimeInterval, _ work: @escaping @Sendable () async -> Void) {
        lock.lock()
        pending.append(work)
        delays.append(delay)
        lock.unlock()
    }

    var scheduledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return delays.count
    }

    /// Runs every scheduled work item (as if the delay elapsed).
    func fireAll() async {
        for item in takeAll() { await item() }
    }

    private func takeAll() -> [@Sendable () async -> Void] {
        lock.withLock {
            let work = pending
            pending = []
            return work
        }
    }
}

/// A unique directory under `app/.build/persistence-tmp`, removed by `cleanUp()`.
struct TempDirectory {
    let url: URL

    init() {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        url = packageRoot
            .appendingPathComponent(".build/persistence-tmp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }

    var workspaceFile: URL { url.appendingPathComponent(PersistenceDefaults.workspaceFileName) }

    func contents() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }
}

/// A workspace that contains every record type, including tombstones, built with `TreeOps`.
enum Sample {
    struct IDs {
        let profile = Fx.uuid(1)
        let theme = Fx.uuid(2)
        let space = Fx.uuid(3)
        let deletedSpace = Fx.uuid(4)
        let folder = Fx.uuid(5)
        let deletedSpaceFolder = Fx.uuid(6)
        let pinnedTab = Fx.uuid(10)
        let todayTab = Fx.uuid(11)
        let favoriteTab = Fx.uuid(12)
        let archivedTab = Fx.uuid(13)
        let splitTab = Fx.uuid(14)
        let deletedSpaceTab = Fx.uuid(15)
        let split = Fx.uuid(20)
    }

    static let ids = IDs()

    static func workspace() throws -> WorkspaceState {
        let i = ids
        var s = TreeOps.createProfile(WorkspaceState(), id: i.profile, name: "Personal", now: Fx.t(0))
        s = try TreeOps.updateProfileSettings(
            s, id: i.profile, settings: ProfileSettings(searchEngine: .bing, todayLifetime: 24 * 3600), now: Fx.t(0)
        )
        s.themes[i.theme] = Theme(
            id: i.theme,
            appearance: .dark,
            colors: [RGBAColor(hex: 0x6E5BD6), RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.5)],
            grain: 0.25,
            brightness: 0.7,
            now: Fx.t(0)
        )
        s = try TreeOps.createSpace(s, id: i.space, profileID: i.profile, name: "Home", icon: "🏠", themeID: i.theme, now: Fx.t(1))
        s = try TreeOps.createSpace(s, id: i.deletedSpace, profileID: i.profile, name: "Old", now: Fx.t(2))
        s = try TreeOps.createFolder(s, id: i.folder, spaceID: i.space, title: "Reading", now: Fx.t(3))
        s = try TreeOps.createFolder(s, id: i.deletedSpaceFolder, spaceID: i.deletedSpace, title: "Gone", now: Fx.t(3))
        s = try TreeOps.openTab(s, id: i.pinnedTab, spaceID: i.space, url: URL(string: "https://pinned.example"), title: "Pinned", now: Fx.t(4))
        s = try TreeOps.moveTab(s, id: i.pinnedTab, to: .pinned(spaceID: i.space, folderID: i.folder), position: .first, now: Fx.t(5))
        s = try TreeOps.renameTab(s, id: i.pinnedTab, customTitle: "My pinned", now: Fx.t(6))
        s = try TreeOps.openTab(s, id: i.todayTab, spaceID: i.space, url: URL(string: "https://today.example/a?b=c"), title: "Today", now: Fx.t(7))
        s = try TreeOps.openTab(s, id: i.favoriteTab, spaceID: i.space, url: URL(string: "https://fav.example"), title: "Fav", now: Fx.t(8))
        s = try TreeOps.moveTab(s, id: i.favoriteTab, to: .favorite(profileID: i.profile), position: .last, now: Fx.t(9))
        s = try TreeOps.openTab(s, id: i.archivedTab, spaceID: i.space, url: URL(string: "https://archived.example"), title: "Archived", now: Fx.t(10))
        s = try TreeOps.archiveTab(s, id: i.archivedTab, now: Fx.t(11))
        s = try TreeOps.openTab(s, id: i.splitTab, spaceID: i.space, url: nil, title: "New Tab", now: Fx.t(12))
        s = try TreeOps.addSplitPane(s, layoutID: i.split, existingTabID: i.todayTab, newTabID: i.splitTab, now: Fx.t(13))
        s = try TreeOps.openTab(s, id: i.deletedSpaceTab, spaceID: i.deletedSpace, url: URL(string: "https://old.example"), title: "Old", now: Fx.t(14))
        s = try TreeOps.deleteSpace(s, id: i.deletedSpace, now: Fx.t(15))
        // Opaque backend data must survive untouched.
        s.tabs[i.todayTab]?.meta.backendSystemFields = Data([0xDE, 0xAD, 0xBE, 0xEF])
        return s
    }
}

extension XCTestCase {
    /// Waits (without sleeping) until the actor reports a condition, by yielding repeatedly.
    func eventually(
        _ condition: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition not met", file: file, line: line)
    }
}
