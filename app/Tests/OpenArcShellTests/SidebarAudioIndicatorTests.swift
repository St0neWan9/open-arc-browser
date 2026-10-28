import XCTest
import OpenArcModel
import OpenArcEngine
@testable import OpenArcShell

/// `docs/arc-spec/05-surfaces.md` tab audio indicator (E26, observed): a speaker glyph between
/// the favicon and the title while the tab plays sound; a click mutes it (crossed-out speaker that
/// stays while muted) and a second click unmutes; it stays when another tab is selected; a click on
/// it does not select the row.
@MainActor
final class SidebarAudioIndicatorTests: XCTestCase {

    /// 05 tab audio indicator: glyph per state (none / waves / crossed out) and its accessibility.
    func testGlyphPerState() {
        XCTAssertNil(SidebarAudioIndicator(isAudible: false, isMuted: false))
        XCTAssertEqual(SidebarAudioIndicator(isAudible: true, isMuted: false), .playing)
        XCTAssertEqual(SidebarAudioIndicator(isAudible: true, isMuted: true), .muted)
        XCTAssertEqual(SidebarAudioIndicator(isAudible: false, isMuted: true), .muted, "stays while muted")
        XCTAssertEqual(SidebarAudioIndicator.playing.symbol, "speaker.wave.2.fill")
        XCTAssertEqual(SidebarAudioIndicator.muted.symbol, "speaker.slash.fill")
        XCTAssertEqual(SidebarAudioIndicator.playing.accessibilityLabel, "Mute tab")
        XCTAssertEqual(SidebarAudioIndicator.muted.accessibilityLabel, "Unmute tab")
        XCTAssertEqual(SidebarAudioIndicator.accessibilityIdentifier, "openarc.sidebar.row.audio")
    }

    /// 05 tab audio indicator: the speaker sits between the favicon and the title.
    func testPlacementBetweenFaviconAndTitle() {
        XCTAssertEqual(SidebarTabRowPart.leadingParts(audio: nil), [.icon, .title])
        XCTAssertEqual(SidebarTabRowPart.leadingParts(audio: .playing), [.icon, .audio(.playing), .title])
        XCTAssertEqual(SidebarTabRowPart.leadingParts(audio: .muted), [.icon, .audio(.muted), .title])
    }

    /// 05 tab audio indicator: a click mutes (crossed out), a second click unmutes; the glyph stays
    /// when another tab is selected, and the click never changes the selection.
    func testClickTogglesMuteWithoutSelecting() async throws {
        let f = SidebarFixture()
        let (vm, _) = makeSidebarViewModel(f)
        vm.selectTab(f.today1)
        await vm.settleEngineWork()
        let live = try XCTUnwrap(vm.liveTab(for: f.today1) as? FakeTab)
        XCTAssertNil(vm.audioIndicator(for: f.today1))

        live.simulateAudio(true)
        try await waitUntil(vm) { vm.audioIndicator(for: f.today1) == .playing }

        vm.selectTab(f.today2)
        await vm.settleEngineWork()
        XCTAssertEqual(vm.audioIndicator(for: f.today1), .playing, "stays when another tab is selected")

        vm.audioIndicatorClicked(f.today1)
        try await waitUntil(vm) { vm.audioIndicator(for: f.today1) == .muted }
        let muted = await live.currentState()
        XCTAssertTrue(muted.audio.isMuted)
        XCTAssertEqual(vm.selectedTabID, f.today2, "the click does not select the row")

        live.simulateAudio(false)
        await vm.settleEngineWork()
        XCTAssertEqual(vm.audioIndicator(for: f.today1), .muted, "stays while muted")

        vm.audioIndicatorClicked(f.today1)
        try await waitUntil(vm) { vm.audioIndicator(for: f.today1) == nil }
        let unmuted = await live.currentState()
        XCTAssertFalse(unmuted.audio.isMuted)
        XCTAssertEqual(vm.selectedTabID, f.today2)
        vm.stop()
    }

    /// 05 tab audio indicator: a press on the glyph does not select the row (the press-to-select
    /// monitor skips it), while the rest of the row still selects on press.
    func testPressOnGlyphDoesNotSelect() {
        let row = CGRect(x: 0, y: 200, width: 276, height: 41)
        let glyph = CGRect(x: 43, y: 200, width: 20, height: 24)
        var select = row
        select.size.width -= 38
        let item = SidebarDragSourceItem(item: .tab(SidebarFixture.id(40)), frame: row, selectRect: select, clickOnlyRects: [glyph])
        XCTAssertFalse(item.selects(at: CGPoint(x: 50, y: 210)), "speaker")
        XCTAssertTrue(item.selects(at: CGPoint(x: 25, y: 210)), "favicon")
        XCTAssertTrue(item.selects(at: CGPoint(x: 120, y: 210)), "title")
        XCTAssertFalse(item.selects(at: CGPoint(x: 260, y: 210)), "hover ✕ area")

        let f = SidebarFixture()
        let snap = SidebarSnapshot.make(workspace: f.ws, spaceID: f.home, profileID: f.profile)
        let frames = SidebarLayout().listItemFrames(snap.listKinds)
        var rowFrames: [UUID: CGRect] = [:]
        var index = 0
        for entry in snap.pinned { rowFrames[entry.id] = frames[index]; index += 1 }
        let items = SidebarDragSourceItem.make(snapshot: snap, rowFrames: rowFrames, listViewport: .null,
                                               favoriteSlots: [], accessoryWidth: 38,
                                               audioGlyphFrames: [CGRect(x: 43, y: frames[0].minY + 8, width: 20, height: 24)])
        XCTAssertEqual(items.first?.clickOnlyRects.count, 1, "glyph attached to its own row")
        XCTAssertEqual(items.dropFirst().filter { !$0.clickOnlyRects.isEmpty }.count, 0)
    }

    private func waitUntil(_ vm: SidebarViewModel, _ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<400 {
            if condition() { return }
            await vm.settleEngineWork()
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }
}
