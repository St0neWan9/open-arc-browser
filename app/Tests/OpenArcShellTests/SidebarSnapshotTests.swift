import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// What the sidebar draws. Spec: [06 §4] tab states, [06 §3] folders, [06 §13] new tab and reload.
final class SidebarSnapshotTests: XCTestCase {
    private let f = SidebarFixture()

    private func snapshot(_ ws: WorkspaceState? = nil, space: UUID? = nil) -> SidebarSnapshot {
        SidebarSnapshot.make(workspace: ws ?? f.ws, spaceID: space ?? f.home, profileID: f.profile)
    }

    /// [06 §3, §12] observed: folders nest, children are indented one level, collapsed folders
    /// hide their contents; the pinned tab comes after the folders.
    func testPinnedAreaOrderDepthAndCollapse() throws {
        let s = snapshot()
        XCTAssertEqual(s.pinned.map(\.id), [f.folderA, f.folderB, f.deepTab, f.inFolderTab, f.folderC, f.pinnedTab])
        XCTAssertEqual(s.pinned.map(\.depth), [0, 1, 2, 1, 0, 0])
        let collapsed = try TreeOps.setFolderExpanded(f.ws, id: f.folderA, isExpanded: false, now: f.now)
        XCTAssertEqual(snapshot(collapsed).pinned.map(\.id), [f.folderA, f.folderC, f.pinnedTab])
        XCTAssertTrue(s.hasPinnedContent)
    }

    /// [06 §13] observed: Today lists newest first; favorites are per profile, shared by spaces.
    func testTodayNewestFirstAndSharedFavorites() {
        XCTAssertEqual(snapshot().today.map(\.id), [f.today3, f.today2, f.today1])
        XCTAssertEqual(snapshot().favorites.map(\.id), [f.fav1, f.fav2])
        XCTAssertEqual(snapshot(space: f.work).favorites.map(\.id), [f.fav1, f.fav2])
        XCTAssertEqual(snapshot(space: f.work).today.map(\.id), [f.workTab])
    }

    /// [06 §4] observed: an empty space shows only "+ New Tab" and no divider.
    func testEmptySpaceHasNoDivider() throws {
        var ws = f.ws
        ws = try TreeOps.clearToday(ws, spaceID: f.work, now: f.now)
        let s = snapshot(ws, space: f.work)
        XCTAssertTrue(s.isEmptySpace)
        XCTAssertFalse(s.showsDivider)
        XCTAssertEqual(s.listKinds, [.newTabRow])
        XCTAssertFalse(s.canClear)
    }

    /// Pinned content but an empty Today: no divider; "+ New Tab" follows the pinned rows directly.
    /// [07 §1] observed row structure (B16: the reference shows no divider row then); inferred rule.
    func testPinnedOnlySpaceHasNoDivider() throws {
        let ws = try TreeOps.clearToday(f.ws, spaceID: f.home, now: f.now)
        let s = snapshot(ws)
        XCTAssertTrue(s.today.isEmpty)
        XCTAssertFalse(s.showsDivider)
        XCTAssertFalse(s.isEmptySpace)
        XCTAssertEqual(s.listKinds, Array(repeating: .row, count: 6) + [.newTabRow])
    }

    /// [06 §4] observed: once the space has tabs, the divider (with Clear) sits between pinned and Today.
    func testDividerBetweenPinnedAndToday() {
        let s = snapshot()
        XCTAssertTrue(s.showsDivider)
        XCTAssertTrue(s.canClear)
        // [07 §4] observed: "+ New Tab" right under the divider, at the top of Today.
        XCTAssertEqual(s.listKinds, Array(repeating: .row, count: 6) + [.divider, .newTabRow] + Array(repeating: .row, count: 3))
    }

    /// [06 §13] observed: while loading the reload button becomes stop; [06 §4] the URL box shows
    /// only the domain, green for secure pages; [05 §window hierarchy] empty box is a placeholder.
    func testReloadModeAndUrlBoxContent() {
        XCTAssertEqual(SidebarReloadMode.make(isLoading: true), .stop)
        XCTAssertEqual(SidebarReloadMode.make(isLoading: false), .reload)
        XCTAssertEqual(SidebarURLBoxContent.make(url: URL(string: "https://example.com/a/b?q=1")), .domain("example.com", isSecure: true))
        XCTAssertEqual(SidebarURLBoxContent.make(url: URL(string: "http://example.com")), .domain("example.com", isSecure: false))
        XCTAssertEqual(SidebarURLBoxContent.make(url: nil), .placeholder)
        XCTAssertEqual(SidebarURLBoxContent.placeholderText, "Search or Enter URL…")
    }

    /// Engine events drive the live state used by the loading and audible row states.
    func testLiveStateReducer() {
        var live = SidebarTabLiveState()
        live.apply(.loadStateChanged(LoadState(isLoading: true, progress: 0.2)))
        XCTAssertTrue(live.isLoading)
        live.apply(.audioStateChanged(AudioState(isAudible: true, isMuted: false)))
        XCTAssertTrue(live.isAudible)
        // A snapshot is the full engine state, audio included.
        live.apply(.snapshot(BrowserTabState(url: URL(string: "https://a.example"), title: "A", loadState: .idle, navigation: NavigationState(canGoBack: true, canGoForward: false), audio: AudioState(isAudible: true, isMuted: true))))
        XCTAssertFalse(live.isLoading)
        XCTAssertTrue(live.isAudible)
        XCTAssertTrue(live.isMuted)
        XCTAssertEqual(live.title, "A")
        XCTAssertTrue(live.canGoBack)
        live.apply(.renderProcessGone)
        XCTAssertTrue(live.isCrashed)
        live.apply(.closed)
        XCTAssertFalse(live.isAudible)
    }
}
