import Foundation
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// Deterministic sample workspace for the sidebar tests.
///
/// Home space layout (display order):
///   favorites : fav1, fav2
///   pinned    : folderA (expanded) { folderB (expanded) { deepTab }, inFolderTab }, folderC (empty, expanded), pinnedTab
///   Today     : today3, today2, today1   (newest on top)
/// Work space has one Today tab (`workTab`).
struct SidebarFixture {
    var ws = WorkspaceState()
    let now = Date(timeIntervalSince1970: 1_000)

    let profile = SidebarFixture.id(1)
    let home = SidebarFixture.id(2)
    let work = SidebarFixture.id(3)
    let fav1 = SidebarFixture.id(10), fav2 = SidebarFixture.id(11)
    let folderA = SidebarFixture.id(20), folderB = SidebarFixture.id(21), folderC = SidebarFixture.id(22)
    let pinnedTab = SidebarFixture.id(30), inFolderTab = SidebarFixture.id(31), deepTab = SidebarFixture.id(32)
    let today1 = SidebarFixture.id(40), today2 = SidebarFixture.id(41), today3 = SidebarFixture.id(42)
    let workTab = SidebarFixture.id(50)

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    init() {
        do {
            ws.profiles[profile] = Profile(id: profile, name: "Default", now: now)
            ws = try TreeOps.createSpace(ws, id: home, profileID: profile, name: "Home", now: now)
            ws = try TreeOps.createSpace(ws, id: work, profileID: profile, name: "Work", afterSpaceID: home, now: now)
            // Order matters: createFolder goes to the top, so create C first, then A (A ends up above C).
            ws = try TreeOps.createFolder(ws, id: folderC, spaceID: home, title: "C", now: now)
            ws = try TreeOps.createFolder(ws, id: folderA, spaceID: home, title: "A", now: now)
            ws = try TreeOps.createFolder(ws, id: folderB, spaceID: home, parentFolderID: folderA, title: "B", now: now)
            try addTab(pinnedTab, "pinned.example.com", home, to: .pinned(spaceID: home, folderID: nil))
            try addTab(inFolderTab, "infolder.example.com", home, to: .pinned(spaceID: home, folderID: folderA))
            try addTab(deepTab, "deep.example.com", home, to: .pinned(spaceID: home, folderID: folderB))
            try addTab(fav1, "fav1.example.com", home, to: .favorite(profileID: profile))
            try addTab(fav2, "fav2.example.com", home, to: .favorite(profileID: profile))
            ws = try TreeOps.openTab(ws, id: today1, spaceID: home, url: URL(string: "https://today1.example.com"), title: "today1", now: now)
            ws = try TreeOps.openTab(ws, id: today2, spaceID: home, url: URL(string: "https://today2.example.com"), title: "today2", now: now)
            ws = try TreeOps.openTab(ws, id: today3, spaceID: home, url: URL(string: "http://today3.example.com"), title: "today3", now: now)
            ws = try TreeOps.openTab(ws, id: workTab, spaceID: work, url: URL(string: "https://work.example.com"), title: "work", now: now)
        } catch {
            fatalError("fixture is invalid: \(error)")
        }
    }

    private mutating func addTab(_ id: UUID, _ host: String, _ space: UUID, to location: TabLocation) throws {
        ws = try TreeOps.openTab(ws, id: id, spaceID: space, url: URL(string: "https://\(host)"), title: host, now: now)
        ws = try TreeOps.moveTab(ws, id: id, to: location, position: .last, now: now)
    }

    var allDraggables: [SidebarDragItem] {
        [fav1, fav2, pinnedTab, inFolderTab, deepTab, today1, today2, today3].map(SidebarDragItem.tab)
            + [folderA, folderB, folderC].map(SidebarDragItem.folder)
    }

    /// Ids in the order the pinned area shows them at the top level.
    func topLevelPinnedIDs() -> [UUID] {
        ws.pinnedChildren(spaceID: home, folderID: nil).map(\.id)
    }
}

/// Counter-based id source so view-model tests are deterministic.
final class SidebarIDSource {
    private var next = 1_000
    func make() -> UUID {
        next += 1
        return SidebarFixture.id(next)
    }
}

@MainActor
func makeSidebarViewModel(_ fixture: SidebarFixture = SidebarFixture(), engine: FakeEngine = FakeEngine()) -> (SidebarViewModel, SidebarIDSource) {
    let ids = SidebarIDSource()
    let vm = SidebarViewModel(
        engine: engine,
        workspace: fixture.ws,
        selectedSpaceID: fixture.home,
        now: { fixture.now.addingTimeInterval(10) },
        makeID: { ids.make() }
    )
    return (vm, ids)
}

extension AppPreferences {
    /// In-memory preferences with "Sync Sidebar" on. Since B73 the default is off (plan Q14), so
    /// tests of a running sync store turn it on explicitly.
    static func syncOn() -> AppPreferences {
        let preferences = AppPreferences.inMemory()
        preferences.isSidebarSyncEnabled = true
        return preferences
    }
}
